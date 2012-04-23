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
                  op_stats,
                  op_latency,

                  server_stats,
                  default_target,

                  highest_read_version,
                  last_write_version,
                  highest_version
               }).

%% Tracks latencies up to 5 secs w/ 250 us resolution
%-define(NEW_HIST, basho_stats_histogram:new(0, 5000000, 20000)).
%-define(NEW_HIST, []).
-define(NEW_HIST, 0).


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
      op_stats = {0,0},
      op_latency = {?NEW_HIST, ?NEW_HIST},
      highest_read_version = 0,
      last_write_version = 0
   },
%   timer:send_interval(?UPDATE_SERVER_STATS_PERIOD, self(), update_server_stats),
   loop(self(), State).


report(Manager, {Stale, Inconsistent}, PutLatencies, GetLatencies, ReadPct) ->
   SI = case GetLatencies of
      0 -> {0, 0};
      NumGets ->
%         Sp = Stale / NumGets,
%         Ip = Inconsistent / NumGets,
%         io:format("Stale: ~.5f Inconsistent: ~.5f with ~w Gets at ~w%\n", [Sp, Ip, NumGets, ReadPct]),
         {Stale / NumGets, Inconsistent / NumGets}
   end,
   Manager ! {SI, [GetLatencies], [PutLatencies]},
   exit(stop_and_report).
%
%         [Gets, Puts] = lists:map(
%            fun(Hist) ->
%                  {Min, Mean, Max, _, _} = basho_stats_histogram:summary_stats(Hist),
%                  {
%                     basho_stats_histogram:observations(Hist),
%                     Min,
%                     trunc(Mean),
%                     trunc(basho_stats_histogram:quantile(0.50, Hist)),
%                     trunc(basho_stats_histogram:quantile(0.95, Hist)),
%                     trunc(basho_stats_histogram:quantile(0.99, Hist)),
%                     Max
%                  }
%            end,
%            [GetLatencies, PutLatencies]
%         ),
%
%         Manager ! {SI, Gets, Puts}



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
      op_stats = OpStats = {Stale, Inconsistent},
      op_latency = {PutLatencies, GetLatencies},
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
      ManagerPid ->
         report(ManagerPid, OpStats, PutLatencies, GetLatencies, ReadPct)
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

      {Manager, stop_and_report} ->
         loop(Self, State#state{ report_to = Manager });

      update_server_stats ->
         {N, NextRand} = random:uniform_s(length(ServerStats), Rand),
         {Server, #server_stats{latency = Latency}} = lists:nth(N, ServerStats),
         %erlang:send_after(Latency, Server, {Self, get_stats}),
         Server ! {Self, get_stats},
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

         Oracle ! {Self, pre, Op, Key},
         {OpTargets, Version, Rand4} = receive
%            {Manager, stop_and_report} ->
%               loop(Self, State#state{ report_to = Manager });

            {pre, Op, Key, OracleVersion, SuggestedServer} ->
               {Targets, Rand3} = case Policy of
                  round_robin ->
                     { [{SuggestedServer, 0}] , Rand2};
                     %#server_stats{latency = L} = fetch(SuggestedServer, ServerStats),
                     %[{SuggestedServer, L}];

                  {random, Num} ->
                     {RandomTargets, _, Rand3a} = lists:foldl(
                        fun(_, {PickedServers, RemServers, RandIn}) ->
                              {X, RandOut} = random:uniform_s(length(RemServers), RandIn),
                              {S1, [{S,#server_stats{latency = L}} | S2]} = lists:split(X - 1, RemServers),
                              { [{S,L} | PickedServers] , S1 ++ S2 , RandOut }
                        end,
                        {[], ServerStats, Rand2},
                        lists:seq(1, Num)
                     ),
                     {RandomTargets, Rand3a};

                  {sla, _} when Op == put ->
                     [{PrimaryServer, #server_stats{latency=L}} | _] = ServerStats,
                     [{PrimaryServer, L}, Rand2];

                  _ ->
                     {DefaultTarget, Rand2}

               end,
               {Targets, OracleVersion, Rand3}
         end,

         %io:format("@ ~p Op ~p Target ~p\n", [Self, Op, OpTargets]),

         NextState = case Op of
            get ->
               ExpectedVersion = Version,
%               Start = now(),
%               [erlang:send_after(L, S, {req, {get, {Self, Key}}}) || {S,L} <- OpTargets],
               [ S ! {req, {get, {Self, Key}}} || {S,L} <- OpTargets],
               receive
%                  {Manager1, stop_and_report} ->
%                     loop(Self, State#state{ report_to = Manager1 });

                  {get_res, _Server, Key, GotVersion} ->
%                    OpLatency = timer:now_diff(now(), Start),
                     NewStale = if
                        GotVersion < ExpectedVersion ->
                           Stale + 1;
                        true -> Stale
                     end,

                     NewInconsistent = case ets:lookup(KeysVersions, Key) of
                        [{Key, LastVersion}] when GotVersion < LastVersion ->
                           Inconsistent + 1;
                        _ ->
                           ets:insert(KeysVersions, {Key, GotVersion}),
                           Inconsistent
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
                        op_stats = {NewStale, NewInconsistent},
                        op_latency = {
                           PutLatencies,
                           GetLatencies + 1
%                           [OpLatency | GetLatencies]
                           %basho_stats_histogram:update(OpLatency, GetLatencies)
                        }
                     }
               end;

            put ->
%               Start = now(),
               %[erlang:send_after(L, S, {req, {put, {Self, Key, Version}}}) || {S,L} <- OpTargets],
               [ S ! {req, {put, {Self, Key, Version}}} || {S,L} <- OpTargets],
               receive
                  {put_res, _Server, Key, PutVersion} ->  % Server might actually have newer version
%                     OpLatency = timer:now_diff(now(), Start),
                     ets:insert(KeysVersions, {Key, PutVersion}),
                     State#state{
                        rand = Rand4,
                        op_counter = (OpCounter + 1) rem 100,
                        last_write_version = PutVersion,
                        op_latency = {
                           %basho_stats_histogram:update(OpLatency, PutLatencies),
%                           [OpLatency | PutLatencies],
                           PutLatencies + 1,
                           GetLatencies
                        }
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
