-module(ehp_session).
-export([start_link/1, init/1, on_request/1]).
-record(state, {sock, bin=[], n=0, service, timeout, multipart=false, 
        expect_header = false, handle_post_pamams=false, callback, c, 
        method, remaining=0, boundary, req_stat}).
-record(params, {data, status=key, key= <<>>, value= <<>>, skip}).

-define(KEEP_ALIVE_TIMEOUT, 300*1000).
-define(REQUEST_TIMEOUT, 30*1000).
-define(MAX_PARAMS_HANDLE, 4096*1024).

start_link(Sock)->
    Pid = spawn_link(?MODULE, init, [Sock]),
    {ok, Pid}.

init(Sock)->
    {ok, Callback} = application:get_env(ehp, callback_module),
    {ok, Handle_post_pamams} = application:get_env(ehp, handle_post_pamams),
    on_request(#state{sock = Sock, handle_post_pamams =Handle_post_pamams,
            timeout=?KEEP_ALIVE_TIMEOUT, callback=Callback}).

on_request(S)->
    try
        {ok, ReqStat} = inet:getstat(S#state.sock, [recv_oct, send_oct]),
        inet:setopts(S#state.sock, [{active, once},{packet,http_bin}]),
        header_loop(S#state{bin=[], n=S#state.n+1,req_stat=ReqStat})
    catch Type:Error ->
        {ok, Status, ContentType, Body} = try
            {ok, C, T, B} = apply(S#state.callback, handle_error, [Type, Error])
        catch _:_->
            {ok, "500 Internal Server Error", "text/html", io_lib:format("<h1>Error: ~p</h1><pre>\n~p</pre>\n", [Error, erlang:get_stacktrace()])}
        end,
        send_response(S#state.sock, ContentType, Body, Status)
    end.

header_loop(#state{sock = Sock, callback=Callback} = S)->
    receive
        {http, Sock, {http_request, Method , Uri , {V1,V2} }} ->
            case Uri of
                {absoluteURI, Schema, Host, _, Path} ->
                    {ok, Path2, C1} = Callback:init(Method, Path),
                    {ok, C2, Host2} = Callback:handle_header('Host', Host, C1),
                    Data = [be_list(Method), " ",atom_to_list(Schema),"://",Host2, Path2, " HTTP/", be_list(V1),".",be_list(V2),"\r\n"],
                    S2 = S#state{bin = [Data], method=Method, timeout=?REQUEST_TIMEOUT, c=C2},
                    inet:setopts(Sock, [{active, once}]),
                    header_loop(S2);
                {abs_path, Path} -> 
                    {ok, Path2, C1} = Callback:init(Method, Path),
                    Data = [be_list(Method), " ", Path2, " HTTP/", be_list(V1),".",be_list(V2),"\r\n"],
                    inet:setopts(Sock, [{active, once}]),
                    header_loop(S#state{c=C1, method=Method, bin = [Data], timeout=?REQUEST_TIMEOUT});
                BadUrl -> 
                    throw({bad_url, BadUrl})
            end;
            
        {http, Sock, {http_header, _ , 'Expect' , _ , Val }} when S#state.handle_post_pamams ->
            inet:setopts(Sock, [{active, once}]),
            header_loop(S#state{expect_header = true});

        {http, Sock, {http_header, _ , Header , _ , Val }} ->
            S2 = case Header of
                'Content-Length' ->
                    S#state{remaining=list_to_integer(binary_to_list(Val))};
                'Content-Type' when S#state.handle_post_pamams  ->
                    case binary:match(Val, <<"multipart/">>) of
                        {_,_} ->
                            {N, M} = binary:match(Val, <<"boundary=">>),
                            N2 = N+M,
                            <<_:N2/binary, Boundary/binary>> = Val,
                            S#state{multipart = true, boundary = Boundary};
                        _ -> S
                    end;
                _-> S
            end,
            {ok, C2, Val2} = Callback:handle_header(Header, Val, S#state.c),
            inet:setopts(Sock, [{active, once}]),
            header_loop(S2#state{c=C2, bin = [ [be_list(Header), ": ", Val2,"\r\n"] | S#state.bin]});

        {http, Sock, http_eoh} ->
            S2 = case Callback:handle_eof(S#state.c) of
                {ok, HeaderAddon, C2} ->
                    S#state{bin=[[HeaderAddon|"\r\n"] | S#state.bin], c=C2};
                {ok, C2}->
                    S#state{bin=["\r\n" | S#state.bin], c=C2}
            end,
            case S#state.handle_post_pamams of
                true when S#state.method=:='POST' ->
                    handle_data(S2);               
                _ ->
                    execute(S2)
            end;
                    
        {tcp_closed, Sock} -> ok;
            
        Msg ->
            throw({bad_request,Msg})
    after S#state.timeout->
        throw(request_timeout)
    end.

handle_data(#state{expect_header=true} = S)->
    gen_tcp:send(S#state.sock, "HTTP/1.1 100 Continue\r\n\r\n"),
    handle_data(S#state{expect_header=false});
handle_data(#state{multipart=true, boundary=Boundary} = S)->
    io:format("~p:~p\n",[?LINE, Boundary]), %todo: multipart
    execute(S);

handle_data(S)->
    inet:setopts(S#state.sock, [{active, once}, {packet, 0}]),
    on_data_qs(S, #params{data=[]}).

on_data_qs(#state{remaining=0} = S, P)->
    P2 = parse_data(eof, P),
    {ok, C2} = (S#state.callback):handle_params(P2#params.data, S#state.c),
    execute(S#state{c=C2});
on_data_qs(#state{remaining=R, sock=Sock} = S, P) when R >0 ->
    receive
        {tcp, Sock, Bin} ->
            inet:setopts(Sock, [{active, once}]),
            L = byte_size(Bin),
            P2 = parse_data(Bin, P),
            on_data_qs(S#state{bin = [ Bin | S#state.bin], remaining=R-L}, P2);
        {tcp_closed, Bin} -> ok;
        M -> erlang:display(M)
    end.

% /abc=bcd status=key, name="", value=""
% a/bc=bcd status=key, name="a", value=""
% abc/=bcd status=key, name="abc", value=""
% abc=/bcd status=val, name="abc", value=""
% abc=b/cd status=val, name="abc", value="b"
% abc=bc/d status=val, name="abc", value="bc"
% abc=bcd/ status=val, name="abc", value="abc"
parse_data(eof, P)->
    P#params{data= [{P#params.key , P#params.value} | P#params.data],
    value= <<>>, key= <<>>, status=key };
parse_data(<<>>, P)-> P;
parse_data(Bin, #params{status=key, key=Key} = P)->
    case binary:match(Bin, [<<"&">>,<<"=">>]) of
        {N, _} ->
            case binary:at(Bin, N) of
                $= ->
                    <<Data:N/binary, _:1/binary, Tail/binary>> = Bin,
                    parse_data(Tail, P#params{ key= <<Key/binary, Data/binary>>, value= <<>>, status=value });
                $& ->
                    <<Data:N/binary, _:1/binary, Tail/binary>> = Bin,
                    parse_data(Tail, P#params{ key= <<>>, value= <<>>, status=key })
            end;
        nomatch ->
            parse_data(<<>>, P#params{ key= <<Key/binary , Bin/binary>> })
    end;
parse_data(Bin, #params{status=value, value=Value} = P)->
    case binary:match(Bin, <<"&">>) of
        {N, _} ->
            <<Data:N/binary, _:1/binary, Tail/binary>> = Bin,
            parse_data(Tail, P#params{data= [{P#params.key , <<Value/binary, Data/binary>>} | P#params.data],
                    value= <<>>, key= <<>>, status=key });
        nomatch ->
            parse_data(<<>>, P#params{ value= <<Value/binary, Bin/binary>> })
    end;
parse_data(Bin, P)-> 
    throw({Bin,P}).

execute(#state{callback=Callback} = S)->
    {ok, UpStream, C2} = Callback:handle_upstream(S#state.c),
    {ok, Type, Count } = ehp_protocol:start(S#state.sock, S#state.callback, UpStream, lists:reverse(S#state.bin), S#state.remaining, S#state.req_stat,[]),
    Callback:handle_finish({ok, Count}, C2),
    case Type of
        next -> ?MODULE:on_request(S#state{service=undefined, timeout=?KEEP_ALIVE_TIMEOUT});
        exit -> ok
    end.

be_list(A) when is_binary(A) -> binary_to_list(A);
be_list(A) when is_number(A) -> integer_to_list(A);
be_list(A) when is_atom(A) -> atom_to_list(A);
be_list(A) when is_list(A) -> A.

send_response(Sock, ContentType, Body, Status)->
    BodyStr = lists:flatten(Body),
    gen_tcp:send(Sock, ["HTTP/1.1 ", Status,
             "\r\nContent-Type: ",ContentType,
             "\r\nCache-Control: no-cache",
             "\r\nContent-Length: ", integer_to_list(length(BodyStr)),
             "\r\nExpires: ", "Thu, 01 Jan 1970 00:00:00 GMT",
             "\r\nConnection: close",
             "\r\n\r\n", BodyStr]).
