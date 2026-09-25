package riverine.studio.epub

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var silence: AudioTrack? = null
    private var openChannel: MethodChannel? = null
    private var pendingBook: Uri? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingBook = viewedUri(intent)
        openChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_reader/open").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initial" -> {
                        val uri = pendingBook
                        pendingBook = null
                        if (uri == null) result.success(null) else resolveBook(uri) { result.success(it) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_reader/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "headphones" -> result.success(headphonesOn())
                "silence" -> {
                    if (call.arguments == true) startSilence() else stopSilence()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_reader/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "brightness" -> {
                    val value = (call.arguments as? Number)?.toFloat() ?: -1f
                    val attributes = window.attributes
                    attributes.screenBrightness =
                        if (value < 0f) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE else value.coerceIn(0.01f, 1f)
                    window.attributes = attributes
                    result.success(null)
                }
                "systemBrightness" -> {
                    val level = try {
                        Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS)
                    } catch (_: Exception) {
                        -1
                    }
                    result.success(if (level < 0) null else level / 255.0)
                }
                "keepOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        stopSilence()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = viewedUri(intent) ?: return
        resolveBook(uri) { path -> if (path != null) openChannel?.invokeMethod("open", path) }
    }

    private fun viewedUri(intent: Intent?): Uri? =
        if (intent?.action == Intent.ACTION_VIEW) intent.data else null

    // Reading a content URI can be slow, so it runs off the main thread.
    private fun resolveBook(uri: Uri, done: (String?) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        Thread {
            val path = try {
                bookPath(uri)
            } catch (_: Exception) {
                null
            }
            main.post { done(path) }
        }.start()
    }

    // The book's own path when this app can read it, so the shelf follows the real file.
    // Otherwise a copy in the app's files, under opened/.
    private fun bookPath(uri: Uri): String? {
        val direct = directPath(uri)
        if (direct != null) {
            val file = File(direct)
            if (file.isFile && file.canRead() && direct.lowercase().endsWith(".epub")) return file.absolutePath
        }
        val name = (displayName(uri) ?: direct?.let { File(it).name } ?: "book.epub").replace('/', '_')
        val epubName = name.lowercase().endsWith(".epub")
        if (!epubName && contentResolver.getType(uri) != "application/epub+zip") return null
        val fileName = if (epubName) name else "$name.epub"
        val dir = File(filesDir, "opened").apply { mkdirs() }
        val target = File(dir, fileName)
        val temp = File(dir, "$fileName.part")
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { source -> temp.outputStream().use { source.copyTo(it) } }
        if (!temp.renameTo(target)) {
            temp.delete()
            return null
        }
        return target.absolutePath
    }

    @Suppress("DEPRECATION")
    private fun directPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (uri.scheme != "content") return null
        try {
            if (DocumentsContract.isDocumentUri(this, uri) && uri.authority == "com.android.externalstorage.documents") {
                val parts = DocumentsContract.getDocumentId(uri).split(":", limit = 2)
                if (parts.size == 2) {
                    return if (parts[0].equals("primary", ignoreCase = true)) {
                        File(Environment.getExternalStorageDirectory(), parts[1]).path
                    } else {
                        "/storage/${parts[0]}/${parts[1]}"
                    }
                }
            }
        } catch (_: Exception) {
        }
        // Some file managers put the real path inside their own URI.
        uri.path?.let { raw ->
            val at = raw.indexOf("/storage/")
            if (at >= 0 && File(raw.substring(at)).isFile) return raw.substring(at)
        }
        try {
            contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex("_data")
                    if (column >= 0) return cursor.getString(column)
                }
            }
        } catch (_: Exception) {
        }
        return null
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    // Android gives headset buttons to the media session of the app that is playing audio.
    // The system voice plays from the TTS engine's own process, so without this track the
    // buttons go to whichever music app played last.
    private fun startSilence() {
        if (silence != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val rate = 8000
        val frames = rate / 2
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(frames * 2)
                .build()
        } catch (_: Exception) {
            return
        }
        try {
            track.write(ShortArray(frames), 0, frames)
            track.setLoopPoints(0, frames, -1)
            track.play()
            silence = track
        } catch (_: Exception) {
            track.release()
        }
    }

    private fun stopSilence() {
        val track = silence ?: return
        silence = null
        try {
            track.stop()
        } catch (_: Exception) {
        }
        track.release()
    }

    // Bluetooth audio counts, so a Bluetooth speaker or car also reads as headphones.
    private fun headphonesOn(): Boolean {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            return audio.isWiredHeadsetOn || audio.isBluetoothA2dpOn
        }
        val kinds = mutableSetOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) kinds += AudioDeviceInfo.TYPE_USB_HEADSET
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) kinds += AudioDeviceInfo.TYPE_BLE_HEADSET
        return audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in kinds }
    }
}
