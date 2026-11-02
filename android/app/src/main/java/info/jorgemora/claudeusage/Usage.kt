package info.jorgemora.claudeusage

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.util.Calendar
import java.util.Date
import java.util.Locale

data class Row(val label: String, val percent: Double, val resetAt: Long?, val windowSec: Long) {
    val isWeek get() = windowSec >= 6 * 86400
}

object Store {
    private fun prefs(c: Context) = c.getSharedPreferences("usage", Context.MODE_PRIVATE)

    /** Guarda filas nuevas o, si fallan, solo el error (se conservan los últimos datos buenos). */
    fun save(c: Context, key: String, rows: List<Row>?, error: String?) {
        val e = prefs(c).edit()
        if (rows != null) {
            e.putString(key, toJson(rows)).remove(key + "_err").putLong(key + "_at", System.currentTimeMillis())
        } else {
            e.putString(key + "_err", error)
        }
        e.apply()
    }

    fun rows(c: Context, key: String): List<Row> =
        prefs(c).getString(key, null)?.let { runCatching { fromJson(it) }.getOrNull() } ?: emptyList()

    fun error(c: Context, key: String): String? = prefs(c).getString(key + "_err", null)
    fun updated(c: Context, key: String): Long = prefs(c).getLong(key + "_at", 0)

    private fun toJson(rows: List<Row>): String = JSONArray().apply {
        rows.forEach { r ->
            put(JSONObject().put("l", r.label).put("p", r.percent).put("r", r.resetAt ?: -1L).put("w", r.windowSec))
        }
    }.toString()

    private fun fromJson(s: String): List<Row> {
        val a = JSONArray(s)
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            Row(o.getString("l"), o.getDouble("p"), o.getLong("r").takeIf { it > 0 }, o.getLong("w"))
        }
    }
}

object Parse {
    fun claude(body: String): List<Row> {
        val o = JSONObject(body)
        val out = mutableListOf<Row>()
        for ((key, label, span) in listOf(
            Triple("five_hour", "Sesión (5 h)", 18000L),
            Triple("seven_day", "Semana", 604800L),
            Triple("seven_day_opus", "Semana · Opus", 604800L),
            Triple("seven_day_sonnet", "Semana · Sonnet", 604800L),
        )) {
            val d = o.optJSONObject(key) ?: continue
            if (d.isNull("utilization")) continue
            val u = d.optDouble("utilization", Double.NaN)
            if (u.isNaN()) continue
            val reset = d.optString("resets_at", "").takeIf { it.isNotEmpty() && it != "null" }
                ?.let { runCatching { OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() }
            out += Row(label, u, reset, span)
        }
        if (out.isEmpty()) throw IllegalStateException("Respuesta inesperada de Claude")
        return out
    }

    fun gpt(body: String): List<Row> {
        val rl = JSONObject(body).optJSONObject("rate_limit")
            ?: throw IllegalStateException("Respuesta inesperada de ChatGPT")
        val out = mutableListOf<Row>()
        for (key in listOf("primary_window", "secondary_window")) {
            val w = rl.optJSONObject(key) ?: continue
            val u = w.optDouble("used_percent", Double.NaN)
            if (u.isNaN()) continue
            val span = w.optLong("limit_window_seconds", if (key == "primary_window") 18000L else 604800L)
            val reset = when {
                w.has("reset_at") && !w.isNull("reset_at") -> w.getLong("reset_at") * 1000
                w.has("reset_after_seconds") -> System.currentTimeMillis() + w.getLong("reset_after_seconds") * 1000
                else -> null
            }
            out += Row(if (span >= 6 * 86400) "Semana" else "Sesión (5 h)", u, reset, span)
        }
        if (out.isEmpty()) throw IllegalStateException("Respuesta inesperada de ChatGPT")
        return out
    }
}

/** Personajes animados: 4 humores (filas) × 3 fotogramas */
object Sprites {
    fun row(level: Double?): Int = when {
        level == null -> 0
        level >= 90 -> 3
        level >= 75 -> 2
        level >= 50 -> 1
        else -> 0
    }

    fun frame(c: Context, who: String, row: Int, f: Int): Int =
        c.resources.getIdentifier("sp_${who}_${row}_$f", "drawable", c.packageName)

    /** Más nervioso cuanto peor va */
    fun interval(row: Int): Int = intArrayOf(650, 480, 320, 200)[row.coerceIn(0, 3)]
}

fun usageColor(p: Double): Int = when {
    p < 60 -> 0xFF5CCC80.toInt()
    p < 85 -> 0xFFFFAD42.toInt()
    else -> 0xFFFF6159.toInt()
}

fun hourText(ms: Long): String {
    val d = Date(ms)
    val now = Calendar.getInstance()
    val then = Calendar.getInstance().apply { time = d }
    val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) && now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
    return SimpleDateFormat(if (sameDay) "H.mm" else "EEE H.mm", Locale("es", "ES")).format(d)
}
