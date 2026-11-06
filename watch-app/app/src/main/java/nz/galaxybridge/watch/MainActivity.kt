package nz.galaxybridge.watch

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.layout.fillMaxSize
import androidx.wear.compose.material.Icon
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.ScalingLazyListScope
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.PositionIndicator
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import androidx.wear.compose.material.ToggleChip
import androidx.wear.compose.material.ToggleChipDefaults
import androidx.wear.compose.material.dialog.Alert
import androidx.wear.compose.material.dialog.Dialog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private val Accent = Color(0xFF5C6BFF)
private val Accent2 = Color(0xFF2ED1DB)
private val Good = Color(0xFF3DDC84)
private val Wait = Color(0xFFFFC542)
private val Dim = Color.White.copy(alpha = 0.6f)

class MainActivity : ComponentActivity() {
    companion object {
        const val EXTRA_PAGE = "page"
        const val PAGE_HOME = 0
        const val PAGE_MUSIC = 1
        const val PAGE_CAMERA = 2
        const val PAGE_FIND = 3
        const val PAGE_SETTINGS = 4
        const val PAGE_WORKOUT = 5
    }

    private val permissions = arrayOf(
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.BLUETOOTH_ADVERTISE,
        Manifest.permission.BODY_SENSORS,
        Manifest.permission.ACTIVITY_RECOGNITION,
        Manifest.permission.POST_NOTIFICATIONS,
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.READ_CONTACTS,
        Manifest.permission.WRITE_CONTACTS,
        Manifest.permission.READ_MEDIA_AUDIO,
    )

