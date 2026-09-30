package dev.iyscode.movil

import dev.iyscode.movil.bench.Benchmark
import dev.iyscode.movil.bench.BenchmarkEnvironment
import dev.iyscode.movil.bench.BenchmarkReport
import dev.iyscode.movil.diagnostics.FlightRecorder
import dev.iyscode.movil.gus.ChatMessage
import dev.iyscode.movil.gus.DeviceBudget
import dev.iyscode.movil.gus.Generation
import dev.iyscode.movil.gus.GenerationStats
import dev.iyscode.movil.gus.GusBuild
import dev.iyscode.movil.gus.GusCatalog
import dev.iyscode.movil.gus.GusModel
import dev.iyscode.movil.gus.LlamaEngine
import dev.iyscode.movil.gus.LocalEngine
import dev.iyscode.movil.gus.ModelState
import dev.iyscode.movil.gus.ModelStore
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

class CatalogTest {
    @Test fun catalogMatchesTheIosPins() {
        val ids = GusCatalog.all.map { it.id }
        assertEquals("ids are unique", ids.size, ids.toSet().size)
        assertTrue(ids.containsAll(listOf("qwen15-18b-q4km", "qwen25-05b-q4km", "smollm2-360m-q4km")))
        for (m in GusCatalog.all) {
            assertTrue(m.sourceUrl, m.sourceUrl.startsWith("https://huggingface.co/${m.repository}/resolve/${m.revision}/"))
            assertEquals(64, m.sha256.length)
            assertEquals(40, m.revision.length)
            assertTrue(m.byteCount > 0)
        }
        assertEquals(491_400_032L, GusCatalog.qwen25Q4KM.byteCount)
        assertEquals("74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db", GusCatalog.qwen25Q4KM.sha256)
        assertFalse(GusCatalog.qwen25Q4KM.isExperimental)
        assertEquals("842b1880415d6f508f03b789e5ce70194def7bfd", GusBuild.LLAMA_CPP_COMMIT)
    }

    @Test fun peakEstimateCountsWeightsKvAndOverhead() {
        val m = GusCatalog.qwen25Q4KM
        assertEquals((m.kvBytesPerToken ?: 0) * 2048, m.estimatedPeakBytes(4096) - m.estimatedPeakBytes(2048))
        assertTrue(m.estimatedPeakBytes(2048) > m.byteCount)
    }
}

class DeviceBudgetTest {
    @Test fun classificationThresholds() {
        assertEquals(DeviceBudget.Fit.COMFORTABLE, DeviceBudget.classify(700, 1000))
        assertEquals(DeviceBudget.Fit.TIGHT, DeviceBudget.classify(850, 1000))
        assertEquals(DeviceBudget.Fit.UNLIKELY, DeviceBudget.classify(950, 1000))
        assertEquals(DeviceBudget.Fit.UNLIKELY, DeviceBudget.classify(1, 0))
    }

    @Test fun budgetUsesAvailableMemoryAboveTheKillThreshold() {
        val b = DeviceBudget.from(totalMem = 8L shl 30, availMem = 3L shl 30, threshold = 512L shl 20, footprint = 200L shl 20)
        assertEquals((3L shl 30) - (512L shl 20) + (200L shl 20), b.appMemoryLimit)
        assertEquals(DeviceBudget.Fit.COMFORTABLE, b.fit(GusCatalog.smolLM2Q4KM))
        assertEquals(DeviceBudget.Fit.UNLIKELY, b.fit(GusCatalog.all.first { it.id == "nemotron-nano-9b-v2-q4km" }))
    }
}

class VisibleAnswerTest {
    @Test fun thinkBlocksAreHidden() {
        assertEquals("Paris", LlamaEngine.visibleAnswer("<think>hmm</think>\nParis"))
        assertEquals("", LlamaEngine.visibleAnswer("<think>still thinking"))
        assertEquals("Paris", LlamaEngine.visibleAnswer("draft\n</think>\n\nParis\n"))
        assertEquals("Paris", LlamaEngine.visibleAnswer("Paris"))
    }

