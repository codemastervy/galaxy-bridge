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

    /** Oldest first, skipping [exclude] (batches already in flight), reading at most [limit] files. */
    @Synchronized
    fun pending(limit: Int = Int.MAX_VALUE, exclude: Set<String> = emptySet()): List<Pair<String, List<HealthSample>>> {
        val out = ArrayList<Pair<String, List<HealthSample>>>()
        for (f in batchFiles()) {
            if (out.size >= limit) break
            val id = f.nameWithoutExtension
            if (id in exclude) continue
            val items = runCatching { parse(f.readText()) }.getOrNull()
            if (items == null) f.delete() else out += id to items
        }
        return out
    }

    /**
     * Merges small batches (one per background reading) into full ones, so a long time offline
     * syncs in a few round trips instead of hundreds. In-flight batches are left alone. The merged
     * file is written before the originals are deleted; if that's interrupted, the phone just sees
     * some samples twice, which Apple Health ignores (each sample has a stable sync identifier).
     */
    @Synchronized
    fun compact(exclude: Set<String>) {
        val small = batchFiles().filter { it.nameWithoutExtension !in exclude }
        if (small.size < 2) return
        var group = ArrayList<File>()
        var items = ArrayList<HealthSample>()
        fun flush() {
            if (group.size >= 2) {
                val id = UUID.randomUUID().toString()
                val tmp = File(dir, "$id.tmp")
                tmp.writeText(JSONArray(items.map { it.toJson() }).toString())
                // Keep the oldest timestamp so ordering (oldest first) is preserved.
                tmp.setLastModified(group.first().lastModified())
                if (tmp.renameTo(File(dir, "$id.json"))) group.forEach { it.delete() }
            }
            group = ArrayList()
            items = ArrayList()
        }
        for (f in small) {
            val parsed = runCatching { parse(f.readText()) }.getOrNull()
            if (parsed == null) { f.delete(); continue }
            if (items.size + parsed.size > MAX_PER_BATCH) flush()
            group += f
            items += parsed
        }
        flush()
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
        /** Must not exceed GBMessage.maxSamplesPerBatch (500) on the iPhone. */
        const val MAX_PER_BATCH = 500
    }
}
