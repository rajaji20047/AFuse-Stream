package com.raja.fuse

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.URL
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

private const val TAG = "WarpModule"
private const val CHANNEL = "dev.rajaji.raja/warp"

/** How to reach Cloudflare, tried in order until traffic passes. */
private data class TunnelMode(val label: String, val args: List<String>)

private val TUNNEL_MODES = listOf(
    TunnelMode("HTTP/3", emptyList()),
    // Networks that block QUIC (UDP 443) usually still allow TCP 443.
    TunnelMode("HTTP/2", listOf("--http2")),
    // Last resort for an endpoint whose certificate does not match the pinned key.
    TunnelMode("HTTP/3 without certificate pinning", listOf("--insecure")),
)

private const val TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace"

/**
 * Cloudflare WARP as a local HTTP proxy, ported from the Vega app's
 * WarpModule (React Native) to a Flutter MethodChannel.
 *
 * There is no system VPN here and no VpnService permission: the `usque`
 * binary (a MASQUE/WARP client, shipped as `libusque.so` in jniLibs)
 * runs as a subprocess exposing an HTTP proxy on 127.0.0.1:<port>, and
 * the app's own Dart HTTP client routes through it. Other apps and the
 * system resolver are untouched.
 *
 * First launch registers a fresh WARP account with Cloudflare
 * (api.cloudflareclient.com) and writes `warp/config.json` under the
 * app's files dir; later launches reuse it.
 */
class WarpModule(private val appContext: Context) {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var warpProcess: Process? = null

    @Volatile
    private var currentPort: Int? = null

