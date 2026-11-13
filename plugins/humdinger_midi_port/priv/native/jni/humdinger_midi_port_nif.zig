//! humdinger_midi_port_nif — Humdinger's Android MIDI NIF (Zig).
//!
//! Bridges to the Kotlin HumdingerMidiBridge (HumdingerMidiBridge.kt): the
//! virtual MIDI port (a MidiDeviceService), the MIDI device watcher and
//! Bluetooth-MIDI scan/connect. Elixir: Humdinger.Output.Native.
//!
//! NIFs (all return {:error, :unavailable} until the bridge registered):
//!   port_send(bytes)       :ok | {:error, :no_client | :send_failed}
//!   port_connections()     integer, apps connected to the port
//!   subscribe()            :ok; events go to the caller from then on
//!   devices()              JSON binary, a list of devices
//!   ble_scan(ms)           :ok | {:error, reason}
//!   ble_stop_scan()        :ok
//!   ble_connect(address)   :ok | {:error, reason}
//!   ble_disconnect(address) :ok
//!
//! Events, sent by nativeDeliver to the subscribed pid:
//!   {:humdinger_midi, tag, json_binary}
//! with tag one of port, device_added, device_removed, ble_found,
//! ble_scan_done, ble_connected, ble_failed.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

const Methods = struct {
    port_send: jni.JMethodID = null,
    port_connections: jni.JMethodID = null,
    subscribe: jni.JMethodID = null,
    devices: jni.JMethodID = null,
    ble_scan: jni.JMethodID = null,
    ble_stop_scan: jni.JMethodID = null,
    ble_connect: jni.JMethodID = null,
    ble_disconnect: jni.JMethodID = null,
};
var g_m: Methods = .{};
var g_cls: jni.JClass = null;

export fn Java_com_genericjam_humdinger_midi_HumdingerMidiBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_cls = jni.newGlobalRef(jenv, cls);
    if (g_cls == null) return;
    g_m.port_send = jni.getStaticMethodID(jenv, cls, "portSend", "([B)I");
    g_m.port_connections = jni.getStaticMethodID(jenv, cls, "portConnections", "()I");
    g_m.subscribe = jni.getStaticMethodID(jenv, cls, "subscribe", "(J)V");
    g_m.devices = jni.getStaticMethodID(jenv, cls, "devices", "()Ljava/lang/String;");
    g_m.ble_scan = jni.getStaticMethodID(jenv, cls, "bleScan", "(I)Ljava/lang/String;");
    g_m.ble_stop_scan = jni.getStaticMethodID(jenv, cls, "bleStopScan", "()V");
    g_m.ble_connect = jni.getStaticMethodID(jenv, cls, "bleConnect", "(Ljava/lang/String;)Ljava/lang/String;");
    g_m.ble_disconnect = jni.getStaticMethodID(jenv, cls, "bleDisconnect", "(Ljava/lang/String;)V");
}

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return @bitCast(pid.pid);
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return .{ .pid = @bitCast(jpid) };
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = @intCast(low) };
}

inline fn unavailable(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.errorTuple(env, erts.atom(env, "unavailable"));
}

inline fn failed(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.errorTuple(env, erts.atom(env, "failed"));
}

fn makeBinary(env: ?*erts.ErlNifEnv, data: []const u8) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(data.len, &bin);
    if (data.len > 0) @memcpy(bin.data[0..data.len], data);
    return erts.enif_make_binary(env, &bin);
}

// A pending Java exception must never outlive the JNI call on a BEAM
// scheduler thread. Same approach as mob_midi_nif.zig: ExceptionOccurred is
// opaque in mob_zig, so give it its JNI signature here.
fn clearPendingException(jenv: *jni.JNIEnv) bool {
    const exception_occurred: *align(1) const fn (*jni.JNIEnv) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.ExceptionOccurred.?);
    const thrown = exception_occurred(jenv);
    if (thrown == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, thrown);
    return true;
}

// A Java String result as a binary (empty for null).
fn stringTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, str: jni.JString) erts.ERL_NIF_TERM {
    if (str == null) return makeBinary(env, "");
    defer jni.deleteLocalRef(jenv, str);
    const cstr = jni.getStringUTFChars(jenv, str) orelse return makeBinary(env, "");
    defer jni.releaseStringUTFChars(jenv, str, cstr);
    return makeBinary(env, std.mem.span(cstr));
}

// The bridge answers "" for success or an error reason, which becomes
// {:error, :reason}.
fn reasonTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, str: jni.JString) erts.ERL_NIF_TERM {
    if (str == null) return erts.ok(env);
    defer jni.deleteLocalRef(jenv, str);
    const cstr = jni.getStringUTFChars(jenv, str) orelse return failed(env);
    defer jni.releaseStringUTFChars(jenv, str, cstr);
    if (cstr[0] == 0) return erts.ok(env);
    return erts.errorTuple(env, erts.enif_make_atom(env, cstr));
}

// Copies a binary argument into a NUL-terminated buffer for NewStringUTF.
fn argCString(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) ?[*:0]const u8 {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0) return null;
    if (bin.size >= buf.len) return null;
    @memcpy(buf[0..bin.size], bin.data[0..bin.size]);
    buf[bin.size] = 0;
    return @ptrCast(buf.ptr);
}

