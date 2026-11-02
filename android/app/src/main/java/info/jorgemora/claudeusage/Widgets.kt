package info.jorgemora.claudeusage

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Base de los dos widgets: el diseño se adapta al tamaño que tenga cada uno en el escritorio */
abstract class BaseWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, m: AppWidgetManager, ids: IntArray) {
        ids.forEach { Widgets.render(c, m, it) }
        Scheduler.schedule(c)
    }

    override fun onAppWidgetOptionsChanged(c: Context, m: AppWidgetManager, id: Int, o: Bundle) {
        Widgets.render(c, m, id)
    }

    override fun onEnabled(c: Context) {
        Scheduler.schedule(c)
        Scheduler.now(c)
    }

    override fun onDeleted(c: Context, ids: IntArray) {
        ids.forEach { Widgets.forget(c, it) }
    }

    override fun onReceive(c: Context, intent: Intent) {
        super.onReceive(c, intent)
        if (intent.action == Widgets.ACTION_REFRESH) {
            Widgets.updateAll(c, refreshing = true)
            // Consulta al momento, sin esperar a que Android programe la tarea
            val pending = goAsync()
            CoroutineScope(Dispatchers.IO).launch {
                val ok = withTimeoutOrNull(40_000) { Fetch.quick(c); true } ?: false
                if (!ok) {
                    runCatching { Widgets.updateAll(c) }
                    Scheduler.now(c)
                }
                pending.finish()
            }
        }
    }
}

/** Widget grande: tarjetas, cuadrícula o lista según el tamaño */
class UsageWidget : BaseWidget()

/** Widget de una fila a todo el ancho; si se estira hacia arriba pasa a varias filas */
class RowWidget : BaseWidget()

object Widgets {
    const val ACTION_REFRESH = "info.jorgemora.claudeusage.REFRESH"
    private const val DIM = 0x8CFFFFFF.toInt()

    private fun prefs(c: Context) = c.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    fun services(c: Context, id: Int): List<Service> {
        val s = prefs(c).getString("s_$id", null) ?: return Service.entries.toList()
        return s.split(",").mapNotNull { Service.from(it) }.ifEmpty { Service.entries.toList() }
    }

    fun setServices(c: Context, id: Int, list: List<Service>) =
        prefs(c).edit().putString("s_$id", list.joinToString(",") { it.key }).apply()

    fun forget(c: Context, id: Int) = prefs(c).edit().remove("s_$id").apply()

    private fun allIds(c: Context, m: AppWidgetManager): List<Int> =
        listOf(UsageWidget::class.java, RowWidget::class.java).flatMap { m.getAppWidgetIds(ComponentName(c, it)).toList() }

    fun updateAll(c: Context, refreshing: Boolean = false) {
        val m = AppWidgetManager.getInstance(c)
        allIds(c, m).forEach { runCatching { render(c, m, it, refreshing) } }
    }

    fun render(c: Context, m: AppWidgetManager, id: Int, refreshing: Boolean = false) {
        val o = m.getAppWidgetOptions(id)
        val cards = services(c, id).map { Cards.card(c, it) }
        val views = if (Build.VERSION.SDK_INT >= 31) {
            @Suppress("DEPRECATION")
            val sizes = o.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
            if (!sizes.isNullOrEmpty()) RemoteViews(sizes.distinct().take(8).associateWith { build(c, cards, it.width, it.height, refreshing) })
            else build(c, cards, minW(o), maxH(o), refreshing)
        } else build(c, cards, minW(o), maxH(o), refreshing)
        m.updateAppWidget(id, views)
    }

