%%% hs_server.erl
%%%
%%% TLS 1.3 server that accepts connections, completes a full handshake,
%%% and immediately closes the socket. No application data is exchanged.
%%% Session resumption / tickets are disabled so every connection is a
%%% full handshake.
%%%
%%% Usage:
%%%   erl -noshell -pa . -s hs_server start <Port> <CertPem> <KeyPem>
%%%
%%% Writes a single "READY <Port>\n" line to stdout once the listener is
%%% bound, so the runner script can synchronise with it.

-module(hs_server).
-export([start/1]).

start([PortStr, CertFile, KeyFile]) ->
    Port = list_to_integer(atom_to_list(PortStr)),
    ok = application:ensure_started(crypto),
    ok = application:ensure_started(asn1),
    ok = application:ensure_started(public_key),
    ok = application:ensure_started(ssl),
    Opts = [
        {certs_keys, [#{certfile => atom_to_list(CertFile),
                        keyfile  => atom_to_list(KeyFile)}]},
        {versions, ['tlsv1.3']},
        {session_tickets, disabled},
        {reuseaddr, true},
        {backlog, 4096},
        {active, false},
        {verify, verify_none}
    ],
    {ok, ListenSock} = ssl:listen(Port, Opts),
    {ok, {_, BoundPort}} = ssl:sockname(ListenSock),
    io:format("READY ~p~n", [BoundPort]),
    accept_loop(ListenSock).

accept_loop(ListenSock) ->
    case ssl:transport_accept(ListenSock) of
        {ok, TransportSock} ->
            spawn(fun() -> handshake_and_close(TransportSock) end),
            accept_loop(ListenSock);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            accept_loop(ListenSock)
    end.

handshake_and_close(TransportSock) ->
    case ssl:handshake(TransportSock, 5000) of
        {ok, Sock} ->
            ssl:close(Sock);
        _ ->
            (catch ssl:close(TransportSock)),
            ok
    end.
