package dev.iyscode.movil.gus

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

sealed interface ModelState {
    data object NotDownloaded : ModelState
    data class Downloading(val progress: Double) : ModelState
    data object Verifying : ModelState
    data class Ready(val file: File) : ModelState
    data class Failed(val message: String) : ModelState
}

class ModelStoreException(message: String) : IOException(message)

/**
 * Downloads, verifies and keeps GGUF files. Only catalog models are accepted,
 * only from Hugging Face hosts, and a file is usable only after its size and
 * SHA-256 match the pin. Same rules as the iOS GUSModelDownloadManager.
 */
class ModelStore(
    private val directory: File,
    private val catalog: List<GusModel> = GusCatalog.all,
    private val client: OkHttpClient = defaultClient(),
    private val allowedHosts: Set<String> = ALLOWED_HOSTS,
    private val sourceUrlFor: (GusModel) -> String = { it.sourceUrl },
) {
    private val _states = MutableStateFlow<Map<String, ModelState>>(emptyMap())
    val states: StateFlow<Map<String, ModelState>> = _states.asStateFlow()

    fun state(id: String): ModelState = _states.value[id] ?: ModelState.NotDownloaded
    fun installedFile(id: String): File? = (state(id) as? ModelState.Ready)?.file?.takeIf { it.exists() }
    fun installedModels(): List<GusModel> = catalog.filter { installedFile(it.id) != null }

    private fun set(id: String, state: ModelState) = _states.update { it + (id to state) }
    private fun target(model: GusModel) = File(directory, model.filename)
    private fun partial(model: GusModel) = File(directory, "${model.id}.${model.filename}.partial")

    /** Adopts files already on disk (e.g. after an app update); verifies each one. */
    suspend fun refresh() {
        for (model in catalog) {
            val file = target(model)
            if (!file.exists()) {
                if (state(model.id) !is ModelState.Downloading) set(model.id, ModelState.NotDownloaded)
                continue
            }
            if (state(model.id) is ModelState.Ready) continue
            set(model.id, ModelState.Verifying)
            val ok = runCatching { verify(file, model) }.isSuccess
            if (ok) set(model.id, ModelState.Ready(file)) else { file.delete(); set(model.id, ModelState.NotDownloaded) }
        }
    }

    /** Downloads [model], resuming a previous partial file when the server allows it. */
    suspend fun download(model: GusModel) {
        require(catalog.any { it == model }) { "Modelo no aprobado." }
        directory.mkdirs()
        ensureSpace(model)
        val part = partial(model)
        try {
            withContext(Dispatchers.IO) {
                val offset = if (part.exists() && part.length() < model.byteCount) part.length() else 0L
                if (offset == 0L) part.delete()
                val request = Request.Builder().url(sourceUrlFor(model))
                    .apply { if (offset > 0) header("Range", "bytes=$offset-") }
                    .build()
                client.newCall(request).execute().use { response ->
                    val host = response.request.url.host.lowercase()
                    if (host !in allowedHosts) throw ModelStoreException("La descarga salió de los hosts aprobados de Hugging Face.")
                    if (!response.isSuccessful) throw ModelStoreException("El servidor respondió ${response.code}.")
                    val append = offset > 0 && response.code == 206
                    val body = response.body ?: throw ModelStoreException("Respuesta vacía.")
                    var written = if (append) offset else 0L
                    java.io.FileOutputStream(part, append).use { out ->
                        body.byteStream().use { input ->
                            val buffer = ByteArray(1 shl 16)
                            var lastReport = 0L
                            while (true) {
                                currentCoroutineContext().ensureActive()
                                val n = input.read(buffer)
                                if (n < 0) break
                                written += n
                                if (written > model.byteCount) throw ModelStoreException("El archivo es más grande que el aprobado.")
                                out.write(buffer, 0, n)
                                if (written - lastReport > 4L * 1024 * 1024 || written == model.byteCount) {
                                    lastReport = written
                                    set(model.id, ModelState.Downloading(written.toDouble() / model.byteCount))
                                }
                            }
                        }
                    }
                }
                set(model.id, ModelState.Verifying)
                verify(part, model)
                val file = target(model)
                file.delete()
                if (!part.renameTo(file)) throw ModelStoreException("No pude mover el modelo verificado.")
                set(model.id, ModelState.Ready(file))
            }
        } catch (e: ModelStoreException) {
            if (e.message?.contains("SHA-256") == true || e.message?.contains("tamaño") == true) part.delete()
            set(model.id, ModelState.Failed(e.message ?: "Error de descarga."))
            throw e
        } catch (e: kotlinx.coroutines.CancellationException) {
            // Keep the partial file so the next attempt resumes.
            set(model.id, ModelState.NotDownloaded)
            throw e
        } catch (e: IOException) {
            set(model.id, ModelState.Failed("Descarga interrumpida: ${e.message ?: "sin conexión"}. Reintenta para continuar."))
            throw e
        }
    }

    fun delete(model: GusModel) {
        target(model).delete()
        partial(model).delete()
        set(model.id, ModelState.NotDownloaded)
    }

    private fun ensureSpace(model: GusModel) {
        val free = directory.usableSpace
        val required = model.byteCount - (partial(model).takeIf { it.exists() }?.length() ?: 0L) + 100_000_000L
        if (free in 1 until required) {
            throw ModelStoreException("No hay espacio suficiente: faltan ${(required - free) / 1_000_000} MB.")
        }
    }

    // Import / export (models survive reinstalls)

    data class ImportSummary(
        val imported: List<String> = emptyList(),
        val alreadyInstalled: List<String> = emptyList(),
        /** GGUF files that do not match any catalog pin (size or SHA-256). */
        val rejected: List<String> = emptyList(),
    )

    /** One file picked by the user: its display name, size and a way to read it. */
    class ImportCandidate(val name: String, val size: Long, val open: () -> InputStream)

    /**
     * Adopts GGUF files picked in the system file picker. Only files whose
     * size and SHA-256 match a catalog pin are accepted, even if renamed.
     */
    suspend fun import(candidates: List<ImportCandidate>): ImportSummary = withContext(Dispatchers.IO) {
        var summary = ImportSummary()
        directory.mkdirs()
        for (candidate in candidates.filter { it.name.lowercase().endsWith(".gguf") }) {
            val matches = catalog.filter { it.byteCount == candidate.size }
                .sortedBy { if (it.filename == candidate.name) 0 else 1 }
            if (matches.isEmpty()) { summary = summary.copy(rejected = summary.rejected + candidate.name); continue }
            val alreadyReady = matches.firstOrNull { installedFile(it.id) != null }
            if (alreadyReady != null) {
                summary = summary.copy(alreadyInstalled = summary.alreadyInstalled + alreadyReady.id)
                continue
            }
            // Copy once while hashing, then adopt it as whichever candidate the digest matches.
            val staging = File(directory, "import-${System.nanoTime()}.partial")
            val digest = runCatching {
                candidate.open().use { input -> staging.outputStream().use { out -> copyHashing(input, out) } }
            }.getOrNull()
            val model = matches.firstOrNull { it.sha256.equals(digest, ignoreCase = true) }
            if (model == null) {
                staging.delete()
                summary = summary.copy(rejected = summary.rejected + candidate.name)
                continue
            }
            val file = target(model)
            file.delete()
            if (staging.renameTo(file)) {
                set(model.id, ModelState.Ready(file))
                summary = summary.copy(imported = summary.imported + model.id)
            } else {
                staging.delete()
                summary = summary.copy(rejected = summary.rejected + candidate.name)
            }
        }
        summary
    }

    companion object {
        val ALLOWED_HOSTS = setOf("huggingface.co", "us.aws.cdn.hf.co", "cdn-lfs.huggingface.co", "cas-bridge.xethub.hf.co")

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .followSslRedirects(false)
            // Every hop must stay on an approved host, not only the final one.
            .addNetworkInterceptor(Interceptor { chain ->
                val host = chain.request().url.host.lowercase()
                if (chain.request().url.scheme != "https" || host !in ALLOWED_HOSTS) {
                    throw ModelStoreException("La descarga salió de los hosts aprobados de Hugging Face.")
                }
                chain.proceed(chain.request())
            })
            .build()

        /** Size first (cheap), then the full SHA-256. */
        fun verify(file: File, model: GusModel) {
            val size = file.length()
            if (size != model.byteCount) throw ModelStoreException("El tamaño no coincide (${size} de ${model.byteCount} bytes).")
            val digest = file.inputStream().use { copyHashing(it, null) }
            if (!digest.equals(model.sha256, ignoreCase = true)) throw ModelStoreException("La huella SHA-256 no coincide con el catálogo.")
        }

        fun copyHashing(input: InputStream, output: java.io.OutputStream?): String {
            val sha = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                sha.update(buffer, 0, n)
                output?.write(buffer, 0, n)
            }
            return sha.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
