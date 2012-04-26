-module(client).
-export([
      new/5
   ]).

-include("pileus.hrl").

-record(server_stats, {
                        latency,
                        queue_delay = 0,
                        version = 0
                     }).

-record(state, {
                  rand,
                  oracle,
                  can_run,
                  policy,
                  read_percentage,
                  op_counter,

                  report_to,
                  reads_remaining,

                  key_versions,

                  stale_counts,
                  inconsistent_count,
                  put_latencies,
                  get_latencies,

                  server_stats,
                  default_target,

                  highest_read_version,
                  last_write_version,
                  highest_version
               }).

%% Tracks latencies up to 5 secs w/ 250 us resolution
%-define(NEW_HIST, basho_stats_histogram:new(0, 5000000, 20000)).
-define(NEW_HIST, []).


new(Oracle, Policy, Seed, ReadPct, NumReads) ->
   Client = spawn(fun() -> init(Oracle, Policy, Seed, ReadPct, NumReads) end),
   Oracle ! {reg_client, Client},
   Client.

init(Oracle, Policy, Seed, ReadPct, NumReads) ->
   {OpCounter, Rand} = random:uniform_s(100, Seed),
   State = #state{
      rand = Rand,
      oracle = Oracle,
      can_run = infinity,
      policy = Policy,
      read_percentage = ReadPct,
      op_counter = OpCounter,
      reads_remaining = NumReads,
      key_versions = ets:new(key_versions, []),
      server_stats = [],
      stale_counts = [],
      inconsistent_count = 0,
      put_latencies = ?NEW_HIST,
      get_latencies = ?NEW_HIST,
      highest_read_version = 0,
      last_write_version = 0
   },
   timer:send_interval(?UPDATE_SERVER_STATS_PERIOD, self(), update_server_stats),
   loop(self(), State).


