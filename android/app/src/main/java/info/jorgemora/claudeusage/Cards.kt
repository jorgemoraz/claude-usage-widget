package info.jorgemora.claudeusage

import android.content.Context
import kotlin.math.roundToInt

enum class Service(val key: String, val title: String, val short: String, val sprite: String, val color: Int, val isAPI: Boolean) {
    CLAUDE("claude", "Claude", "Claude", "claude", 0xFFE3876A.toInt(), false),
    CHATGPT("gpt", "ChatGPT", "GPT", "chatgpt", 0xFF4DC79E.toInt(), false),
    OPENAI("openai", "API OpenAI", "OpenAI", "chatgpt", 0xFF7FD6B8.toInt(), true),
    SONIOX("soniox", "API Soniox", "Soniox", "soniox", 0xFF6FA8FF.toInt(), true);

    companion object {
        fun from(key: String) = entries.firstOrNull { it.key == key }
    }
}

/** Una línea de una tarjeta: etiqueta, valor, barra (0–100) y cuándo se reinicia */
/** percent = usado (0–100); la barra pinta lo que queda. timeLeft = fracción de tiempo hasta el reinicio. */
data class Line(val label: String, val value: String, val percent: Double?, val note: String, val color: Int, val timeLeft: Double? = null)

fun timeLeft(resetAt: Long?, windowSec: Long): Double? {
    if (resetAt == null || windowSec <= 0) return null
    val left = (resetAt - System.currentTimeMillis()) / 1000.0
    return if (left > 0) (left / windowSec).coerceAtMost(1.0) else null
}

/** Lo que se pinta de un servicio, igual en todos los formatos */
data class Card(
    val service: Service,
    val hasData: Boolean,
    val level: Double?,
    val big: String,          // dato principal (semana % o saldo)
    val small: String,        // dato secundario corto
    val lines: List<Line>,
    val error: String?,
    val updated: Long,
) {
    val row get() = Sprites.row(level)

    fun phrase(): String {
        if (!hasData) return error ?: if (service.isAPI) "Sin datos de la API" else "Sin datos todavía"
        val list = if (service.isAPI) listOf(
            listOf("Cartera sana", "Hay saldo de sobra", "Gasta tranquilo"),
            listOf("Ojo con el gasto", "Gasta con cabeza"),
            listOf("Recarga pronto", "El saldo baja rápido"),
            listOf("¡Recarga ya!", "¡Me quedo sin saldo!"),
        )[row] else listOf(
            listOf("A tope de energía", "Ritmo de crucero", "Pídeme lo que quieras"),
            listOf("Ojo, que baja", "Dosifícame un poco"),
            listOf("Esto se acaba", "Solo lo importante"),
            listOf("¡Últimas gotas!", "¡Que me apago!"),
        )[row]
        return list[((System.currentTimeMillis() / 90_000) % list.size).toInt()]
    }
}

private const val DIM = 0x8CFFFFFF.toInt()

fun pct(p: Double) = "${p.roundToInt()} %"

fun resetNote(at: Long?): String = when {
    at == null -> ""
    at > System.currentTimeMillis() -> "vuelve ${hourText(at)}"
    else -> "reiniciado"
}

object Cards {
    fun all(c: Context): List<Card> = Service.entries.map { card(c, it) }

    fun card(c: Context, s: Service): Card = if (s.isAPI) api(c, s) else subscription(c, s)

    private fun subscription(c: Context, s: Service): Card {
        val rows = Store.rows(c, s.key)
        val err = Store.error(c, s.key)
        if (rows.isEmpty()) return Card(s, false, null, "–", "sin datos", emptyList(), err, 0)
        val session = rows.firstOrNull { !it.isWeek }
        val week = rows.firstOrNull { it.isWeek }
        val lines = rows.map {
            Line(if (!it.isWeek) "5 horas" else it.label.substringAfter("· "), pct(it.percent), it.percent,
                timeLeft(it.resetAt, it.windowSec)?.let { t -> "tiempo ${(t * 100).roundToInt()} % · ${resetNote(it.resetAt)}" } ?: resetNote(it.resetAt),
                usageColor(it.percent), timeLeft(it.resetAt, it.windowSec))
        }
        return Card(
            s, true, rows.maxOf { it.percent },
            week?.let { pct(it.percent) } ?: session?.let { pct(it.percent) } ?: "–",
            session?.let { "5h ${pct(it.percent)}" } ?: "",
            lines, err, Store.updated(c, s.key),
        )
    }

    private fun api(c: Context, s: Service): Card {
        val err = Wallets.error(c, s.key)
        val moni = Gastos.spend(c)?.apiUSD(s.key)
        val w = Wallets.get(c, s.key) ?: moni?.let { Wallet(month = it, source = "Moni") }
            ?: return Card(s, false, null, "–", "sin datos", emptyList(), err, 0)
        val lines = mutableListOf<Line>()
        val level = w.level
        if (w.available != null) {
            val total = w.granted?.let { " de ${dollars(it)}" } ?: ""
            lines += Line("Saldo", dollars(w.available), level, "queda$total",
                level?.let { usageColor(it) } ?: 0xFF5CCC80.toInt())
        }
        if (w.used != null && w.available != null) lines += Line("Gastado", dollars(w.used), null, "del saldo cargado", DIM)
        val month = w.month ?: moni
        if (month != null) {
            val b = w.budget?.let { " de ${dollars(it)}" } ?: ""
            lines += Line("Este mes", dollars(month), w.budget?.takeIf { it > 0 }?.let { 100 * month / it },
                (if (w.source == "Moni") "según Moni" else "gastado") + b, DIM)
        }
        return Card(
            s, true, level,
            w.available?.let { dollars(it) } ?: month?.let { dollars(it) } ?: "–",
            if (w.available != null) month?.let { "mes ${dollars(it)}" } ?: "saldo" else "este mes",
            lines, err, Wallets.updated(c, s.key),
        )
    }
}
