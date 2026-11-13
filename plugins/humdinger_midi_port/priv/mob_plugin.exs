# Humdinger's Android MIDI: the virtual "Humdinger" port, the MIDI device
# watcher and Bluetooth-MIDI connect. Android only; the Elixir side is
# Humdinger.Output.Port and Humdinger.Output.Device (see AGENTS.md, "Output").
%{
  name: :humdinger_midi_port,
  description: "Humdinger's virtual MIDI port, MIDI device watcher and Bluetooth-MIDI connect",
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  nifs: [
    %{
      module: :humdinger_midi_port_nif,
      native_dir: "priv/native/jni",
      lang: :zig,
      platform: :android
    }
  ],
  android: %{
    permissions: [
      # Bluetooth-MIDI. API <= 30: BLUETOOTH / BLUETOOTH_ADMIN (install-time)
      # and fine location for BLE scans. API 31+: the Nearby-devices
      # permissions (plus location, as BLUETOOTH_SCAN isn't neverForLocation).
      # Requested at runtime as the :midi_bluetooth capability.
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
      "android.permission.BLUETOOTH_SCAN",
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.ACCESS_FINE_LOCATION",
      "android.permission.ACCESS_COARSE_LOCATION"
    ],
    bridge_kt: "priv/native/android/HumdingerMidiBridge.kt",
    bridge_class: "com.genericjam.humdinger.midi.HumdingerMidiBridge",
    # The port's service. Android binds it (BIND_MIDI_DEVICE_SERVICE) when an
    # app opens the port; the meta-data points at its device info.
    manifest_application_snippets: [
      """
      <service
          android:name="com.genericjam.humdinger.midi.HumdingerMidiService"
          android:exported="true"
          android:permission="android.permission.BIND_MIDI_DEVICE_SERVICE">
          <intent-filter>
              <action android:name="android.media.midi.MidiDeviceService" />
          </intent-filter>
          <meta-data
              android:name="android.media.midi.MidiDeviceService"
              android:resource="@xml/humdinger_midi_port" />
      </service>
      """
    ],
    res_files: ["priv/native/android/res/xml/humdinger_midi_port.xml"]
  }
}