    @Test fun chatSamplesButBenchmarkStaysGreedy() {
        assertNull(LlamaEngine.samplingFor(0f))
        val chat = LlamaEngine.samplingFor(0.6f)!!
        assertEquals(0.6f, chat[0])
        assertTrue("repetition penalty on", chat[4] > 1f)
        assertEquals(128f, chat[5])
    }

    @Test fun nativeStatsDecode() {
        val s = GenerationStats.fromNative(doubleArrayOf(100.0, 500.0, 40.0, 20.0, 1.0, 1.0))
        assertEquals(400.0, s.prefillTokensPerSecond, 1e-9)
        assertEquals(40.0, s.generationTokensPerSecond, 1e-9)
        assertEquals(GenerationStats.TemplateSource.EMBEDDED, s.templateSource)
        assertTrue(s.stoppedAtEndOfTurn)
    }
}

class FlightRecorderTest {
    private fun marker(phase: String, foreground: Boolean = true) = FlightRecorder.SessionMarker(
        "s", "t", "1", "Android 15", "Pixel 8", 8L shl 30, phase, "t", "qwen3-4b-q4km", foreground, 3L shl 30)

    @Test fun cleanRunsProduceNoReport() {
        assertNull(FlightRecorder.diagnose(null, null, emptyList(), "t"))
        assertNull(FlightRecorder.diagnose(marker("idle"), null, emptyList(), "t"))
        assertNull(FlightRecorder.diagnose(marker("launch"), null, emptyList(), "t"))
        assertNull(FlightRecorder.diagnose(marker("generate", foreground = false), null, emptyList(), "t"))
    }

    @Test fun foregroundDeathDuringLoadIsAttributedToMemory() {
        val crumb = FlightRecorder.Breadcrumb("t", "model.load.begin", emptyMap(), 3L shl 30, 40L shl 20)
        val r = FlightRecorder.diagnose(marker("model.load"), null, listOf(crumb), "t")!!
        assertEquals(FlightRecorder.CrashReport.Kind.UNCLEAN_EXIT, r.kind)
        assertTrue(r.summary.contains("carga del modelo"))
        assertTrue(r.summary.contains("qwen3-4b-q4km"))
        assertTrue(r.likelyCause.contains("memoria"))
    }

    @Test fun caughtSignalWins() {
        val r = FlightRecorder.diagnose(marker("generate"), "signal=6", emptyList(), "t")!!
        assertEquals(FlightRecorder.CrashReport.Kind.FATAL_SIGNAL, r.kind)
        assertTrue(r.summary.startsWith("SIGABRT"))
    }

    @Test fun roundTripDetectsUncleanExitOnNextLaunch() {
        val dir = Files.createTempDirectory("fr").toFile()
        try {
            val first = FlightRecorder(dir)
            assertTrue(first.start("0.5.0", "15", "Pixel 8", 8L shl 30).isEmpty())
            first.beginPhase("generate", "smollm2-360m-q4km", mapOf("chars" to "12"))
            // Simulated SIGKILL: no endPhase; a new process starts.
            val second = FlightRecorder(dir)
            val reports = second.start("0.5.0", "15", "Pixel 8", 8L shl 30)
            assertEquals(1, reports.size)
            assertEquals("smollm2-360m-q4km", reports[0].marker?.modelId)
            assertTrue(reports[0].breadcrumbs.any { it.event == "generate.begin" })
            assertEquals(1, second.reports().size)
            assertTrue(second.exportJson(reports[0]).contains("UNCLEAN_EXIT"))
            second.endPhase("generate")
            assertTrue(FlightRecorder(dir).start("0.5.0", "15", "Pixel 8", 8L shl 30).isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }
}

class ModelStoreTest {
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun fixture(id: String, filename: String, bytes: ByteArray, url: String = "https://huggingface.co/x/y/resolve/r/$filename") =
        GusCatalog.qwen25Q4KM.copy(id = id, filename = filename, sourceUrl = url, byteCount = bytes.size.toLong(), sha256 = sha(bytes))

    @Test fun downloadVerifiesAndRejectsTamperedFiles() = runBlocking<Unit> {
        val good = "gguf weights".toByteArray()
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody(Buffer().write(good)))
            server.enqueue(MockResponse().setBody(Buffer().write("gguf weightz".toByteArray())))
            server.start()
            val url = server.url("/m.gguf").toString()
            val model = fixture("m", "m.gguf", good, url)
            val dir = Files.createTempDirectory("store").toFile()
            val store = ModelStore(dir, listOf(model), OkHttpClient(), setOf(server.hostName))
            store.download(model)
            assertTrue(store.state("m") is ModelState.Ready)
            assertEquals(good.toList(), store.installedFile("m")!!.readBytes().toList())

            store.delete(model)
            try { store.download(model); fail("tampered file accepted") } catch (_: Exception) {}
            assertNull(store.installedFile("m"))
            assertTrue(store.state("m") is ModelState.Failed)
            dir.deleteRecursively()
        }
    }

