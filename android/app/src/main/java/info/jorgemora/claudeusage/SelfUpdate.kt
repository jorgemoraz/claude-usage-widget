package info.jorgemora.claudeusage

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
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

/**
 * Actualización desde GitHub con el instalador oficial de Android (PackageInstaller).
 * La primera vez Android pide permiso para que esta app instale actualizaciones y una confirmación;
 * después, como la app ya es quien se instala a sí misma, Android 12+ deja actualizar sin preguntar.
 */
object SelfUpdate {
    const val API = "https://api.github.com/repos/jorgemoraz/claude-usage-widget/releases/tags/android-latest"
    private const val CHANNEL = "actualizaciones"
    private const val NOTIF = 77

    data class Release(val version: Int, val url: String, val name: String)

    fun current(c: Context): Int = runCatching {
        val i = c.packageManager.getPackageInfo(c.packageName, 0)
        if (Build.VERSION.SDK_INT >= 28) i.longVersionCode.toInt() else @Suppress("DEPRECATION") i.versionCode
    }.getOrDefault(0)

    private fun prefs(c: Context) = c.getSharedPreferences("update", Context.MODE_PRIVATE)
    fun status(c: Context): String? = prefs(c).getString("status", null)
    private fun setStatus(c: Context, s: String?) = prefs(c).edit().putString("status", s).apply()

    suspend fun latest(): Release? = withContext(Dispatchers.IO) {
        runCatching {
            val conn = URL(API).openConnection() as HttpURLConnection
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.setRequestProperty("User-Agent", "UsoDeClaude-Android")
            conn.connectTimeout = 10000; conn.readTimeout = 15000
            val o = JSONObject(conn.inputStream.bufferedReader().readText())
            val a = o.getJSONArray("assets").getJSONObject(0)
            val name = a.getString("name")
            val v = Regex("v(\\d+)\\.apk").find(name)?.groupValues?.get(1)?.toInt() ?: return@runCatching null
            Release(v, a.getString("browser_download_url"), name)
        }.getOrNull()
    }

    /** Descarga dentro de la app (sin navegador), siguiendo la redirección de GitHub */
    private suspend fun download(c: Context, r: Release, progress: (Int) -> Unit): File? = withContext(Dispatchers.IO) {
        runCatching {
            var url = URL(r.url)
            var conn: HttpURLConnection
            var hops = 0
            while (true) {
                conn = url.openConnection() as HttpURLConnection
                conn.instanceFollowRedirects = false
                conn.setRequestProperty("User-Agent", "UsoDeClaude-Android")
                conn.connectTimeout = 15000; conn.readTimeout = 30000
                val code = conn.responseCode
                if (code in 300..399 && hops++ < 5) { url = URL(url, conn.getHeaderField("Location")); conn.disconnect(); continue }
                if (code != 200) error("HTTP $code")
                break
            }
            val total = conn.contentLengthLong
            val f = File(c.cacheDir, "actualizacion.apk")
            var done = 0L
            var last = -1
            conn.inputStream.use { inp ->
                f.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = inp.read(buf); if (n < 0) break
                        out.write(buf, 0, n); done += n
                        if (total > 0) { val p = (100 * done / total).toInt(); if (p != last) { last = p; progress(p) } }
                    }
                }
            }
            if (f.length() < 500_000) error("descarga incompleta")
            f
        }.getOrNull()
    }

    fun canInstall(c: Context) = Build.VERSION.SDK_INT < 26 || c.packageManager.canRequestPackageInstalls()

    fun askPermission(a: Activity) {
        a.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${a.packageName}")))
    }

    /**
     * Busca, descarga e instala. Devuelve un texto para mostrar.
     * foreground: con la app abierta se puede mostrar la confirmación de Android directamente.
     */
    suspend fun run(c: Context, foreground: Boolean, progress: (String) -> Unit = {}): String {
        progress("Buscando actualizaciones…")
        val r = latest() ?: return "No he podido consultar GitHub"
        if (r.version <= current(c)) { setStatus(c, null); return "Tienes la última versión (${current(c)})" }
        if (!canInstall(c)) return "Hay versión nueva (${r.version}). Falta darle permiso a la app para instalarla"
        progress("Descargando la versión ${r.version}…")
        val f = download(c, r) { p -> progress("Descargando la versión ${r.version}… $p %") } ?: return "La descarga ha fallado; lo reintento luego"
        progress("Instalando la versión ${r.version}…")
        install(c, f, foreground)
        setStatus(c, "Instalando la versión ${r.version}")
        return "Instalando la versión ${r.version}…"
    }

    private fun install(c: Context, f: File, foreground: Boolean) {
        val pi = c.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(c.packageName)
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = pi.createSession(params)
        pi.openSession(id).use { s ->
            s.openWrite("app.apk", 0, f.length()).use { out -> f.inputStream().use { it.copyTo(out) }; s.fsync(out) }
            val intent = Intent(c, InstallResult::class.java).putExtra("fg", foreground)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            s.commit(PendingIntent.getBroadcast(c, id, intent, flags).intentSender)
        }
    }

    fun notify(c: Context, title: String, text: String, intent: Intent?) {
        val nm = c.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Actualizaciones", NotificationManager.IMPORTANCE_DEFAULT))
        val tap = intent ?: Intent(c, MainActivity::class.java)
        val pi = PendingIntent.getActivity(c, 5, tap.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) android.app.Notification.Builder(c, CHANNEL) else android.app.Notification.Builder(c)
        nm.notify(NOTIF, b.setSmallIcon(android.R.drawable.stat_sys_download_done).setContentTitle(title).setContentText(text)
            .setContentIntent(pi).setAutoCancel(true).build())
    }
}

/** Respuesta del instalador de Android */
class InstallResult : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val prefs = c.getSharedPreferences("update", Context.MODE_PRIVATE)
        when (i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = i.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                if (i.getBooleanExtra("fg", false)) {
                    runCatching { c.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        .onFailure { SelfUpdate.notify(c, "Actualización de Uso de Claude", "Toca para instalarla", confirm) }
                } else SelfUpdate.notify(c, "Actualización de Uso de Claude lista", "Toca para instalarla", confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> prefs.edit().remove("status").apply()
            else -> {
                val msg = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "error"
                prefs.edit().putString("status", "No se pudo instalar: $msg").apply()
            }
        }
    }
}
