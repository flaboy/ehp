-module(ehp).
-export([start/0, stop/0, status/0]).

start()->
    application:start(?MODULE).
    
stop()->
    application:stop(?MODULE).
    
status()->
    ets:foldr(fun({_,Upstream, Status}, D)->
        {Ready, Working} = try dict:fetch(Upstream, D) catch _:_ -> {0,0} end,
            R2 = case Status of ready-> {Ready+1, Working}; _->{Ready, Working+1} end,
            dict:store(Upstream, R2, D)
        end, dict:new(), ehp_socket).