    @Test fun downloadRefusesUnapprovedHosts() = runBlocking<Unit> {
        val bytes = "x".toByteArray()
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("x"))
            server.start()
            val model = fixture("m", "m.gguf", bytes, server.url("/m.gguf").toString())
            val store = ModelStore(Files.createTempDirectory("s").toFile(), listOf(model), OkHttpClient(), setOf("huggingface.co"))
            try { store.download(model); fail("unapproved host accepted") } catch (e: Exception) {
                assertTrue(e.message!!.contains("hosts aprobados"))
            }
        }
    }

    @Test fun importAdoptsRenamedMatchesAndRejectsOthers() = runBlocking<Unit> {
        val qwen = "qwen weights".toByteArray()
        val smol = "smol weights!".toByteArray()
        val models = listOf(fixture("qwen", "qwen.gguf", qwen), fixture("smol", "smol.gguf", smol))
        val dir = Files.createTempDirectory("imp").toFile()
        val store = ModelStore(dir, models, OkHttpClient())
        fun cand(name: String, bytes: ByteArray) = ModelStore.ImportCandidate(name, bytes.size.toLong()) { bytes.inputStream() }

        val tampered = store.import(listOf(cand("smol.gguf", "smol weightz!".toByteArray())))
        assertEquals(listOf("smol.gguf"), tampered.rejected)

        val summary = store.import(listOf(
            cand("my-qwen-copy.gguf", qwen), cand("smol.gguf", smol),
            cand("random.gguf", "not pinned".toByteArray()), cand("notes.txt", "x".toByteArray()),
        ))
        assertEquals(setOf("qwen", "smol"), summary.imported.toSet())
        assertEquals(listOf("random.gguf"), summary.rejected)
        assertEquals("qwen.gguf", store.installedFile("qwen")!!.name)

        val again = store.import(listOf(cand("smol.gguf", smol)))
        assertEquals(listOf("smol"), again.alreadyInstalled)

        // Files on disk are adopted again after an app update.
        val fresh = ModelStore(dir, models, OkHttpClient())
        fresh.refresh()
        assertEquals(2, fresh.installedModels().size)
        dir.deleteRecursively()
    }
}

class BenchmarkTest {
    private class FakeEngine(private val answers: Map<String, String>) : LocalEngine {
        override var loadedModelId: String? = null
        override suspend fun load(model: GusModel, file: File, contextTokens: Int) { loadedModelId = model.id }
        var lastTemperature = -1f
        override suspend fun generate(messages: List<ChatMessage>, maxTokens: Int, temperature: Float): Generation {
            lastTemperature = temperature
            val q = messages.last().content
            val text = answers.entries.firstOrNull { q.contains(it.key) }?.value ?: "ok"
            return Generation(text, GenerationStats(40, 20, 100.0, 500.0, GenerationStats.TemplateSource.EMBEDDED, true))
        }
        override fun cancel() {}
        override suspend fun unload() { loadedModelId = null }
    }

