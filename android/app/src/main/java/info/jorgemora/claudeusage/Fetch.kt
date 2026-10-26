package info.jorgemora.claudeusage

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.resume

/** Resultado de una consulta: código HTTP y cuerpo */
data class Res(val status: Int, val body: String)

/**
 * Consulta directa con la sesión guardada (cookies de la app). Funciona en segundo plano,
 * sin abrir ningún navegador. Es la vía que usa el widget.
 */
object Http {
    private fun get(url: String, ua: String, cookie: String?, headers: Map<String, String> = emptyMap()): Res {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = 8000
        conn.readTimeout = 10000
        conn.setRequestProperty("User-Agent", ua)
        conn.setRequestProperty("Accept", "application/json")
        if (cookie != null) conn.setRequestProperty("Cookie", cookie)
        headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
        val code = conn.responseCode
        val body = runCatching { (if (code < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.readText() }
            .getOrNull() ?: ""
        conn.disconnect()
        return Res(code, body)
    }

    suspend fun claude(c: Context): Res = withContext(Dispatchers.IO) {
        val ua = browserUA(c)
        val cookie = CookieManager.getInstance().getCookie("https://claude.ai")
            ?: return@withContext Res(401, "")
        val orgs = get("https://claude.ai/api/organizations", ua, cookie)
        if (orgs.status != 200) return@withContext orgs
        val list = JSONArray(orgs.body)
        var org: JSONObject? = null
        for (i in 0 until list.length()) {
            val o = list.getJSONObject(i)
            val caps = o.optJSONArray("capabilities")?.toString() ?: ""
            if (caps.contains("\"chat\"")) { org = o; break }
        }
        if (org == null && list.length() > 0) org = list.getJSONObject(0)
        val id = org?.optString("uuid") ?: return@withContext Res(404, "")
        get("https://claude.ai/api/organizations/$id/usage", ua, cookie)
    }

    suspend fun gpt(c: Context): Res = withContext(Dispatchers.IO) {
        val ua = browserUA(c)
        val cookie = CookieManager.getInstance().getCookie("https://chatgpt.com")
            ?: return@withContext Res(401, "")
        val s = get("https://chatgpt.com/api/auth/session", ua, cookie)
        if (s.status != 200) return@withContext s
        val session = runCatching { JSONObject(s.body) }.getOrNull() ?: return@withContext Res(401, "")
        val token = session.optString("accessToken").takeIf { it.isNotEmpty() } ?: return@withContext Res(401, "")
        val h = mutableMapOf("Authorization" to "Bearer $token")
        session.optJSONObject("account")?.optString("id")?.takeIf { it.isNotEmpty() }?.let { h["chatgpt-account-id"] = it }
        get("https://chatgpt.com/backend-api/wham/usage", ua, cookie, h)
    }
}

/**
 * Plan B, solo con la app abierta: la misma consulta hecha desde dentro de la web,
 * por si la web bloquea la consulta directa. Sin puentes JavaScript.
 */
object WebFetcher {
    @SuppressLint("SetJavaScriptEnabled")
    suspend fun run(ctx: Context, url: String, js: String, timeoutMs: Long = 40_000): Res? =
        withContext(Dispatchers.Main) {
            withTimeoutOrNull(timeoutMs) {
                suspendCancellableCoroutine { cont ->
                    val main = Handler(Looper.getMainLooper())
                    val wv = WebView(ctx)
                    var done = false
                    fun finish(r: Res?) {
                        if (done) return
                        done = true
                        wv.stopLoading()
                        wv.destroy()
                        if (cont.isActive) cont.resume(r)
                    }
                    wv.settings.javaScriptEnabled = true
                    wv.settings.domStorageEnabled = true
                    wv.settings.userAgentString = browserUA(ctx)
                    val start = "window.__uso = ''; (async () => { try { const r = await (async () => {" + js +
                        "})(); window.__uso = JSON.stringify(r); } catch (e) { window.__uso = JSON.stringify({status: -1, body: String(e)}); } })(); 'ok'"
                    fun poll(left: Int) {
                        if (done) return
                        wv.evaluateJavascript("window.__uso || ''") { v ->
                            // evaluateJavascript devuelve la cadena entrecomillada en JSON
                            val s = runCatching { JSONArray("[$v]").getString(0) }.getOrNull() ?: ""
                            if (s.isNotEmpty()) {
                                val o = runCatching { JSONObject(s) }.getOrNull()
                                finish(o?.let { Res(it.optInt("status"), it.optString("body")) })
                            } else if (left > 0) {
                                main.postDelayed({ poll(left - 1) }, 400)
                            } else finish(null)
                        }
                    }
                    var started = false
                    wv.webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, u: String) {
                            if (done || started) return
                            started = true
                            view.evaluateJavascript(start, null)
                            main.postDelayed({ poll(60) }, 400)
                        }
                    }
                    cont.invokeOnCancellation { main.post { finish(null) } }
                    wv.loadUrl(url)
                }
            }
        }
}

