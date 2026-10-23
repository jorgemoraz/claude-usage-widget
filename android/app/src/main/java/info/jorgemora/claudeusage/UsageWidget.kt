package info.jorgemora.claudeusage

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import kotlin.math.roundToInt

class UsageWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, m: AppWidgetManager, ids: IntArray) {
        render(c, m, ids)
        Scheduler.schedule(c)
    }

    override fun onEnabled(c: Context) {
        Scheduler.schedule(c)
        Scheduler.now(c)
    }

    override fun onReceive(c: Context, intent: Intent) {
        super.onReceive(c, intent)
        if (intent.action == ACTION_REFRESH) {
            updateAll(c, refreshing = true)
            Scheduler.now(c)
        }
    }

    companion object {
        const val ACTION_REFRESH = "info.jorgemora.claudeusage.REFRESH"

        fun updateAll(c: Context, refreshing: Boolean = false) {
            val m = AppWidgetManager.getInstance(c)
            render(c, m, m.getAppWidgetIds(ComponentName(c, UsageWidget::class.java)), refreshing)
        }

        private fun render(c: Context, m: AppWidgetManager, ids: IntArray, refreshing: Boolean = false) {
            if (ids.isEmpty()) return
            val v = views(c, refreshing)
            ids.forEach { m.updateAppWidget(it, v) }
        }

        private fun bind(v: RemoteViews, id: String, c: Context, row: Row?) {
            val res = c.resources
            fun vid(name: String) = res.getIdentifier("${id}_$name", "id", c.packageName)
            val p = row?.percent ?: 0.0
            v.setTextViewText(vid("pct"), row?.let { "${it.percent.roundToInt()} %" } ?: "–")
            v.setTextColor(vid("pct"), if (row != null) usageColor(p) else 0x80FFFFFF.toInt())
            v.setProgressBar(vid("bar"), 100, p.roundToInt().coerceIn(0, 100), false)
            if (Build.VERSION.SDK_INT >= 31) {
                v.setColorStateList(vid("bar"), "setProgressTintList", ColorStateList.valueOf(usageColor(p)))
            }
            v.setTextViewText(vid("reset"), row?.resetAt?.let {
                if (it > System.currentTimeMillis()) "Se reinicia ${hourText(it)}" else "Reiniciado"
            } ?: "")
        }

        fun views(c: Context, refreshing: Boolean = false): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget)
            val claude = Store.rows(c, "claude")
            val gpt = Store.rows(c, "gpt")
            val worst = claude.maxOfOrNull { it.percent }
            val mood = Mood.from(worst)
            val session = claude.firstOrNull { !it.isWeek }

            v.setImageViewResource(R.id.mascot, mood.drawable)
            v.setTextViewText(R.id.phrase, if (claude.isEmpty()) "Abre la app e inicia sesión" else mood.phrase())
            v.setTextViewText(R.id.big, session?.let { "${it.percent.roundToInt()} % de la sesión" } ?: "–")
            v.setTextColor(R.id.big, usageColor(session?.percent ?: 0.0))

            val cErr = Store.error(c, "claude")
            v.setViewVisibility(R.id.claude_err, if (cErr != null) View.VISIBLE else View.GONE)
            v.setTextViewText(R.id.claude_err, cErr ?: "")
            bind(v, "c5", c, session)
            bind(v, "cw", c, claude.firstOrNull { it.isWeek })

            val gErr = Store.error(c, "gpt")
            v.setViewVisibility(R.id.gpt_err, if (gErr != null) View.VISIBLE else View.GONE)
            v.setTextViewText(R.id.gpt_err, gErr ?: "")
            bind(v, "g5", c, gpt.firstOrNull { !it.isWeek })
            bind(v, "gw", c, gpt.firstOrNull { it.isWeek })

            val at = maxOf(Store.updated(c, "claude"), Store.updated(c, "gpt"))
            v.setTextViewText(R.id.footer, when {
                refreshing -> "Actualizando…"
                at > 0 -> "Actualizado ${hourText(at)} · toca para actualizar"
                else -> "Toca para actualizar"
            })

            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val refresh = PendingIntent.getBroadcast(c, 0,
                Intent(c, UsageWidget::class.java).setAction(ACTION_REFRESH), flags)
            v.setOnClickPendingIntent(R.id.root, refresh)
            val open = PendingIntent.getActivity(c, 1, Intent(c, MainActivity::class.java), flags)
            v.setOnClickPendingIntent(R.id.mascot, open)
            return v
        }
    }
}