    /** The port the proxy is listening on, or null when WARP is off. */
    val proxyPort: Int? get() = currentPort

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startWarp" -> Thread { startWarp(result) }.start()
                "stopWarp" -> Thread { stopWarp(result) }.start()
                "getStatus" -> getStatus(result)
                else -> result.notImplemented()
            }
        }
    }

    /** Stops the proxy. Called when the Flutter engine goes away. */
    fun stop() {
        stopInternal()
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(
        result: MethodChannel.Result,
        code: String,
        message: String?,
    ) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun getBinaryFile(): File {
        val nativeLib = File(appContext.applicationInfo.nativeLibraryDir, "libusque.so")
        if (nativeLib.exists()) {
            if (!nativeLib.canExecute()) {
                nativeLib.setExecutable(true, false)
            }
            return nativeLib
        }

        // Older builds extracted an arm64-only copy to the files root; it can never run on 32-bit devices.
        val legacyCopy = File(appContext.filesDir, "libusque.so")
        if (legacyCopy.exists() && !legacyCopy.delete()) {
            Log.w(TAG, "Failed to delete legacy libusque.so copy at ${legacyCopy.absolutePath}")
        }

        try {
            val apkPath = appContext.applicationInfo.sourceDir
            if (apkPath != null) {
                val apkFile = File(apkPath)
                if (apkFile.exists()) {
                    java.util.zip.ZipFile(apkFile).use { zip ->
                        // Only consider ABIs the device lists, in preference order.
                        for (abi in android.os.Build.SUPPORTED_ABIS) {
                            val entry = zip.getEntry("lib/$abi/libusque.so") ?: continue
                            val fallback = File(File(File(appContext.filesDir, "native"), abi), "libusque.so")
                            val stale = !fallback.exists() ||
                                fallback.length() == 0L ||
                                (entry.size >= 0L && fallback.length() != entry.size)
                            if (stale) {
                                fallback.parentFile?.mkdirs()
                                val temp = File(fallback.parentFile, "libusque.so.tmp")
                                zip.getInputStream(entry).use { input ->
                                    temp.outputStream().use { output ->
                                        input.copyTo(output)
                                    }
                                }
                                if (fallback.exists()) fallback.delete()
                                if (!temp.renameTo(fallback)) {
                                    temp.delete()
                                    throw IOException("Cannot move extracted binary to ${fallback.absolutePath}")
                                }
                                Log.i(TAG, "Extracted libusque.so ($abi) from APK to ${fallback.absolutePath}")
                            }
                            fallback.setExecutable(true, false)
                            Log.i(TAG, "Using libusque.so for ABI $abi")
                            return fallback
                        }
                        Log.w(TAG, "APK has no libusque.so for supported ABIs ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to extract libusque.so fallback from APK: ${e.message}")
        }

        return nativeLib
    }

    private fun getWarpDir(): File {
        val dir = File(appContext.filesDir, "warp")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    private fun getConfigFile(): File {
        return File(getWarpDir(), "config.json")
    }

    private fun killOrphanProcesses() {
        try {
            Runtime.getRuntime().exec(arrayOf("killall", "libusque.so")).waitFor(500, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
        }
    }

    private fun stopInternal() {
        try {
            val proc = warpProcess
            if (proc != null && proc.isAlive) {
                proc.destroy()
                proc.waitFor(2, TimeUnit.SECONDS)
                if (proc.isAlive) {
                    proc.destroyForcibly()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping WARP process: ${e.message}")
        } finally {
            warpProcess = null
            currentPort = null
            killOrphanProcesses()
        }
    }

    private fun generateEcKeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("prime256v1"))
        return kpg.generateKeyPair()
    }

    private fun toFixedByteArray(bi: java.math.BigInteger, targetLen: Int): ByteArray {
        val raw = bi.toByteArray()
        if (raw.size == targetLen) return raw
        val out = ByteArray(targetLen)
        if (raw.size > targetLen) {
            System.arraycopy(raw, raw.size - targetLen, out, 0, targetLen)
        } else {
            System.arraycopy(raw, 0, out, targetLen - raw.size, raw.size)
        }
        return out
    }

    private fun encodeSec1PrivateKey(keyPair: KeyPair): String {
        val privKey = keyPair.private as ECPrivateKey
        val pubKey = keyPair.public as ECPublicKey

        val dBytes = toFixedByteArray(privKey.s, 32)
        val xBytes = toFixedByteArray(pubKey.w.affineX, 32)
        val yBytes = toFixedByteArray(pubKey.w.affineY, 32)

        val uncompressed = byteArrayOf(0x04) + xBytes + yBytes
        val sec1 = byteArrayOf(
            0x30.toByte(), 0x77.toByte(),
            0x02.toByte(), 0x01.toByte(), 0x01.toByte(),
            0x04.toByte(), 0x20.toByte(),
        ) + dBytes + byteArrayOf(
            0xa0.toByte(), 0x0a.toByte(),
            0x06.toByte(), 0x08.toByte(),
            0x2a.toByte(), 0x86.toByte(), 0x48.toByte(), 0xce.toByte(), 0x3d.toByte(), 0x03.toByte(), 0x01.toByte(), 0x07.toByte(),
            0xa1.toByte(), 0x44.toByte(),
            0x03.toByte(), 0x42.toByte(), 0x00.toByte(),
        ) + uncompressed

        return Base64.encodeToString(sec1, Base64.NO_WRAP)
    }

    /**
     * POSTs/reads JSON over HTTPS. Returns the parsed body, or throws on a
     * non-2xx status. HttpURLConnection, not OkHttp: the app has no OkHttp
     * dependency, and these two calls do not need one.
     */
    private fun httpJson(
        url: String,
        method: String,
        body: JSONObject?,
        headers: Map<String, String>,
    ): JSONObject {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15000
            conn.readTimeout = 15000
            for ((key, value) in headers) {
                conn.setRequestProperty(key, value)
            }
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                conn.outputStream.use { out ->
                    out.write(body.toString().toByteArray(Charsets.UTF_8))
                }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.readText().orEmpty()
            if (code !in 200..299) {
                throw IOException("HTTP $code: $text")
            }
            return JSONObject(text)
        } finally {
            conn.disconnect()
        }
    }

    private fun registerCloudflare(configFile: File) {
        val keyPair = generateEcKeyPair()
        val sec1PrivKeyBase64 = encodeSec1PrivateKey(keyPair)
        val masquePubKeyBase64 = Base64.encodeToString(keyPair.public.encoded, Base64.NO_WRAP)

        val secureRandom = SecureRandom()
        val wgRandom = ByteArray(32)
        secureRandom.nextBytes(wgRandom)
        val wgKeyBase64 = Base64.encodeToString(wgRandom, Base64.NO_WRAP)

        val serialBytes = ByteArray(8)
        secureRandom.nextBytes(serialBytes)
        val serialHex = serialBytes.joinToString("") { "%02x".format(it) }

        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
        sdf.timeZone = TimeZone.getTimeZone("UTC")
        val tos = sdf.format(Date())

        val baseHeaders = mapOf(
            "User-Agent" to "WARP for Android",
            "CF-Client-Version" to "a-6.35-4471",
            "Connection" to "Keep-Alive",
        )

        // 1. POST /v0a4471/reg
        val regBodyJson = JSONObject().apply {
            put("key", wgKeyBase64)
            put("install_id", "")
            put("fcm_token", "")
            put("tos", tos)
            put("model", "PC")
            put("serial_number", serialHex)
            put("os_version", "")
            put("key_type", "curve25519")
            put("tunnel_type", "wireguard")
            put("locale", "en_US")
        }

        val regJson = httpJson(
            "https://api.cloudflareclient.com/v0a4471/reg",
            "POST",
            regBodyJson,
            baseHeaders,
        )
        val regObj = if (regJson.has("result") && !regJson.isNull("result")) {
            regJson.getJSONObject("result")
        } else {
            regJson
        }
        val accountId = regObj.getString("id")
        val token = regObj.getString("token")

        // 2. PATCH /v0a4471/reg/{id}
        val patchBodyJson = JSONObject().apply {
            put("key", masquePubKeyBase64)
            put("key_type", "secp256r1")
            put("tunnel_type", "masque")
        }

        val patchJson = httpJson(
            "https://api.cloudflareclient.com/v0a4471/reg/$accountId",
            "PATCH",
            patchBodyJson,
            baseHeaders + ("Authorization" to "Bearer $token"),
        )
        val patchObj = if (patchJson.has("result") && !patchJson.isNull("result")) {
            patchJson.getJSONObject("result")
        } else {
            patchJson
        }
        val configObj = patchObj.getJSONObject("config")
        val peerObj = configObj.getJSONArray("peers").getJSONObject(0)
        val endpointObj = peerObj.getJSONObject("endpoint")

        val endpointV4 = endpointObj.getString("v4").removeSuffix(":0")
        val endpointV6 = endpointObj.getString("v6").removePrefix("[").removeSuffix("]:0")
        val peerPubKey = peerObj.getString("public_key")

        val interfaceObj = configObj.getJSONObject("interface")
        val addressesObj = interfaceObj.getJSONObject("addresses")
        val ipv4 = addressesObj.getString("v4")
        val ipv6 = addressesObj.getString("v6")

        val finalConfig = JSONObject().apply {
            put("private_key", sec1PrivKeyBase64)
            put("endpoint_v4", endpointV4)
            put("endpoint_v6", endpointV6)
            put("endpoint_h2_v4", "162.159.198.2")
            put("endpoint_h2_v6", "")
            put("endpoint_pub_key", peerPubKey)
            put("id", patchObj.getString("id"))
            put("access_token", token)
            put("ipv4", ipv4)
            put("ipv6", ipv6)
        }

        configFile.parentFile?.mkdirs()
        configFile.writeText(finalConfig.toString(2))
        Log.i(TAG, "WARP config.json written successfully")
    }

    /**
     * Starts the proxy and waits until it listens. Uses http-proxy, not
     * l4-http-proxy: the L4 mode looks up site names with plain DNS
     * outside the tunnel, where an ISP that poisons DNS returns its block
     * page address; http-proxy resolves names inside the tunnel.
     */
    private fun launchProxy(
        binary: File,
        configFile: File,
        port: Int,
        extraArgs: List<String>,
    ): Process? {
        val command = mutableListOf(
            binary.absolutePath,
            "-c", configFile.absolutePath,
            "http-proxy",
            "-b", "127.0.0.1",
            "-p", port.toString(),
            "-d", "1.1.1.1",
            "-d", "8.8.8.8",
        )
        command.addAll(extraArgs)
        val pb = ProcessBuilder(command)
        pb.directory(getWarpDir())
        pb.redirectErrorStream(true)
        val proc = pb.start()

        val listening = java.util.concurrent.atomic.AtomicBoolean(false)
        Thread {
            try {
                proc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d("WarpProcess", line)
                    if (line.contains("listening on", ignoreCase = true)) {
                        listening.set(true)
                    }
                }
            } catch (_: Exception) {
            }
        }.start()

        var waitedMs = 0
        while (waitedMs < 3000 && proc.isAlive && !listening.get()) {
            Thread.sleep(100)
            waitedMs += 100
        }
        return if (proc.isAlive) proc else null
    }

    /** True when a request through the proxy reaches Cloudflare with WARP on. */
    private fun tunnelWorks(port: Int): Boolean {
        return try {
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))
            val conn = URL(TRACE_URL).openConnection(proxy) as HttpURLConnection
            try {
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.connect()
                val code = conn.responseCode
                val body = conn.inputStream?.bufferedReader()?.readText().orEmpty()
                code in 200..299 &&
                    (body.contains("warp=on") || body.contains("warp=plus"))
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Log.w(TAG, "WARP check through port $port failed: ${e.message}")
            false
        }
    }

    private fun startWarp(result: MethodChannel.Result) {
        try {
            // A local, not the volatile field: another thread can clear
            // the port between the null check and the use.
            val livePort = currentPort
            if (warpProcess?.isAlive == true && livePort != null) {
                postSuccess(
                    result,
                    mapOf("running" to true, "port" to livePort),
                )
                return
            }

            killOrphanProcesses()

            val binary = getBinaryFile()
            if (!binary.exists()) {
                postError(
                    result,
                    "WARP_BINARY_NOT_FOUND",
                    "libusque.so not found at ${binary.absolutePath}",
                )
                return
            }

            val configFile = getConfigFile()
            if (!configFile.exists() || configFile.length() == 0L) {
                Log.i(TAG, "Registering Cloudflare WARP account via HTTPS...")
                try {
                    registerCloudflare(configFile)
                } catch (e: Exception) {
                    Log.e(TAG, "WARP registration error: ${e.message}", e)
                    postError(
                        result,
                        "WARP_REGISTRATION_FAILED",
                        "Failed to register WARP client: ${e.message}",
                    )
                    return
                }
            }

            val failures = mutableListOf<String>()
            for (mode in TUNNEL_MODES) {
                val port = try {
                    ServerSocket(0).use { it.localPort }
                } catch (e: Exception) {
                    8086
                }
                val proc = launchProxy(binary, configFile, port, mode.args)
                if (proc == null) {
                    failures.add("${mode.label}: proxy exited")
                    continue
                }
                if (!tunnelWorks(port)) {
                    failures.add("${mode.label}: no traffic through Cloudflare")
                    proc.destroy()
                    proc.waitFor(2, TimeUnit.SECONDS)
                    if (proc.isAlive) proc.destroyForcibly()
                    continue
                }

                warpProcess = proc
                currentPort = port
                // Clears the routing when the proxy dies, so requests stop pointing at a
                // dead port.
                Thread {
                    try {
                        proc.waitFor()
                    } catch (_: Exception) {
                    }
                    if (warpProcess == proc) {
                        Log.i(TAG, "WARP proxy process terminated unexpectedly")
                        stopInternal()
                    }
                }.start()

                Log.i(TAG, "WARP connected over ${mode.label} on port $port")
                postSuccess(
                    result,
                    mapOf(
                        "running" to true,
                        "port" to port,
                        "transport" to mode.label,
                    ),
                )
                return
            }

            stopInternal()
            postError(
                result,
                "WARP_TUNNEL_FAILED",
                "Could not connect to Cloudflare WARP. ${failures.joinToString("; ")}",
            )
        } catch (e: Exception) {
            stopInternal()
            postError(result, "WARP_ERROR", e.message)
        }
    }

    private fun stopWarp(result: MethodChannel.Result) {
        try {
            stopInternal()
            postSuccess(result, mapOf("running" to false))
        } catch (e: Exception) {
            postError(result, "WARP_ERROR", e.message)
        }
    }

    private fun getStatus(result: MethodChannel.Result) {
        val isRunning = warpProcess?.isAlive == true
        val map = mutableMapOf<String, Any>("running" to isRunning)
        currentPort?.let { map["port"] = it }
        postSuccess(result, map)
    }
}
