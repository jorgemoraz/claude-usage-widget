package info.jorgemora.claudeusage

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient

/** Ventana para iniciar sesión. La sesión queda guardada en la app, no se copia a ningún sitio. */
class LoginActivity : Activity() {
    private lateinit var web: WebView

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
        bar.addView(TextView(this).apply {
            text = "Inicia sesión y pulsa Listo"
            setTextColor(Color.WHITE)
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        bar.addView(Button(this).apply {
            text = "Listo"
            isAllCaps = false
            setOnClickListener {
                CookieManager.getInstance().flush()
                Scheduler.now(this@LoginActivity)
                finish()
            }
        })
        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            webViewClient = WebViewClient()
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
        root.addView(bar)
        root.addView(web)
        setContentView(root)
        web.loadUrl(intent.getStringExtra("url") ?: "https://claude.ai/login")
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (web.canGoBack()) web.goBack() else super.onBackPressed()
    }
}
