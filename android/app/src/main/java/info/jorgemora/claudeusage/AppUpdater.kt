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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** Busca versiones nuevas en GitHub y las instala (Android siempre pide confirmación al usuario). */
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

    suspend fun check(c: Context): Long? = withContext(Dispatchers.IO) {
        runCatching {
            val conn = URL(API).openConnection() as HttpURLConnection
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.connectTimeout = 15000
            conn.readTimeout = 15000
            val name = JSONObject(conn.inputStream.bufferedReader().readText()).optString("name")
            Regex("versión (\\d+)").find(name)?.groupValues?.get(1)?.toLong()
        }.getOrNull()?.also { prefs(c).edit().putLong("latest_version", it).apply() }
    }

    suspend fun download(c: Context): File? = withContext(Dispatchers.IO) {
        runCatching {
            val f = File(c.cacheDir, "UsoDeClaude.apk")
            val conn = URL(MainActivity.APK_URL).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = true
            conn.connectTimeout = 20000
            conn.readTimeout = 60000
            conn.inputStream.use { input -> f.outputStream().use { input.copyTo(it) } }
            f
        }.getOrNull()
    }

    /** Devuelve false si antes hay que dar permiso para instalar apps desde esta app. */
    fun ensurePermission(a: Activity): Boolean {
        if (Build.VERSION.SDK_INT >= 26 && !a.packageManager.canRequestPackageInstalls()) {
            a.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + a.packageName)))
            return false
        }
        return true
    }

    fun install(c: Context, apk: File) {
        val installer = c.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        val id = installer.createSession(params)
        installer.openSession(id).use { s ->
            apk.inputStream().use { input ->
                s.openWrite("UsoDeClaude.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    s.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val pi = PendingIntent.getBroadcast(c, 3, Intent(c, InstallReceiver::class.java), flags)
            s.commit(pi.intentSender)
        }
    }
}

class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        if (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1) == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            c.startActivity(confirm)
        }
    }
}