    private object Env : BenchmarkEnvironment {
        override val appVersion = "0.5.0 (5)"
        override val deviceModel = "Pixel 8"
        override val osVersion = "Android 15 (API 35)"
        override val ramBytes = 8L shl 30
        override fun appMemoryLimitBytes() = 3L shl 30
        override fun footprintBytes() = 500L shl 20
        override fun thermalState() = "nominal"
        override fun powerSaveMode() = false
        override fun now() = "2026-09-30T10:00:00Z"
    }

    @Test fun protocolMatchesIos() {
        assertEquals(1, Benchmark.PROTOCOL_VERSION)
        assertEquals(listOf("short-answer", "json-object", "long-prefill", "sustained-generation"), Benchmark.tasks.map { it.id })
        assertTrue(Benchmark.longPassage.length > 2_500)
        assertTrue(Benchmark.isJsonObject("{\"city\":\"Tokyo\",\"country\":\"Japan\"}", listOf("city", "country")))
        assertTrue(Benchmark.isJsonObject("```json\n{\"city\":\"Tokyo\",\"country\":\"Japan\"}\n```", listOf("city")))
        assertFalse(Benchmark.isJsonObject("Sure! {\"city\":\"Tokyo\"}", listOf("city")))
    }

    @Test fun completedRunHasAllTasksAndSnakeCaseSchema() = runBlocking<Unit> {
        val pending = File(Files.createTempDirectory("b").toFile(), "pending.json")
        val engine = FakeEngine(mapOf("France" to "Paris", "Japan" to "{\"city\":\"Tokyo\",\"country\":\"Japan\"}", "Count" to "1 2 3 4 5 6 7 8 9 10 11 12"))
        val report = Benchmark.run(GusCatalog.qwen25Q4KM, File("x"), engine, Env, GusBuild.LLAMA_CPP_COMMIT, pending)
        assertEquals(BenchmarkReport.Status.COMPLETED, report.status)
        assertEquals(4, report.tasks.size)
        assertTrue(report.tasks.all { it.passed })
        assertFalse(pending.exists())
        assertNull(engine.loadedModelId)
        assertEquals("the benchmark must decode greedily", 0f, engine.lastTemperature)
        val json = report.json()
        for (key in listOf("\"schema\"", "\"protocol\"", "\"run_id\"", "\"peak_footprint_bytes\"", "\"app_memory_limit_bytes\"",
                "\"llama_cpp_commit\"", "\"platform\": \"android\"", "\"status\": \"completed\"", "isycode.gus.benchmark/1")) {
            assertTrue(key, json.contains(key))
        }
    }

    @Test fun pendingRunBecomesKilled() {
        val pending = File(Files.createTempDirectory("k").toFile(), "pending.json")
        val partial = BenchmarkReport(runId = "r1", status = BenchmarkReport.Status.FAILED, createdAt = "t", appVersion = "0.5.0",
            llamaCppCommit = GusBuild.LLAMA_CPP_COMMIT,
            device = BenchmarkReport.Device(model = "Pixel 8", os = "15", ramBytes = 1, appMemoryLimitBytes = 1, lowPowerMode = false),
            model = BenchmarkReport.Model("qwen25-05b-q4km", GusCatalog.qwen25Q4KM.sha256, 1, 2048),
            footprintBeforeBytes = 1, peakFootprintBytes = 1, thermalStart = "nominal", stoppedDuring = "load")
        pending.writeText(partial.json(pretty = false))
        val killed = Benchmark.takeKilledRun(pending)
        assertNotNull(killed)
        assertEquals(BenchmarkReport.Status.KILLED, killed!!.status)
        assertFalse(pending.exists())
        assertNull(Benchmark.takeKilledRun(pending))
    }
}
