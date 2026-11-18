package info.jorgemora.claudeusage

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.work.ForegroundInfo
import androidx.work.OutOfQuotaPolicy
import kotlinx.coroutines.withTimeoutOrNull
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class UsageWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        // Si la consulta directa falla (Cloudflare, sesión caducada…), se repite desde dentro de la web
        runCatching { withTimeoutOrNull(150_000) { Fetch.all(applicationContext, foreground = true) } }
        runCatching { Widgets.updateAll(applicationContext) }
        // Como mucho cada 3 horas: buscar versión nueva e instalarla (sin preguntar si Android lo permite)
        val p = applicationContext.getSharedPreferences("update", Context.MODE_PRIVATE)
        if (System.currentTimeMillis() - p.getLong("checked", 0) > 3 * 3600_000 && SelfUpdate.canInstall(applicationContext)) {
            p.edit().putLong("checked", System.currentTimeMillis()).apply()
            runCatching { SelfUpdate.run(applicationContext, foreground = false) }
        }
        return Result.success()
    }

    /** Necesario para las tareas urgentes en Android 11 o anterior */
    override suspend fun getForegroundInfo(): ForegroundInfo {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel("consulta", "Consulta del uso", NotificationManager.IMPORTANCE_MIN))
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(applicationContext, "consulta") else Notification.Builder(applicationContext)
        return ForegroundInfo(78, b.setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("Actualizando el uso…").build())
    }
}

object Scheduler {
    private val net = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /** Cada 15 minutos (el mínimo que permite Android) */
    fun schedule(c: Context) {
        WorkManager.getInstance(c).enqueueUniquePeriodicWork(
            "usage", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<UsageWorker>(15, TimeUnit.MINUTES).setConstraints(net).build()
        )
    }

    /** Ya: tarea urgente (expedited), para el toque en el widget */
    fun now(c: Context) {
        WorkManager.getInstance(c).enqueueUniqueWork(
            "usage_now", ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<UsageWorker>().setConstraints(net)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST).build()
        )
    }

    /** Pronto, sin cortar una consulta que ya esté en marcha */
    fun soon(c: Context) {
        WorkManager.getInstance(c).enqueueUniqueWork(
            "usage_now", ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<UsageWorker>().setConstraints(net).build()
        )
    }
}
