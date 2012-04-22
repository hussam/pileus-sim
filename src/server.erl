-module(server).
-export([
      new/1,
      reg_new/1
   ]).

-include("pileus.hrl").

-record(state, {
                  store,
                  versions,
                  queue,
                  queue_delay,
                  servers,
                  latencies,
                  rand,
                  oracle,
                  qproc
               }).

reg_new(OracleNode) ->
   {oracle, OracleNode} ! {self(), ping},
   receive
      {OraclePid, pong} ->
         NewServer = new(OraclePid),
         OraclePid ! {reg_server, NewServer}
   end.

new(Oracle) ->
   Server = spawn(fun() -> init(Oracle) end),
   spawn(fun() -> qproc(Server) end),
   Server.

init(Oracle) ->
   Self = self(),
   State = #state {
      store = ets:new(server_store, []),
      versions = dict:store(Self, 0, dict:new()),
      queue = queue:new(),
      queue_delay = 0,
      servers = [],
      latencies = dict:new(),
      rand = ?SEED,
      oracle = Oracle
   },
   timer:send_interval(?GOSSIP_PERIOD, Self, do_gossip),
   loop(Self, State).

loop(Self, State = #state{ store = Store,
                           versions = Versions,
                           queue = WorkQueue,
                           queue_delay = QueueDelay,
                           servers = Servers,
                           latencies = NetLatencies,
                           rand = Rand,
                           qproc = QProc } ) ->
   receive
      {qproc, QueueProcessor} ->
         loop(Self, State#state{qproc = QueueProcessor});

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
         Latency = dict:fetch(Client, NetLatencies),
         timer:send_after(Latency, Client, {
                                             server_stats,
                                             Self,
                                             QueueDelay,
                                             dict:fetch(Self, Versions)
                                          }),
         loop(Self, State);

      {req, Request} ->
         case queue:is_empty(WorkQueue) of
            true  -> QProc ! resume;
            false -> nothing_to_do
         end,
         NewQueueDelay = case Request of
            {put, _} -> QueueDelay + ?PUT_DELAY;
            {get, _} -> QueueDelay + ?GET_DELAY
         end,
         NewQueue = queue:in(Request, WorkQueue),
         loop(Self, State#state{queue = NewQueue, queue_delay = NewQueueDelay});

      {do, {get, {Ref, Client, Key}}} ->
         Version = case ets:lookup(Store, Key) of
            [{Key,V}] -> V;
            [] -> 0
         end,
         Latency = dict:fetch(Client, NetLatencies),
         timer:send_after(Latency, Client, {get_res, Ref, Self, Key, Version}),
         loop(Self, State#state{queue_delay = QueueDelay - ?GET_DELAY});

      {do, {put, {Ref, Client, Key, Version}}} ->
         Latency = dict:fetch(Client, NetLatencies),
         PutVersion = case ets:lookup(Store, Key) of
            [{Key, LocalVersion}] when LocalVersion > Version ->
               LocalVersion;

            _ ->
               ets:insert(Store, {Key, Version}),
               State#state.oracle ! {done_put, Key, Version},
               Version
         end,
         timer:send_after(Latency, Client, {put_res, Ref, Self, Key, PutVersion}),
         loop(Self, State#state{
               versions = dict:store(Self, PutVersion, Versions),
               queue_delay = QueueDelay - ?PUT_DELAY
            });

      {dequeue, QProc} ->
         {NextItem, NextQueue} = queue:out(WorkQueue),
         QProc ! NextItem,
         loop(Self, State#state{queue = NextQueue});

      do_gossip ->
         case length(Servers) of
            0 -> loop(Self, State);
            Len ->
               {N, Rand2} = random:uniform_s(Len, Rand),
               Peer = lists:nth(N, Servers),
               timer:send_after(dict:fetch(Peer, NetLatencies), Peer,
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
         Latency = dict:fetch(Peer, NetLatencies),

         if    % peer has new updates
            PeerVersion > LocalPeerVersion ->
               timer:send_after(Latency, Peer,
                  {gossip_digest, Self, LocalVersion, LocalPeerVersion});
            true -> do_nothing
         end,

         if    % local has new updates
            LocalVersion > LocalVersionAtPeer ->
               Updates = ets:select(Store,
                  [{{'$1','$2'},[{'>','$2', LocalVersionAtPeer}],[{{'$1','$2'}}]}]),
               UpdatesToGossip = lists:sublist(lists:keysort(2, Updates), ?UPDATES_PER_GOSSIP),
               timer:send_after(Latency, Peer, {gossip_reply, Self, UpdatesToGossip});

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

qproc(Server) ->
   Server ! {qproc, self()},
   qproc(Server, self()).

qproc(Server, Self) ->
   Server ! {dequeue, Self},
   receive
      {value, {put, _} = Request} ->
         timer:sleep(?PUT_DELAY),
         Server ! {do, Request};
      {value, {get, _} = Request} ->
         timer:sleep(?GET_DELAY),
         Server ! {do, Request};
      empty ->
         receive resume -> resume end
   end,
   qproc(Server, Self).