object Fetch {
    private const val CLAUDE_JS = """
        const o = await fetch('/api/organizations', {credentials: 'include'});
        if (o.status !== 200) return {status: o.status, body: ''};
        const orgs = await o.json();
        const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
        if (!org) return {status: 404, body: ''};
        const r = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
        return {status: r.status, body: await r.text()};
    """

    private const val GPT_JS = """
        const sr = await fetch('/api/auth/session', {credentials: 'include'});
        const s = sr.status === 200 ? await sr.json() : null;
        if (!s || !s.accessToken) return {status: 401, body: ''};
        const h = {'Authorization': 'Bearer ' + s.accessToken};
        if (s.account && s.account.id) h['chatgpt-account-id'] = s.account.id;
        const r = await fetch('/backend-api/wham/usage', {headers: h, credentials: 'include'});
        return {status: r.status, body: await r.text()};
    """

    private fun handle(c: Context, key: String, site: String, res: Res?, parse: (String) -> List<Row>) {
        if (res == null) return Store.save(c, key, null, "Sin respuesta de $site")
        try {
            when (res.status) {
                401 -> Store.save(c, key, null, "Inicia sesión en $site desde la app")
                403 -> Store.save(c, key, null, "$site bloqueó la consulta (403). Abre la app")
                200 -> Store.save(c, key, parse(res.body), null)
                else -> Store.save(c, key, null, "Error ${res.status} de $site")
            }
        } catch (e: Exception) {
            Store.save(c, key, null, e.message ?: "Error")
        }
    }

    /**
     * foreground = true cuando la app está abierta: si la consulta directa falla,
     * se reintenta desde dentro de la web.
     */
    /** Al tocar el widget: Claude y ChatGPT a la vez, por la vía directa (sin navegador) */
    suspend fun quick(c: Context) {
        coroutineScope {
            val r = async { runCatching { Http.claude(c) }.getOrNull() }
            val g = async { runCatching { Http.gpt(c) }.getOrNull() }
            handle(c, "claude", "claude.ai", r.await(), Parse::claude)
            handle(c, "gpt", "chatgpt.com", g.await(), Parse::gpt)
        }
        runCatching { UsageWidget.updateAll(c) }
    }

    suspend fun all(c: Context, foreground: Boolean = false) {
        runCatching {
            var r = runCatching { Http.claude(c) }.getOrNull()
            if (foreground && (r == null || r.status != 200)) r = WebFetcher.run(c, "https://claude.ai/", CLAUDE_JS) ?: r
            handle(c, "claude", "claude.ai", r, Parse::claude)

            var g = runCatching { Http.gpt(c) }.getOrNull()
            if (foreground && (g == null || g.status != 200)) g = WebFetcher.run(c, "https://chatgpt.com/", GPT_JS) ?: g
            handle(c, "gpt", "chatgpt.com", g, Parse::gpt)
        }
        runCatching { UsageWidget.updateAll(c) }
    }
}
