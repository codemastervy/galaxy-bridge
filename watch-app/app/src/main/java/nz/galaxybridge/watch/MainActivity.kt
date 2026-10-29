package nz.galaxybridge.watch

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import kotlinx.coroutines.launch

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
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
        ) {
            Text(
                when (status) {
                    LinkService.Status.CONNECTED -> "iPhone connected"
                    LinkService.Status.WAITING -> "Waiting for iPhone"
                    LinkService.Status.STOPPED -> "Allow permissions to start"
                },
                textAlign = TextAlign.Center,
            )
            if (pending > 0) Text("$pending batches to sync", style = MaterialTheme.typography.caption2)
            Button(
                onClick = { LinkService.sendShutter() },
                enabled = status == LinkService.Status.CONNECTED,
            ) { Text("Shutter") }
            Chip(
                onClick = { LinkService.forgetPhone(this@MainActivity) },
                label = { Text("Forget iPhone") },
                colors = ChipDefaults.secondaryChipColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
