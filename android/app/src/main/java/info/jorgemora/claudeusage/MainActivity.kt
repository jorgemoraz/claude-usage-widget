package info.jorgemora.claudeusage

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

class MainActivity : Activity() {
    companion object {
        const val APK_URL = "https://github.com/jorgemoraz/claude-usage-widget/releases/download/android-latest/UsoDeClaude.apk"
    }

    private val scope = MainScope()
    private lateinit var status: TextView
    private lateinit var mascot: ImageView
    private lateinit var updateButton: Button

    private fun dp(v: Int) = (v * resources.displayMetrics.density).roundToInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(24))
        }
        fun text(t: String, size: Float, color: Int = Color.WHITE, bold: Boolean = false) = TextView(this).apply {
            text = t
            textSize = size
            setTextColor(color)
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, dp(6), 0, dp(6))
        }
        fun button(t: String, onClick: () -> Unit) = Button(this).apply {
            text = t
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(0x26FFFFFF) }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(50)).apply { topMargin = dp(10) }
            setOnClickListener { onClick() }
        }

        mascot = ImageView(this).apply {
            setImageResource(R.drawable.mascot_tranquilo)
            layoutParams = LinearLayout.LayoutParams(dp(96), dp(96)).apply { gravity = Gravity.CENTER_HORIZONTAL }
        }
        root.addView(mascot)
        root.addView(text("Uso de Claude", 28f, bold = true).apply { gravity = Gravity.CENTER_HORIZONTAL })
        root.addView(text("Inicia sesión una vez en cada servicio. Entra con tu correo y escribe el código que te llega; no toques el enlace del correo, porque se abriría en otra app. La ventana se cierra sola al entrar.", 14f, 0xFFB8B0AE.toInt()))
        root.addView(button("Iniciar sesión en Claude") { login("https://claude.ai/login") })
        root.addView(button("Iniciar sesión en ChatGPT") { login("https://chatgpt.com/auth/login") })
        root.addView(button("Actualizar ahora") { refresh() })
        status = text("", 15f)
        root.addView(status)
        root.addView(text("Para añadir el widget: mantén pulsado el escritorio › Widgets › Uso de Claude. Tócalo para actualizar; toca la mascota para abrir esta pantalla.", 13f, 0xFF8F8786.toInt()))
        updateButton = button("Buscar versión nueva") { update() }
        root.addView(updateButton)
        root.addView(button("Plan B: instalar con el instalador de Android") {
            val apk = AppUpdater.cachedApk(this)
            if (apk == null) {
                updateButton.text = "Primero pulsa «Buscar versión nueva» para descargarla"
            } else {
                AppUpdater.openSystemInstaller(this, apk)
            }
        })

        setContentView(ScrollView(this).apply {
            setBackgroundColor(0xFF1C1817.toInt())
            fitsSystemWindows = true
            addView(root)
        })
        Scheduler.schedule(this)
    }

    override fun onResume() {
        super.onResume()
        show()
        refresh()
        scope.launch {
            AppUpdater.check(this@MainActivity)
            show()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun login(url: String) {
        startActivity(Intent(this, LoginActivity::class.java).putExtra("url", url))
    }

    private fun refresh() {
        status.text = "Actualizando…"
        scope.launch {
            Fetch.all(this@MainActivity)
            show()
        }
    }

    private fun update() {
        if (!AppUpdater.canInstall(this)) {
            updateButton.text = "Activa «Permitir de esta fuente» y vuelve"
            AppUpdater.askPermission(this)
            return
        }
        updateButton.text = "Comprobando…"
        scope.launch {
            val latest = AppUpdater.check(this@MainActivity)
            val cur = AppUpdater.current(this@MainActivity)
            if (latest == null) {
                updateButton.text = AppUpdater.lastResult(this@MainActivity) ?: "No pude comprobar"
                return@launch
            }
            if (latest <= cur) {
                updateButton.text = "Ya tienes la última versión ($cur)"
                return@launch
            }
            updateButton.text = "Descargando versión $latest…"
            val apk = AppUpdater.download(this@MainActivity)
            if (apk == null) {
                updateButton.text = AppUpdater.lastResult(this@MainActivity) ?: "No se pudo descargar"
                return@launch
            }
            updateButton.text = "Instalando versión $latest…"
            AppUpdater.install(this@MainActivity, apk)
        }
    }

    private fun show() {
        val result = AppUpdater.lastResult(this)
        updateButton.text = when {
            AppUpdater.hasUpdate(this) -> "Instalar versión nueva (${AppUpdater.latestKnown(this)})"
            else -> "Buscar versión nueva · tienes la ${AppUpdater.current(this)}"
        } + (result?.let { "\n$it" } ?: "")
        val claude = Store.rows(this, "claude")
        val gpt = Store.rows(this, "gpt")
        mascot.setImageResource(Mood.from(claude.maxOfOrNull { it.percent }).drawable)
        fun line(r: Row) = "  ${r.label}: ${r.percent.roundToInt()} %" +
            (r.resetAt?.takeIf { it > System.currentTimeMillis() }?.let { " · se reinicia ${hourText(it)}" } ?: "")
        val sb = StringBuilder()
        sb.append("CLAUDE\n")
        if (claude.isEmpty()) sb.append("  ").append(Store.error(this, "claude") ?: "Sin datos todavía").append("\n")
        claude.forEach { sb.append(line(it)).append("\n") }
        Store.error(this, "claude")?.takeIf { claude.isNotEmpty() }?.let { sb.append("  ⚠︎ ").append(it).append("\n") }
        sb.append("\nCHATGPT\n")
        if (gpt.isEmpty()) sb.append("  ").append(Store.error(this, "gpt") ?: "Sin datos todavía").append("\n")
        gpt.forEach { sb.append(line(it)).append("\n") }
        Store.error(this, "gpt")?.takeIf { gpt.isNotEmpty() }?.let { sb.append("  ⚠︎ ").append(it).append("\n") }
        status.text = sb.toString()
    }
}
