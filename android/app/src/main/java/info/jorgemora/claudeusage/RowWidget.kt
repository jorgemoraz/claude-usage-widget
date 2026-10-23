package info.jorgemora.claudeusage

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import kotlin.math.roundToInt

/** Widget de una sola fila, a todo el ancho (4×1 o 5×1) */
class RowWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, m: AppWidgetManager, ids: IntArray) {
        ids.forEach { m.updateAppWidget(it, views(c)) }
        Scheduler.schedule(c)
    }

    override fun onEnabled(c: Context) {
        Scheduler.schedule(c)
        Scheduler.now(c)
    }

    companion object {
        fun updateAll(c: Context, refreshing: Boolean = false) {
            val m = AppWidgetManager.getInstance(c)
            val ids = m.getAppWidgetIds(ComponentName(c, RowWidget::class.java))
            if (ids.isEmpty()) return
            val v = views(c, refreshing)
            ids.forEach { m.updateAppWidget(it, v) }
        }

        private fun pct(v: RemoteViews, id: Int, row: Row?) {
            v.setTextViewText(id, row?.let { "${it.percent.roundToInt()}%" } ?: "–")
            v.setTextColor(id, row?.let { usageColor(it.percent) } ?: 0x80FFFFFF.toInt())
        }

        fun views(c: Context, refreshing: Boolean = false): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget_row)
            val claude = Store.rows(c, "claude")
            val gpt = Store.rows(c, "gpt")
            v.setImageViewResource(R.id.mascot, Mood.from(claude.maxOfOrNull { it.percent }).drawable)
            pct(v, R.id.c_week, claude.firstOrNull { it.isWeek })
            pct(v, R.id.c_5h, claude.firstOrNull { !it.isWeek })
            pct(v, R.id.g_week, gpt.firstOrNull { it.isWeek })
            pct(v, R.id.g_5h, gpt.firstOrNull { !it.isWeek })
            // Si no hay datos, se muestra el motivo en lugar de guiones
            val cErr = Store.error(c, "claude").takeIf { claude.isEmpty() }
            val gErr = Store.error(c, "gpt").takeIf { gpt.isEmpty() }
            v.setTextViewText(R.id.c_err, cErr ?: "")
            v.setViewVisibility(R.id.c_err, if (cErr != null) View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.c_vals, if (cErr != null) View.GONE else View.VISIBLE)
            v.setTextViewText(R.id.g_err, gErr ?: "")
            v.setViewVisibility(R.id.g_err, if (gErr != null) View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.g_vals, if (gErr != null) View.GONE else View.VISIBLE)
            val note = when {
                refreshing -> "…"
                else -> ""
            }
            v.setTextViewText(R.id.note, note)
            v.setViewVisibility(R.id.note, if (note.isEmpty()) View.GONE else View.VISIBLE)

            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            v.setOnClickPendingIntent(R.id.root, PendingIntent.getBroadcast(c, 10,
                Intent(c, UsageWidget::class.java).setAction(UsageWidget.ACTION_REFRESH), flags))
            v.setOnClickPendingIntent(R.id.mascot, PendingIntent.getActivity(c, 11,
                Intent(c, MainActivity::class.java), flags))
            return v
        }
    }
}
