-module(ehp_server).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([connect/1, finish/3]).
-record(state,{}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    ets:new(ehp_socket, [named_table, set, protected]),
    ets:new(ehp_pool_req, [named_table, bag, private]),
    ets:new(ehp_pool_sock, [named_table, bag, private]),
    {ok, #state{}}.

handle_call(_Request, _From, S) ->
    {reply, ok, S}.

handle_cast({request, Req, Upstream}, S) ->
    case ets:lookup(ehp_pool_sock, Upstream) of
        [{_, Sock} | _]->
            
            gen_tcp:controlling_process(Sock, Req),
            Req ! {upstream, Sock},
            ets:insert(ehp_socket, {Sock, Upstream, Req}),
            ets:delete_object(ehp_pool_sock, {Upstream, Sock});

        [] ->
            spawn_connect(Upstream),
            ets:insert(ehp_pool_req, {Upstream, Req}),
            {noreply, S}
    end,
    {noreply, S};

handle_cast({finish, Type, Upstream, Req, Sock}, S) ->
    case Type of
        next ->
            next_request(Upstream, Sock);
        tcp_closed ->
            ets:delete(ehp_socket, Sock)
    end,
    {noreply, S};

handle_cast({connect_result, Upstream, {ok, Sock}}, S) ->
    next_request(Upstream, Sock),
    {noreply, S};
    
handle_cast({connect_result, Upstream, {error, Why}}, S) ->
    case ets:lookup(ehp_pool_req, Upstream) of
        [{Upstream, Req} | _] ->
            Req ! {connect_error, Why},
            ets:delete_object(ehp_pool_req, {Upstream, Req});
        [] -> ok
    end,
    {noreply, S};

handle_cast(_Msg, S) ->
    {noreply, S}.
    
handle_info({tcp_closed,Sock}, S) ->
    case ets:lookup(ehp_socket, Sock) of
        [{_, Upstream, ready}|_] ->
            ets:delete(ehp_socket, Sock),
            ets:delete_object(ehp_pool_sock, {Upstream, Sock});
        [] -> true
    end,
    {noreply, S};

handle_info(_Info, S) ->
    erlang:display({?MODULE, ?LINE,_Info}),
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

connect(Upstream)->
    gen_server:cast(?MODULE, {request, self(), Upstream}),
    receive
        {upstream, Sock} -> {ok, Sock};
        {upstream_error, Why} -> {error, Why}
    after 30*1000 -> {error, timeout}
    end.
    
    
finish(Type, Sock, Upstream)->
    Master = erlang:whereis(?MODULE),
    case Type of
        next ->
            gen_tcp:controlling_process(Sock, Master);
        tcp_closed -> ok
    end,
    gen_server:cast(Master, {finish, Type, Upstream, self(), Sock}).
    
next_request(Upstream, Sock)->
    case ets:lookup(ehp_pool_req, Upstream) of
        [{Upstream, Req} | _] ->
            gen_tcp:controlling_process(Sock, Req),
            Req ! {upstream, Sock},
            ets:insert(ehp_socket, {Sock, Upstream, Req}),
            ets:delete_object(ehp_pool_req, {Upstream, Req});
        [] ->
            ets:insert(ehp_socket, {Sock, Upstream, ready}),
            ets:insert(ehp_pool_sock, {Upstream, Sock})
    end.
    
spawn_connect({Addr, Port})->
    Master = self(),
    proc_lib:spawn(fun()->
        Ret = case gen_tcp:connect(Addr, Port,[{active,once},{buffer, 10240}]) of
            {ok, Sock} -> gen_tcp:controlling_process(Sock, Master), {ok, Sock};
            Error -> Error
        end,
        gen_server:cast(Master, {connect_result, {Addr, Port}, Ret})
    end).