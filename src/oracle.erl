-module(oracle).
-export([
      start/0
   ]).

-include("pileus.hrl").

-record(state, {
                  table,
                  servers,
                  clients,
                  rand,
                  count
               }).

start() ->
   spawn(fun() -> init() end).

init() ->
   State = #state {
      table = ets:new(oracle_store, []),
      servers = [],
      clients = [],
      rand = ?SEED,
      count = 0
   },

   loop(State, 1).

loop(State = #state { table = Table,
                      servers = Servers,
                      clients = Clients,
                      rand = Rand,
                      count = Count
                   }, I ) ->
   receive
      {reg_server, NewServer} ->
         io:format("Registered new server ~p\n", [NewServer]),
         Rand2 = notify_of_existing_servers(NewServer, Servers, Rand),
         Rand3 = notify_of_new_server(NewServer, Clients, Rand2),
         NextRand = notify_of_new_server(NewServer, Servers, Rand3),
         loop(State#state{servers = [NewServer | Servers], rand=NextRand}, I);

      {start_server, _Node} ->
         NewServer = server:new(self()), %rpc:call(_Node, server, new, [self()]),
         %io:format("Created new server ~p\n", [NewServer]),
         Rand2 = notify_of_existing_servers(NewServer, Servers, Rand),
         Rand3 = notify_of_new_server(NewServer, Clients, Rand2),
         NextRand = notify_of_new_server(NewServer, Servers, Rand3),
         loop(State#state{servers = [NewServer | Servers], rand=NextRand}, I);

      {reg_client, NewClient} ->
         NextRand = notify_of_existing_servers(NewClient, Servers, Rand),
         loop(State#state{clients = [NewClient | Clients], rand=NextRand}, I);

      {Client, get_servers} ->
         NextRand = notify_of_existing_servers(Client, Servers, Rand),
         loop(State#state{rand = NextRand}, I);

      {Client, pick_server} ->
         Client ! {pick_server, lists:nth(I, Servers)},
         loop(State, ((I+1) rem length(Servers)) + 1);

      {Client, pre, get, Key} ->
         Version = case ets:lookup(Table, Key) of
            [{Key, V}] -> V;
            [] -> 0
         end,
         Client ! {pre, get, Key, Version, lists:nth(I, Servers)},
         loop(State, ((I+1) rem length(Servers)) + 1);

      {Client, pre, put, Key} ->
         Client ! {pre, put, Key, Count + 1, lists:nth(I, Servers)},
         loop(State#state{count = Count + 1}, ((I+1) rem length(Servers)) + 1);

      {done_put, Key, Version} ->
         ets:insert(Table, {Key, Version}),
         loop(State, I);

      {Client, ping} ->
         Client ! {self(), pong},
         loop(State, I);

      {Manager, stop} ->
         [ exit(Server, kill) || Server <- Servers ],
         Manager ! oracle_stopped
   end.

notify_of_new_server(NewServer, ExistingNodes, Rand) when is_list(ExistingNodes) ->
   lists:foldl(
      fun(S, Rand1) ->
            {Latency, Rand2} = random:uniform_s(?VAR_LATENCY, Rand1),
            S ! {new_server, NewServer, ?MIN_LATENCY + Latency},
            Rand2
      end,
      Rand,
      ExistingNodes
   ).

notify_of_existing_servers(NewNode, ExistingServers, Rand) when is_list(ExistingServers) ->
   {ServersLatencies, NextRand} = lists:foldl(
      fun(S, {SLs, Rand1}) ->
            {Latency, Rand2} = random:uniform_s(?VAR_LATENCY, Rand1),
            { [{S, ?MIN_LATENCY + Latency} | SLs] , Rand2 }
      end,
      {[], Rand},
      ExistingServers
   ),
   NewNode ! {all_servers, ServersLatencies},
   NextRand.

