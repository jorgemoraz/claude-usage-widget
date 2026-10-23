package info.jorgemora.claudeusage

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Actualización desde GitHub.
 * - Android 12 o superior: la app puede actualizarse a sí misma sin preguntar si ya tiene el permiso
 *   «Instalar apps desconocidas» (se intenta en segundo plano).
 * - Si Android exige confirmación, se guarda como pendiente y se pide al abrir la app.
 * - Plan B: abrir el instalador del sistema con el APK descargado.
 */
object AppUpdater {
    private const val API = "https://api.github.com/repos/jorgemoraz/claude-usage-widget/releases/tags/android-latest"

    fun current(c: Context): Long {
        val info = c.packageManager.getPackageInfo(c.packageName, 0)
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    }

    private fun prefs(c: Context) = c.getSharedPreferences("usage", Context.MODE_PRIVATE)
    fun latestKnown(c: Context): Long = prefs(c).getLong("latest_version", 0)
    fun hasUpdate(c: Context): Boolean = latestKnown(c) > current(c)
    fun lastResult(c: Context): String? = prefs(c).getString("install_result", null)
    fun setResult(c: Context, s: String?) = prefs(c).edit().putString("install_result", s).apply()
    fun canInstall(c: Context): Boolean = Build.VERSION.SDK_INT < 26 || c.packageManager.canRequestPackageInstalls()

    suspend fun check(c: Context): Long? = withContext(Dispatchers.IO) {
        runCatching {
            val conn = URL(API).openConnection() as HttpURLConnection
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.setRequestProperty("User-Agent", "UsoDeClaude-Android")
            conn.connectTimeout = 15000
            conn.readTimeout = 15000
            val name = JSONObject(conn.inputStream.bufferedReader().readText()).optString("name")
            Regex("(\\d+)\\)?\\s*$").find(name)?.groupValues?.get(1)?.toLong()
        }.onFailure { setResult(c, "No pude consultar GitHub: ${it.message}") }
            .getOrNull()?.also { prefs(c).edit().putLong("latest_version", it).apply() }
    }

    suspend fun download(c: Context): File? = withContext(Dispatchers.IO) {
        runCatching {
            var url = URL(MainActivity.APK_URL)
            var conn: HttpURLConnection
            // Sigue las redirecciones de GitHub a su almacén de archivos
            var hops = 0
            while (true) {
                conn = url.openConnection() as HttpURLConnection
                conn.instanceFollowRedirects = false
                conn.setRequestProperty("User-Agent", "UsoDeClaude-Android")
                conn.connectTimeout = 20000
                conn.readTimeout = 60000
                val code = conn.responseCode
                if (code in 300..399 && hops++ < 5) {
                    url = URL(url, conn.getHeaderField("Location"))
                    conn.disconnect()
                    continue
                }
                if (code != 200) throw IllegalStateException("HTTP $code")
                break
            }
            val f = File(c.cacheDir, "UsoDeClaude.apk")
            conn.inputStream.use { input -> f.outputStream().use { input.copyTo(it) } }
            if (f.length() < 100_000) throw IllegalStateException("archivo incompleto")
            f
        }.onFailure { setResult(c, "No pude descargar: ${it.message}") }.getOrNull()
    }

    fun askPermission(a: Activity) {
        a.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + a.packageName)))
    }

    /** Instala con PackageInstaller (sin preguntar cuando Android lo permite). */
    fun install(c: Context, apk: File) {
        runCatching {
            val installer = c.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            params.setAppPackageName(c.packageName)
            val id = installer.createSession(params)
            installer.openSession(id).use { s ->
                apk.inputStream().use { input ->
                    s.openWrite("UsoDeClaude.apk", 0, apk.length()).use { out ->
                        input.copyTo(out)
                        s.fsync(out)
                    }
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val pi = PendingIntent.getBroadcast(c, 3, Intent(c, InstallReceiver::class.java).setPackage(c.packageName), flags)
                s.commit(pi.intentSender)
            }
            setResult(c, "Instalando…")
        }.onFailure { setResult(c, "Error al instalar: ${it.message}") }
    }

    /** Plan B: abre el instalador de Android con el APK ya descargado. */
    fun openSystemInstaller(a: Activity, apk: File) {
        val uri = FileProvider.getUriForFile(a, "info.jorgemora.claudeusage.files", apk)
        a.startActivity(Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun cachedApk(c: Context): File? = File(c.cacheDir, "UsoDeClaude.apk").takeIf { it.exists() && it.length() > 100_000 }

    /** Desde el trabajo en segundo plano: descarga e intenta instalar sin molestar. */
    suspend fun backgroundUpdate(c: Context) {
        val latest = check(c) ?: return
        if (latest <= current(c) || !canInstall(c) || Build.VERSION.SDK_INT < 31) return
        val apk = download(c) ?: return
        install(c, apk)
    }
}

class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)
        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                AppUpdater.setResult(c, "Falta tu confirmación")
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                runCatching { c.startActivity(confirm) }
                    .onFailure { AppUpdater.setResult(c, "Abre la app para confirmar la actualización") }
            }
            PackageInstaller.STATUS_SUCCESS -> AppUpdater.setResult(c, "Actualizada")
            else -> AppUpdater.setResult(c, "Android rechazó la instalación ($status): ${msg ?: "sin detalle"}")
        }
    }
}
