package info.jorgemora.claudeusage

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.NumberFormat
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Currency
import java.util.Locale

/** Saldo y gasto de una API de pago */
data class Wallet(
    val available: Double? = null,   // saldo que queda
    val used: Double? = null,        // gastado del saldo cargado
    val granted: Double? = null,     // total cargado
    val month: Double? = null,       // gastado este mes
    val budget: Double? = null,      // tope del mes
    val source: String = "",
) {
    /** 0–100: cuánto se ha consumido. Decide el humor del personaje. */
    val level: Double?
        get() {
            if (granted != null && granted > 0 && used != null) return (100 * used / granted).coerceIn(0.0, 100.0)
            if (available != null && used != null && available + used > 0) return (100 * used / (available + used)).coerceIn(0.0, 100.0)
            if (budget != null && budget > 0 && month != null) return (100 * month / budget).coerceIn(0.0, 100.0)
            return null
        }

    fun toJson(): String = JSONObject().apply {
        available?.let { put("a", it) }; used?.let { put("u", it) }; granted?.let { put("g", it) }
        month?.let { put("m", it) }; budget?.let { put("b", it) }; put("s", source)
    }.toString()

    companion object {
        fun fromJson(s: String): Wallet {
            val o = JSONObject(s)
            fun d(k: String) = if (o.has(k)) o.getDouble(k) else null
            return Wallet(d("a"), d("u"), d("g"), d("m"), d("b"), o.optString("s"))
        }
    }
}

fun dollars(v: Double): String = NumberFormat.getCurrencyInstance(Locale("es", "ES")).apply {
    currency = Currency.getInstance("USD")
    maximumFractionDigits = if (v >= 100) 0 else 2
    minimumFractionDigits = if (v >= 100) 0 else 2
}.format(v).replace("US$", "$")

/** Número que puede venir como número o como texto ("12.40") */
private fun JSONObject.num(k: String): Double? {
    if (!has(k) || isNull(k)) return null
    return when (val v = get(k)) {
        is Number -> v.toDouble()
        is String -> v.toDoubleOrNull()
        else -> null
    }
}

object Wallets {
    private fun prefs(c: Context) = c.getSharedPreferences("wallets", Context.MODE_PRIVATE)

    fun save(c: Context, key: String, w: Wallet?, error: String?) {
        val e = prefs(c).edit()
        if (w != null) e.putString(key, w.toJson()).remove(key + "_err").putLong(key + "_at", System.currentTimeMillis())
        else e.putString(key + "_err", error)
        e.apply()
    }

    fun get(c: Context, key: String): Wallet? =
        prefs(c).getString(key, null)?.let { runCatching { Wallet.fromJson(it) }.getOrNull() }

    fun error(c: Context, key: String): String? = prefs(c).getString(key + "_err", null)
    fun updated(c: Context, key: String): Long = prefs(c).getLong(key + "_at", 0)

    fun secret(c: Context, key: String): String? = prefs(c).getString("key_$key", null)?.takeIf { it.isNotBlank() }
    fun setSecret(c: Context, key: String, v: String?) {
        val e = prefs(c).edit()
        if (v.isNullOrBlank()) e.remove("key_$key").remove(key).remove(key + "_err") else e.putString("key_$key", v.trim())
        e.apply()
    }

    fun forget(c: Context, key: String) = prefs(c).edit().remove(key).remove(key + "_err").remove(key + "_at").apply()
}

