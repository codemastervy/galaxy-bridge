package nz.galaxybridge.watch

import android.content.Context
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.DimensionBuilders.wrap
import androidx.wear.protolayout.LayoutElementBuilders as L
import androidx.wear.protolayout.ModifiersBuilders as M
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

/** iPhone Reminders, as sent by the phone. Ticking one off on the watch tells the phone. */
object Reminders {
    data class Item(val id: String, val title: String, val due: Long, val list: String)

    val items = MutableStateFlow<List<Item>>(emptyList())
    private fun prefs(c: Context) = c.getSharedPreferences("reminders", Context.MODE_PRIVATE)

    fun receive(s: LinkService, j: JSONObject) {
        val arr = j.optJSONArray("items") ?: return
        if (arr.length() > 50) return
        val list = (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val id = o.optString("id").take(120)
            if (id.isEmpty()) return@mapNotNull null
            Item(id, Features.clean(o.optString("title")).take(80), o.optLong("due", 0).coerceAtLeast(0),
                Features.clean(o.optString("list")).take(30))
        }
        items.value = list
        prefs(s).edit().putString("items", arr.toString()).apply()
        Tiles.refresh(s)
    }

    fun load(c: Context): List<Item> {
        if (items.value.isEmpty()) {
            val s = prefs(c).getString("items", null) ?: return emptyList()
            val arr = runCatching { JSONArray(s) }.getOrNull() ?: return emptyList()
            items.value = (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                Item(o.optString("id"), o.optString("title"), o.optLong("due"), o.optString("list"))
            }
        }
        return items.value
    }

    fun complete(c: Context, id: String) {
        val left = load(c).filterNot { it.id == id }
        items.value = left
        prefs(c).edit().putString("items", JSONArray(left.map {
            JSONObject().put("id", it.id).put("title", it.title).put("due", it.due).put("list", it.list)
        }).toString()).apply()
        LinkService.sendFeature("reminderDone", JSONObject().put("id", id))
    }
}

object Tiles {
    fun refresh(c: Context) {
        for (cls in listOf(CalendarTile::class.java, RemindersTile::class.java, WeatherTile::class.java,
            PhoneBatteryTile::class.java, NowPlayingTile::class.java)) {
            runCatching { TileService.getUpdater(c).requestUpdate(cls) }
        }
    }

    // --- tiny layout kit ---
    const val WHITE = 0xFFFFFFFF.toInt()
    const val DIM = 0x99FFFFFF.toInt()
    const val ACCENT = 0xFF2ED1DB.toInt()
    const val CHIP = 0x2EFFFFFF

    fun text(s: String, size: Float = 14f, color: Int = WHITE, bold: Boolean = false, lines: Int = 1): L.LayoutElement =
        L.Text.Builder().setText(s).setMaxLines(lines)
            .setOverflow(L.TEXT_OVERFLOW_ELLIPSIZE_END)
            .setFontStyle(L.FontStyle.Builder().setSize(sp(size)).setColor(argb(color))
                .setWeight(if (bold) L.FONT_WEIGHT_BOLD else L.FONT_WEIGHT_NORMAL).build())
            .build()

    fun space(h: Float) = L.Spacer.Builder().setHeight(dp(h)).build()

    fun column(vararg items: L.LayoutElement): L.LayoutElement =
        L.Column.Builder().setWidth(expand()).setHorizontalAlignment(L.HORIZONTAL_ALIGN_CENTER)
            .apply { items.forEach { addContent(it) } }.build()

    fun row(vararg items: L.LayoutElement): L.LayoutElement =
        L.Row.Builder().setVerticalAlignment(L.VERTICAL_ALIGN_CENTER).apply { items.forEach { addContent(it) } }.build()

    /** A rounded, tappable pill; [id] comes back as the last clickable id on the next request. */
    fun chip(c: Context, content: L.LayoutElement, id: String? = null, color: Int = CHIP, width: Float = 170f): L.LayoutElement {
        val clickable = M.Clickable.Builder().setId(id ?: "open").setOnClick(
            if (id != null) ActionBuilders.LoadAction.Builder().build()
            else ActionBuilders.LaunchAction.Builder().setAndroidActivity(
                ActionBuilders.AndroidActivity.Builder().setPackageName(c.packageName)
                    .setClassName(MainActivity::class.java.name).build()).build()
        ).build()
        return L.Box.Builder().setWidth(dp(width)).setHeight(wrap())
            .setModifiers(M.Modifiers.Builder()
                .setClickable(clickable)
                .setBackground(M.Background.Builder().setColor(argb(color))
                    .setCorner(M.Corner.Builder().setRadius(dp(18f)).build()).build())
                .setPadding(M.Padding.Builder().setStart(dp(10f)).setEnd(dp(10f)).setTop(dp(6f)).setBottom(dp(6f)).build())
                .build())
            .addContent(content).build()
    }

    fun page(c: Context, root: L.LayoutElement, freshMs: Long = 15 * 60_000L): TileBuilders.Tile =
        TileBuilders.Tile.Builder().setResourcesVersion("1").setFreshnessIntervalMillis(freshMs)
            .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(
                L.Box.Builder().setWidth(expand()).setHeight(expand())
                    .setVerticalAlignment(L.VERTICAL_ALIGN_CENTER)
                    .setModifiers(M.Modifiers.Builder().setClickable(M.Clickable.Builder().setId("open").setOnClick(
                        ActionBuilders.LaunchAction.Builder().setAndroidActivity(
                            ActionBuilders.AndroidActivity.Builder().setPackageName(c.packageName)
                                .setClassName(MainActivity::class.java.name).build()).build()).build()).build())
                    .addContent(root).build()))
            .build()
}

