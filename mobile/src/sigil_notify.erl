%% sigil_notify — Erlang NIF stub for Android run notifications.
%% On device the NIF is statically linked. Host Mix tests leave it unloaded.
-module(sigil_notify).
-export([app_visible/0, update_running/1, show_ended/1]).
-on_load(init/0).

init() ->
    case erlang:load_nif("sigil_notify", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

app_visible() -> false.
update_running(_Json) -> ok.
show_ended(_Json) -> ok.
