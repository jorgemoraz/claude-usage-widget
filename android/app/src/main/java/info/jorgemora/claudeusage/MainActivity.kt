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
    private lateinit var list: LinearLayout
    private lateinit var openaiButton: Button
    private lateinit var sonioxButton: Button
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

        root.addView(text("Uso de Claude", 28f, bold = true).apply { gravity = Gravity.CENTER_HORIZONTAL })
        val ver = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: ""
        root.addView(text("Versión $ver", 13f, 0xFF8F8786.toInt()).apply { gravity = Gravity.CENTER_HORIZONTAL })
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(10), 0, dp(4)) }
        root.addView(list)
        root.addView(text("Inicia sesión una vez en cada servicio. Entra con tu correo y escribe el código que te llega; no toques el enlace del correo, porque se abriría en otra app. La ventana se cierra sola al entrar.", 14f, 0xFFB8B0AE.toInt()))
        root.addView(button("Iniciar sesión en Claude") { login("https://claude.ai/login") })
        root.addView(button("Iniciar sesión en ChatGPT") { login("https://chatgpt.com/auth/login") })
        openaiButton = button("") { openai() }
        root.addView(openaiButton)
        sonioxButton = button("") { soniox() }
        root.addView(sonioxButton)
        root.addView(button("Actualizar ahora") { refresh() })
        moniButton = button("") { connectMoni() }
        root.addView(moniButton)
        status = text("", 18f)
        root.addView(status)
        root.addView(text("Para añadir el widget: mantén pulsado el escritorio › Widgets › Uso de Claude. Hay dos: el grande y el de una fila; los dos se adaptan al tamaño (estíralos). Tócalo para actualizar; toca un personaje para abrir esta pantalla. Para elegir qué servicios muestra cada uno: mantén pulsado el widget › Configuración.", 13f, 0xFF8F8786.toInt()))
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
                    else { Gastos.forget(this); show(); Widgets.updateAll(this) }
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

    /** OpenAI: el saldo se lee con la sesión de platform.openai.com (vía no oficial) */
    private fun openai() {
        if (!OpenAI.hasSession(this)) return login("https://platform.openai.com/login")
        android.app.AlertDialog.Builder(this)
            .setTitle("API de OpenAI")
            .setItems(arrayOf("Volver a iniciar sesión", "Cerrar sesión")) { _, i ->
                if (i == 0) login("https://platform.openai.com/login")
                else { OpenAI.logout(this); show(); Widgets.updateAll(this) }
            }.show()
    }

    /** Soniox: clave de API (console.soniox.com › API keys). Se guarda solo en este móvil. */
    private fun soniox() {
        val field = android.widget.EditText(this).apply {
            hint = "Clave de la API de Soniox"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val b = android.app.AlertDialog.Builder(this)
            .setTitle("API de Soniox")
            .setMessage("Pega una clave de organización de Soniox (empieza por snx_org_): console.soniox.com › Settings › Organization API keys. Las de proyecto (snx_proj_) no dan acceso al saldo. Solo se usa para leer el saldo y el gasto, y se queda en este móvil.")
            .setView(field)
            .setPositiveButton("Guardar") { _, _ ->
                val k = field.text.toString().trim()
                if (k.length < 10) android.widget.Toast.makeText(this, "Esa clave no parece válida", android.widget.Toast.LENGTH_LONG).show()
                else { Wallets.setSecret(this, Soniox.KEY, k); refresh() }
            }
            .setNegativeButton("Cancelar", null)
        if (Wallets.secret(this, Soniox.KEY) != null) b.setNeutralButton("Borrar la clave") { _, _ ->
            Wallets.setSecret(this, Soniox.KEY, null); show(); Widgets.updateAll(this)
        }
        b.show()
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
        list.removeAllViews()
        Cards.all(this).forEach { card -> list.addView(cardView(card)) }
        openaiButton.text = if (OpenAI.hasSession(this)) "API de OpenAI…" else "Iniciar sesión en OpenAI (saldo de la API)"
        sonioxButton.text = if (Wallets.secret(this, Soniox.KEY) != null) "Clave de la API de Soniox…" else "Pegar la clave de la API de Soniox"
        moniButton.text = if (Gastos.configured(this)) "Gastos de Moni…" else "Conectar con Moni (gastos del mes)"
        val sb = StringBuilder()
        if (Gastos.configured(this)) {
            sb.append("GASTOS DEL MES\n")
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

    /** Tarjeta de un servicio con su personaje animado */
    private fun cardView(card: Card): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        val anim = android.graphics.drawable.AnimationDrawable().apply {
            for (i in 0..2) addFrame(getDrawable(Sprites.frame(this@MainActivity, card.service.sprite, card.row, i))!!, Sprites.interval(card.row))
            isOneShot = false
        }
        row.addView(ImageView(this).apply {
            setImageDrawable(anim)
            layoutParams = LinearLayout.LayoutParams(dp(64), dp(64))
            post { anim.start() }
        })
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        col.addView(TextView(this).apply {
            text = card.service.title + "  ·  " + card.phrase()
            setTextColor(card.service.color); textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        if (card.lines.isEmpty()) col.addView(TextView(this).apply {
            text = card.error ?: "Sin datos todavía"; setTextColor(0xFFFFB366.toInt()); textSize = 14f
        })
        card.lines.forEach { l ->
            col.addView(TextView(this).apply {
                text = "${l.label}: ${l.value}" + (l.note.takeIf { it.isNotEmpty() }?.let { " · $it" } ?: "")
                setTextColor(if (l.percent != null) l.color else Color.WHITE); textSize = 17f
            })
        }
        if (card.lines.isNotEmpty()) card.error?.let { e ->
            col.addView(TextView(this).apply { text = "⚠︎ $e"; setTextColor(0xFFFFB366.toInt()); textSize = 12f })
        }
        row.addView(col)
        return row
    }
}
