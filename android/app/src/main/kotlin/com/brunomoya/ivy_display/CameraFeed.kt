package com.brunomoya.ivy_display

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.graphics.YuvImage
import android.hardware.Camera
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * The display's 5 MP camera. Its HAL is v1 only, hence the legacy Camera API.
 * Runs while motion detection is on or a JPEG was asked for in the last 15 s
 * (the :2971 camera endpoints), at ~640x480 and the lowest frame rate offered.
 * Motion = share of a 32x24 grid of luma samples that changed between frames
 * 200 ms apart; with the privacy shutter closed frames are black, so no motion.
 */
@Suppress("DEPRECATION")
class CameraFeed(private val onMotion: (Int) -> Unit) {
    private val thread = HandlerThread("ivy-cam").apply { start() }
    private val bg = Handler(thread.looper)
    private val tex = SurfaceTexture(10) // preview needs a target; frames come from the callback
    private var cam: Camera? = null
    private var w = 0
    private var h = 0
    private var startedAt = 0L
    private var lastSample = 0L
    private var lastUse = 0L
    private var lastMotion = 0L
    private var prev: IntArray? = null
    private val latest = Any()
    private var frame: ByteArray? = null // NV21 copy of the newest frame
    var motion = false
        set(v) {
            field = v
            if (v) bg.post { open() } // when off, the idleCheck loop closes it
        }

    /** Latest frame as JPEG (opens the camera and waits for exposure to settle if needed). */
    fun jpeg(quality: Int = 70): ByteArray? {
        lastUse = System.currentTimeMillis()
        bg.post { open() }
        val deadline = System.currentTimeMillis() + 4000
        while (System.currentTimeMillis() < deadline) {
            val warm = cam != null && System.currentTimeMillis() - startedAt > 1200
            val f = synchronized(latest) { frame }
            if (warm && f != null) {
                val out = ByteArrayOutputStream()
                YuvImage(f, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), quality, out)
                return out.toByteArray()
            }
            Thread.sleep(50)
        }
        return null
    }

    private fun open() {
        if (cam != null) return
        try {
            val c = Camera.open(0)
            val p = c.parameters
            val size = p.supportedPreviewSizes.minByOrNull { Math.abs(it.width - 640) + Math.abs(it.height - 480) }!!
            p.setPreviewSize(size.width, size.height)
            p.previewFormat = ImageFormat.NV21
            p.supportedPreviewFpsRange.minByOrNull { it[1] }?.let { p.setPreviewFpsRange(it[0], it[1]) }
            c.parameters = p
            w = size.width
            h = size.height
            val bytes = w * h * 3 / 2
            repeat(2) { c.addCallbackBuffer(ByteArray(bytes)) }
            c.setPreviewCallbackWithBuffer { data, camera -> onFrame(data); camera.addCallbackBuffer(data) }
            c.setPreviewTexture(tex)
            c.startPreview()
            cam = c
            startedAt = System.currentTimeMillis()
            prev = null
            Log.i("ivy-cam", "open ${w}x$h")
            bg.postDelayed(::idleCheck, 15_000)
        } catch (e: Exception) {
            Log.e("ivy-cam", "open failed: $e")
        }
    }

    private fun idleCheck() {
        if (cam == null) return
        if (!motion && System.currentTimeMillis() - lastUse > 15_000) {
            cam?.run { setPreviewCallbackWithBuffer(null); stopPreview(); release() }
            cam = null
            synchronized(latest) { frame = null }
            Log.i("ivy-cam", "closed")
        } else {
            bg.postDelayed(::idleCheck, 5_000)
        }
    }

    private fun onFrame(data: ByteArray) {
        val now = System.currentTimeMillis()
        if (now - lastSample < 200) return
        lastSample = now
        synchronized(latest) {
            val f = frame?.takeIf { it.size == data.size } ?: ByteArray(data.size)
            System.arraycopy(data, 0, f, 0, data.size)
            frame = f
        }
        if (!motion) return
        val grid = IntArray(32 * 24) { i -> data[(i / 32 * h / 24 + h / 48) * w + (i % 32) * w / 32 + w / 64].toInt() and 0xff }
        val old = prev
        prev = grid
        // Skip auto-exposure settling after opening.
        if (old == null || now - startedAt < 3000) return
        // Subtract the frame-wide brightness shift first: auto-exposure and the screen's own
        // light (photo changes) move every cell together; a person moves only some.
        val shift = grid.indices.sumOf { grid[it] - old[it] } / grid.size
        val changed = grid.indices.count { Math.abs(grid[it] - old[it] - shift) > 25 }
        if (changed >= 16 && now - lastMotion > 2000) { // ~2 % of the grid
            lastMotion = now
            onMotion(changed * 100 / grid.size)
        }
    }

    fun stop() {
        motion = false
        bg.post {
            cam?.run { setPreviewCallbackWithBuffer(null); stopPreview(); release() }
            cam = null
        }
        thread.quitSafely()
    }
}
