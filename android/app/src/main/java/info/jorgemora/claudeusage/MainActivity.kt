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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

class MainActivity : Activity() {
    companion object {
        const val RELEASE_PAGE = "https://github.com/jorgemoraz/claude-usage-widget/releases/tag/android-latest"
        const val RELEASE_API = "https://api.github.com/repos/jorgemoraz/claude-usage-widget/releases/tags/android-latest"
    }

    private val scope = MainScope()
    private lateinit var status: TextView
    private lateinit var mascot: ImageView
    private lateinit var updateButton: Button
    private lateinit var moniButton: Button

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
        val ver = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: ""
        root.addView(text("Versión $ver", 13f, 0xFF8F8786.toInt()).apply { gravity = Gravity.CENTER_HORIZONTAL })
        root.addView(text("Inicia sesión una vez en cada servicio. Entra con tu correo y escribe el código que te llega; no toques el enlace del correo, porque se abriría en otra app. La ventana se cierra sola al entrar.", 14f, 0xFFB8B0AE.toInt()))
        root.addView(button("Iniciar sesión en Claude") { login("https://claude.ai/login") })
        root.addView(button("Iniciar sesión en ChatGPT") { login("https://chatgpt.com/auth/login") })
        root.addView(button("Actualizar ahora") { refresh() })
        moniButton = button("") { connectMoni() }
        root.addView(moniButton)
        status = text("", 18f)
        root.addView(status)
        root.addView(text("Para añadir el widget: mantén pulsado el escritorio › Widgets › Uso de Claude. Tócalo para actualizar; toca la mascota para abrir esta pantalla.", 13f, 0xFF8F8786.toInt()))
        updateButton = button("Descargar la última versión") { openLatest() }
        root.addView(updateButton)

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
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /** Gastos del mes: se pega el enlace con token que da el cerebro de Moni (o se escanea su QR y se copia). */
    private fun connectMoni() {
        if (Gastos.configured(this)) {
            android.app.AlertDialog.Builder(this)
                .setTitle("Gastos de Moni")
                .setItems(arrayOf("Abrir el panel de gastos", "Desconectar")) { _, i ->
                    if (i == 0) Gastos.panelUrl(this)?.let { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) }
                    else { Gastos.forget(this); show(); UsageWidget.updateAll(this) }
                }.show()
            return
        }
        val field = android.widget.EditText(this).apply { hint = "http://100.…:8765/gastos?token=…" }
        android.app.AlertDialog.Builder(this)
            .setTitle("Conectar con Moni")
            .setMessage("Pega el enlace que muestra el cerebro de Moni en el Mac (el QR). El móvil tiene que tener Tailscale encendido.")
            .setView(field)
            .setPositiveButton("Conectar") { _, _ ->
                if (Gastos.configure(this, field.text.toString())) refresh()
                else android.widget.Toast.makeText(this, "Ese enlace no vale", android.widget.Toast.LENGTH_LONG).show()
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    private fun login(url: String) {
        startActivity(Intent(this, LoginActivity::class.java).putExtra("url", url))
    }

    private fun refresh() {
        status.text = "Actualizando…"
        scope.launch {
            Fetch.all(this@MainActivity, foreground = true)
            show()
        }
    }

    /** Pide a GitHub el enlace exacto de la última versión (cada versión tiene nombre propio, sin cachés) */
    private fun openLatest() {
        updateButton.text = "Buscando la última versión…"
        scope.launch {
            val info = withContext(Dispatchers.IO) {
                runCatching {
                    val conn = java.net.URL(RELEASE_API).openConnection() as java.net.HttpURLConnection
                    conn.setRequestProperty("Accept", "application/vnd.github+json")
                    conn.setRequestProperty("User-Agent", "UsoDeClaude-Android")
                    val o = org.json.JSONObject(conn.inputStream.bufferedReader().readText())
                    val asset = o.getJSONArray("assets").getJSONObject(0)
                    Pair(o.optString("name"), asset.getString("browser_download_url"))
                }.getOrNull()
            }
            updateButton.text = "Descargar la última versión"
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(info?.second ?: RELEASE_PAGE)))
        }
    }

    private fun show() {
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
        moniButton.text = if (Gastos.configured(this)) "Gastos de Moni…" else "Conectar con Moni (gastos del mes)"
        if (Gastos.configured(this)) {
            sb.append("\nGASTOS DEL MES\n")
            val g = Gastos.spend(this)
            if (g != null) {
                sb.append("  Gastado: ${euros(g.spentEUR)} · previsto ${euros(g.forecastEUR)}\n")
                g.budgetUSD?.let { sb.append(String.format(java.util.Locale("es", "ES"), "  APIs: %.2f de %.0f $\n", g.apiUSD, it)) }
                sb.append("  Tokens: ${tokensText(g.tokens)} (${tokensText(g.tokensApps)} apps, ${tokensText(g.tokensAPIs)} APIs)\n")
                g.apps.forEach { (n, d) -> sb.append("    $n: $d\n") }
                g.apis.forEach { (n, d) -> sb.append("    $n: $d\n") }
                if (g.savedEUR > 0) sb.append("  Las suscripciones te ahorran ${euros(g.savedEUR)}\n")
            }
            Gastos.error(this)?.let { sb.append("  ⚠︎ ").append(it).append("\n") }
        }
        status.text = sb.toString()
    }
}
