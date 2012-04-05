-module(ehp_session).
-export([start_link/1, init/1, on_request/1]).
-record(state, {sock, data=[], n=0, service, timeout, callback, c}).

-define(KEEP_ALIVE_TIMEOUT, 300*1000).
-define(REQUEST_TIMEOUT, 30*1000).

start_link(Sock)->
    Pid = spawn_link(?MODULE, init, [Sock]),
    {ok, Pid}.

init(Sock)->
    %erlang:display(inet:getopts(Sock, [buffer])),
    {ok, Callback} = application:get_env(ehp, callback_module),
    on_request(#state{sock = Sock, timeout=?KEEP_ALIVE_TIMEOUT, callback=Callback}).

on_request(S)->
    try
        inet:setopts(S#state.sock, [{active, once},{packet,http_bin}]),
        header_loop(S#state{data=[], n=S#state.n+1})
    catch Type:Error ->
        {ok, Code, Body} = try
            {ok, C, B} = apply(S#state.callback, handle_error, [Type, Error])
        catch _:_->
            {ok, 500, io_lib:format("<h1>Error: ~p</h1><pre>\n~p</pre>\n", [Error, erlang:get_stacktrace()])}
        end,
        send_response(S#state.sock, Body, Code)
    end.

header_loop(#state{sock = Sock, callback=Callback} = S)->
    receive
        {http, Sock, {http_request, Method , Uri , {V1,V2} }} ->
            case Uri of
                {absoluteURI, Schema, Host, _, Path} ->
                    {ok, C1} = Callback:init(Method, Path),
                    Data = [be_list(Method), " ",atom_to_list(Schema),"://",Host, Path, " HTTP/", be_list(V1),".",be_list(V2),"\r\n"],
                    {ok, C2} = Callback:handle_header('Host', Host, C1),
                    S2 = S#state{data = [Data], timeout=?REQUEST_TIMEOUT, c=C2},
                    inet:setopts(Sock, [{active, once}]),
                    header_loop(S2);
                {abs_path, Path} -> 
                    {ok, C1} = Callback:init(Method, Path),
                    Data = [be_list(Method), " ", Path, " HTTP/", be_list(V1),".",be_list(V2),"\r\n"],
                    inet:setopts(Sock, [{active, once}]),
                    header_loop(S#state{c=C1, data = [Data], timeout=?REQUEST_TIMEOUT});
                BadUrl -> 
                    throw({bad_url, BadUrl})
            end;

        {http, Sock, {http_header, _ , Header , _ , Val }} ->
            {ok, C2} = Callback:handle_header(Header, Val, S#state.c),
            inet:setopts(Sock, [{active, once}]),
            header_loop(S#state{c=C2, data = [ [be_list(Header), ": ", Val,"\r\n"] | S#state.data]});

        {http, Sock, http_eoh} ->
            execute(S#state{data=["\r\n" | S#state.data]});
                    
        {tcp_closed, Sock} -> ok;
            
        Msg ->
            throw({bad_request,Msg})
    after S#state.timeout->
        throw(request_timeout)
    end.

execute(#state{callback=Callback} = S)->
    {ok, UpStream, C2} = Callback:handle_upstream(S#state.c),
    {ok, Type, Count } = ehp_protocol:start(S#state.sock, UpStream, lists:reverse(S#state.data), []),
    Callback:handle_finish({ok, Count}, C2),
    case Type of
        next -> ?MODULE:on_request(S#state{service=undefined, timeout=?KEEP_ALIVE_TIMEOUT});
        exit -> ok
    end.

be_list(A) when is_binary(A) -> binary_to_list(A);
be_list(A) when is_number(A) -> integer_to_list(A);
be_list(A) when is_atom(A) -> atom_to_list(A);
be_list(A) when is_list(A) -> A.

send_response(Sock, Body, Code)->
    BodyStr = lists:flatten(Body),
    gen_tcp:send(Sock, ["HTTP/1.1 ", integer_to_list(Code),
             "\r\nContent-Type: text/html",
             "\r\nCache-Control: no-cache",
             "\r\nContent-Length: ", integer_to_list(length(BodyStr)),
             "\r\nExpires: ", "Thu, 01 Jan 1970 00:00:00 GMT",
             "\r\nConnection: close",
             "\r\n\r\n", BodyStr]).