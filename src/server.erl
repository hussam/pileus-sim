-module(server).
-export([
      new/1,
      reg_new/1,
      handle_request/4
   ]).

-include("pileus.hrl").

-record(state, {
                  store,
                  versions,
                  servers,
                  latencies,
                  rand,
                  oracle
               }).

reg_new(OracleNode) ->
   {oracle, OracleNode} ! {self(), ping},
   receive
      {OraclePid, pong} ->
         NewServer = new(OraclePid),
         OraclePid ! {reg_server, NewServer}
   end.

new(Oracle) ->
   spawn(fun() -> init(Oracle) end).

init(Oracle) ->
   Self = self(),
   State = #state {
      store = ets:new(server_store, [ public, {write_concurrency, true}, {read_concurrency, true} ]),
      versions = dict:store(Self, 0, dict:new()),
      servers = [],
      latencies = dict:new(),
      rand = ?SEED,
      oracle = Oracle
   },
   %timer:send_interval(?GOSSIP_PERIOD, Self, do_gossip),
   loop(Self, State).

loop(Self, State = #state{ store = Store,
                           versions = Versions,
                           servers = Servers,
                           latencies = NetLatencies,
                           rand = Rand
                        } ) ->
   receive
      {new_server, Server, Latency} ->
         NewState = State#state {
            servers = [Server | Servers],
            versions = dict:store(Server, 0, Versions),
            latencies = dict:store(Server, Latency, NetLatencies)
         },
         loop(Self, NewState);

      {all_servers, ServersLatencies} ->
         {NextServerSet, NextNetLatencies, NextVersions} = lists:foldl(
            fun({S, L}, {Ss, SLs, Vs}) ->
                  case sets:is_element(S, Ss) of
                     true -> {Ss, SLs, Vs};
                     false -> {
                           sets:add_element(S, Ss),
                           dict:store(S, L, SLs),
                           dict:store(S, 0, Vs)
                        }
                  end
            end,
            {sets:from_list(Servers), NetLatencies, Versions},
            ServersLatencies
         ),
         NextState = State#state {
            servers = sets:to_list(NextServerSet),
            latencies = NextNetLatencies,
            versions = NextVersions
         },
         loop(Self, NextState);

      {connect_client, Pid, Latency} ->
         NewLatencies = case dict:is_key(Pid, NetLatencies) of
            true  -> NetLatencies;
            false -> dict:store(Pid, Latency, NetLatencies)
         end,
         loop(Self, State#state{latencies = NewLatencies});

      {Client, get_stats} ->
         %Latency = dict:fetch(Client, NetLatencies),
         %erlang:send_after(Latency, Client, {
         erlang:send(Client, {
               server_stats,
               Self,
               0, %QueueDelay,
               dict:fetch(Self, Versions)
            }),
         loop(Self, State);

      {req, Request} ->
         Latency = 0, %dict:fetch(Client, NetLatencies),
         spawn(?MODULE, handle_request, [Self, Store, Latency, Request]),
         loop(Self, State);

      {done_put, Version} = Msg ->
         NextVersions = case dict:fetch(Self, Versions) of
            HighestVersion when HighestVersion < Version ->
               dict:store(Self, Version, Versions);
            _ -> Versions
         end,
         State#state.oracle ! Msg,
         loop(Self, State#state{ versions = NextVersions });

      do_gossip ->
         case length(Servers) of
            0 -> loop(Self, State);
            Len ->
               {N, Rand2} = random:uniform_s(Len, Rand),
               Peer = lists:nth(N, Servers),
               erlang:send_after(dict:fetch(Peer, NetLatencies), Peer,
                  { gossip_digest,
                     Self,
                     dict:fetch(Self, Versions),
                     dict:fetch(Peer, Versions)
                  }),
               loop(Self, State#state{rand = Rand2})
         end;

      {gossip_digest, Peer, PeerVersion, LocalVersionAtPeer} ->
         LocalVersion = dict:fetch(Self, Versions),
         LocalPeerVersion = dict:fetch(Peer, Versions),
         %Latency = dict:fetch(Peer, NetLatencies),

         if    % peer has new updates
            PeerVersion > LocalPeerVersion ->
               %erlang:send_after(Latency, Peer,
               erlang:send(Peer,
                  {gossip_digest, Self, LocalVersion, LocalPeerVersion});
            true -> do_nothing
         end,

         if    % local has new updates
            LocalVersion > LocalVersionAtPeer ->
               Updates = ets:select(Store,
                  [{{'$1','$2'},[{'>','$2', LocalVersionAtPeer}],[{{'$1','$2'}}]}]),
               UpdatesToGossip = lists:sublist(lists:keysort(2, Updates), ?UPDATES_PER_GOSSIP),
               %erlang:send_after(Latency, Peer, {gossip_reply, Self, UpdatesToGossip});
               erlang:send(Peer, {gossip_reply, Self, UpdatesToGossip});

            true -> do_nothing
         end,
         loop(Self, State);

      {gossip_reply, Peer, Updates} ->
         NextVersion = lists:foldl(
            fun(Pair = {K,V1}, _V) ->
                  case ets:lookup(Store, K) of
                     [{K, V2}] when V2 >= V1 -> V1;
                     _ -> ets:insert(Store, Pair), V1
                  end
            end,
            0,
            Updates
         ),

         WithNewPeerVersion = dict:store(Peer, NextVersion, Versions),
         NextVersions = case dict:fetch(Self, Versions) of
            LocalVersion when LocalVersion < NextVersion ->
               dict:store(Self, NextVersion, WithNewPeerVersion);
            _ ->
               WithNewPeerVersion
         end,
         loop(Self, State#state{versions = NextVersions});

      version ->
         NodesVersions = [{node(S),V} || {S,V} <- dict:to_list(Versions)],
         io:format("Current versions are ~p\n", [lists:sort(NodesVersions)]),
         loop(Self, State)

   end.


handle_request(Server, Store, _ClientLatency, {get, {Client, Key}}) ->
   %timer:sleep(?GET_DELAY),
   Version = case ets:lookup(Store, Key) of
      [{Key,V}] -> V;
      [] -> 0
   end,
   %erlang:send_after(ClientLatency, Client, {get_res, Key, Version}),
   erlang:send(Client, {get_res, Server, Key, Version});

handle_request(Server, Store, _ClientLatency, {put, {Client, Key, Version}}) ->
   %timer:sleep(?PUT_DELAY),
   ets:insert(Store, {Key, Version}),
   %erlang:send_after(ClientLatency, Client, {put_res, ServerLoop, Key, PutVersion}),
   erlang:send(Client, {put_res, Server, Key, Version}),
   Server ! {done_put, Version}.


