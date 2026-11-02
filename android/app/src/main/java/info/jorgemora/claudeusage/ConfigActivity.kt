package info.jorgemora.claudeusage

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Elegir qué servicios muestra cada widget (mantén pulsado el widget › Configuración) */
class ConfigActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()
        val result = Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
        setResult(RESULT_OK, result)   // si se sale sin tocar nada, el widget se queda con todo
        val d = resources.displayMetrics.density
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((20 * d).toInt(), (24 * d).toInt(), (20 * d).toInt(), (24 * d).toInt())
        }
        root.addView(TextView(this).apply {
            text = "¿Qué muestra este widget?"
            textSize = 22f; setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        val current = Widgets.services(this, id)
        val boxes = Service.entries.map { s ->
            CheckBox(this).apply {
                text = s.title + if (s.isAPI) "  (saldo y gasto)" else "  (5 horas y semana)"
                textSize = 17f; setTextColor(Color.WHITE)
                isChecked = s in current
                setPadding(0, (10 * d).toInt(), 0, (10 * d).toInt())
            }.also { root.addView(it) }
        }
        root.addView(Button(this).apply {
            text = "Guardar"
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply { cornerRadius = 14 * d; setColor(0x33FFFFFF) }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (50 * d).toInt()).apply { topMargin = (16 * d).toInt() }
            setOnClickListener {
                val chosen = Service.entries.filterIndexed { i, _ -> boxes[i].isChecked }
                Widgets.setServices(this@ConfigActivity, id, chosen.ifEmpty { Service.entries.toList() })
                Widgets.render(this@ConfigActivity, AppWidgetManager.getInstance(this@ConfigActivity), id)
                setResult(RESULT_OK, result)
                finish()
            }
        })
        setContentView(ScrollView(this).apply {
            setBackgroundColor(0xFF1C1817.toInt())
            fitsSystemWindows = true
            addView(root)
        })
    }
}
