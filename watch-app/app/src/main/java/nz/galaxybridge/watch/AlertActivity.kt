package nz.galaxybridge.watch

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/** Full-screen incoming call (answer/decline on the iPhone) and "find my watch" screens. */
class AlertActivity : ComponentActivity() {
    companion object {
        const val EXTRA_MODE = "mode"
        const val MODE_CALL = "call"
        const val MODE_FIND = "find"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        val mode = intent.getStringExtra(EXTRA_MODE)
        setContent {
            MaterialTheme {
                if (mode == MODE_FIND) FindScreen() else CallScreen()
            }
        }
    }

    @Composable
    private fun CallScreen() {
        val call by PhoneNotifier.incomingCall.collectAsState()
        LaunchedEffect(call) { if (call == null) finish() }
        val c = call ?: return
        Column(
            Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF0E3B2E), Color.Black))),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("iPhone call", style = MaterialTheme.typography.caption2, color = Color.White.copy(alpha = 0.7f))
            Text(c.caller, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
            Text(c.detail, style = MaterialTheme.typography.caption3, color = Color.White.copy(alpha = 0.6f),
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                RoundAction("✕", Color(0xFFE5484D), c.declineLabel) {
                    LinkService.performAction(c.uid, positive = false); finish()
                }
                RoundAction("✓", Color(0xFF30A46C), c.acceptLabel) {
                    LinkService.performAction(c.uid, positive = true); finish()
                }
            }
            Text("Audio stays on your iPhone", style = MaterialTheme.typography.caption3,
                color = Color.White.copy(alpha = 0.45f), modifier = Modifier.padding(top = 10.dp))
        }
    }

    @Composable
    private fun FindScreen() {
        val ringing by LinkService.findingWatch.collectAsState()
        LaunchedEffect(ringing) { if (!ringing) finish() }
        Box(
            Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Color(0xFF5C6BFF), Color.Black))),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Here I am!", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color.White)
                Text("Your iPhone is looking for this watch", style = MaterialTheme.typography.caption3,
                    color = Color.White.copy(alpha = 0.8f), textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 28.dp, vertical = 6.dp))
                Button(onClick = { LinkService.stopFindingWatch(); finish() },
                    modifier = Modifier.size(72.dp)) { Text("Found") }
            }
        }
    }

    @Composable
    private fun RoundAction(symbol: String, color: Color, label: String, onClick: () -> Unit) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Button(onClick = onClick, colors = ButtonDefaults.buttonColors(backgroundColor = color),
                modifier = Modifier.size(56.dp)) {
                Text(symbol, fontSize = 22.sp, color = Color.White)
            }
            Text(label.take(12), style = MaterialTheme.typography.caption3, color = Color.White.copy(alpha = 0.7f),
                modifier = Modifier.padding(top = 4.dp))
        }
    }
}
