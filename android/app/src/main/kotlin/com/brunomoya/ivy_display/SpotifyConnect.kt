package com.brunomoya.ivy_display

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File

/**
 * Spotify Connect receiver: runs librespot (bundled as lib/armeabi-v7a/liblibrespot.so so
 * Android extracts it executable into nativeLibraryDir), plays its raw PCM stdout through an
 * AudioTrack and forwards "--onevent" metadata (printed on stderr) to Flutter.
 */
class SpotifyConnect(
    private val ctx: Context,
    private val onEvent: (Map<String, String>) -> Unit,
    private val onLyrics: (String, String) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private var process: Process? = null
    @Volatile private var running = false
    private var multicast: WifiManager.MulticastLock? = null

    private val fields = listOf(
        "event", "name", "artists", "album", "cover", "duration_ms", "position_ms", "volume",
        "track_id", "shuffle", "repeat",
    )
    private val commands = java.util.concurrent.Executors.newSingleThreadExecutor()

    /** Line command for our librespot patch (play_pause, next, prev, shuffle 1, volume N, seek MS, lyrics ID). */
    fun send(cmd: String) {
        val p = process ?: return
        commands.execute {
            try {
                p.outputStream.write("$cmd\n".toByteArray())
                p.outputStream.flush()
            } catch (e: Exception) {
                Log.w(TAG, "send $cmd failed", e)
            }
        }
    }

    fun start() {
        if (running) return
        running = true
        // mDNS (zeroconf) packets are filtered on Wi-Fi unless someone holds this lock.
        multicast = (ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
            .createMulticastLock("ivy:spotify").apply { setReferenceCounted(false); acquire() }
        Thread({ supervise() }, "librespot").start()
    }

    fun stop() {
        running = false
        process?.destroy()
        multicast?.release()
    }

    private fun supervise() {
        val script = File(ctx.filesDir, "onevent.sh").apply {
            // One tab-separated line per event; multi-line vars flattened.
            writeText(
                "nl='\n'\n" +
                    "printf 'IVYEV\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"\$PLAYER_EVENT\" \"\$NAME\" " +
                    "\"\${ARTISTS//\$nl/, }\" \"\$ALBUM\" \"\${COVERS%%\$nl*}\" \"\$DURATION_MS\" \"\$POSITION_MS\" \"\$VOLUME\" " +
                    "\"\$TRACK_ID\" \"\$SHUFFLE\" \"\$REPEAT\" >&2\n"
            )
        }
        val bin = File(ctx.applicationInfo.nativeLibraryDir, "liblibrespot.so").absolutePath
        val cache = File(ctx.filesDir, "librespot").apply { mkdirs() }.absolutePath
        // Per-device name so two screens don't clash on the network. Set with
        // `settings put global ivy_name "Lenovo Cocina"`; defaults to the old name.
        val name = android.provider.Settings.Global.getString(ctx.contentResolver, "ivy_name")
            ?.takeIf { it.isNotBlank() } ?: "Lenovo Smart Display"
        while (running) {
            try {
                val p = ProcessBuilder(
                    bin,
                    "--name", name,
                    "--device-type", "speaker",
                    "--backend", "pipe",
                    "--format", "S16",
                    "--bitrate", "320",
                    "--cache", cache,
                    "--disable-audio-cache",
                    "--initial-volume", "70",
                    "--enable-volume-normalisation",
                    "--onevent", "/system/bin/sh ${script.absolutePath}",
                ).apply {
                    // Rust's temp_dir() defaults to /data/local/tmp on Android (not writable by apps).
                    environment()["TMPDIR"] = ctx.cacheDir.absolutePath
                }.start()
                process = p
                Thread({ readEvents(p) }, "librespot-events").start()
                pumpAudio(p)
                Log.w(TAG, "librespot exited: ${p.waitFor()}")
            } catch (e: Exception) {
                Log.e(TAG, "librespot failed", e)
            }
            if (running) Thread.sleep(5000)
        }
    }

    /** librespot's pipe sink writes 44.1 kHz stereo S16LE to stdout. */
    private fun pumpAudio(p: Process) {
        val min = AudioTrack.getMinBufferSize(44100, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(44100)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(min * 4)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track.play()
        val buf = ByteArray(8192)
        try {
            p.inputStream.use { input ->
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    track.write(buf, 0, n)
                }
            }
        } finally {
            track.stop()
            track.release()
        }
    }

    private fun readEvents(p: Process) {
        p.errorStream.bufferedReader().forEachLine { line ->
            if (line.startsWith("IVYLYR\t")) {
                val parts = line.split('\t', limit = 3)
                main.post { onLyrics(parts.getOrElse(1) { "" }, parts.getOrElse(2) { "" }) }
            } else if (line.startsWith("IVYEV\t")) {
                val values = line.split('\t').drop(1)
                val event = fields.zip(values + List(fields.size) { "" }).toMap()
                main.post { onEvent(event) }
            } else {
                Log.d(TAG, line)
            }
        }
    }

    companion object {
        private const val TAG = "librespot"
    }
}