    private val request = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        startIfAllowed()
    }

    private var page by mutableIntStateOf(PAGE_HOME)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        page = intent.getIntExtra(EXTRA_PAGE, PAGE_HOME)
        setContent { MaterialTheme { Screen() } }
        if (missing().isEmpty()) startIfAllowed() else request.launch(missing().toTypedArray())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        page = intent.getIntExtra(EXTRA_PAGE, page)
    }

    private fun missing() = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    private fun startIfAllowed() {
        val needed = setOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        if (missing().any { it in needed }) return
        LinkService.start(this)
        askToIgnoreBatteryOptimisation()
        if (checkSelfPermission(Manifest.permission.BODY_SENSORS) == PackageManager.PERMISSION_GRANTED) {
            lifecycleScope.launch { runCatching { Health.register(this@MainActivity) } }
        }
    }

    /** Without this Samsung's battery manager stops the link service when the watch idles. */
    private fun askToIgnoreBatteryOptimisation() {
        val pm = getSystemService(android.os.PowerManager::class.java)
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        runCatching {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        }
    }

    @Composable
    private fun Screen() {
        BackHandler(enabled = page != PAGE_HOME) { page = PAGE_HOME }
        val listState = rememberScalingLazyListState()
        LaunchedEffect(page) { listState.scrollToItem(0) }
        Scaffold(
            timeText = { TimeText() },
            positionIndicator = { PositionIndicator(scalingLazyListState = listState) },
            modifier = Modifier.background(Color.Black).background(Brush.radialGradient(
                listOf(Color(0xFF2A1F6B), Color(0xFF0B1F33), Color.Black), radius = 420f)),
        ) {
            ScalingLazyColumn(
                state = listState,
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                when (page) {
                    PAGE_MUSIC -> musicPage()
                    PAGE_CAMERA -> cameraPage()
                    PAGE_FIND -> findPage()
                    PAGE_SETTINGS -> settingsPage()
                    PAGE_WORKOUT -> workoutPage()
                    else -> homePage()
                }
            }
        }
    }

    // --- Home ---

    private fun ScalingLazyListScope.homePage() {
        item { HeroRing() }
        item { PairingOrNothing() }
        item { ClockCard() }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Launcher(R.drawable.ic_run, "Workout", Good, Color(0xFF0E8F5A)) { page = PAGE_WORKOUT }
                Launcher(R.drawable.ic_music, "Music", Accent, Color(0xFFB04CFF)) { page = PAGE_MUSIC }
                Launcher(R.drawable.ic_camera, "Camera", Accent2, Color(0xFF1E5BB8)) { page = PAGE_CAMERA }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Launcher(R.drawable.ic_find, "Find", Wait, Color(0xFFFF7A2E)) { page = PAGE_FIND }
                Launcher(R.drawable.ic_tune, "Settings", Color(0xFF8E96B8), Color(0xFF3A3F5C)) { page = PAGE_SETTINGS }
            }
        }
        item { WeatherCard() }
        item { AgendaCard() }
    }

    @Composable
    private fun PairingOrNothing() {
        val pairingUntil by LinkService.pairingUntil.collectAsState()
        val hasPhone by LinkService.hasPhone.collectAsState()
        when {
            pairingUntil > 0 -> PairingCard(pairingUntil) { LinkService.cancelPairing() }
            !hasPhone -> Chip(
                onClick = { LinkService.openPairing() },
                label = { Text("Pair iPhone") },
                secondaryLabel = { Text("Start here") },
                colors = ChipDefaults.gradientBackgroundChipColors(startBackgroundColor = Accent, endBackgroundColor = Accent2),
                modifier = Modifier.fillMaxWidth(),
            )
            else -> Spacer(Modifier.height(0.dp))
        }
    }

    /** Apps can't set the system clock, so point the user at Date & time when it's wrong. */
    @Composable
    private fun ClockCard() {
        val skew by LinkService.clockSkew.collectAsState()
        val zone by LinkService.zoneMismatch.collectAsState()
        if (skew == 0L && zone.isEmpty()) return
        val minutes = kotlin.math.abs(skew) / 60_000
        val off = when {
            skew == 0L -> "Time zone differs from iPhone ($zone)"
            minutes >= 60 * 24 -> "Off by ${minutes / (60 * 24)} days"
            minutes >= 60 -> "Off by ${minutes / 60} h"
            else -> "Off by $minutes min"
        }
        Chip(
            onClick = { open(Intent(Settings.ACTION_DATE_SETTINGS)) },
            label = { Text("Watch time is wrong") },
            secondaryLabel = { Text("$off · Tap to fix", maxLines = 2) },
            colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF8A3B12)),
            modifier = Modifier.fillMaxWidth(),
        )
    }

    @Composable
    private fun PhoneSummary() {
        val battery by LinkService.phoneBattery.collectAsState()
        val ancs by AppleClient.connected.collectAsState()
        val status by LinkService.statusFlow().collectAsState()
        if (status != LinkService.Status.CONNECTED) return
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.08f))
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("iPhone", style = MaterialTheme.typography.caption2, color = Dim)
                Text(battery?.let { "${it.percent}%" + if (it.charging) " ⚡" else "" } ?: "—",
                    fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("Notifications", style = MaterialTheme.typography.caption3, color = Dim)
                Text(if (ancs) "On" else "Off", style = MaterialTheme.typography.caption2,
                    color = if (ancs) Good else Wait)
            }
        }
    }

    @Composable
    private fun WeatherCard() {
        val w by LinkService.weather.collectAsState()
        val weather = w ?: return
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
                .background(Brush.linearGradient(listOf(Color(0xFF1E5BB8), Color(0xFF2ED1DB))))
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(weatherSymbol(weather.code), fontSize = 26.sp)
            Spacer(Modifier.size(10.dp))
            Column(Modifier.weight(1f)) {
                Text("${weather.tempC.toInt()}°", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color.White)
                Text(weather.place.ifEmpty { "Weather" }, style = MaterialTheme.typography.caption3,
                    color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text("H ${weather.highC.toInt()}°\nL ${weather.lowC.toInt()}°", style = MaterialTheme.typography.caption3,
                color = Color.White, textAlign = TextAlign.End)
        }
    }

    @Composable
    private fun AgendaCard() {
        val events by LinkService.events.collectAsState()
        val upcoming = events.filter { it.end > System.currentTimeMillis() }.take(3)
        if (upcoming.isEmpty()) return
        val fmt = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.08f))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Text("Up next", style = MaterialTheme.typography.caption2, color = Accent2)
            for (e in upcoming) {
                Row(Modifier.padding(top = 4.dp)) {
                    Text(if (e.allDay) "All day" else fmt.format(Date(e.start)),
                        style = MaterialTheme.typography.caption3, color = Dim, modifier = Modifier.size(width = 48.dp, height = 16.dp))
                    Text(e.title.ifEmpty { "Event" }, style = MaterialTheme.typography.caption2, color = Color.White,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }

    // --- Music ---

    private fun ScalingLazyListScope.musicPage() {
        item { ListHeader { Text("Music") } }
        item { MusicControls() }
    }

    @Composable
    private fun MusicControls() {
        val np by AppleClient.nowPlaying.collectAsState()
        val ancs by AppleClient.connected.collectAsState()
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
            Text(np.title.ifEmpty { if (np.active) np.player else "Nothing playing" }, fontWeight = FontWeight.SemiBold,
                color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp))
            Text(np.artist.ifEmpty { if (ancs) "Play something on your iPhone" else "Waiting for iPhone" },
                style = MaterialTheme.typography.caption2, color = Dim, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                SmallRound("⏮") { LinkService.media(Ams.CMD_PREVIOUS) }
                Button(onClick = { LinkService.media(Ams.CMD_TOGGLE) }, modifier = Modifier.size(56.dp),
                    colors = ButtonDefaults.buttonColors(backgroundColor = Accent)) {
                    Text(if (np.playing) "❚❚" else "▶", fontSize = 18.sp, color = Color.White)
                }
                SmallRound("⏭") { LinkService.media(Ams.CMD_NEXT) }
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                SmallRound("−") { LinkService.media(Ams.CMD_VOLUME_DOWN) }
                SmallRound("+") { LinkService.media(Ams.CMD_VOLUME_UP) }
            }
        }
    }

    // --- Camera ---

    private fun ScalingLazyListScope.cameraPage() {
        item { ListHeader { Text("Camera remote") } }
        item { CameraPreviewBox() }
        item { CameraControls() }
        item {
            val remote by HidShutter.connected.collectAsState()
            val status by LinkService.statusFlow().collectAsState()
            ShutterButton(enabled = status == LinkService.Status.CONNECTED || remote) { LinkService.sendShutter() }
        }
        item {
            val remote by HidShutter.connected.collectAsState()
            Text(if (remote) "Works in the iPhone Camera app" else "Open the camera in Wear OS Bridge on your iPhone",
                style = MaterialTheme.typography.caption3, color = Dim, textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 20.dp))
        }
    }

    @Composable
    private fun CameraPreviewBox() {
        val frame by CameraRemote.frame.collectAsState()
        val open by CameraRemote.open.collectAsState()
        androidx.compose.runtime.DisposableEffect(Unit) {
            CameraRemote.view(true)
            onDispose { CameraRemote.view(false) }
        }
        val bmp = frame
        if (bmp != null) {
            androidx.compose.foundation.Image(bmp.asImageBitmap(), contentDescription = "iPhone camera preview",
                modifier = Modifier.size(140.dp).clip(RoundedCornerShape(16.dp)),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        } else if (open) {
            Text("Loading preview…", style = MaterialTheme.typography.caption3, color = Dim)
        }
    }

    @Composable
    private fun CameraControls() {
        val open by CameraRemote.open.collectAsState()
        val timer by CameraRemote.timer.collectAsState()
        if (!open) return
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallRound("⟲") { CameraRemote.command("flip") }
            SmallRound(if (timer == 0) "⏱" else "${timer}s") { CameraRemote.command("timer") }
        }
    }

    // --- Workout ---

    private fun ScalingLazyListScope.workoutPage() {
        item { ListHeader { Text("Workout") } }
        item { WorkoutPanel() }
    }

    @Composable
    private fun WorkoutPanel() {
        val live by Workouts.live.collectAsState()
        var error by remember { mutableStateOf<String?>(null) }
        val current = live
        if (current == null) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for (k in Workouts.Kind.entries) Chip(
                    onClick = { lifecycleScope.launch { error = Workouts.start(this@MainActivity, k) } },
                    label = { Text(k.label) },
                    colors = ChipDefaults.secondaryChipColors(), modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, style = MaterialTheme.typography.caption3, color = Wait, textAlign = TextAlign.Center) }
                Text("Saved to Apple Health with your route", style = MaterialTheme.typography.caption3, color = Dim,
                    textAlign = TextAlign.Center)
            }
            return
        }
        var now by remember { mutableStateOf(android.os.SystemClock.elapsedRealtime()) }
        LaunchedEffect(Unit) { while (true) { delay(1000); now = android.os.SystemClock.elapsedRealtime() } }
        val secs = (now - Workouts.startedAt) / 1000
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(current.kind.label + if (current.gps) " · GPS" else "", style = MaterialTheme.typography.caption2, color = Good)
            Text("%d:%02d:%02d".format(secs / 3600, secs / 60 % 60, secs % 60), fontSize = 28.sp,
                fontWeight = FontWeight.Bold, color = Color.White)
            Text("♥ ${current.hr.toInt().takeIf { it > 0 } ?: "--"}   ${"%.2f".format(current.distM / 1000)} km   ${current.kcal.toInt()} kcal",
                style = MaterialTheme.typography.caption2, color = Color.White)
            Spacer(Modifier.height(8.dp))
            Button(onClick = { lifecycleScope.launch { Workouts.stop(this@MainActivity) } },
                colors = ButtonDefaults.buttonColors(backgroundColor = Color(0xFFE5484D))) { Text("End") }
        }
    }

    // --- Find ---

    private fun ScalingLazyListScope.findPage() {
        item { ListHeader { Text("Find iPhone") } }
        item {
            val finding by LinkService.findingPhone.collectAsState()
            val status by LinkService.statusFlow().collectAsState()
            Button(
                onClick = { LinkService.findPhone(!finding) },
                enabled = status == LinkService.Status.CONNECTED,
                modifier = Modifier.size(96.dp),
                colors = ButtonDefaults.buttonColors(backgroundColor = if (finding) Color(0xFFE5484D) else Wait),
            ) { Text(if (finding) "Stop" else "Ring", fontWeight = FontWeight.Bold, color = Color.Black) }
        }
        item {
            Text("Your iPhone plays a sound, even on silent if Wear OS Bridge is allowed to send alerts.",
                style = MaterialTheme.typography.caption3, color = Dim, textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 20.dp))
        }
    }

    // --- Settings ---

    private fun ScalingLazyListScope.settingsPage() {
        item { ListHeader { Text("Settings") } }
        item { Toggle("iPhone notifications", WatchSettings.NOTIFICATIONS) }
        item { Toggle("Incoming calls", WatchSettings.CALLS) }
        item { Toggle("Clear on iPhone too", WatchSettings.CLEAR_ON_IPHONE) }
        item { Toggle("Music controls", WatchSettings.MUSIC) }
        item { ListHeader { Text("Apple Health sync") } }
        item { Toggle("Heart rate", WatchSettings.SYNC_HEART) }
        item { Toggle("Steps", WatchSettings.SYNC_STEPS) }
        item { Toggle("Active energy", WatchSettings.SYNC_ENERGY) }
        item { Toggle("Distance", WatchSettings.SYNC_DISTANCE) }
        item { ListHeader { Text("Let iPhone change") } }
        item { PermissionChips() }
        item { ListHeader { Text("Phone") } }
        item { PhoneChips() }
        item { AboutText() }
    }

    @Composable
    private fun Toggle(label: String, key: String) {
        val context = LocalContext.current
        val version by WatchSettings.changes.collectAsState()
        val on = remember(version) { WatchSettings.enabled(context, key) }
        ToggleChip(
            checked = on,
            onCheckedChange = { WatchSettings.set(context, key, if (it) 1 else 0) },
            label = { Text(label) },
            toggleControl = { androidx.wear.compose.material.Icon(
                imageVector = ToggleChipDefaults.switchIcon(on), contentDescription = if (on) "On" else "Off") },
            modifier = Modifier.fillMaxWidth(),
        )
    }

    @Composable
    private fun PermissionChips() {
        val context = LocalContext.current
        var tick by remember { mutableIntStateOf(0) }
        LaunchedEffect(Unit) { while (true) { delay(2000); tick++ } }
        val system = remember(tick) { WatchSettings.canWriteSystem(context) }
        val dnd = remember(tick) { WatchSettings.canChangeDnd(context) }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Chip(
                onClick = { open(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:$packageName"))) },
                label = { Text("Brightness & timeout") },
                secondaryLabel = { Text(if (system) "Allowed" else "Tap to allow") },
                colors = ChipDefaults.secondaryChipColors(), modifier = Modifier.fillMaxWidth(),
            )
            Chip(
                onClick = { open(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) },
                label = { Text("Do Not Disturb") },
                secondaryLabel = { Text(if (dnd) "Allowed" else "Tap to allow") },
                colors = ChipDefaults.secondaryChipColors(), modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    private fun open(intent: Intent) {
        runCatching { startActivity(intent) }
    }

    @Composable
    private fun PhoneChips() {
        val hasPhone by LinkService.hasPhone.collectAsState()
        val pairingUntil by LinkService.pairingUntil.collectAsState()
        var confirmForget by remember { mutableStateOf(false) }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (hasPhone && pairingUntil == 0L) Chip(
                onClick = { LinkService.openPairing(); page = PAGE_HOME },
                label = { Text("Pair new phone") },
                secondaryLabel = { Text("Replaces this iPhone") },
                colors = ChipDefaults.secondaryChipColors(), modifier = Modifier.fillMaxWidth(),
            )
            Chip(
                onClick = { confirmForget = true },
                label = { Text("Forget iPhone") },
                secondaryLabel = { Text(if (hasPhone) "Stops syncing" else "Clears old pairings") },
                colors = ChipDefaults.secondaryChipColors(), modifier = Modifier.fillMaxWidth(),
            )
        }
        Dialog(showDialog = confirmForget, onDismissRequest = { confirmForget = false }) {
            Alert(
                title = { Text("Forget iPhone?", textAlign = TextAlign.Center) },
                negativeButton = {
                    Button(onClick = { confirmForget = false }, colors = ButtonDefaults.secondaryButtonColors()) { Text("✕") }
                },
                positiveButton = {
                    Button(onClick = { LinkService.forgetPhone(this@MainActivity); confirmForget = false }) { Text("✓") }
                },
            ) {
                Text("Notifications and health sync stop until you pair again.", textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.body2)
            }
        }
    }

    @Composable
    private fun AboutText() {
        Text("Wear OS Bridge ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.caption3, color = Dim,
            modifier = Modifier.padding(top = 8.dp, bottom = 24.dp))
    }

    @Composable
    private fun NavChip(label: String, secondary: String, dot: Color, onClick: () -> Unit) {
        Chip(
            onClick = onClick,
            label = { Text(label) },
            secondaryLabel = { Text(secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            icon = { Box(Modifier.size(10.dp).clip(CircleShape).background(dot)) },
            colors = ChipDefaults.secondaryChipColors(),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** Round status hero: the arc is the iPhone's battery, the glow shows the link state. */
@Composable
private fun HeroRing() {
    val status by LinkService.statusFlow().collectAsState()
    val battery by LinkService.phoneBattery.collectAsState()
    val ancs by AppleClient.connected.collectAsState()
    val pending by LinkService.pending.collectAsState()
    val connected = status == LinkService.Status.CONNECTED
    val level by animateFloatAsState((battery?.percent ?: 0) / 100f, label = "level")
    val pulse by rememberInfiniteTransition(label = "pulse").animateFloat(
        0.35f, 0.8f, infiniteRepeatable(tween(1600), RepeatMode.Reverse), label = "glow")
    val glow = if (connected) Accent2 else Wait
    Box(contentAlignment = Alignment.Center, modifier = Modifier.padding(top = 18.dp).size(132.dp)) {
        Canvas(Modifier.fillMaxSize()) {
            val w = 9.dp.toPx()
            drawCircle(Brush.radialGradient(listOf(glow.copy(alpha = 0.28f * pulse), Color.Transparent)))
            drawArc(Color.White.copy(alpha = 0.10f), 0f, 360f, false, style = Stroke(w))
            if (connected && battery != null) drawArc(
                Brush.sweepGradient(listOf(Accent2, Accent, Color(0xFFB04CFF), Accent2)),
                -90f, 360f * level, false, style = Stroke(w, cap = StrokeCap.Round))
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("WEAR OS BRIDGE", fontSize = 8.sp, letterSpacing = 1.6.sp, fontWeight = FontWeight.Bold, color = Accent2)
            Text(if (connected) battery?.let { "${it.percent}%" } ?: "—" else "—",
                fontSize = 30.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Text(if (battery?.charging == true && connected) "iPhone ⚡" else "iPhone",
                style = MaterialTheme.typography.caption3, color = Dim)
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 3.dp)) {
                Box(Modifier.size(6.dp).clip(CircleShape).background(if (connected) Good else Wait))
                Spacer(Modifier.size(4.dp))
                Text(when (status) {
                    LinkService.Status.CONNECTED -> if (ancs) "Linked · alerts on" else "Linked"
                    LinkService.Status.WAITING -> "Waiting"
                    LinkService.Status.STOPPED -> "Allow permissions"
                }, fontSize = 10.sp, color = Color.White.copy(alpha = 0.85f))
            }
        }
    }
    if (pending > 0) Text(if (connected) "Syncing $pending to Health" else "$pending waiting for iPhone",
        style = MaterialTheme.typography.caption3, color = Accent2)
}

/** Round gradient launcher with a caption. */
@Composable
private fun Launcher(icon: Int, label: String, from: Color, to: Color, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Button(onClick = onClick, modifier = Modifier.size(48.dp),
            colors = ButtonDefaults.buttonColors(backgroundColor = Color.Transparent)) {
            Box(Modifier.fillMaxSize().clip(CircleShape).background(Brush.linearGradient(listOf(from, to))),
                contentAlignment = Alignment.Center) {
                Icon(painterResource(icon), contentDescription = label, tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }
        Text(label, fontSize = 10.sp, color = Color.White.copy(alpha = 0.8f), modifier = Modifier.padding(top = 2.dp))
    }
}

@Composable
private fun StatusHeader() {
    val status by LinkService.statusFlow().collectAsState()
    val pending by LinkService.pending.collectAsState()
    val connected = status == LinkService.Status.CONNECTED
    val dot by animateColorAsState(if (connected) Good else Wait, label = "dot")
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(top = 24.dp)) {
        Text("Wear OS Bridge", fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = Color.White)
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
            Spacer(Modifier.size(6.dp))
            Text(
                when (status) {
                    LinkService.Status.CONNECTED -> "iPhone connected"
                    LinkService.Status.WAITING -> "Waiting for iPhone"
                    LinkService.Status.STOPPED -> "Allow permissions"
                },
                style = MaterialTheme.typography.caption2,
                color = Color.White.copy(alpha = 0.8f),
            )
        }
        if (pending > 0) {
            Text(if (connected) "Syncing $pending to Apple Health" else "$pending waiting for iPhone",
                style = MaterialTheme.typography.caption3, color = Accent2)
        }
    }
}

@Composable
private fun PairingCard(until: Long, onCancel: () -> Unit) {
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(until) {
        while (System.currentTimeMillis() < until) { now = System.currentTimeMillis(); delay(1000) }
    }
    val seconds = ((until - now) / 1000).coerceAtLeast(0)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Brush.linearGradient(listOf(Accent, Accent2)))
            .padding(12.dp),
    ) {
        Text("Ready to pair", fontWeight = FontWeight.SemiBold, color = Color.White)
        Text("On your iPhone: Wear OS Bridge → Find my watch. Check the codes match.",
            style = MaterialTheme.typography.caption3, color = Color.White, textAlign = TextAlign.Center)
        Text("${seconds / 60}:${"%02d".format(seconds % 60)}", style = MaterialTheme.typography.caption2,
            color = Color.White.copy(alpha = 0.85f), modifier = Modifier.padding(top = 4.dp))
        Chip(onClick = onCancel, label = { Text("Cancel") }, colors = ChipDefaults.secondaryChipColors(),
            modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun SmallRound(symbol: String, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = Modifier.size(40.dp), colors = ButtonDefaults.secondaryButtonColors()) {
        Text(symbol, fontSize = 16.sp, color = Color.White)
    }
}

/** WMO weather code (as sent by the iPhone app) to a symbol. */
internal fun weatherSymbol(code: Int) = when (code) {
    0 -> "☀️"
    1, 2 -> "⛅"
    3 -> "☁️"
    45, 48 -> "🌫️"
    in 51..67, in 80..82 -> "🌧️"
    in 71..77, 85, 86 -> "❄️"
    in 95..99 -> "⛈️"
    else -> "🌡️"
}

/** Big circular shutter with a ring that pulses on press. */
@Composable
private fun ShutterButton(enabled: Boolean, onClick: () -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (pressed) 0.9f else 1f, label = "press")
    LaunchedEffect(pressed) {
        if (pressed) { delay(120); pressed = false }
    }
    Button(
        onClick = { pressed = true; onClick() },
        enabled = enabled,
        modifier = Modifier
            .size(96.dp)
            .scale(scale)
            .semantics { contentDescription = "Take photo" },
        colors = ButtonDefaults.buttonColors(backgroundColor = Color.Transparent,
            disabledBackgroundColor = Color.Transparent),
    ) {
        Canvas(Modifier.size(96.dp)) {
            val ring = Brush.sweepGradient(listOf(Accent, Accent2, Accent))
            drawCircle(brush = ring, radius = size.minDimension / 2 - 4.dp.toPx(),
                style = Stroke(width = 5.dp.toPx()), alpha = if (enabled) 1f else 0.3f)
            drawCircle(color = Color.White.copy(alpha = if (enabled) 1f else 0.25f),
                radius = size.minDimension / 2 - 14.dp.toPx())
        }
    }
}
