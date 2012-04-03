-module(ehp_listener).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([accecptor/2, start_link/2]).
-record(state,{sock,factory,max=100,connection=0}).

start_link(Factory, Opts) ->
    gen_server:start_link({local, Factory}, ?MODULE, [Factory, Opts], []).

init([Factory , Opts])->
    {ok, {Ip, Port}} = application:get_env(ehp,listen),
    {ok,Sock} = gen_tcp:listen(Port,[{ip,Ip}|Opts]),
    Max = case application:get_env(ehp, max_conn) of
            undefined -> 100;
            {ok, M} -> M
        end,
    S = #state{sock=Sock, factory=Factory, max=Max},
    io:format("ehp listen ~p:~p, max-conn=~p\n",[Ip, Port, Max]),
    proc_lib:spawn_link(?MODULE,accecptor,[S, self()]),
    {ok, S}.

handle_call({change_max, Max}, _From, S) ->
    {reply, ok, S#state{max = Max}};
    
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({decrement, _From, _Stat}, #state{connection=Conn} = S) ->
    %erlang:display({decrement, Conn}),
    {noreply, S#state{connection = Conn-1}};

handle_info({next_request, _From, _Sock}, #state{connection=Conn, max=Max} = S) ->
    %erlang:display({connections, Conn, Max}),
    try
        if
             Conn=:=Max ->
                {ok,Sock} = gen_tcp:accept(S#state.sock),
                apply(S#state.factory, handle_max, [Sock]),
                gen_tcp:close(Sock),
                self() ! {next_request, self(), null},
                {noreply, S};
            true ->
                proc_lib:spawn_link(?MODULE,accecptor,[S, self()]),
                {noreply, S#state{connection = Conn+1}}
        end
    catch _:Error->
        erlang:display({?FILE,?LINE,Error}),
        {noreply, S}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%-----------------------------------------------

accecptor(#state{factory=Factory} = S, Top)->
    try
        process_flag(trap_exit, true),
        {ok,Sock} = gen_tcp:accept(S#state.sock),
        Top ! {next_request, self(), Sock},
        {ok,Pid} = Factory:start_link(Sock),
        gen_tcp:controlling_process(Sock,Pid),
        receive
            {'EXIT',Pid, Stat} -> Top ! {decrement, self(), Stat}
        end
    catch _:Reason->
        Top ! {decrement, self(), Reason}
    end.