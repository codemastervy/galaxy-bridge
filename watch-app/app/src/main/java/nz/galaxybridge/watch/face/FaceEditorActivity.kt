package nz.galaxybridge.watch.face

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import androidx.wear.watchface.editor.EditorSession
import kotlinx.coroutines.launch

/** The watch's "Customise" screen for the Wear OS Bridge face: pick what each complication shows. */
class FaceEditorActivity : ComponentActivity() {
    private var session: EditorSession? = null
    private var ready by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch {
            session = EditorSession.createOnWatchEditorSession(this@FaceEditorActivity)
            ready = true
        }
        setContent {
            MaterialTheme {
                ScalingLazyColumn(horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    item { Text("Complications", color = Color(0xFF2ED1DB), modifier = Modifier.padding(top = 24.dp)) }
                    for ((label, id) in listOf("Left" to BridgeFaceService.LEFT, "Right" to BridgeFaceService.RIGHT,
                        "Bottom" to BridgeFaceService.BOTTOM)) item {
                        Chip(onClick = { lifecycleScope.launch { session?.openComplicationDataSourceChooser(id) } },
                            enabled = ready, label = { Text(label) }, colors = ChipDefaults.secondaryChipColors(),
                            modifier = Modifier.fillMaxWidth())
                    }
                    item {
                        Text("Pick designs in the iPhone app: More → Watch faces.", style = MaterialTheme.typography.caption3,
                            textAlign = TextAlign.Center, color = Color.White.copy(alpha = 0.6f))
                    }
                    item { Chip(onClick = { finish() }, label = { Text("Done") }, modifier = Modifier.fillMaxWidth()) }
                }
            }
        }
    }

    override fun onDestroy() {
        session?.close()
        super.onDestroy()
    }
}
