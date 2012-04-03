
-module(ehp_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    TcpServer = {ehp_session, {ehp_listener , start_link, 
            [ehp_session,[binary, {buffer, 10240},
            {packet,http_bin},{active, false}, {reuseaddr, true}]]},
            permanent, 5000, worker, [ehp_listener ,ehp_session]},
    Server = ?CHILD(ehp_server, worker),
    {ok, { {one_for_one, 5, 10}, [TcpServer, Server]} }.