// ── NIFs ─────────────────────────────────────────────────────────────────

export fn nif_port_send(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_m.port_send == null) return unavailable(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &bin) == 0) return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);

    const jarr = jni.newByteArray(jenv, @intCast(bin.size));
    if (jarr == null) {
        _ = clearPendingException(jenv);
        return erts.errorTuple(env, erts.atom(env, "send_failed"));
    }
    defer jni.deleteLocalRef(jenv, jarr);
    jni.setByteArrayRegion(jenv, jarr, 0, @intCast(bin.size), @ptrCast(bin.data));
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_cls, g_m.port_send, jarr);
    if (clearPendingException(jenv)) return erts.errorTuple(env, erts.atom(env, "send_failed"));
    // Codes mirror HumdingerMidiBridge.SEND_*.
    return switch (code) {
        0 => erts.ok(env),
        1 => erts.errorTuple(env, erts.atom(env, "no_client")),
        else => erts.errorTuple(env, erts.atom(env, "send_failed")),
    };
}

export fn nif_port_connections(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_m.port_connections == null) return unavailable(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);
    const n = jenv.*.CallStaticIntMethod.?(jenv, g_cls, g_m.port_connections);
    if (clearPendingException(jenv)) return failed(env);
    return erts.enif_make_int(env, @intCast(n));
}

export fn nif_subscribe(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_m.subscribe == null) return unavailable(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_cls, g_m.subscribe, pidToJlong(pid));
    if (clearPendingException(jenv)) return failed(env);
    return erts.ok(env);
}

export fn nif_devices(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_m.devices == null) return unavailable(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);
    const json = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_m.devices);
    if (clearPendingException(jenv)) return failed(env);
    return stringTerm(env, jenv, json);
}

export fn nif_ble_scan(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_m.ble_scan == null) return unavailable(env);
    var ms: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &ms) == 0 or ms <= 0) return erts.badarg(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);
    const reason = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_m.ble_scan, @as(jni.JInt, ms));
    if (clearPendingException(jenv)) return failed(env);
    return reasonTerm(env, jenv, reason);
}

export fn nif_ble_stop_scan(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_m.ble_stop_scan == null) return unavailable(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_cls, g_m.ble_stop_scan);
    if (clearPendingException(jenv)) return failed(env);
    return erts.ok(env);
}

// ble_connect / ble_disconnect take the device's Bluetooth address
// ("AA:BB:CC:DD:EE:FF") as a binary.
fn callWithAddress(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, argv: [*]const erts.ERL_NIF_TERM, returns_reason: bool) erts.ERL_NIF_TERM {
    if (mid == null) return unavailable(env);
    var buf: [64]u8 = undefined;
    const address = argCString(env, argv[0], &buf) orelse return erts.badarg(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);
    const jaddress = jni.newStringUTF(jenv, address);
    if (jaddress == null) {
        _ = clearPendingException(jenv);
        return failed(env);
    }
    defer jni.deleteLocalRef(jenv, jaddress);
    if (returns_reason) {
        const reason = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, mid, jaddress);
        if (clearPendingException(jenv)) return failed(env);
        return reasonTerm(env, jenv, reason);
    }
    jenv.*.CallStaticVoidMethod.?(jenv, g_cls, mid, jaddress);
    if (clearPendingException(jenv)) return failed(env);
    return erts.ok(env);
}

export fn nif_ble_connect(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callWithAddress(env, g_m.ble_connect, argv, true);
}

export fn nif_ble_disconnect(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callWithAddress(env, g_m.ble_disconnect, argv, false);
}

// ── Delivery thunk (called from HumdingerMidiBridge.kt) ──────────────────

pub export fn Java_com_genericjam_humdinger_midi_HumdingerMidiBridge_nativeDeliver(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, tag: jni.JString, json: jni.JString) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const tag_c = jni.getStringUTFChars(jenv, tag) orelse return;
    defer jni.releaseStringUTFChars(jenv, tag, tag_c);
    const json_c = jni.getStringUTFChars(jenv, json) orelse return;
    defer jni.releaseStringUTFChars(jenv, json, json_c);

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "humdinger_midi"),
        erts.enif_make_atom(env, tag_c),
        makeBinary(env, std.mem.span(json_c)),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIF table + init ─────────────────────────────────────────────────────

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "port_send", .arity = 1, .fptr = nif_port_send, .flags = 0 },
    .{ .name = "port_connections", .arity = 0, .fptr = nif_port_connections, .flags = 0 },
    .{ .name = "subscribe", .arity = 0, .fptr = nif_subscribe, .flags = 0 },
    .{ .name = "devices", .arity = 0, .fptr = nif_devices, .flags = 0 },
    .{ .name = "ble_scan", .arity = 1, .fptr = nif_ble_scan, .flags = 0 },
    .{ .name = "ble_stop_scan", .arity = 0, .fptr = nif_ble_stop_scan, .flags = 0 },
    .{ .name = "ble_connect", .arity = 1, .fptr = nif_ble_connect, .flags = 0 },
    .{ .name = "ble_disconnect", .arity = 1, .fptr = nif_ble_disconnect, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "humdinger_midi_port_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn humdinger_midi_port_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
