package nz.galaxybridge.watch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SampleQueueTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun hr(t: Long) = HealthSample(SampleKind.HEART_RATE, t, t, 70.0)

    @Test fun compactsSmallBatchesIntoFullOnes() {
        val q = SampleQueue(tmp.root)
        repeat(300) { i -> q.add(listOf(hr(i * 1000L), hr(i * 1000L + 1))) } // 300 tiny batches, 600 samples
        assertEquals(300, q.size())
        q.compact(exclude = emptySet())
        val batches = q.pending()
        assertEquals(2, batches.size)                      // 500 + 100
        assertEquals(600, batches.sumOf { it.second.size })
        assertTrue(batches.all { it.second.size <= SampleQueue.MAX_PER_BATCH })
    }

    @Test fun leavesInFlightBatchesAlone() {
        val q = SampleQueue(tmp.root)
        repeat(5) { i -> q.add(listOf(hr(i.toLong()))) }
        val inFlight = q.pending(limit = 1).single().first
        q.compact(exclude = setOf(inFlight))
        val ids = q.pending().map { it.first }
        assertTrue(inFlight in ids)
        assertEquals(2, ids.size)                          // the in-flight one + one merged batch of 4
    }

    @Test fun pendingRespectsLimitAndExclude() {
        val q = SampleQueue(tmp.root)
        repeat(4) { i -> q.add(listOf(hr(i.toLong()))) }
        val first = q.pending(limit = 2)
        assertEquals(2, first.size)
        val rest = q.pending(exclude = first.map { it.first }.toSet())
        assertEquals(2, rest.size)
    }
}
