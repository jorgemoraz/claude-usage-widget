package info.jorgemora.claudeusage

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import kotlin.coroutines.resume

/** Navegador invisible: abre la web con tu sesión y hace la consulta como lo haría la propia web. */
object WebFetcher {
    private class Bridge(val onResult: (String) -> Unit) {
        @JavascriptInterface
        fun post(s: String) = onResult(s)
    }

    @SuppressLint("SetJavaScriptEnabled")
    suspend fun run(ctx: Context, url: String, js: String, timeoutMs: Long = 40_000): String? =
        withContext(Dispatchers.Main) {
            withTimeoutOrNull(timeoutMs) {
                suspendCancellableCoroutine { cont ->
                    val main = Handler(Looper.getMainLooper())
                    val wv = WebView(ctx.applicationContext)
                    var done = false
                    fun finish(result: String?) {
                        main.post {
                            if (done) return@post
                            done = true
                            wv.stopLoading()
                            wv.destroy()
                            if (cont.isActive) cont.resume(result)
                        }
                    }
                    wv.settings.javaScriptEnabled = true
                    wv.settings.domStorageEnabled = true
                    wv.settings.userAgentString = browserUA(ctx)
                    wv.addJavascriptInterface(Bridge { finish(it) }, "Bridge")
                    val script = "(async () => { try { const r = await (async () => {" + js +
                        "})(); Bridge.post(JSON.stringify(r)); } catch (e) { Bridge.post(JSON.stringify({status: -1, body: String(e)})); } })();"
                    wv.webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, u: String) {
                            if (!done) view.evaluateJavascript(script, null)
                        }
                    }
                    cont.invokeOnCancellation { main.post { if (!done) { done = true; wv.destroy() } } }
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

    private fun handle(c: Context, key: String, site: String, res: String?, parse: (String) -> List<Row>) {
        if (res == null) return Store.save(c, key, null, "Sin respuesta de $site")
        try {
            val o = JSONObject(res)
            when (val st = o.optInt("status")) {
                401, 403 -> Store.save(c, key, null, "Inicia sesión en $site desde la app")
                200 -> Store.save(c, key, parse(o.optString("body")), null)
                else -> Store.save(c, key, null, "Error $st de $site")
            }
        } catch (e: Exception) {
            Store.save(c, key, null, e.message ?: "Error")
        }
    }

    suspend fun all(c: Context) {
        handle(c, "claude", "claude.ai", WebFetcher.run(c, "https://claude.ai/", CLAUDE_JS), Parse::claude)
        handle(c, "gpt", "chatgpt.com", WebFetcher.run(c, "https://chatgpt.com/", GPT_JS), Parse::gpt)
        AppUpdater.check(c)
        UsageWidget.updateAll(c)
    }
}
