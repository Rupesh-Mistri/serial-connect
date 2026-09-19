package com.mcu.serialconnect.serial_connect

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val METHOD_CHANNEL = "com.mcu.serialconnect/usb_serial"
        private const val EVENT_CHANNEL = "com.mcu.serialconnect/usb_serial_events"
        private const val ACTION_USB_PERMISSION = "com.mcu.serialconnect.USB_PERMISSION"
    }

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sendExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var usbManager: UsbManager? = null
    private var usbPort: UsbSerialPort? = null
    private var ioManager: SerialInputOutputManager? = null
    private var currentBaudRate = 115200
    private var driverName = ""
    private val lineBuffer = StringBuilder()

    private val flushRunnable = Runnable { flushBuffer() }

    private val usbReceiver = object : BroadcastReceiver() {
        @Override
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            val action = intent.action
            if (ACTION_USB_PERMISSION == action) {
                val device: UsbDevice? = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (granted && device != null) {
                    openDevice(device)
                } else {
                    emitError("USB permission denied")
                }
            } else if (UsbManager.ACTION_USB_DEVICE_DETACHED == action) {
                disconnect()
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager

        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        ContextCompat.registerReceiver(this, usbReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(this)

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent != null && UsbManager.ACTION_USB_DEVICE_ATTACHED == intent.action) {
            connect(currentBaudRate)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> {
                val baud = call.argument<Int>("baudRate") ?: 115200
                connect(baud)
                result.success(true)
            }
            "disconnect" -> {
                disconnect()
                result.success(true)
            }
            "send" -> {
                val data = call.argument<String>("data") ?: ""
                send(data)
                result.success(true)
            }
            "sendRaw" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes != null) {
                    sendRaw(bytes)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGS", "Bytes array is null", null)
                }
            }
            "setBaudRate" -> {
                val baud = call.argument<Int>("baudRate") ?: 115200
                setBaudRate(baud)
                result.success(true)
            }
            "setDtr" -> {
                val high = call.argument<Boolean>("high") ?: true
                val res = setDtr(high)
                result.success(res)
            }
            "setRts" -> {
                val high = call.argument<Boolean>("high") ?: true
                val res = setRts(high)
                result.success(res)
            }
            "isConnected" -> {
                result.success(isConnected())
            }
            "getBaudRate" -> {
                result.success(currentBaudRate)
            }
            "getDriverName" -> {
                result.success(driverName)
            }
            "listDevices" -> {
                result.success(getDeviceList())
            }
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun isConnected(): Boolean {
        return usbPort != null && usbPort!!.isOpen
    }

    @Synchronized
    private fun connect(baudRate: Int) {
        this.currentBaudRate = baudRate
        val mgr = usbManager ?: return
        val prober = UsbSerialProber.getDefaultProber()
        val drivers: List<UsbSerialDriver> = prober.findAllDrivers(mgr)

        if (drivers.isEmpty()) {
            emitError("No supported USB serial device found")
            return
        }

        val driver = drivers[0]
        val device = driver.device

        if (isConnected()) {
            setBaudRate(currentBaudRate)
            driverName = driver.javaClass.simpleName
            emitConnected(driverName)
            return
        }

        if (!mgr.hasPermission(device)) {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 31) {
                flags = flags or PendingIntent.FLAG_MUTABLE
            }
            val pi = PendingIntent.getBroadcast(this, 0, Intent(ACTION_USB_PERMISSION), flags)
            mgr.requestPermission(device, pi)
        } else {
            openDevice(device)
        }
    }

    @Synchronized
    private fun openDevice(device: UsbDevice) {
        val mgr = usbManager ?: return
        if (isConnected()) {
            val existingDriver = UsbSerialProber.getDefaultProber().probeDevice(device)
            driverName = existingDriver?.javaClass?.simpleName ?: "UsbSerialDevice"
            emitConnected(driverName)
            return
        }

        ioManager?.let {
            try { it.stop() } catch (ignored: Exception) {}
            ioManager = null
        }
        usbPort?.let {
            try { it.close() } catch (ignored: Exception) {}
            usbPort = null
        }

        try {
            val driver = UsbSerialProber.getDefaultProber().probeDevice(device)
            if (driver == null) {
                emitError("Unsupported USB serial device")
                return
            }
            val connection: UsbDeviceConnection? = mgr.openDevice(device)
            if (connection == null) {
                emitError("Could not open USB connection")
                return
            }

            val port = driver.ports[0]
            port.open(connection)
            port.setParameters(currentBaudRate, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
            try { port.dtr = true } catch (ignored: Exception) {}
            try { port.rts = true } catch (ignored: Exception) {}

            synchronized(lineBuffer) {
                lineBuffer.setLength(0)
            }

            usbPort = port
            driverName = driver.javaClass.simpleName

            ioManager = SerialInputOutputManager(port, object : SerialInputOutputManager.Listener {
                override fun onNewData(data: ByteArray?) {
                    processIncomingBytes(data)
                }

                override fun onRunError(e: Exception?) {
                    if (usbPort != null) {
                        emitError(e?.message ?: "USB serial error")
                        disconnect()
                    }
                }
            })
            ioManager?.start()
            emitConnected(driverName)
        } catch (e: Exception) {
            emitError(e.message ?: "USB open error")
        }
    }

    private fun processIncomingBytes(data: ByteArray?) {
        if (data == null || data.isEmpty()) return

        // Emit raw bytes event for flasher and low-level tools
        emitRawData(data)

        val clean = StringBuilder()
        for (b in data) {
            val unsigned = b.toInt() and 0xFF
            if (unsigned == '\n'.code || unsigned == '\r'.code || unsigned == '\t'.code ||
                (unsigned in 32..126) || unsigned >= 160) {
                clean.append(unsigned.toChar())
            }
        }

        if (clean.isEmpty()) return

        synchronized(lineBuffer) {
            lineBuffer.append(clean)
            var newlineIndex: Int
            while (lineBuffer.indexOf("\n").also { newlineIndex = it } >= 0) {
                var line = lineBuffer.substring(0, newlineIndex)
                lineBuffer.delete(0, newlineIndex + 1)
                if (line.endsWith("\r")) {
                    line = line.substring(0, line.length - 1)
                }
                line = line.trim()
                if (line.isNotEmpty()) {
                    emitData(line)
                }
            }
            mainHandler.removeCallbacks(flushRunnable)
            if (lineBuffer.isNotEmpty()) {
                mainHandler.postDelayed(flushRunnable, 100)
            }
        }
    }

    private fun flushBuffer() {
        synchronized(lineBuffer) {
            if (lineBuffer.isNotEmpty()) {
                var remaining = lineBuffer.toString()
                lineBuffer.setLength(0)
                if (remaining.endsWith("\r")) {
                    remaining = remaining.substring(0, remaining.length - 1)
                }
                remaining = remaining.trim()
                if (remaining.isNotEmpty()) {
                    emitData(remaining)
                }
            }
        }
    }

    @Synchronized
    private fun setBaudRate(baud: Int) {
        currentBaudRate = baud
        usbPort?.let {
            if (it.isOpen) {
                try {
                    it.setParameters(currentBaudRate, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
                } catch (e: Exception) {
                    emitError("Failed to set baud rate: ${e.message}")
                }
            }
        }
    }

    @Synchronized
    private fun setDtr(high: Boolean): Boolean {
        return usbPort?.let {
            if (it.isOpen) {
                try {
                    it.dtr = high
                    true
                } catch (ignored: Exception) { false }
            } else false
        } ?: false
    }

    @Synchronized
    private fun setRts(high: Boolean): Boolean {
        return usbPort?.let {
            if (it.isOpen) {
                try {
                    it.rts = high
                    true
                } catch (ignored: Exception) { false }
            } else false
        } ?: false
    }

    @Synchronized
    private fun send(text: String) {
        sendRaw(text.toByteArray(StandardCharsets.UTF_8))
    }

    @Synchronized
    private fun sendRaw(bytes: ByteArray) {
        val port = usbPort
        if (port == null || !port.isOpen) {
            emitError("USB serial is not connected")
            return
        }
        sendExecutor.execute {
            try {
                synchronized(this) {
                    if (usbPort != null && usbPort!!.isOpen) {
                        usbPort!!.write(bytes, 2000)
                    }
                }
            } catch (e: IOException) {
                emitError(e.message ?: "USB send error")
            }
        }
    }

    @Synchronized
    private fun disconnect() {
        mainHandler.removeCallbacks(flushRunnable)
        flushBuffer()

        ioManager?.let {
            try { it.stop() } catch (ignored: Exception) {}
            ioManager = null
        }
        usbPort?.let {
            try { it.close() } catch (ignored: Exception) {}
            usbPort = null
        }
        driverName = ""
        emitDisconnected()
    }

    private fun getDeviceList(): List<Map<String, Any>> {
        val list = mutableListOf<Map<String, Any>>()
        val mgr = usbManager ?: return list
        val drivers = UsbSerialProber.getDefaultProber().findAllDrivers(mgr)
        for (d in drivers) {
            val dev = d.device
            val map = mapOf(
                "deviceId" to dev.deviceId,
                "deviceName" to dev.deviceName,
                "vendorId" to dev.vendorId,
                "productId" to dev.productId,
                "driverName" to d.javaClass.simpleName,
                "portsCount" to d.ports.size
            )
            list.add(map)
        }
        return list
    }

    private fun emitConnected(driver: String) {
        mainHandler.post {
            eventSink?.success(mapOf("event" to "connected", "driver" to driver))
        }
    }

    private fun emitDisconnected() {
        mainHandler.post {
            eventSink?.success(mapOf("event" to "disconnected"))
        }
    }

    private fun emitData(data: String) {
        mainHandler.post {
            eventSink?.success(mapOf("event" to "data", "data" to data))
        }
    }

    private fun emitRawData(bytes: ByteArray) {
        mainHandler.post {
            eventSink?.success(mapOf("event" to "rawData", "bytes" to bytes))
        }
    }

    private fun emitError(error: String) {
        mainHandler.post {
            eventSink?.success(mapOf("event" to "error", "error" to error))
        }
    }

    override fun onDestroy() {
        disconnect()
        sendExecutor.shutdown()
        try {
            unregisterReceiver(usbReceiver)
        } catch (ignored: Exception) {}
        super.onDestroy()
    }
}
