package com.brunomoya.ivy_display

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log

/** 16 kHz mono S16 microphone stream for the HA Assist pipeline, in 64 ms chunks. */
class Mic(private val onChunk: (ByteArray) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var running = false

    fun start() {
        if (running) return
        running = true
        Thread({
            val min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val rec = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, 8192),
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.e("ivy-mic", "AudioRecord init failed (RECORD_AUDIO granted?)")
                running = false
                return@Thread
            }
            rec.startRecording()
            var peak = 0
            var chunks = 0
            try {
                while (running) {
                    val buf = ByteArray(2048)
                    val n = rec.read(buf, 0, buf.size)
                    for (i in 0 until n - 1 step 2) peak = maxOf(peak, Math.abs((buf[i + 1].toInt() shl 8) or (buf[i].toInt() and 0xff)))
                    if (++chunks == 80) { // ~5 s
                        Log.d("ivy-mic", "peak $peak / 32767")
                        peak = 0
                        chunks = 0
                    }
                    if (n > 0) main.post { onChunk(if (n == buf.size) buf else buf.copyOf(n)) }
                }
            } finally {
                rec.stop()
                rec.release()
            }
        }, "ivy-mic").start()
    }

    fun stop() {
        running = false
    }

    companion object {
        /** Linear gain on S16LE PCM, clipped. */
        fun boost(pcm: ByteArray, gain: Float): ByteArray {
            if (gain == 1f) return pcm
            val out = ByteArray(pcm.size)
            for (i in 0 until pcm.size - 1 step 2) {
                val s = (pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xff)
                val v = (s * gain).toInt().coerceIn(-32768, 32767)
                out[i] = v.toByte()
                out[i + 1] = (v shr 8).toByte()
            }
            return out
        }
    }
}