    private fun minW(o: Bundle) = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 300).toFloat().takeIf { it > 0 } ?: 300f
    private fun maxH(o: Bundle) = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 200).toFloat().takeIf { it > 0 } ?: 200f

    private fun sprite(c: Context, v: RemoteViews, card: Card) {
        val r = card.row
        listOf(R.id.f0, R.id.f1, R.id.f2).forEachIndexed { i, f -> v.setImageViewResource(f, Sprites.frame(c, card.service.sprite, r, i)) }
        v.setInt(R.id.sprite, "setFlipInterval", Sprites.interval(r))
        v.setOnClickPendingIntent(R.id.sprite, openApp(c))
    }

    private fun bigColor(card: Card) = when {
        !card.hasData -> DIM
        card.service.isAPI -> card.level?.let { usageColor(it) } ?: 0xFFFFFFFF.toInt()
        else -> usageColor(card.level ?: 0.0)
    }

    /** Celda compacta: personaje, nombre, dato grande y uno pequeño */
    private fun compact(c: Context, card: Card, layout: Int, wide: Boolean, narrow: Boolean = false, showSmall: Boolean = true): RemoteViews {
        val v = RemoteViews(c.packageName, layout)
        sprite(c, v, card)
        fun tight(t: String) = if (narrow) t.replace(" %", "%").replace(" $", "$") else t
        v.setTextViewText(R.id.name, when {
            wide -> card.service.title
            narrow || card.service.isAPI || !card.hasData -> card.service.short
            else -> card.service.short + " · sem"
        })
        v.setTextColor(R.id.name, card.service.color)
        v.setTextViewText(R.id.big, tight(card.big))
        v.setTextColor(R.id.big, bigColor(card))
        if (narrow) v.setTextViewTextSize(R.id.big, android.util.TypedValue.COMPLEX_UNIT_SP, 18f)
        val small = when {
            !card.hasData -> card.error ?: "sin datos"
            card.service.isAPI -> if (wide && card.small.startsWith("mes")) "saldo · ${card.small}" else tight(card.small)
            wide -> "semana · ${card.small}"
            else -> tight(card.small)
        }
        v.setTextViewText(R.id.small, small)
        v.setViewVisibility(R.id.small, if (showSmall) View.VISIBLE else View.GONE)
        v.setTextColor(R.id.small, if (!card.hasData && card.error != null) 0xFFFFB366.toInt() else DIM)
        return v
    }

    /** Tarjeta completa: personaje, frase y hasta [maxLines] líneas con barra */
    private fun full(c: Context, card: Card, maxLines: Int, wide: Boolean): RemoteViews {
        val v = RemoteViews(c.packageName, R.layout.cell_card)
        v.removeAllViews(R.id.lines)
        sprite(c, v, card)
        v.setTextViewText(R.id.name, card.service.title)
        v.setTextColor(R.id.name, card.service.color)
        v.setTextViewText(R.id.phrase, if (wide && card.hasData) card.phrase() else "")
        // Si solo cabe una línea, la que está más apurada
        val shown = if (maxLines == 1 && !card.service.isAPI) listOfNotNull(card.lines.maxByOrNull { it.percent ?: 0.0 }) else card.lines.take(maxLines)
        shown.forEach { l ->
            val r = RemoteViews(c.packageName, R.layout.line_row)
            r.setTextViewText(R.id.label, l.label)
            r.setTextViewText(R.id.value, l.value)
            r.setTextColor(R.id.value, if (l.percent != null) l.color else 0xFFFFFFFF.toInt())
            if (l.percent != null) {
                r.setProgressBar(R.id.bar, 100, l.percent.roundToInt().coerceIn(0, 100), false)
                if (Build.VERSION.SDK_INT >= 31) r.setColorStateList(R.id.bar, "setProgressTintList", ColorStateList.valueOf(l.color))
                r.setViewVisibility(R.id.bar, View.VISIBLE)
            } else r.setViewVisibility(R.id.bar, View.INVISIBLE)
            r.setTextViewText(R.id.note, if (wide) l.note else "")
            v.addView(R.id.lines, r)
        }
        val err = when {
            !card.hasData -> card.error ?: "Sin datos todavía"
            else -> card.error?.let { "⚠︎ $it" }
        }
        v.setTextViewText(R.id.err, err ?: "")
        v.setViewVisibility(R.id.err, if (err != null && (maxLines >= 2 || !card.hasData)) View.VISIBLE else View.GONE)
        return v
    }

    fun build(c: Context, cards: List<Card>, w: Float, h: Float, refreshing: Boolean): RemoteViews {
        val n = max(1, cards.size)
        val v: RemoteViews
        if (h < 100) {
            // Una fila: tantas columnas como quepan
            v = RemoteViews(c.packageName, R.layout.w_root_row)
            v.removeAllViews(R.id.cells)
            val fit = max(1, min(n, (w / 96).toInt()))
            val wide = w / fit >= 150
            val narrow = w / fit < 120
            cards.take(fit).forEach { v.addView(R.id.cells, compact(c, it, R.layout.cell_col, wide, narrow)) }
            v.setTextViewText(R.id.footer, "…")
            v.setViewVisibility(R.id.footer, if (refreshing) View.VISIBLE else View.GONE)
        } else {
            v = RemoteViews(c.packageName, R.layout.w_root)
            v.removeAllViews(R.id.cells)
            val avail = h - 24 - 18
            val per = avail / n
            when {
                w >= 230 && per >= 56 -> {
                    val lines = ((per - 18) / 21).toInt().coerceIn(1, 3)
                    cards.forEach { v.addView(R.id.cells, full(c, it, lines, w >= 300)) }
                }
                w >= 200 && n > 2 -> {
                    // Cuadrícula de dos columnas
                    val rows = ceil(n / 2.0).toInt()
                    val wide = w / 2 >= 150
                    for (i in 0 until rows) {
                        val row = RemoteViews(c.packageName, R.layout.w_hrow)
                        cards.drop(i * 2).take(2).forEach { row.addView(R.id.cells, compact(c, it, R.layout.cell_col, wide)) }
                        v.addView(R.id.cells, row)
                    }
                }
                else -> {
                    val fit = max(1, min(n, (avail / 40).toInt()))
                    val showSmall = avail / fit >= 54
                    cards.take(fit).forEach { v.addView(R.id.cells, compact(c, it, R.layout.cell_list, w >= 250, w < 140, showSmall)) }
                }
            }
            val at = cards.maxOfOrNull { it.updated } ?: 0L
            v.setTextViewText(R.id.footer, when {
                refreshing -> "Actualizando…"
                at > 0 && w < 250 -> "Actualizado ${hourText(at)}"
                at > 0 -> "Actualizado ${hourText(at)} · toca para actualizar"
                else -> "Toca para actualizar"
            })
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        v.setOnClickPendingIntent(R.id.root, PendingIntent.getBroadcast(c, 0,
            Intent(c, UsageWidget::class.java).setAction(ACTION_REFRESH), flags))
        return v
    }

    private fun openApp(c: Context): PendingIntent = PendingIntent.getActivity(c, 1,
        Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}
