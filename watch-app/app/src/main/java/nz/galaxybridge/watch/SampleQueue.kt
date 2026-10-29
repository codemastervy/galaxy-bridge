package nz.galaxybridge.watch

import org.json.JSONArray
import java.io.File
import java.util.UUID

/**
 * Durable outbox of health-sample batches. A batch is deleted only after the phone acks it
 * (which it does after Apple Health has stored it), so nothing is lost while disconnected.
 * Bounded so a long disconnection can't fill the watch's storage.
 */
class SampleQueue(dir: File, private val maxBatches: Int = 2_000) {
    private val dir = File(dir, "outbox").apply { mkdirs() }

    @Synchronized
    fun add(items: List<HealthSample>) {
        val valid = items.filter { it.isPlausible() }
        if (valid.isEmpty()) return
        valid.chunked(MAX_PER_BATCH).forEach { chunk ->
            val id = UUID.randomUUID().toString()
            val tmp = File(dir, "$id.tmp")
            tmp.writeText(JSONArray(chunk.map { it.toJson() }).toString())
            tmp.renameTo(File(dir, "$id.json"))
        }
        trim()
    }

    /** Oldest first. */
    @Synchronized
    fun pending(): List<Pair<String, List<HealthSample>>> =
        batchFiles().mapNotNull { f ->
            val id = f.nameWithoutExtension
            val items = runCatching { parse(f.readText()) }.getOrNull()
            if (items == null) { f.delete(); null } else id to items
        }

    @Synchronized
    fun ack(batchId: String) {
        if (!PhoneMessage.isBatchId(batchId)) return
        File(dir, "$batchId.json").delete()
    }

    @Synchronized
    fun size(): Int = batchFiles().size

    private fun batchFiles(): List<File> =
        (dir.listFiles { f -> f.name.endsWith(".json") } ?: emptyArray()).sortedBy { it.lastModified() }

    private fun trim() {
        val files = batchFiles()
        if (files.size > maxBatches) files.take(files.size - maxBatches).forEach { it.delete() }
    }

    private fun parse(text: String): List<HealthSample> {
        val arr = JSONArray(text)
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            val kind = SampleKind.entries.first { it.wire == o.getString("k") }
            HealthSample(kind, o.getLong("start"), o.getLong("end"), o.getDouble("v"))
        }
    }

    companion object {
        const val MAX_PER_BATCH = 200
    }
}
