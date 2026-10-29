package nz.galaxybridge.watch

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import androidx.wear.compose.material.dialog.Alert
import androidx.wear.compose.material.dialog.Dialog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val Accent = Color(0xFF5C6BFF)
private val Accent2 = Color(0xFF2ED1DB)
private val Good = Color(0xFF3DDC84)
private val Wait = Color(0xFFFFC542)

class MainActivity : ComponentActivity() {

    private val permissions = arrayOf(
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.BLUETOOTH_ADVERTISE,
        Manifest.permission.BODY_SENSORS,
        Manifest.permission.ACTIVITY_RECOGNITION,
        Manifest.permission.POST_NOTIFICATIONS,
    )

    private val request = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        startIfAllowed()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { Screen() } }
        if (missing().isEmpty()) startIfAllowed() else request.launch(missing().toTypedArray())
    }

    private fun missing() = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    private fun startIfAllowed() {
        val needed = setOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        if (missing().any { it in needed }) return
        LinkService.start(this)
        if (checkSelfPermission(Manifest.permission.BODY_SENSORS) == PackageManager.PERMISSION_GRANTED) {
            lifecycleScope.launch { runCatching { Health.register(this@MainActivity) } }
        }
    }

    @Composable
    private fun Screen() {
        val status by LinkService.statusFlow().collectAsState()
        val pending by LinkService.pending.collectAsState()
        val remote by HidShutter.connected.collectAsState()
        val pairingUntil by LinkService.pairingUntil.collectAsState()
        val hasPhone by LinkService.hasPhone.collectAsState()
        var confirmForget by remember { mutableStateOf(false) }
        val listState = rememberScalingLazyListState()

        Scaffold(
            timeText = { TimeText() },
            modifier = Modifier.background(Brush.verticalGradient(listOf(Color(0xFF14163A), Color.Black))),
        ) {
            ScalingLazyColumn(
                state = listState,
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                item { StatusHeader(status, pending) }
                if (pairingUntil > 0) {
                    item { PairingCard(pairingUntil) { LinkService.cancelPairing() } }
                } else if (!hasPhone) {
                    item {
                        Chip(
                            onClick = { LinkService.openPairing() },
                            label = { Text("Pair iPhone") },
                            secondaryLabel = { Text("Start here") },
                            colors = ChipDefaults.gradientBackgroundChipColors(
                                startBackgroundColor = Accent, endBackgroundColor = Accent2),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                item {
                    ShutterButton(
                        enabled = status == LinkService.Status.CONNECTED || remote,
                        onClick = { LinkService.sendShutter() },
                    )
                }
                item {
                    Text(
                        if (remote) "Works in the iPhone Camera app" else "Open the camera in Galaxy Bridge",
                        style = MaterialTheme.typography.caption3,
                        color = Color.White.copy(alpha = 0.6f),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                }
                item { Spacer(Modifier.height(4.dp)) }
                if (hasPhone && pairingUntil == 0L) item {
                    Chip(
                        onClick = { LinkService.openPairing() },
                        label = { Text("Pair new phone") },
                        secondaryLabel = { Text("Replaces this iPhone") },
                        colors = ChipDefaults.secondaryChipColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (hasPhone) item {
                    Chip(
                        onClick = { confirmForget = true },
                        label = { Text("Forget iPhone") },
                        secondaryLabel = { Text("Stops syncing") },
                        colors = ChipDefaults.secondaryChipColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }

        Dialog(showDialog = confirmForget, onDismissRequest = { confirmForget = false }) {
            Alert(
                title = { Text("Forget iPhone?", textAlign = TextAlign.Center) },
                negativeButton = {
                    Button(onClick = { confirmForget = false }, colors = ButtonDefaults.secondaryButtonColors()) {
                        Text("✕")
                    }
                },
                positiveButton = {
                    Button(onClick = {
                        LinkService.forgetPhone(this@MainActivity)
                        confirmForget = false
                    }) { Text("✓") }
                },
            ) {
                Text("Health data stops syncing until you pair again.", textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.body2)
            }
        }
    }
}

@Composable
private fun StatusHeader(status: LinkService.Status, pending: Int) {
    val connected = status == LinkService.Status.CONNECTED
    val dot by animateColorAsState(if (connected) Good else Wait, label = "dot")
    Box(Modifier.padding(top = 24.dp), contentAlignment = Alignment.Center) {
        androidx.compose.foundation.layout.Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Galaxy Bridge", fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = Color.White)
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
                Text("$pending to sync", style = MaterialTheme.typography.caption3, color = Accent2)
            }
        }
    }
}

@Composable
private fun PairingCard(until: Long, onCancel: () -> Unit) {
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    androidx.compose.runtime.LaunchedEffect(until) {
        while (System.currentTimeMillis() < until) { now = System.currentTimeMillis(); delay(1000) }
    }
    val seconds = ((until - now) / 1000).coerceAtLeast(0)
    androidx.compose.foundation.layout.Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .clip(androidx.compose.foundation.shape.RoundedCornerShape(24.dp))
            .background(Brush.linearGradient(listOf(Accent, Accent2)))
            .padding(12.dp),
    ) {
        Text("Ready to pair", fontWeight = FontWeight.SemiBold, color = Color.White)
        Text("On your iPhone: Galaxy Bridge → Pair a watch. Check the codes match.",
            style = MaterialTheme.typography.caption3, color = Color.White, textAlign = TextAlign.Center)
        Text("${seconds / 60}:${"%02d".format(seconds % 60)}", style = MaterialTheme.typography.caption2,
            color = Color.White.copy(alpha = 0.85f), modifier = Modifier.padding(top = 4.dp))
        Chip(onClick = onCancel, label = { Text("Cancel") }, colors = ChipDefaults.secondaryChipColors(),
            modifier = Modifier.padding(top = 6.dp))
    }
}

/** Big circular shutter with a ring that pulses on press. */
@Composable
private fun ShutterButton(enabled: Boolean, onClick: () -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (pressed) 0.9f else 1f, label = "press")
    androidx.compose.runtime.LaunchedEffect(pressed) {
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