loop(Self, State = #state{
      rand = Rand,
      oracle = Oracle,
      can_run = CanRun,
      policy = Policy,
      read_percentage = ReadPct,
      op_counter = OpCounter,
      report_to = ReportTo,
      reads_remaining = ReadsRemaining,
      key_versions = KeysVersions,
      stale_counts = StaleCounts,
      inconsistent_count = InconsistentCount,
      put_latencies = PutLatencies,
      get_latencies = GetLatencies,
      server_stats = ServerStats,
      default_target = DefaultTarget,
      highest_read_version = HighestReadVersion,
      last_write_version = LastWriteVersion
   }) ->

   case ReportTo of
      undefined ->
         do_nothing;
      _ when ReadsRemaining > 0 ->
         do_nothing;
      Manager ->
         NumStaleGets = length([X || X <- StaleCounts, X > 0]),
         Manager ! [NumStaleGets, InconsistentCount, StaleCounts, GetLatencies, PutLatencies],
         exit(stop_and_report)
   end,

   receive
      {new_server, Server, Latency} ->
         Server ! {connect_client, Self, Latency},
         NextServerStats = lists:sort(store(Server, #server_stats{latency=Latency}, ServerStats)),
         NextDefaultTarget = compute_fixed_pref(Rand, Oracle, Policy, NextServerStats, HighestReadVersion, LastWriteVersion),
         loop(Self, State#state{
               can_run = 0,
               server_stats = NextServerStats,
               default_target = NextDefaultTarget
            });

      {all_servers, ServersLatencies} ->
         NextServerStats = lists:sort(lists:foldl(
            fun ({S, L}, Stats) ->
                  S ! {connect_client, Self, L},
                  store(S, #server_stats{latency = L}, Stats)
            end,
            ServerStats,
            ServersLatencies
         )),
         NextDefaultTarget = compute_fixed_pref(Rand, Oracle, Policy, NextServerStats, HighestReadVersion, LastWriteVersion),
         loop(Self, State#state {
               can_run = 0,
               server_stats = NextServerStats,
               default_target = NextDefaultTarget
            });

      {ManagerPid, stop_and_report} ->
         loop(Self, State#state{ report_to = ManagerPid });

      update_server_stats ->
         {N, NextRand} = random:uniform_s(length(ServerStats), Rand),
         {Server, #server_stats{latency = Latency}} = lists:nth(N, ServerStats),
         erlang:send_after(Latency, Server, {Self, get_stats}),
         loop(Self, State#state{rand = NextRand});

      {server_stats, Server, QDelay, Version} ->
         Stats = fetch(Server, ServerStats),
         NextServerStats = store(Server,
                                 Stats#server_stats{queue_delay = QDelay, version = Version},
                                 ServerStats),
         NextDefaultTarget = compute_fixed_pref(Rand,
                                                Oracle,
                                                Policy,
                                                NextServerStats,
                                                HighestReadVersion,
                                                LastWriteVersion),
         loop(Self, State#state{
               server_stats = NextServerStats,
               default_target = NextDefaultTarget
            })

   after CanRun ->
         N = OpCounter,
         {Key, Rand2} = random:uniform_s(?MAX_KEY, Rand),

         Op = if N =< ReadPct -> get; true -> put end,

         {OpTargets, Rand4} = case Policy of
            round_robin ->
               {Server, #server_stats{latency=L}} = lists:nth( (N rem length(ServerStats)) + 1, ServerStats),
               { [{Server, L}] , Rand2 };

            {random, Num} ->
               {RandomTargets, _, Rand3} = lists:foldl(
                  fun(_, {PickedServers, RemServers, RandIn}) ->
                        {X, RandOut} = random:uniform_s(length(RemServers), RandIn),
                        {S1, [{S,#server_stats{latency = L}} | S2]} = lists:split(X - 1, RemServers),
                        { [{S,L} | PickedServers] , S1 ++ S2 , RandOut }
                  end,
                  {[], ServerStats, Rand2},
                  lists:seq(1, Num)
               ),
               {RandomTargets, Rand3};

            {sla, _} when Op == put ->
               [{PrimaryServer, #server_stats{latency=L}} | _] = ServerStats,
               [{PrimaryServer, L}, Rand2];

            _ ->
               {DefaultTarget, Rand2}
         end,

         NextState = case Op of
            get ->
               Start = now(),
               [erlang:send_after(L, S, {req, Self, {get, Key}}) || {S,L} <- OpTargets],
               receive
                  {get_res, _Server, Key, GotVersion, StaleCount} ->
                     OpLatency = timer:now_diff(now(), Start),

                     NewInconsistentCount = case ets:lookup(KeysVersions, Key) of
                        [{Key, LastVersion}] when GotVersion < LastVersion ->
                           InconsistentCount + 1;
                        _ ->
                           ets:insert(KeysVersions, {Key, GotVersion}),
                           InconsistentCount
                     end,

                     NewHighestReadVersion = if
                        GotVersion > HighestReadVersion -> GotVersion;
                        true -> HighestReadVersion
                     end,

                     State#state{
                        rand = Rand4,
                        op_counter = (OpCounter + 1) rem 100,
                        reads_remaining = ReadsRemaining - 1,
                        highest_read_version = NewHighestReadVersion,
                        stale_counts = [StaleCount | StaleCounts],
                        inconsistent_count = NewInconsistentCount,
                        get_latencies = [OpLatency | GetLatencies]
                     }
               end;

            put ->
               Oracle ! {Self, get_counter},
               Version = receive {counter, C} -> C end,
               Pair = {Key, Version},

               Start = now(),
               [erlang:send_after(L, S, {req, Self, {put, Pair}}) || {S,L} <- OpTargets],
               receive
                  {put_res, _Server, Pair} ->
                     OpLatency = timer:now_diff(now(), Start),
                     ets:insert(KeysVersions, Pair),
                     State#state{
                        rand = Rand4,
                        op_counter = (OpCounter + 1) rem 100,
                        last_write_version = Version,
                        put_latencies = [OpLatency | PutLatencies]
                     }
               end
         end,
         loop(Self, NextState)
   end.

store(Key, Value, TupleList) ->
   lists:keystore(Key, 1, TupleList, {Key, Value}).

fetch(Key, TupleList) ->
   {Key, Value} = lists:keyfind(Key, 1, TupleList),
   Value.

compute_fixed_pref(Rand, Oracle, Policy, ServerStats, HighestReadVersion, LastWriteVersion) ->
   case Policy of
      {fixed, global} ->   % All clients use same server
         {Server, #server_stats{latency=L}} = lists:min(ServerStats),
         [{Server, L}];

      {fixed, random} ->   % Each client picks a random server
         {N, _} = random:uniform_s(length(ServerStats), Rand),
         {Server, #server_stats{latency=L}} = lists:nth(N, ServerStats),
         [{Server, L}];

      {fixed, even} ->     % The oracle assigns clients to servers
         Oracle ! {self(), pick_server},
         receive
            {pick_server, Server} ->
               % XXX: problematic if client has no connection to that server
               #server_stats{latency=L} = fetch(Server, ServerStats),
               [{Server, L}]
         end;

      {fixed, {latency, Num}} -> % Each client picks the closets `Num` servers
         LSs = [ {L, S} || {S, #server_stats{latency = L}} <- ServerStats ],
         lists:sublist([{S,L} || {L,S} <- lists:sort(LSs)], Num);

      min_delay ->
         [{Server, #server_stats{latency = Latency}} | _] = sort_by_delay(ServerStats),
         [{Server, Latency}];

      {sla, SLA} ->  % Clients pick servers according to a consistency SLA
         SortedServers = lists:map(
            fun({S, #server_stats{latency=L, queue_delay=Q, version=V}}) ->
                  {S, V, L+Q+L, L}
            end,
            sort_by_delay(ServerStats)
         ),

         [{PrimaryServer, _} | _] = ServerStats,
         PossibleServers = ( lists:map(
            fun({ConsistencyGuarantee, Latency}) ->
                  lists:filter(
                     fun({S, V, T, _L}) ->
                           (T =< Latency) and
                           case ConsistencyGuarantee of
                              strong -> S == PrimaryServer;
                              ryw -> V >= LastWriteVersion;
                              monotonic -> V >= HighestReadVersion;
                              _ -> true
                           end
                     end,
                     SortedServers
                  )
            end,
            SLA
         ) ),

         %io:format("@ ~w PossibleServers is ~w SortedServers is ~w\n", [self(), PossibleServers, SortedServers]),

         case lists:flatten(PossibleServers) of
            [{Server, _Version, _TimeEstimate, Latency} | _] ->
               [{Server, Latency}];

            [] ->    % No server can satisfy the SLA, just pick the one with the highest version number
               [{Server, _, _, Latency} | _] = lists:sort(
                  fun({_S1, V1, _T1, L1}, {_S2, V2, _T2, L2}) ->
                        % Sort descending by version first, break ties by latency ascending
                        if
                           V1 > V2 -> true;
                           V1 < V2 -> false;
                           L1 > L2 -> false;
                           true -> true
                        end
                  end,
                  SortedServers
               ),
               [{Server, Latency}]
         end;

      _ ->
         {null, null}
   end.


% Sort by time estimate first, break ties by latency
sort_by_delay(ServerStats) ->
   lists:sort(
      fun(  {_S1, #server_stats{latency=L1, queue_delay=Q1}},
            {_S2, #server_stats{latency=L2, queue_delay=Q2}}) ->

            T1 = L1 + Q1 + L1,
            T2 = L2 + Q2 + L2,

            if
               T1 < T2 -> true;
               T1 > T2 -> false;
               L1 < L2 -> true;
               true -> false
            end
      end,
      ServerStats
   ).
