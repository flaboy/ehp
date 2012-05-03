-module(ehp_protocol).
-export([start/7]).
-define(debug_router(),ok).
-record(state, {upstream, request, response, option=[], chuncked=false, recv_remaining=0, rev,
        remaining, channel, req_stat, rst_stat, request_inet_opts, timeout=30*1000}).
-record(channel_state, {master, sock}).

-define(multi_receive(F,Timeout), 

    {tcp, RequestSock, Data} ->
        send_sock(ResponseSock, Data),
        inet:setopts(RequestSock, [{active, once}]),
        F(S#state{recv_remaining = S#state.recv_remaining - erlang:byte_size(Data)});

    {tcp_closed, ResponseSock} ->
        S#state.channel ! {tcp_closed, ResponseSock},
        Ret = return(S, exit),
        gen_tcp:close(RequestSock),
        Ret;

    {tcp_closed, RequestSock} ->
        S#state.channel ! {tcp_closed, ResponseSock},
        Ret = return(S, exit),
        gen_tcp:close(ResponseSock),
        Ret;

    A -> io:format("o: ~p ~n",[A]),
        F(S)

    after Timeout->
        throw({backend_timeout,?LINE})
).

return(S, Type)->
    Report = case inet:getstat(S#state.request, [recv_oct, send_oct]) of
        {ok, A} ->
            {proplists:get_value(recv_oct, A) - proplists:get_value(recv_oct, S#state.req_stat),
            proplists:get_value(send_oct, A) - proplists:get_value(send_oct, S#state.req_stat)};
        {error, _} ->
            case inet:getstat(S#state.response, [recv_oct, send_oct]) of
                {ok, B} ->
                    {proplists:get_value(send_oct, B) - proplists:get_value(send_oct, S#state.rst_stat),
                    proplists:get_value(recv_oct, B) - proplists:get_value(recv_oct, S#state.rst_stat)};
                _ -> error
            end
    end,
    {ok, Type, Report}.

send_sock(Sock, Data)->
    gen_tcp:send(Sock, Data).
    
start(RequestSock, Callback, UpstreamList, Blocks, Req_remaining, ReqStat, Option)->
    
    {ok, RequestOpts} = inet:getopts(RequestSock, [active, packet]),
    inet:setopts(RequestSock,[{active, once},{packet,0}]),
    
    {ok, ResponseSock, Upstream} = ehp_server:connect(UpstreamList, Callback),
    
    try
        gen_tcp:send(ResponseSock, Blocks),
	    
        Timeout = case proplists:get_value(timeout, Option) of
            N when is_integer(N) and (N>1000) and (N < 181*1000)-> N;
            _ -> 30*1000
        end,
        
        Auto_close_reqsock = case proplists:get_value(auto_close_reqsock, Option) of
            false -> false;
            _ -> true
        end,
        
        {ok, RstStat} = inet:getstat(ResponseSock, [recv_oct, send_oct]),
	    
        loop(#state{request = RequestSock, response = ResponseSock, 
                req_stat = ReqStat, rst_stat = RstStat,
                timeout = Timeout, upstream = Upstream,
                recv_remaining = Req_remaining,
                option=Option, request_inet_opts = RequestOpts })
    catch _:Error->
        erlang:display(erlang:get_stacktrace()),
        gen_tcp:close(ResponseSock),
        ehp_server:finish(tcp_closed, ResponseSock, Upstream),
        throw(Error)
    end.

loop(#state{response=ResponseSock, request=RequestSock} = S)->
    receive
            
        {http,ResponseSock,{http_response,{V1,V2},Code,Text}} ->
        
            send_sock(RequestSock, ["HTTP/",
                be_list(V1),$.,be_list(V2),$ ,
                be_list(Code),$ ,Text,"\r\n"]),
                
            inet:setopts(ResponseSock, [{active, once}]),
            case Code of
                100 ->
                    receive
                        {http, ResponseSock, http_eoh} ->
                            gen_tcp:send(RequestSock, "\r\n"),
                            inet:setopts(ResponseSock, [{active, once}]),
                            loop(S)
                    end;
                _ ->
                    case V2 of
                        1 -> loop(S#state{remaining=0, rev="1.1"});
                        0 -> loop(S#state{remaining=unlimited,  rev="1.0"})
                    end
            end;
            
        {http,ResponseSock, {http_header,_,'Transfer-Encoding',_,Val}} ->
            send_sock(RequestSock, ["Transfer-Encoding: ", Val,"\r\n"]),
            inet:setopts(ResponseSock, [{active, once}]),
            case binary:match(Val,<<"chunked">>) of
                nomatch ->
                    loop(S#state{chuncked = false});
                _ ->
                    loop(S#state{chuncked = true, remaining=0})
            end;
        
        {http,ResponseSock, {http_header,_,'Connection',_,Val}} ->
            send_sock(RequestSock, ["Connection: ", Val,"\r\n"]),
            inet:setopts(ResponseSock, [{active, once}]),
            case binary:match(Val,<<"close">>) of
                nomatch -> loop(S);
                _ -> loop(S#state{remaining = unlimited})
            end;
            
        {http,ResponseSock, {http_header,_,'Content-Length',_,Val}} ->
            send_sock(RequestSock, ["Content-Length: ", Val,"\r\n"]),
            inet:setopts(ResponseSock, [{active, once}]),
            loop(S#state{remaining = list_to_integer(be_list(Val))});
            
        {http,ResponseSock, {http_header,_,Header,_,Val}} ->
            send_sock(RequestSock, [be_list(Header), ": ", Val,"\r\n"]),
            inet:setopts(ResponseSock, [{active, once}]),
            loop(S);
            
        {http, ResponseSock, http_eoh} ->
            gen_tcp:send(RequestSock, "\r\n"),
            case S#state.chuncked of
                true ->
                    inet:setopts(ResponseSock, [{packet, line}, binary, {active,once}]);
                _ ->
                    inet:setopts(ResponseSock, [{packet, 0}, binary, {active,once}])
            end,
            response_body_loop(S);

        ?multi_receive(loop, S#state.timeout)
    end.

response_body_loop(#state{remaining=0, chuncked=false} = S)-> 
    next(S);
    
response_body_loop(#state{response=ResponseSock, request=RequestSock, remaining=0, chuncked=true} = S)->
    receive
        {tcp, ResponseSock, Bin}->
            gen_tcp:send(S#state.request, Bin),
            inet:setopts(S#state.response, [{packet,0}, binary, {active,once}]),
            LenStr = binary_to_list(binary:part(Bin,{0, size(Bin)-2})),

            case list_to_integer(string:strip(LenStr),16) of
                0 -> 
                    receive
                        {tcp, ResponseSock, <<"\r\n">>} ->
                            gen_tcp:send(S#state.request, ["\r\n"])
                    end,
                    next(S);
                L ->
                    response_body_loop(S#state{remaining=L})
            end;
            
        ?multi_receive(response_body_loop, S#state.timeout)
    end;

response_body_loop(#state{response=ResponseSock, request=RequestSock} = S)->
    receive
        {tcp, ResponseSock, Bin}->
			case S#state.remaining of
				unlimited ->
						gen_tcp:send(S#state.request, Bin),
			            inet:setopts(ResponseSock, [{active, once}]),
						response_body_loop(S);
				M when is_integer(M) ->
				    case S#state.remaining - erlang:byte_size(Bin) of
    					0 ->
    						gen_tcp:send(S#state.request, Bin),
    						response_chunck_fix(S),
    			            inet:setopts(ResponseSock, [{active, once}]),
    						response_body_loop(S#state{remaining = 0});
    					N when N < 0 ->
    						gen_tcp:unrecv(S#state.response,
    							 binary:part(Bin, S#state.remaining, size(Bin) -S#state.remaining)),
    						gen_tcp:send(S#state.request, binary:part(Bin, 0, S#state.remaining)),
    						response_chunck_fix(S),
    			            inet:setopts(ResponseSock, [{active, once}]),
    						response_body_loop(S#state{remaining = 0});
    					N ->
    						gen_tcp:send(S#state.request, Bin),
    			            inet:setopts(ResponseSock, [{active, once}]),
    						response_body_loop(S#state{remaining = N})
    				end
			end;

        ?multi_receive(response_body_loop, S#state.timeout)
    end.

next(#state{response=ResponseSock} = S) ->
    receive
        {tcp, ResponseSock, Data} ->
            io:format("next upstream not empty: ~s \nstate=~p\n",[Data, S]),
            ehp_server:finish(tcp_closed, ResponseSock, S#state.upstream),
            gen_tcp:close(ResponseSock);
        {tcp_closed, ResponseSock} ->
            ehp_server:finish(tcp_closed, ResponseSock, S#state.upstream)
    after 0->
        ehp_server:finish(next, ResponseSock, S#state.upstream)
    end,
    
    %erlang:display({?LINE, inet:getopts(S#state.request, [active])}),
    flush(S#state.request, S#state.recv_remaining),
    inet:setopts(S#state.request, S#state.request_inet_opts),
    return(S, next).

flush(Sock, 0) -> ok;
flush(Sock, Remaining) ->erlang:display({?MODULE,?LINE,Remaining}),
    receive
        {tcp, Sock, D} ->
            flush(Sock, Remaining - erlang:byte_size(D)),
            inet:setopts(Sock, [active,once])
    end.

be_list(A) when is_binary(A) -> binary_to_list(A);
be_list(A) when is_number(A) -> integer_to_list(A);
be_list(A) when is_atom(A) -> atom_to_list(A);
be_list(A) when is_list(A) -> A.

response_chunck_fix(#state{response=ResponseSock, request=RequestSock, chuncked=true}=S)->
    inet:setopts(ResponseSock, [{packet,line},{active,once}]),
    receive
        {tcp, ResponseSock, <<"\r\n">>}->
            gen_tcp:send(S#state.request, ["\r\n"]);
            
        {tcp, ResponseSock, Data}->
            io:format("bad chunckending ~p\n",[Data]);
            
        ?multi_receive(response_chunck_fix, 5000)
    end;
response_chunck_fix(_S)->ok.
