package info.jorgemora.claudeusage

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Pinta los widgets en varios tamaños con datos de ejemplo y guarda capturas */
@RunWith(AndroidJUnit4::class)
class Capturas {
    @Test
    fun formatos() {
        val ins = InstrumentationRegistry.getInstrumentation()
        val c = ins.targetContext
        val now = System.currentTimeMillis()
        Store.save(c, "claude", listOf(
            Row("Sesión (5 h)", 34.0, now + 2 * 3600_000, 18000),
            Row("Semana", 61.0, now + 3 * 86400_000, 604800),
            Row("Semana · Sonnet", 12.0, now + 3 * 86400_000, 604800)), null)
        Store.save(c, "gpt", listOf(
            Row("Sesión (5 h)", 8.0, now + 4 * 3600_000, 18000),
            Row("Semana", 92.0, now + 86400_000, 604800)), null)
        Wallets.save(c, "openai", Wallet(available = 7.4, used = 12.6, granted = 20.0, month = 3.2, source = "OpenAI"), null)
        Wallets.save(c, "soniox", null, "Falta la clave de Soniox: ábrela en la app")
        val dir = File(c.getExternalFilesDir(null), "shots").apply { mkdirs() }
        val d = c.resources.displayMetrics.density
        val cards = Cards.all(c)
        val sizes = listOf(
            "fila-4x1" to (330f to 70f), "fila-2x1" to (160f to 70f), "fila-5x1" to (410f to 70f),
            "grande-4x3" to (330f to 300f), "grande-4x2" to (330f to 180f), "grande-2x2" to (160f to 180f),
            "grande-3x2" to (250f to 150f), "grande-4x4" to (330f to 420f), "dos-servicios-4x2" to (330f to 180f),
        )
        for ((name, wh) in sizes) {
            val (w, h) = wh
            val list = if (name.startsWith("dos")) cards.take(2) else cards
            ins.runOnMainSync {
                val parent = FrameLayout(c)
                val v: View = Widgets.build(c, list, w, h, false).apply(c, parent)
                val pw = (w * d).toInt(); val ph = (h * d).toInt()
                v.measure(View.MeasureSpec.makeMeasureSpec(pw, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(ph, View.MeasureSpec.EXACTLY))
                v.layout(0, 0, pw, ph)
                val bmp = Bitmap.createBitmap(pw, ph, Bitmap.Config.ARGB_8888)
                Canvas(bmp).apply { drawColor(0xFF3A5A7A.toInt()) ; v.draw(this) }
                File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
    }
}
