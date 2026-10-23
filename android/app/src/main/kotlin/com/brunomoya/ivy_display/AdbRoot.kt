package com.brunomoya.ivy_display

import java.io.DataInputStream
import java.io.File
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// Root for the app: the AOSP `su` only serves shell/root, and SELinux blocks setprop
/// from an app even as uid 0, so commands go through the local adbd (ro.adb.secure is
/// unset on these builds: no auth) as `shell:su 0 sh -c ...`.
/// ADB over Wi-Fi off = an iptables DROP for :5555 on everything but loopback, so adbd
/// stays reachable from here (and over USB) and the app can lift it again. iptables
/// rules don't survive a reboot: the flag file makes the app re-apply them at start.
class AdbRoot(filesDir: File) {
    private val flag = File(filesDir, "adb_wifi_off")
    val wifiOff get() = flag.exists()

    private val rule = "INPUT -p tcp --dport 5555 ! -i lo -j DROP"

    /// Blocking: call off the UI thread. Returns the new state (true = Wi-Fi ADB blocked).
    fun setWifiOff(off: Boolean): Boolean {
        if (off) flag.writeText("1") else flag.delete()
        apply()
        return wifiOff
    }

    /// Re-applies the saved state. At boot adbd may not be up yet: retry for ~1 min.
    fun apply() {
        val script = if (wifiOff) {
            "for t in iptables ip6tables; do \$t -w -C $rule 2>/dev/null || \$t -w -I $rule; done"
        } else {
            "for t in iptables ip6tables; do while \$t -w -D $rule 2>/dev/null; do :; done; done"
        }
        for (i in 0 until 12) {
            try {
                android.util.Log.i("ivy-adb", "wifiOff=$wifiOff: ${shell("su 0 sh -c '$script'")}")
                return
            } catch (e: Exception) {
                android.util.Log.w("ivy-adb", "adbd: $e")
                Thread.sleep(5000)
            }
        }
    }

    /// Minimal adb wire protocol: CNXN, OPEN shell:, collect WRTE until CLSE.
    fun shell(cmd: String): String {
        Socket("127.0.0.1", 5555).use { s ->
            s.soTimeout = 15000
            val out = s.getOutputStream()
            val inp = DataInputStream(s.getInputStream())
            fun send(c: Int, a0: Int, a1: Int, data: ByteArray = ByteArray(0)) {
                val b = ByteBuffer.allocate(24 + data.size).order(ByteOrder.LITTLE_ENDIAN)
                b.putInt(c).putInt(a0).putInt(a1).putInt(data.size)
                    .putInt(data.sumOf { it.toInt() and 0xff }).putInt(c.inv()).put(data)
                out.write(b.array()); out.flush()
            }
            // (command, arg0 = sender's stream id, payload)
            fun recv(): Triple<Int, Int, ByteArray> {
                val h = ByteArray(24).also { inp.readFully(it) }
                val bb = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN)
                return Triple(bb.getInt(0), bb.getInt(4), ByteArray(bb.getInt(12)).also { inp.readFully(it) })
            }
            send(CNXN, 0x01000000, 4096, "host::\u0000".toByteArray())
            while (true) {
                val (c, _, _) = recv()
                if (c == CNXN) break
                if (c == AUTH) error("adbd pide autenticación (ro.adb.secure=1)")
            }
            send(OPEN, 1, 0, "shell:$cmd\u0000".toByteArray())
            val res = StringBuilder()
            while (true) {
                val (c, remote, d) = recv()
                when (c) {
                    WRTE -> { res.append(String(d)); send(OKAY, 1, remote) }
                    CLSE -> { send(CLSE, 1, remote); return res.toString().trim() }
                }
            }
        }
    }

    companion object {
        private const val CNXN = 0x4e584e43
        private const val AUTH = 0x48545541
        private const val OPEN = 0x4e45504f
        private const val OKAY = 0x59414b4f
        private const val WRTE = 0x45545257
        private const val CLSE = 0x45534c43
    }
}