private fun httpGet(url: String, headers: Map<String, String>): Res {
    val conn = URL(url).openConnection() as HttpURLConnection
    conn.connectTimeout = 8000
    conn.readTimeout = 12000
    conn.setRequestProperty("Accept", "application/json")
    headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
    val code = conn.responseCode
    val body = runCatching { (if (code < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.readText() }
        .getOrNull() ?: ""
    conn.disconnect()
    return Res(code, body)
}

/** Soniox: saldo prepago y gasto del mes con su API oficial (clave pegada en la app) */
object Soniox {
    const val KEY = "soniox"

    suspend fun fetch(c: Context) = withContext(Dispatchers.IO) {
        val k = Wallets.secret(c, KEY) ?: return@withContext Wallets.save(c, KEY, null, "Falta la clave de Soniox: ábrela en la app")
        try {
            val h = mapOf("Authorization" to "Bearer $k")
            val b = httpGet("https://api.soniox.com/v1/organization/balance", h)
            val m = httpGet("https://api.soniox.com/v1/organization/usage/monthly", h)
            var w = Wallet(source = "Soniox")
            if (b.status == 200) {
                val o = JSONObject(b.body)
                val a = o.num("available_balance_usd")
                val u = o.num("used_balance_usd")
                w = w.copy(available = a, used = u, granted = if (a != null && u != null) a + u else null)
            }
            if (m.status == 200) {
                val o = JSONObject(m.body)
                w = w.copy(month = o.num("usage_usd"), budget = o.num("monthly_budget_usd"))
            }
            when {
                w.available != null || w.month != null -> Wallets.save(c, KEY, w, null)
                b.status == 401 || b.status == 403 -> Wallets.save(c, KEY, null, "Soniox no acepta la clave")
                else -> Wallets.save(c, KEY, null, "Soniox respondió ${b.status}")
            }
        } catch (_: Exception) {
            Wallets.save(c, KEY, null, "Sin respuesta de Soniox")
        }
    }
}

/**
 * OpenAI no da el saldo con una clave de API: se lee con la sesión de platform.openai.com
 * iniciada en la app (lo mismo que ve su página de facturación). Vía no oficial.
 */
object OpenAI {
    const val KEY = "openai"
    private const val TOKEN = "openai_tok"

    /** JavaScript síncrono: busca el token de sesión que guarda la web */
    const val TOKEN_JS = """(function(){try{var o=JSON.parse(localStorage.getItem('oai-auth:onboard')||'null');if(o&&o.accessToken)return o.accessToken;}catch(e){}var t=null;[window.localStorage,window.sessionStorage].forEach(function(st){for(var i=0;i<st.length;i++){var v=st.getItem(st.key(i))||'';if(v.indexOf('access_token')<0)continue;try{var o=JSON.parse(v);var c=(o&&o.body&&o.body.access_token)||(o&&o.access_token);if(c)t=c;}catch(e){}}});return t||'';})()"""

    /** Para WebFetcher: obtiene el token dentro de la web (renovándolo si hace falta) */
    const val FETCH_JS = """
        let tok = null;
        try { const o = JSON.parse(localStorage.getItem('oai-auth:onboard') || 'null'); if (o && o.accessToken) tok = o.accessToken; } catch (e) {}
        if (!tok) for (const st of [window.localStorage, window.sessionStorage]) {
          for (let i = 0; i < st.length; i++) {
            const v = st.getItem(st.key(i)) || '';
            if (v.indexOf('access_token') < 0) continue;
            try { const o = JSON.parse(v); const c = (o && o.body && o.body.access_token) || (o && o.access_token); if (c) tok = c; } catch (e) {}
          }
        }
        if (!tok) {
          try { const s = await fetch('/api/auth/session', {credentials: 'include'}); if (s.status === 200) { const j = await s.json(); tok = j.accessToken || null; } } catch (e) {}
        }
        return {status: tok ? 200 : 401, body: tok || ''};
    """

    fun hasSession(c: Context) = Wallets.secret(c, TOKEN) != null
    fun saveToken(c: Context, t: String) = Wallets.setSecret(c, TOKEN, t)
    fun logout(c: Context) { Wallets.setSecret(c, TOKEN, null); Wallets.forget(c, KEY) }

    /** foreground: con la app abierta se renueva el token desde la web si ha caducado */
    suspend fun fetch(c: Context, foreground: Boolean) {
        var status = query(c)
        if ((status == 401 || status == 403 || status == 0) && foreground) {
            val r = WebFetcher.run(c, "https://platform.openai.com/", FETCH_JS, 30_000)
            if (r != null && r.status == 200 && r.body.isNotEmpty()) { saveToken(c, r.body); status = query(c) }
        }
        when (status) {
            200 -> Unit
            0 -> Wallets.save(c, KEY, null, "Inicia sesión en OpenAI desde la app")
            401, 403 -> Wallets.save(c, KEY, null, "Sesión de OpenAI caducada: abre la app")
            -1 -> Wallets.save(c, KEY, null, "Sin respuesta de OpenAI")
            else -> Wallets.save(c, KEY, null, "OpenAI respondió $status")
        }
    }

    /** Devuelve el código HTTP de la consulta del saldo (0 = sin sesión, -1 = sin red) */
    private suspend fun query(c: Context): Int = withContext(Dispatchers.IO) {
        val t = Wallets.secret(c, TOKEN) ?: return@withContext 0
        try {
            // El token de la web se cambia por una clave de sesión del panel (sess-…)
            val sess = runCatching {
                val conn = URL("https://api.openai.com/v1/dashboard/onboarding/login").openConnection() as HttpURLConnection
                conn.requestMethod = "POST"; conn.doOutput = true
                conn.connectTimeout = 8000; conn.readTimeout = 15000
                conn.setRequestProperty("Authorization", "Bearer $t")
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write("{}".toByteArray()) }
                if (conn.responseCode != 200) { conn.disconnect(); return@runCatching null }
                val j = JSONObject(conn.inputStream.bufferedReader().readText()); conn.disconnect()
                j.optJSONObject("user")?.optJSONObject("session")?.optString("sensitive_id")?.takeIf { it.startsWith("sess-") }
            }.getOrNull()
            val h = mapOf("Authorization" to "Bearer ${sess ?: t}")
            val g = httpGet("https://api.openai.com/v1/dashboard/billing/credit_grants", h)
            var w = Wallet(source = "OpenAI")
            if (g.status == 200) {
                val o = JSONObject(g.body)
                w = w.copy(granted = o.num("total_granted"), used = o.num("total_used"),
                    available = o.num("total_available") ?: o.num("total_paid_available"))
            }
            val today = LocalDate.now(ZoneOffset.UTC)
            val u = httpGet("https://api.openai.com/v1/dashboard/billing/usage?start_date=${today.withDayOfMonth(1)}&end_date=${today.plusDays(1)}", h)
            if (u.status == 200) JSONObject(u.body).num("total_usage")?.let { w = w.copy(month = it / 100) }
            if (w.available == null && w.month == null) return@withContext if (g.status == 200) 422 else g.status
            Wallets.save(c, KEY, w, null)
            200
        } catch (_: Exception) {
            -1
        }
    }
}
