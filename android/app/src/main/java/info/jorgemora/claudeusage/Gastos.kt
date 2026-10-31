package info.jorgemora.claudeusage

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.NumberFormat
import java.util.Locale

/**
 * Gastos y tokens del mes que calcula el cerebro de Moni en el Mac (http://<IP de Tailscale>:8765/gastos).
 * Opcional: solo si en la app se ha pegado el enlace con el token de un dispositivo del cerebro.
 * El móvil tiene que estar en la misma red de Tailscale que el Mac.
 */
data class Spend(
    val spentEUR: Double, val forecastEUR: Double,
    val tokens: Double, val tokensApps: Double, val tokensAPIs: Double,
    val apiUSD: Double, val budgetUSD: Double?, val savedEUR: Double,
    val apps: List<Pair<String, String>>, val apis: List<Pair<String, String>>,
)

object Gastos {
    private fun prefs(c: Context) = c.getSharedPreferences("gastos", Context.MODE_PRIVATE)

    fun configured(c: Context) = base(c) != null && token(c) != null
    fun base(c: Context): String? = prefs(c).getString("base", null)
    private fun token(c: Context): String? = prefs(c).getString("token", null)

    /** Acepta el enlace que da el cerebro (…:8765/gastos?token=…, o /panel?token=…). Devuelve false si no vale. */
    fun configure(c: Context, link: String): Boolean {
        val u = runCatching { Uri.parse(link.trim()) }.getOrNull() ?: return false
        val token = u.getQueryParameter("token")?.takeIf { it.length >= 20 } ?: return false
        if (u.scheme !in listOf("http", "https") || u.host.isNullOrEmpty()) return false
        val base = "${u.scheme}://${u.host}${if (u.port > 0) ":${u.port}" else ""}"
        prefs(c).edit().putString("base", base).putString("token", token).remove("json").remove("err").apply()
        return true
    }

    fun forget(c: Context) = prefs(c).edit().clear().apply()

    fun panelUrl(c: Context): String? = base(c)?.let { b -> token(c)?.let { "$b/panel?token=$it" } }

    suspend fun fetch(c: Context) = withContext(Dispatchers.IO) {
        val b = base(c) ?: return@withContext
        val t = token(c) ?: return@withContext
        val e = prefs(c).edit()
        try {
            val conn = URL("$b/gastos").openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 60000
            conn.setRequestProperty("Authorization", "Bearer $t")
            val code = conn.responseCode
            val body = runCatching { (if (code < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.readText() }.getOrNull() ?: ""
            conn.disconnect()
            when (code) {
                200 -> { parse(body); e.putString("json", body).remove("err").putLong("at", System.currentTimeMillis()) }
                401 -> e.putString("err", "El cerebro de Moni no acepta el token")
                else -> e.putString("err", "El cerebro de Moni respondió $code")
            }
        } catch (_: Exception) {
            e.putString("err", "No llego al cerebro de Moni (¿Tailscale encendido?)")
        }
        e.apply()
    }

    fun error(c: Context): String? = prefs(c).getString("err", null)
    fun updated(c: Context): Long = prefs(c).getLong("at", 0)
    fun spend(c: Context): Spend? = prefs(c).getString("json", null)?.let { runCatching { parse(it) }.getOrNull() }

    fun parse(body: String): Spend {
        val o = JSONObject(body)
        val t = o.getJSONObject("totales")
        val moni = o.optJSONObject("moni") ?: JSONObject()
        val apps = listOf("claude" to "Claude Code", "codex" to "Codex", "hermes" to "Hermes").map { (k, name) ->
            name to tokensText(o.optJSONObject(k)?.optDouble("tokens", 0.0) ?: 0.0)
        }
        val apis = mutableListOf<Pair<String, String>>()
        val arr = o.optJSONArray("apis")
        if (arr != null) for (i in 0 until arr.length()) {
            val a = arr.getJSONObject(i)
            val usd = a.optDouble("usd", 0.0)
            val tok = a.optDouble("tokens", 0.0)
            val min = a.optDouble("minutos", 0.0)
            if (usd <= 0 && tok <= 0) continue
            var d = String.format(Locale("es", "ES"), "%.2f $", usd)
            if (tok > 0) d += " · " + tokensText(tok)
            if (min >= 1) d += " · ${min.toInt()} min"
            apis += a.optString("nombre", "API") to d
        }
        return Spend(
            t.optDouble("real_eur_hasta_hoy"), t.optDouble("real_eur_mes_previsto"),
            t.optDouble("tokens", 0.0), t.optDouble("tokens_suscripciones", 0.0), t.optDouble("tokens_apis", 0.0),
            t.optDouble("apis_usd", moni.optDouble("usd", 0.0)),
            if (moni.isNull("presupuesto_usd")) null else moni.optDouble("presupuesto_usd"),
            t.optDouble("ahorro_suscripciones_eur", 0.0), apps, apis,
        )
    }
}

fun tokensText(n: Double): String = when {
    n >= 1e9 -> String.format(Locale("es", "ES"), "%.1f mil M", n / 1e9)
    n >= 1e6 -> String.format(Locale("es", "ES"), "%.0f M", n / 1e6)
    n >= 1e3 -> String.format(Locale("es", "ES"), "%.0f mil", n / 1e3)
    else -> n.toInt().toString()
}

fun euros(v: Double): String = NumberFormat.getCurrencyInstance(Locale("es", "ES")).apply {
    maximumFractionDigits = if (v >= 100) 0 else 2
}.format(v)
