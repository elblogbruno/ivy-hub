package com.brunomoya.ivy_display

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.os.PowerManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity(), SensorEventListener {
    private var tts: TextToSpeech? = null
    private var ring: MediaPlayer? = null
    private var speech: MediaPlayer? = null
    private var media: MediaPlayer? = null
    @Volatile private var mediaReady = false
    private var channel: MethodChannel? = null
    private val sensors by lazy { getSystemService(SENSOR_SERVICE) as SensorManager }
    private var lastLux = -1f
    private var lastLuxAt = 0L
    private var spotify: SpotifyConnect? = null
    private val callAudio = CallAudio(this)
    // HA's Wyoming path skips the old pipeline's gain (x2 + AGC), so voice is boosted here.
    // Per screen: `settings put global ivy_mic_gain 4` (1 = off), read at app start.
    private val micGain by lazy {
        android.provider.Settings.Global.getFloat(contentResolver, "ivy_mic_gain", 4f)
    }
    private val mic = Mic { callAudio.feed(it); channel?.invokeMethod("mic", Mic.boost(it, micGain)) }
    private val camera = CameraFeed { runOnUiThread { channel?.invokeMethod("motion", it) } }
    // Night mode (set from Dart): voice and earcons play softly; alarms and music don't change.
    private var quiet = false
    private var wyomingRegistration: NsdManager.RegistrationListener? = null
    private val adb by lazy { AdbRoot(filesDir) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )
        val missing = arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA)
            .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 1)
        // iptables rules are lost on reboot: re-block ADB over Wi-Fi if it was turned off.
        if (adb.wifiOff) Thread { adb.apply() }.start()
        // Wi-Fi SSID and scan results need location on 8.1. Granted through the adb root
        // shell instead of requestPermissions: this ROM's permission dialog crashes the app.
        if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) Thread {
            try { adb.shell("pm grant $packageName ${Manifest.permission.ACCESS_COARSE_LOCATION}") }
            catch (e: Exception) { android.util.Log.w("ivy-adb", "grant: $e") }
        }.start()
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) tts?.language = Locale("es", "ES")
        }
        // Lets the voice assistant reopen the mic only after the reply has been spoken.
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) = runOnUiThread { channel?.invokeMethod("ttsDone", id) }
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) = runOnUiThread { channel?.invokeMethod("ttsError", id) }
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ivy/native")
        spotify = SpotifyConnect(
            this,
            onEvent = { channel?.invokeMethod("spotify", it) },
            onLyrics = { id, json -> channel?.invokeMethod("spotifyLyrics", mapOf("id" to id, "json" to json)) },
        ).also { it.start() }
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> tts?.speak(
                    call.arguments as String, TextToSpeech.QUEUE_FLUSH,
                    Bundle().apply { if (quiet) putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 0.25f) }, "ivy"
                )
                "quiet" -> {
                    quiet = call.arguments as Boolean
                    android.util.Log.i("ivy", "quiet=$quiet")
                }
                "wake" -> {
                    @Suppress("DEPRECATION")
                    (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                        "ivy:wake"
                    ).acquire(3000)
                }
                // -1 = follow system brightness; 0..1 = override for this window only.
                "brightness" -> window.attributes = window.attributes.apply {
                    screenBrightness = (call.arguments as Number).toFloat()
                }
                // Media volume (STREAM_MUSIC), 0..100. getVolume reports the current %.
                "volume" -> {
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager
                    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val pct = (call.arguments as Number).toInt().coerceIn(0, 100)
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(max * pct / 100f), 0)
                }
                "getVolume" -> {
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager
                    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    result.success(if (max == 0) 0 else Math.round(am.getStreamVolume(AudioManager.STREAM_MUSIC) * 100f / max))
                    return@setMethodCallHandler
                }
                "sensors" -> registerSensors() // called once Dart listens, so the first reading isn't lost
                "speakUrl" -> playSpeech(call.arguments as String)
                "wyomingSpeakUrl" -> {
                    val args = call.arguments as Map<*, *>
                    playSpeech(args["path"] as String, args["id"] as String)
                }
                "wyomingSpeak" -> {
                    val args = call.arguments as Map<*, *>
                    tts?.speak(args["text"] as String, TextToSpeech.QUEUE_FLUSH,
                        Bundle().apply { if (quiet) putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 0.25f) }, args["id"] as String)
                }
                "speechStop" -> {
                    speech?.run { try { stop() } catch (_: Exception) {}; release() }
                    speech = null
                    tts?.stop()
                    pcmStop()
                }
                // HA's Wyoming TTS stream, played as it arrives instead of after the whole reply.
                "pcmStart" -> {
                    val args = call.arguments as Map<*, *>
                    pcmStart((args["rate"] as Number).toInt(), (args["channels"] as Number).toInt())
                }
                "pcmWrite" -> pcmWrite(call.arguments as ByteArray)
                "pcmEnd" -> pcmEnd(call.arguments as String)
                "wyomingAdvertise" -> {
                    val args = call.arguments as Map<*, *>
                    advertiseWyoming(args["name"] as String, (args["port"] as Number).toInt())
                }
                "wyomingStop" -> stopWyomingDiscovery()
                "deviceId" -> {
                    result.success(android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID))
                    return@setMethodCallHandler
                }
                "playMedia" -> playMedia(call.arguments as String)
                "mediaControl" -> when (call.arguments as String) {
                    "pause" -> media?.takeIf { it.isPlaying }?.pause()
                    "resume" -> media?.start()
                    "stop" -> { media?.run { try { stop() } catch (_: Exception) {}; release() }; media = null }
                }
                "mediaInfo" -> {
                    // Querying position/duration before prepared throws (-38) on this
                    // build; only touch the player once onPrepared has fired.
                    val m = media
                    result.success(if (m == null || !mediaReady) null else mapOf(
                        "playing" to (try { m.isPlaying } catch (_: Exception) { false }),
                        "position_ms" to (try { m.currentPosition } catch (_: Exception) { 0 }),
                        "duration_ms" to (try { m.duration } catch (_: Exception) { -1 })))
                    return@setMethodCallHandler
                }
                "spotifyCmd" -> spotify?.send(call.arguments as String)
                // Screen-to-screen call audio (video is the peer's MJPEG on :2971).
                "callStart" -> callAudio.start(call.arguments as String)
                "callStop" -> callAudio.stop()
                "callMute" -> callAudio.muted = call.arguments as Boolean
                "micStart" -> mic.start()
                "micStop" -> mic.stop()
                "cameraMotion" -> camera.motion = call.arguments as Boolean
                // Blocks until a settled frame exists (camera may be cold): off the UI thread.
                "cameraJpeg" -> {
                    Thread { camera.jpeg().let { runOnUiThread { result.success(it) } } }.start()
                    return@setMethodCallHandler
                }
                // Assistant-style earcons: a soft two-note chime, rising on wake, falling on done.
                "earcon" -> earcon(call.arguments as String)
                "ringStart" -> startRing()
                "ringStop" -> stopRing()
                "filesDir" -> {
                    result.success(filesDir.absolutePath)
                    return@setMethodCallHandler
                }
                // This screen's room (HA area name), e.g. "Kitchen"; set per device with
                // `settings put global ivy_room "Kitchen"`. Null when unset.
                "deviceRoom" -> {
                    result.success(android.provider.Settings.Global.getString(contentResolver, "ivy_room"))
                    return@setMethodCallHandler
                }
                "deviceName" -> {
                    result.success(android.provider.Settings.Global.getString(contentResolver, "ivy_name"))
                    return@setMethodCallHandler
                }
                // The other screen to offer a call button to; set per device with
                // `settings put global ivy_peer_ip`/`ivy_peer_name`. Null when unset.
                "callPeer" -> {
                    val ip = android.provider.Settings.Global.getString(contentResolver, "ivy_peer_ip")
                    val nm = android.provider.Settings.Global.getString(contentResolver, "ivy_peer_name")
                    result.success(if (ip.isNullOrBlank()) null else mapOf("ip" to ip, "name" to (nm ?: "Ivy")))
                    return@setMethodCallHandler
                }
                // Network page (lib/network.dart).
                "wifiInfo" -> {
                    val c = wifi.connectionInfo
                    val d = wifi.dhcpInfo
                    val mac = java.net.NetworkInterface.getByName("wlan0")?.hardwareAddress
                        ?.joinToString(":") { "%02x".format(it) }
                    result.success(mapOf(
                        "ssid" to c?.ssid?.trim('"'),
                        "rssi" to c?.rssi,
                        "ip" to ipv4(c?.ipAddress ?: 0),
                        "gateway" to ipv4(d?.gateway ?: 0),
                        "dns" to ipv4(d?.dns1 ?: 0),
                        "mac" to mac,
                    ))
                    return@setMethodCallHandler
                }
                // Returns the last scan; `true` also starts a new one (results land a few s later).
                "wifiScan" -> {
                    if (call.arguments == true) @Suppress("DEPRECATION") wifi.startScan()
                    result.success(try {
                        wifi.scanResults.filter { it.SSID.isNotBlank() }
                            .groupBy { it.SSID }.map { (_, v) -> v.maxBy { it.level } }
                            .sortedByDescending { it.level }
                            .map { mapOf("ssid" to it.SSID, "level" to it.level,
                                "secure" to Regex("WPA|WEP|PSK|EAP").containsMatchIn(it.capabilities)) }
                    } catch (_: SecurityException) { emptyList() })
                    return@setMethodCallHandler
                }
                // ADB over Wi-Fi: null = query; true/false = allow/block (persists). Returns allowed.
                "adbWifi" -> {
                    val on = call.arguments as Boolean?
                    if (on == null) result.success(!adb.wifiOff)
                    else Thread { adb.setWifiOff(!on).let { runOnUiThread { result.success(!it) } } }.start()
                    return@setMethodCallHandler
                }
                // Null on success, otherwise an error message for the UI.
                "wifiConnect" -> {
                    result.success(wifiConnect(call.argument<String>("ssid")!!, call.argument<String>("password") ?: ""))
                    return@setMethodCallHandler
                }
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            result.success(null)
        }
    }

    private val wifi by lazy { applicationContext.getSystemService(WIFI_SERVICE) as android.net.wifi.WifiManager }

    private fun ipv4(i: Int) = if (i == 0) null else
        "${i and 0xff}.${i shr 8 and 0xff}.${i shr 16 and 0xff}.${i shr 24 and 0xff}"

    // Pre-Q WifiManager API: fine on this Android 8.1 build regardless of targetSdk.
    @Suppress("DEPRECATION")
    private fun wifiConnect(ssid: String, pass: String): String? {
        if (pass.isNotEmpty() && pass.length < 8) return "La contraseña WPA tiene al menos 8 caracteres"
        if (!wifi.isWifiEnabled) wifi.isWifiEnabled = true
        val quoted = "\"$ssid\""
        // Replace our own earlier entry for this SSID; one saved by the system can't be
        // removed by an app, and then addNetwork() fails below.
        wifi.configuredNetworks?.filter { it.SSID == quoted }?.forEach { wifi.removeNetwork(it.networkId) }
        val conf = android.net.wifi.WifiConfiguration().apply {
            SSID = quoted
            if (pass.isEmpty()) allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
            else preSharedKey = "\"$pass\""
        }
        val id = wifi.addNetwork(conf)
        if (id < 0) return "No se pudo guardar la red (¿ya guardada por el sistema?)"
        wifi.enableNetwork(id, true)
        wifi.saveConfiguration()
        wifi.reconnect()
        return null
    }

    // VCNL4200 light + proximity: drive the light-based standby/off mode in Dart.
    override fun onResume() {
        super.onResume()
        registerSensors()
    }

    // On-change sensors emit their current value right after registering.
    private fun registerSensors() {
        sensors.unregisterListener(this)
        lastLux = -1f
        // Android Things registers the VCNL4200 through a user driver, i.e. as a *dynamic* sensor.
        for (type in intArrayOf(Sensor.TYPE_LIGHT, Sensor.TYPE_PROXIMITY)) {
            (sensors.getDefaultSensor(type) ?: sensors.getDynamicSensorList(type).firstOrNull())
                ?.let { sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL) }
        }
    }

    override fun onPause() {
        sensors.unregisterListener(this)
        super.onPause()
    }

    override fun onSensorChanged(e: SensorEvent) {
        when (e.sensor.type) {
            Sensor.TYPE_LIGHT -> {
                val lux = e.values[0]
                val now = System.currentTimeMillis()
                // Only forward meaningful changes (>15 % or 1 lux), or a heartbeat every 10 s.
                if (Math.abs(lux - lastLux) > Math.max(1f, lastLux * 0.15f) || now - lastLuxAt > 10_000) {
                    lastLux = lux
                    lastLuxAt = now
                    channel?.invokeMethod("lux", lux.toDouble())
                }
            }
            Sensor.TYPE_PROXIMITY -> channel?.invokeMethod("near", e.values[0] < e.sensor.maximumRange)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // A gentle two-note chime (sine + soft octave, bell-like decay), synthesised so we
    // ship no audio files: rising perfect fifth on wake, falling on done. Plays on the
    // media stream so it follows the music volume, like the old tones did.
    private fun earcon(kind: String) {
        Thread {
            val sr = 44100
            // A4 -> E5 rising (wake), reversed on done. Grave but still clear on the small speaker.
            val notes = if (kind == "wake") listOf(440.0 to 90, 659.25 to 170)
                        else listOf(659.25 to 90, 440.0 to 190)
            val gain = if (quiet) 0.18 else 0.5
            val total = notes.sumOf { (it.second * sr / 1000) }
            val buf = ShortArray(total)
            var i = 0
            for ((freq, ms) in notes) {
                val n = ms * sr / 1000
                for (s in 0 until n) {
                    val t = s.toDouble() / n
                    // quick attack, exponential bell decay, 5 ms fade-out to kill the click
                    val env = minOf(1.0, s / (sr * 0.006)) * Math.exp(-3.0 * t) *
                              minOf(1.0, (n - s) / (sr * 0.005))
                    val w = Math.sin(2 * Math.PI * freq * s / sr) +
                            0.18 * Math.sin(2 * Math.PI * 2 * freq * s / sr)
                    buf[i++] = (w * env * gain * Short.MAX_VALUE).toInt().toShort()
                }
            }
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sr)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()
                )
                .setBufferSizeInBytes(buf.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            track.write(buf, 0, buf.size)
            track.play()
            try { Thread.sleep((total * 1000L / sr) + 60) } catch (_: Exception) {}
            track.release()
        }.start()
    }

    // Plays the pipeline's TTS MP3 (OpenAI voice) over the media stream, so the voice
    // follows the same volume as music. Signals Dart on finish, exactly like device TTS.
    private fun playSpeech(url: String, completionId: String = "url") {
        speech?.run { try { stop() } catch (_: Exception) {}; release() }
        speech = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
            )
            setOnPreparedListener { if (quiet) setVolume(0.25f, 0.25f); start() }
            setOnCompletionListener {
                runOnUiThread { channel?.invokeMethod("ttsDone", completionId) }
                release(); if (speech === this) speech = null
            }
            setOnErrorListener { _, _, _ ->
                runOnUiThread { channel?.invokeMethod("ttsError", completionId) }
                release(); if (speech === this) speech = null
                true
            }
            setDataSource(url)
            prepareAsync()
        }
    }

    // Live TTS: writes run on one thread, in order; stop/replace drops the old track at once.
    private val pcmThread = java.util.concurrent.Executors.newSingleThreadExecutor()
    @Volatile private var pcm: AudioTrack? = null
    private var pcmBytes = 0L // written to the current track (pcmThread only)

    private fun pcmStart(rate: Int, channels: Int) {
        pcmStop()
        val mask = if (channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
            )
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(mask).build()
            )
            .setBufferSizeInBytes(maxOf(min, rate * channels)) // ~0.5 s
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (quiet) t.setVolume(0.25f)
        t.play()
        pcm = t
        pcmThread.execute { pcmBytes = 0 }
    }

    private fun pcmPut(t: AudioTrack, bytes: ByteArray): Int {
        var off = 0
        while (off < bytes.size && pcm === t) {
            val n = t.write(bytes, off, bytes.size - off, AudioTrack.WRITE_NON_BLOCKING)
            if (n < 0) break
            off += n
            if (n == 0) Thread.sleep(10)
        }
        return off
    }

    private fun pcmWrite(bytes: ByteArray) {
        val t = pcm ?: return
        pcmThread.execute { pcmBytes += pcmPut(t, bytes) }
    }

    // Plays out what's queued, then reports done like the other speech players.
    private fun pcmEnd(id: String) {
        val t = pcm ?: return
        pcmThread.execute {
            val frames = pcmBytes / (2 * t.channelCount)
            // A new track only starts once its buffer is full, and stop() zeroes the
            // position on 8.1: push the tail out with one buffer of silence instead.
            pcmPut(t, ByteArray(t.bufferSizeInFrames * 2 * t.channelCount))
            val deadline = System.currentTimeMillis() + frames * 1000 / t.sampleRate + 3000
            while (pcm === t && t.playbackHeadPosition < frames && System.currentTimeMillis() < deadline) {
                Thread.sleep(20)
            }
            runOnUiThread {
                if (pcm !== t) return@runOnUiThread
                pcm = null
                t.release()
                channel?.invokeMethod("ttsDone", id)
            }
        }
    }

    private fun pcmStop() {
        val t = pcm ?: return
        pcm = null
        try { t.pause(); t.flush() } catch (_: Exception) {}
        pcmThread.execute { t.release() }
    }

    // Radio/stream URL for the HA "Ivy" media_player, on the media stream (same
    // volume as everything else). Tells Dart when it finishes so state goes idle.
    private fun playMedia(url: String) {
        media?.run { try { stop() } catch (_: Exception) {}; release() }
        mediaReady = false
        media = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
            )
            setOnPreparedListener { mediaReady = true; start() }
            setOnCompletionListener {
                mediaReady = false
                runOnUiThread { channel?.invokeMethod("mediaDone", null) }
                release(); if (media === this) media = null
            }
            setOnErrorListener { _, _, _ ->
                mediaReady = false
                runOnUiThread { channel?.invokeMethod("mediaDone", null) }
                release(); if (media === this) media = null
                true
            }
            setDataSource(url)
            prepareAsync()
        }
    }

    private fun startRing() {
        stopRing()
        // This Android Things build has no default alarm configured; fall back to the bundled beep.
        val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
            ?: Uri.fromFile(File("/system/media/audio/alarms/Alarm_Beep_02.ogg"))
        ring = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
            setDataSource(this@MainActivity, uri)
            isLooping = true
            prepare()
            start()
        }
    }

    private fun stopRing() {
        ring?.run { stop(); release() }
        ring = null
    }

    private fun advertiseWyoming(name: String, port: Int) {
        stopWyomingDiscovery()
        val manager = getSystemService(NSD_SERVICE) as NsdManager
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                android.util.Log.w("ivy-wyoming", "mDNS registration failed: $code; use manual IP/port")
            }
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        wyomingRegistration = listener
        manager.registerService(NsdServiceInfo().apply {
            serviceName = name
            serviceType = "_wyoming._tcp."
            setPort(port)
            setAttribute("name", name)
            setAttribute("protocol", "wyoming")
            setAttribute("version", "1.0")
        }, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun stopWyomingDiscovery() {
        wyomingRegistration?.let {
            try { (getSystemService(NSD_SERVICE) as NsdManager).unregisterService(it) }
            catch (_: IllegalArgumentException) {}
        }
        wyomingRegistration = null
    }

    override fun onDestroy() {
        stopWyomingDiscovery()
        mic.stop()
        callAudio.stop()
        camera.stop()
        spotify?.stop()
        stopRing()
        speech?.release()
        media?.release()
        tts?.shutdown()
        super.onDestroy()
    }
}
