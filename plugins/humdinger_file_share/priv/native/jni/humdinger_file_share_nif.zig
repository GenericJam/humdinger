//! humdinger_file_share_nif — Humdinger's Android file share NIF (Zig).
//!
//! Bridges to the Kotlin HumdingerFileShareBridge
//! (HumdingerFileShareBridge.kt). Elixir: Humdinger.Export.Android.
//!
//! NIFs (both {:error, :unavailable} until the bridge registered; dirty IO,
//! as the bridge waits briefly for the UI thread):
//!   share_file(path, mime, title)  :ok | {:error, reason}
//!   print_pdf(path, title)         :ok | {:error, reason}
//! reason: not_found, no_activity, no_app, failed.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

var g_cls: jni.JClass = null;
var g_share_file: jni.JMethodID = null;
var g_print_pdf: jni.JMethodID = null;

export fn Java_com_genericjam_humdinger_share_HumdingerFileShareBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_cls = jni.newGlobalRef(jenv, cls);
    if (g_cls == null) return;
    g_share_file = jni.getStaticMethodID(jenv, cls, "shareFile", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    g_print_pdf = jni.getStaticMethodID(jenv, cls, "printPdf", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
}

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn failed(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.errorTuple(env, erts.atom(env, "failed"));
}

// A pending Java exception must never outlive the JNI call on a BEAM
// thread. As in humdinger_midi_port_nif.zig: ExceptionOccurred is opaque in
// mob_zig, so give it its JNI signature here.
fn clearPendingException(jenv: *jni.JNIEnv) bool {
    const exception_occurred: *align(1) const fn (*jni.JNIEnv) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.ExceptionOccurred.?);
    const thrown = exception_occurred(jenv);
    if (thrown == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, thrown);
    return true;
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

// A binary argument (a path, MIME type or title) as a new Java String; null
// if it isn't a binary, is too long, or the allocation failed.
fn argString(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, term: erts.ERL_NIF_TERM) jni.JString {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0) return null;
    var buf: [1024]u8 = undefined;
    if (bin.size >= buf.len) return null;
    @memcpy(buf[0..bin.size], bin.data[0..bin.size]);
    buf[bin.size] = 0;
    const str = jni.newStringUTF(jenv, @ptrCast(&buf));
    if (str == null) _ = clearPendingException(jenv);
    return str;
}

// Calls a bridge method taking `argc` strings and returning a reason.
fn call(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, argv: [*]const erts.ERL_NIF_TERM, comptime argc: usize) erts.ERL_NIF_TERM {
    if (mid == null) return erts.errorTuple(env, erts.atom(env, "unavailable"));
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);

    var args = std.mem.zeroes([argc]jni.JString);
    defer for (args) |a| {
        if (a != null) jni.deleteLocalRef(jenv, a);
    };
    for (0..argc) |i| {
        args[i] = argString(env, jenv, argv[i]);
        if (args[i] == null) return erts.badarg(env);
    }

    const reason = switch (argc) {
        2 => jenv.*.CallStaticObjectMethod.?(jenv, g_cls, mid, args[0], args[1]),
        3 => jenv.*.CallStaticObjectMethod.?(jenv, g_cls, mid, args[0], args[1], args[2]),
        else => @compileError("2 or 3 string arguments"),
    };
    if (clearPendingException(jenv)) return failed(env);
    return reasonTerm(env, jenv, reason);
}

export fn nif_share_file(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return call(env, g_share_file, argv, 3);
}

export fn nif_print_pdf(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return call(env, g_print_pdf, argv, 2);
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "share_file", .arity = 3, .fptr = nif_share_file, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "print_pdf", .arity = 2, .fptr = nif_print_pdf, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "humdinger_file_share_nif",
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

pub export fn humdinger_file_share_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
