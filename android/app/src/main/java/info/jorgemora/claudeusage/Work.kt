package info.jorgemora.claudeusage

import android.content.Context
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
        Fetch.all(applicationContext)
        return Result.success()
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

    fun now(c: Context) {
        WorkManager.getInstance(c).enqueueUniqueWork(
            "usage_now", ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<UsageWorker>().setConstraints(net).build()
        )
    }
}
