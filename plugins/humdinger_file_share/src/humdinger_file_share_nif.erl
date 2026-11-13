%% humdinger_file_share_nif: the Erlang side of Humdinger's Android file
%% share NIF (priv/native/jni/humdinger_file_share_nif.zig, bridging to
%% HumdingerFileShareBridge.kt). Elixir caller: Humdinger.Export.Android.
%%
%% On the phone the NIF is linked into the app and replaces these functions.
%% Where it isn't (host, iOS), on_load tolerates the failure and every
%% function answers {error, unavailable}.
-module(humdinger_file_share_nif).
-export([share_file/3, print_pdf/2]).
-on_load(init/0).

init() ->
    case erlang:load_nif("humdinger_file_share_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

share_file(_Path, _Mime, _Title) -> {error, unavailable}.
print_pdf(_Path, _Title) -> {error, unavailable}.
