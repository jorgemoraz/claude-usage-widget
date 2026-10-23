package info.jorgemora.claudeusage

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Agente de navegador normal (sin la marca «wv» de WebView, que algunas webs bloquean). */
fun browserUA(c: Context): String =
    WebSettings.getDefaultUserAgent(c).replace("; wv", "").replace(Regex("Version/\\S+ "), "")

/** Ventana para iniciar sesión. La sesión queda guardada en la app, no se copia a ningún sitio. */
class LoginActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var label: TextView
    private var closing = false

    private fun loggedIn(url: String): Boolean {
        val cm = CookieManager.getInstance()
        return if (url.contains("chatgpt.com")) {
            (cm.getCookie("https://chatgpt.com") ?: "").contains("session-token")
        } else {
            (cm.getCookie("https://claude.ai") ?: "").contains("sessionKey=")
        }
    }

    private fun done() {
        CookieManager.getInstance().flush()
        Scheduler.now(this)
        finish()
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val d = resources.displayMetrics.density
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            setBackgroundColor(0xFF1C1817.toInt())
        }
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding((14 * d).toInt(), (8 * d).toInt(), (8 * d).toInt(), (8 * d).toInt())
        }
        label = TextView(this).apply {
            text = "Inicia sesión con tu correo y el código"
            setTextColor(Color.WHITE)
            textSize = 14f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        bar.addView(label)
        bar.addView(Button(this).apply {
            text = "Listo"
            isAllCaps = false
            setOnClickListener { done() }
        })
        val start = intent.getStringExtra("url") ?: "https://claude.ai/login"
        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.userAgentString = browserUA(this@LoginActivity)
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val url = request.url.toString()
                    if (url.startsWith("http://") || url.startsWith("https://")) return false
                    // Enlaces a apps (intent://, claude://…): se usa la alternativa web o se ignoran
                    if (url.startsWith("intent:")) {
                        runCatching { Intent.parseUri(url, Intent.URI_INTENT_SCHEME) }.getOrNull()
                            ?.getStringExtra("browser_fallback_url")?.let { view.loadUrl(it) }
                    }
                    return true
                }

                override fun onPageFinished(view: WebView, url: String) {
                    val path = android.net.Uri.parse(url).path ?: ""
                    val onLogin = path.startsWith("/login") || path.startsWith("/auth") || path.contains("magic-link")
                    if (!onLogin && loggedIn(start) && !closing) {
                        closing = true
                        label.text = "✓ Sesión iniciada"
                        Handler(Looper.getMainLooper()).postDelayed({ done() }, 1200)
                    } else if (!closing) {
                        label.text = "Inicia sesión con tu correo y el código\n" + (android.net.Uri.parse(url).host ?: "") + path
                    }
                }
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
        root.addView(bar)
        root.addView(web)
        setContentView(root)
        web.loadUrl(start)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (web.canGoBack()) web.goBack() else done()
    }
}
