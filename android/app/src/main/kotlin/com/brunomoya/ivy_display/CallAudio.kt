package com.brunomoya.ivy_display

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Two-way LAN voice link for the screen-to-screen call (video is the peer's MJPEG,
 * served separately on :2971). Each device listens on [PORT] and also connects to the
 * peer's [PORT], so two one-way 16 kHz mono PCM streams make a full-duplex call.
 * The mic is the one already captured by [Mic]; [feed] pushes those chunks out.
 */
class CallAudio(private val ctx: Context) {
    companion object {
        const val PORT = 2972
        const val RATE = 16000
    }

    @Volatile var active = false
    @Volatile var muted = false
    private var server: ServerSocket? = null
    private var sendSock: Socket? = null
    @Volatile private var sendOut: OutputStream? = null
    private var track: AudioTrack? = null

    fun start(peerIp: String) {
        if (active) return
        active = true
        // Play on the media path (USAGE_MEDIA/STREAM_MUSIC) — the only one audible on
        // these speaker-only displays; VOICE_COMMUNICATION / MODE_IN_COMMUNICATION stays
        // silent here. No hardware echo cancel, but the screens are in different rooms.
        val min = AudioTrack.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build(),
            AudioFormat.Builder()
                .setSampleRate(RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build(),
            maxOf(min, 8192), AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE
        ).apply { play() }

        // Receive: accept the peer and play whatever it sends.
        Thread({
            try {
                val srv = ServerSocket(PORT).also { server = it }
                while (active) {
                    val s = try { srv.accept() } catch (_: Exception) { break }
                    val ins = s.getInputStream()
                    val buf = ByteArray(2048)
                    try {
                        while (active) {
                            val n = ins.read(buf)
                            if (n < 0) break
                            track?.write(buf, 0, n)
                        }
                    } catch (_: Exception) {}
                    try { s.close() } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                Log.e("ivy-call", "server: $e")
            }
        }, "ivy-call-rx").start()

        // Send: connect to the peer, retrying until its server is up.
        Thread({
            while (active && sendOut == null) {
                try {
                    val s = Socket()
                    s.connect(InetSocketAddress(peerIp, PORT), 2000)
                    sendSock = s
                    sendOut = s.getOutputStream()
                } catch (_: Exception) {
                    try { Thread.sleep(400) } catch (_: Exception) {}
                }
            }
        }, "ivy-call-tx").start()
    }

    /** A mic chunk from [Mic]; sent to the peer unless muted. */
    fun feed(pcm: ByteArray) {
        if (active && !muted) {
            try { sendOut?.apply { write(pcm); flush() } } catch (_: Exception) {}
        }
    }

    fun stop() {
        if (!active) return
        active = false
        try { server?.close() } catch (_: Exception) {}
        try { sendSock?.close() } catch (_: Exception) {}
        sendOut = null; server = null; sendSock = null
        track?.run { try { stop() } catch (_: Exception) {}; release() }
        track = null
    }
}
