package eu.ministrant.manager

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NetworkSignalPlugin(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)
        SnapshotCryptoPlugin().register(flutterEngine.dartExecutor.binaryMessenger)
    }
}

/**
 * AES-GCM with the platform's own library, for the saved pages.
 *
 * The same algorithm, key and BYTES as the Dart implementation in
 * SnapshotEncryptor: data = IV (12 bytes) + ciphertext + 16-byte tag, so what
 * one side writes the other reads. Plain Dart does this at ~50 KB per second in
 * a debug build; this takes milliseconds.
 *
 * It decides nothing: on any failure (a payload that does not authenticate, a
 * wrong key, a bad argument) it answers with an error code, and Dart, which has
 * the authoritative implementation, does the work and gives the real verdict.
 * Neither the key nor any data is ever put in an error message.
 */
class SnapshotCryptoPlugin : MethodChannel.MethodCallHandler {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "eu.ministrant.manager/crypto").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val key = call.argument<ByteArray>("key")
            val data = call.argument<ByteArray>("data")
            if (key == null || data == null || key.size != 32) {
                result.error("bad_arguments", null, null)
                return
            }
            val secret = SecretKeySpec(key, "AES")
            when (call.method) {
                "decrypt" -> {
                    if (data.size <= 12 + 16) {
                        result.error("bad_arguments", null, null)
                        return
                    }
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, data, 0, 12))
                    result.success(cipher.doFinal(data, 12, data.size - 12))
                }
                "encrypt" -> {
                    val iv = call.argument<ByteArray>("iv")
                    if (iv == null || iv.size != 12) {
                        result.error("bad_arguments", null, null)
                        return
                    }
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(128, iv))
                    result.success(iv + cipher.doFinal(data))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // The class of the failure only: never the key, never the data.
            result.error("crypto_failed", e.javaClass.simpleName, null)
        }
    }
}

/**
 * Reports changes of the device's default network to Dart. It states what the
 * SYSTEM knows about the connection (is there a network, does the system
 * consider it validated); it never claims anything about the parish server.
 * All decisions are made in Dart, identically on Android and iOS.
 */
class NetworkSignalPlugin(context: Context) :
    EventChannel.StreamHandler, MethodChannel.MethodCallHandler {

    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var sink: EventChannel.EventSink? = null

    fun register(messenger: BinaryMessenger) {
        EventChannel(messenger, "eu.ministrant.manager/network/events").setStreamHandler(this)
        MethodChannel(messenger, "eu.ministrant.manager/network").setMethodCallHandler(this)
    }

    /**
     * Always read from the system at the moment of the report, never taken
     * from the callback's own arguments: when the default network changes
     * (Wi-Fi to mobile data) the old network's loss can arrive AFTER the new
     * one's arrival, and reporting it as "no network" would be false.
     */
    private fun snapshot(): Map<String, Any?> {
        val network: Network? = connectivity.activeNetwork
        val caps: NetworkCapabilities? =
            if (network == null) null else connectivity.getNetworkCapabilities(network)
        if (caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            return mapOf("hasInterface" to false, "validated" to null, "transport" to "none")
        }
        val transport = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        return mapOf(
            "hasInterface" to true,
            "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            "transport" to transport,
        )
    }

    private fun report() {
        // Callbacks arrive on a connectivity thread; Flutter wants the main one.
        main.post { sink?.success(snapshot()) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = report()
            override fun onLost(network: Network) = report()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = report()
        }
        callback = cb
        connectivity.registerDefaultNetworkCallback(cb)
    }

    override fun onCancel(arguments: Any?) {
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (e: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        callback = null
        sink = null
    }

    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (call.method == "current") result.success(snapshot()) else result.notImplemented()
    }
}
