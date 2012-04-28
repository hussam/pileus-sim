-module(server).
-export([
      new/2
   ]).

-include("pileus.hrl").

-record(state, {
                  store,
                  highest_version,
                  queue,
                  queue_length,
                  workers,
                  client_latencies,
                  gossip_proc,
                  oracle
               }).

new(Oracle, MasterTable) ->
   spawn(fun() -> init(Oracle, MasterTable) end).

init(Oracle, MasterTable) ->
   Self = self(),
   Store = ets:new(server_store, [ public, bag, {write_concurrency, true}, {read_concurrency, true} ]),
   Workers = [spawn(fun() -> worker_proc(MasterTable, Self, Store) end) || _I <- lists:seq(1, ?NUM_WORKERS)],
   GossipProc = spawn(fun gossip_proc/0),
   timer:send_interval(?GOSSIP_PERIOD, GossipProc, push_updates),

   State = #state {
      store = Store,
      highest_version = 0,
      queue = queue:new(),
      queue_length = 0,
      workers = Workers,
      client_latencies = dict:new(),
      gossip_proc = GossipProc,
      oracle = Oracle
   },
   loop(Self, State).

loop(Self, State = #state{
                           store = Store,
                           highest_version = HighestVersion,
                           queue = Queue,
                           queue_length = QLen,
                           workers = Workers,
                           client_latencies = ClientLatencies,
                           gossip_proc = GossipProc
                        } ) ->
   receive
      {new_server, _Server, _Latency} = Msg ->
         GossipProc ! Msg,
         loop(Self, State);

      {all_servers, _ServersLatencies} = Msg ->
         GossipProc ! Msg,
         loop(Self, State);

      {connect_client, Pid, Latency} ->
         NewLatencies = case dict:is_key(Pid, ClientLatencies) of
            true  -> ClientLatencies;
            false -> dict:store(Pid, Latency, ClientLatencies)
         end,
         loop(Self, State#state{client_latencies = NewLatencies});

      {Client, get_stats} ->
         Latency = dict:fetch(Client, ClientLatencies),
         erlang:send_after(Latency, Client, {
               server_stats,
               Self,
               QLen * ?GET_DELAY,
               HighestVersion
            }),
         loop(Self, State);

      {req, Client, Request} ->
         Latency = dict:fetch(Client, ClientLatencies),
         case Workers of
            [] ->
               loop(Self, State#state{
                     queue = queue:in({Client, Latency, Request}, Queue),
                     queue_length = QLen + 1
                  });
            [Worker | Tail] ->
               Worker ! {Client, Latency, Request},
               loop(Self, State#state{ workers = Tail })
         end;

      {done, Worker} ->
         if
            QLen > 0 ->
               {{value, WorkReq}, NextQueue} = queue:out(Queue),
               Worker ! WorkReq,
               loop(Self, State#state{queue = NextQueue, queue_length = QLen - 1});

            true ->
               loop(Self, State#state{workers = [Worker | Workers]})
         end;

      {done_put, Pair = {_Key, Version}} ->
         GossipProc ! {put, Pair},
         NextState = if
            Version > HighestVersion -> State#state{highest_version = Version};
            true -> State
         end,
         loop(Self, NextState);

      {gossip_push, Updates} ->
         ets:insert(Store, Updates),
         NextVersion = max(HighestVersion, lists:max([V || {_K,V} <- Updates])),
         loop(Self, State#state{highest_version = NextVersion});

      version ->
         io:format("Current highest version is ~p\n", [HighestVersion]),
         loop(Self, State)

   end.


worker_proc(MasterTable, Server, Store) ->
   worker_proc(self(), MasterTable, Server, Store).

worker_proc(Self, MasterTable, Server, Store) ->
   receive
      {Client, Latency, {get, Key}} ->
         timer:sleep(?GET_DELAY),
         MasterNumUpdates = case ets:lookup(MasterTable, Key) of
            [] -> 0;
            MasterUpdates -> length(MasterUpdates)
         end,
         {NumUpdates, Version} = case ets:lookup(Store, Key) of
            [] -> {0, 0};
            Updates ->
               {Key, V} = lists:max(Updates),
               {length(Updates), V}
         end,
         NumMissingUpdates = MasterNumUpdates - NumUpdates,
         erlang:send_after(Latency, Client, {get_res, Server, Key, Version, NumMissingUpdates}),
         Server ! {done, Self};

      {Client, Latency, {put, Pair}} ->
         timer:sleep(?PUT_DELAY),
         ets:insert(MasterTable, Pair),
         ets:insert(Store, Pair),
         Server ! {done_put, Pair},
         erlang:send_after(Latency, Client, {put_res, Server, Pair}),
         Server ! {done, Self}
   end,
   worker_proc(Self, MasterTable, Server, Store).


gossip_proc() ->
   gossip_proc([], queue:new(), 0).

gossip_proc(ServersLatencies, Queue, QLen) ->
   receive
      {put, Pair} ->
         gossip_proc(ServersLatencies, queue:in(Pair, Queue), QLen + 1);

      push_updates ->
         case min(QLen, ?UPDATES_PER_GOSSIP) of
            0 ->
               gossip_proc(ServersLatencies, Queue, QLen);
            NumUpdates ->
               {Updates, NextQueue} = queue:split(NumUpdates, Queue),
               Msg = {gossip_push, queue:to_list(Updates)},
               [ erlang:send_after(L, S, Msg) || {S,L} <- ServersLatencies ],
               gossip_proc(ServersLatencies, NextQueue, QLen - NumUpdates)
         end;

      {new_server, Server, Latency} ->
         gossip_proc([{Server, Latency} | ServersLatencies], Queue, QLen);

      {all_servers, AllServersLatencies} ->
         gossip_proc(AllServersLatencies ++ ServersLatencies, Queue, QLen)
   end.



