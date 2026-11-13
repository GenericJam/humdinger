%% humdinger_midi_port_nif: the Erlang side of Humdinger's Android MIDI NIF
%% (priv/native/jni/humdinger_midi_port_nif.zig, bridging to
%% HumdingerMidiBridge.kt). Elixir callers: Humdinger.Output.Port and
%% Humdinger.Output.Device.
%%
%% On the phone the NIF is linked into the app and replaces these functions.
%% Where it isn't (host, iOS), on_load tolerates the failure and every
%% function answers {error, unavailable}, which Humdinger.Output reads as
%% "this destination doesn't exist here".
-module(humdinger_midi_port_nif).
-export([
    port_send/1,
    port_connections/0,
    subscribe/0,
    devices/0,
    ble_scan/1,
    ble_stop_scan/0,
    ble_connect/1,
    ble_disconnect/1
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("humdinger_midi_port_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

port_send(_Bytes) -> {error, unavailable}.
port_connections() -> {error, unavailable}.
subscribe() -> {error, unavailable}.
devices() -> {error, unavailable}.
ble_scan(_Ms) -> {error, unavailable}.
ble_stop_scan() -> {error, unavailable}.
ble_connect(_Address) -> {error, unavailable}.
ble_disconnect(_Address) -> {error, unavailable}.