/** Shared plumbing: a tile is a function of the context and the last tapped id. */
abstract class SimpleTile : TileService() {
    abstract fun build(clicked: String): TileBuilders.Tile

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> {
        PhoneInfo.load(this)
        val clicked = runCatching { requestParams.currentState.lastClickableId }.getOrDefault("")
        val tile = build(clicked)
        return CallbackToFutureAdapter.getFuture { it.set(tile); "tile" }
    }

    override fun onTileResourcesRequest(requestParams: RequestBuilders.ResourcesRequest): ListenableFuture<ResourceBuilders.Resources> =
        CallbackToFutureAdapter.getFuture { it.set(ResourceBuilders.Resources.Builder().setVersion("1").build()); "res" }
}

class CalendarTile : SimpleTile() {
    override fun build(clicked: String): TileBuilders.Tile {
        val fmt = DateFormat.getTimeInstance(DateFormat.SHORT)
        val now = System.currentTimeMillis()
        val next = LinkService.events.value.filter { it.end > now }.take(3)
        val rows = next.map { e ->
            Tiles.column(
                Tiles.text(if (e.allDay) "All day" else fmt.format(Date(e.start)), 11f, Tiles.ACCENT),
                Tiles.text(e.title.ifEmpty { "Event" }, 14f, bold = true))
        }
        val body = if (rows.isEmpty()) arrayOf(Tiles.text("No more events today", 13f, Tiles.DIM))
        else rows.flatMap { listOf(it, Tiles.space(4f)) }.toTypedArray()
        return Tiles.page(this, Tiles.column(Tiles.text("Calendar", 12f, Tiles.DIM), Tiles.space(6f), *body))
    }
}

class RemindersTile : SimpleTile() {
    override fun build(clicked: String): TileBuilders.Tile {
        if (clicked.startsWith("done:")) Reminders.complete(this, clicked.removePrefix("done:"))
        val items = Reminders.load(this).take(3)
        val rows = items.map { r ->
            Tiles.chip(this, Tiles.row(Tiles.text("○  ", 14f, Tiles.ACCENT), Tiles.text(r.title.ifEmpty { "Reminder" }, 13f)),
                id = "done:${r.id}")
        }
        val body = if (rows.isEmpty()) arrayOf(Tiles.text("All done", 13f, Tiles.DIM))
        else rows.flatMap { listOf(it, Tiles.space(4f)) }.toTypedArray()
        return Tiles.page(this, Tiles.column(Tiles.text("Reminders", 12f, Tiles.DIM), Tiles.space(6f), *body))
    }
}

class WeatherTile : SimpleTile() {
    override fun build(clicked: String): TileBuilders.Tile {
        val w = LinkService.weather.value
            ?: return Tiles.page(this, Tiles.column(Tiles.text("Weather", 12f, Tiles.DIM), Tiles.text("Waiting for iPhone", 13f)))
        return Tiles.page(this, Tiles.column(
            Tiles.text(w.place.ifEmpty { "Weather" }, 12f, Tiles.DIM),
            Tiles.text(weatherSymbol(w.code), 30f),
            Tiles.text("${w.tempC.toInt()}°", 34f, bold = true),
            Tiles.text("H ${w.highC.toInt()}°  L ${w.lowC.toInt()}°", 13f, Tiles.DIM)))
    }
}

class PhoneBatteryTile : SimpleTile() {
    override fun build(clicked: String): TileBuilders.Tile {
        val b = PhoneInfo.battery(this)
        return Tiles.page(this, Tiles.column(
            Tiles.text("iPhone", 12f, Tiles.DIM),
            Tiles.text(b?.let { "${it.first}%" } ?: "--", 40f, bold = true),
            Tiles.text(when { b == null -> "Not connected"; b.second -> "Charging"; else -> "Battery" }, 13f, Tiles.ACCENT)), 5 * 60_000L)
    }
}

class NowPlayingTile : SimpleTile() {
    override fun build(clicked: String): TileBuilders.Tile {
        when (clicked) {
            "prev" -> LinkService.media(Ams.CMD_PREVIOUS)
            "toggle" -> LinkService.media(Ams.CMD_TOGGLE)
            "next" -> LinkService.media(Ams.CMD_NEXT)
        }
        val np = AppleClient.nowPlaying.value
        fun button(label: String, id: String) = Tiles.chip(this, Tiles.text(label, 16f, bold = true), id, width = 48f)
        return Tiles.page(this, Tiles.column(
            Tiles.text("Now playing", 12f, Tiles.DIM),
            Tiles.space(4f),
            Tiles.text(np.title.ifEmpty { "Nothing playing" }, 15f, bold = true, lines = 2),
            Tiles.text(np.artist, 12f, Tiles.DIM),
            Tiles.space(8f),
            Tiles.row(button("⏮", "prev"), L.Spacer.Builder().setWidth(dp(6f)).build(),
                button(if (np.playing) "❚❚" else "▶", "toggle"), L.Spacer.Builder().setWidth(dp(6f)).build(),
                button("⏭", "next"))), 60_000L)
    }
}
