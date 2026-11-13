// Humdinger's MIDI plumbing on Android (android.media.midi), for
// Humdinger.Output (Elixir side: Humdinger.Output.Port, Humdinger.Output.Device).
//
// 1. The Humdinger port: HumdingerMidiService is a MidiDeviceService with one
//    output port, "Humdinger". Other apps open it as a MIDI source. Android
//    binds the service (in the app's process) when the first app opens the
//    port and unbinds it when the last one closes it; portSend() hands bytes
//    to the port's receiver, which fans them out to every connected app.
//    With no app connected the bytes are dropped (SEND_NO_CLIENT).
// 2. The device watcher: a MidiManager.DeviceCallback reporting devices
//    plugged in or removed, with their transport (usb / bluetooth / virtual),
//    which mob_midi 0.2.0 doesn't report on Android. Opening and sending to
//    USB and Bluetooth devices goes through mob_midi.
// 3. Bluetooth-MIDI: a BLE scan for the BLE-MIDI service and
//    MidiManager.openBluetoothDevice, which makes the peripheral a MIDI
//    device every app can see while it stays open.
//
// Events go to the one subscribed BEAM process as
// {:humdinger_midi, tag, json} through nativeDeliver (humdinger_midi_port_nif.zig).
package com.genericjam.humdinger.midi

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.LocationManager
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiDeviceService
import android.media.midi.MidiDeviceStatus
import android.media.midi.MidiManager
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

object HumdingerMidiBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    @JvmStatic external fun nativeRegister()

    // {:humdinger_midi, tag, json} to the subscribed pid.
    @JvmStatic external fun nativeDeliver(pid: Long, tag: String, json: String)

    // portSend() results; humdinger_midi_port_nif.zig maps them to
    // :ok / {:error, :no_client} / {:error, :send_failed}.
    private const val SEND_OK = 0
    private const val SEND_NO_CLIENT = 1
    private const val SEND_FAILED = 2

    // The Bluetooth-SIG BLE-MIDI service (MIDI over Bluetooth LE spec).
    private const val BLE_MIDI_SERVICE = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"

    // The Mob.Permissions capability covering BLE scan + connect.
    private const val BLUETOOTH_CAPABILITY = "midi_bluetooth"

    // MidiDeviceInfo property holding a MidiDeviceService's ServiceInfo
    // (PROPERTY_SERVICE_INFO, hidden from the SDK's android.jar).
    private const val PROPERTY_SERVICE_INFO = "service_info"

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var appContext: Context? = null
    @Volatile private var subscriber: Long = 0

    // The port: the running service (null while no app has the port open)
    // and how many apps are connected to its output port.
    @Volatile private var service: HumdingerMidiService? = null
    @Volatile private var connections: Int = 0

    // Main thread only.
    private var watching = false
    private var scanCallback: ScanCallback? = null
    private var scanner: BluetoothLeScanner? = null

    // Bluetooth-MIDI devices opened by bleConnect, by address. Closing one
    // disconnects it.
    private val bleDevices = ConcurrentHashMap<String, MidiDevice>()

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    // MobActivityAware: called from MainActivity.onCreate on the main thread.
    override fun setActivity(activity: Activity) {
        appContext = activity.applicationContext
        watchDevices()
    }

    override fun permissionsFor(cap: String): Array<String>? =
        if (cap == BLUETOOTH_CAPABILITY) bluetoothPermissions() else null

    // API <= 30: BLE scans need fine location (BLUETOOTH / BLUETOOTH_ADMIN are
    // install-time). API 31+: the Nearby-devices permissions, plus location
    // because the manifest's BLUETOOTH_SCAN doesn't claim neverForLocation.
    private fun bluetoothPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT <= 30) {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }

    @JvmStatic
    fun subscribe(pid: Long) {
        subscriber = pid
    }

    private fun deliver(tag: String, json: JSONObject) {
        val pid = subscriber
        if (pid != 0L) nativeDeliver(pid, tag, json.toString())
    }

    // ── The Humdinger port ──────────────────────────────────────────────────

    internal fun serviceCreated(s: HumdingerMidiService) {
        service = s
    }

    internal fun serviceDestroyed(s: HumdingerMidiService) {
        if (service === s) {
            service = null
            setConnections(0)
        }
    }

    internal fun setConnections(count: Int) {
        if (count == connections) return
        connections = count
        deliver("port", JSONObject().put("connections", count))
    }

    @JvmStatic
    fun portConnections(): Int = connections

    @JvmStatic
    fun portSend(bytes: ByteArray): Int {
        val s = service ?: return SEND_NO_CLIENT
        if (connections == 0) return SEND_NO_CLIENT
        val receiver = s.outputPortReceivers?.firstOrNull() ?: return SEND_NO_CLIENT
        return try {
            receiver.send(bytes, 0, bytes.size, System.nanoTime())
            SEND_OK
        } catch (e: IOException) {
            SEND_FAILED
        }
    }

    // ── Devices ─────────────────────────────────────────────────────────────

    private fun midiManager(): MidiManager? =
        appContext?.getSystemService(Context.MIDI_SERVICE) as? MidiManager

    @Suppress("DEPRECATION") // the executor + transport overload is API 33+
    private fun watchDevices() {
        if (watching) return
        val mm = midiManager() ?: return
        mm.registerDeviceCallback(object : MidiManager.DeviceCallback() {
            override fun onDeviceAdded(info: MidiDeviceInfo) {
                deliver("device_added", describe(info))
            }

            override fun onDeviceRemoved(info: MidiDeviceInfo) {
                forgetBluetooth(info.id)
                deliver("device_removed", describe(info))
            }
        }, main)
        watching = true
    }

    @JvmStatic
    @Suppress("DEPRECATION") // getDevicesForTransport is API 33+
    fun devices(): String {
        val arr = JSONArray()
        midiManager()?.devices?.forEach { arr.put(describe(it)) }
        return arr.toString()
    }

    // The address is the Bluetooth device's ("" for USB and virtual devices),
    // so Output can tell which MIDI device a connected address became.
    @Suppress("DEPRECATION") // typed getParcelable is API 33+
    private fun describe(info: MidiDeviceInfo): JSONObject {
        val props = info.properties
        val owner = props.getParcelable<ServiceInfo>(PROPERTY_SERVICE_INFO)?.packageName
        val address = props.getParcelable<BluetoothDevice>(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE)?.address
        val type = when (info.type) {
            MidiDeviceInfo.TYPE_USB -> "usb"
            MidiDeviceInfo.TYPE_BLUETOOTH -> "bluetooth"
            else -> "virtual"
        }
        return JSONObject()
            .put("id", info.id)
            .put("name", deviceName(info))
            .put("type", type)
            .put("inputs", info.inputPortCount)
            .put("outputs", info.outputPortCount)
            .put("own", owner != null && owner == appContext?.packageName)
            .put("address", address ?: "")
    }

    // USB and Bluetooth devices carry PROPERTY_NAME; some only declare
    // manufacturer + product.
    private fun deviceName(info: MidiDeviceInfo): String {
        val props = info.properties
        props.getString(MidiDeviceInfo.PROPERTY_NAME)?.takeIf { it.isNotBlank() }?.let { return it }
        val parts = listOfNotNull(
            props.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER),
            props.getString(MidiDeviceInfo.PROPERTY_PRODUCT),
        ).filter { it.isNotBlank() }
        return if (parts.isEmpty()) "MIDI device" else parts.joinToString(" ")
    }

    // ── Bluetooth-MIDI ──────────────────────────────────────────────────────

    private fun bluetoothAdapter(ctx: Context): BluetoothAdapter? =
        (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun hasBluetoothPermissions(ctx: Context): Boolean =
        bluetoothPermissions().all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    // "" when the scan started, else why not. Results arrive as ble_found
    // events, then one ble_scan_done when it ends.
    @JvmStatic
    fun bleScan(ms: Int): String {
        val ctx = appContext ?: return "no_activity"
        val adapter = bluetoothAdapter(ctx) ?: return "no_bluetooth"
        if (!hasBluetoothPermissions(ctx)) return "no_permission"
        if (!adapter.isEnabled) return "bluetooth_off"
        // API <= 30 scans find nothing while location is switched off.
        if (Build.VERSION.SDK_INT <= 30 && !locationOn(ctx)) return "location_off"
        val leScanner = adapter.bluetoothLeScanner ?: return "bluetooth_off"
        main.post { startScan(leScanner, ms) }
        return ""
    }

    private fun locationOn(ctx: Context): Boolean =
        (ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.isLocationEnabled == true

    private val scanTimeout = Runnable { finishScan(JSONObject()) }

    private fun startScan(leScanner: BluetoothLeScanner, ms: Int) {
        // A new scan replaces a running one, timeout included.
        main.removeCallbacks(scanTimeout)
        stopScanQuietly()
        val seen = HashSet<String>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address
                if (!seen.add(address)) return
                deliver(
                    "ble_found",
                    JSONObject()
                        .put("address", address)
                        .put("name", result.scanRecord?.deviceName ?: "")
                        .put("rssi", result.rssi),
                )
            }

            override fun onScanFailed(errorCode: Int) {
                scanCallback = null
                main.removeCallbacks(scanTimeout)
                deliver("ble_scan_done", JSONObject().put("error", "scan_failed"))
            }
        }
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(BLE_MIDI_SERVICE)).build(),
        )
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            leScanner.startScan(filters, settings, callback)
        } catch (e: SecurityException) {
            deliver("ble_scan_done", JSONObject().put("error", "no_permission"))
            return
        }
        scanCallback = callback
        scanner = leScanner
        main.postDelayed(scanTimeout, ms.toLong())
    }

    @JvmStatic
    fun bleStopScan() {
        main.post { if (scanCallback != null) finishScan(JSONObject()) }
    }

    private fun finishScan(result: JSONObject) {
        main.removeCallbacks(scanTimeout)
        if (scanCallback == null) return
        stopScanQuietly()
        deliver("ble_scan_done", result)
    }

    private fun stopScanQuietly() {
        val callback = scanCallback ?: return
        scanCallback = null
        try {
            scanner?.stopScan(callback)
        } catch (e: SecurityException) {
            // Permission revoked mid-scan; the scan is gone either way.
        } catch (e: IllegalStateException) {
            // Bluetooth switched off mid-scan.
        }
    }

    // "" when the connection was started, else why not. The outcome arrives
    // as ble_connected (with the MIDI device id) or ble_failed.
    @JvmStatic
    fun bleConnect(address: String): String {
        val ctx = appContext ?: return "no_activity"
        val mm = midiManager() ?: return "no_midi_service"
        val adapter = bluetoothAdapter(ctx) ?: return "no_bluetooth"
        if (!BluetoothAdapter.checkBluetoothAddress(address)) return "bad_address"
        if (!hasBluetoothPermissions(ctx)) return "no_permission"
        if (!adapter.isEnabled) return "bluetooth_off"
        bleDevices[address]?.let { open ->
            main.post { deliver("ble_connected", connected(address, open)) }
            return ""
        }
        val device = adapter.getRemoteDevice(address)
        main.post {
            try {
                mm.openBluetoothDevice(device, { midi ->
                    if (midi == null) {
                        deliver("ble_failed", JSONObject().put("address", address).put("reason", "open_failed"))
                    } else {
                        bleDevices.put(address, midi)?.let { closeQuietly(it) }
                        deliver("ble_connected", connected(address, midi))
                    }
                }, main)
            } catch (e: SecurityException) {
                deliver("ble_failed", JSONObject().put("address", address).put("reason", "no_permission"))
            }
        }
        return ""
    }

    private fun connected(address: String, midi: MidiDevice): JSONObject =
        JSONObject()
            .put("address", address)
            .put("id", midi.info.id)
            .put("name", deviceName(midi.info))

    @JvmStatic
    fun bleDisconnect(address: String) {
        bleDevices.remove(address)?.let { closeQuietly(it) }
    }

    // A Bluetooth device that went away (out of range, switched off): drop
    // our handle on it.
    private fun forgetBluetooth(deviceId: Int) {
        val address = bleDevices.entries.firstOrNull { it.value.info.id == deviceId }?.key ?: return
        bleDevices.remove(address)?.let { closeQuietly(it) }
    }

    private fun closeQuietly(c: java.io.Closeable) {
        try {
            c.close()
        } catch (e: IOException) {
            // Already gone.
        }
    }
}

// The Humdinger port. Declared in the manifest with
// res/xml/humdinger_midi_port.xml: one output port, "Humdinger". Android
// creates it when an app opens the port.
class HumdingerMidiService : MidiDeviceService() {
    override fun onCreate() {
        super.onCreate()
        HumdingerMidiBridge.serviceCreated(this)
    }

    override fun onDestroy() {
        HumdingerMidiBridge.serviceDestroyed(this)
        super.onDestroy()
    }

    // The port has no inputs: nothing is sent to Humdinger.
    override fun onGetInputPortReceivers(): Array<MidiReceiver> = emptyArray()

    override fun onDeviceStatusChanged(status: MidiDeviceStatus) {
        HumdingerMidiBridge.setConnections(status.getOutputPortOpenCount(0))
    }
}
