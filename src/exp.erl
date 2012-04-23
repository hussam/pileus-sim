-module(exp).
-export([
      readpct/5, readpct/6,
      scale_clients/5, scale_clients/6
   ]).

-include("pileus.hrl").

-define(NUM_COLUMNS, 12).


readpct(NumServers, NumClients, NumReads, Policy, ExpName) ->
   Results = pmap(
      fun(ReadPct) ->
            run_exp({NumServers, NumClients, ReadPct, NumReads, Policy})
      end,
      [5]% lists:seq(5, 100, 5)
   ),
   write_results(Results, ExpName).

readpct(NumServers, NumClients, NumReads, Policy, ExpName, NumRuns) ->
   Results = multi_run_exp(
      [{NumServers, NumClients, R, NumReads, Policy} || R <- lists:seq(5,100,5)],
      NumRuns
   ),
   write_results(Results, ExpName ++ "_" ++ integer_to_list(NumRuns)).



scale_clients(NumServers, ReadPct, NumReads, Policy, ExpName) ->
   Results = pmap(
      fun(NumClients) ->
            run_exp({NumServers, NumClients, ReadPct, NumReads, Policy})
      end,
      lists:seq(10,100,10)
   ),
   write_results(Results, ExpName).

scale_clients(NumServers, ReadPct, NumReads, Policy, ExpName, NumRuns) ->
   Results = multi_run_exp(
      [{NumServers, C, ReadPct, NumReads, Policy} || C <- lists:seq(10,100,10)],
      NumRuns
   ),
   write_results(Results, ExpName ++ "_" ++ integer_to_list(NumRuns)).


%%%%%%%%%%%%%%%%%
% Private Utils %
%%%%%%%%%%%%%%%%%

multi_run_exp(Confs, NumRuns) ->
   Map = fun(Pid, Conf) -> Pid ! run_exp(Conf) end,

   Reduce = fun(Conf, Results, Acc) ->
         % Merge all the results for a single configuration
         RunsTotal = lists:foldl(
            fun(RunResult, RunningAcc) ->
                  [basho_stats_sample:update(ColValue, ColAcc) ||
                     {ColValue, ColAcc} <- lists:zip(tuple_to_list(RunResult), RunningAcc)]
            end,
            lists:duplicate(?NUM_COLUMNS, basho_stats_sample:new()),
            Results
         ),
         RunsAvg = lists:map(
            fun(X) -> basho_stats_sample:mean(X) end,
            RunsTotal
         ),
         [ {Conf, list_to_tuple(RunsAvg)} | Acc ]
   end,

   phofs:mapreduce(
      Map,
      Reduce,
      [],
      lists:flatten( lists:duplicate(NumRuns, Confs) )
   ).

run_exp(Conf = {NumServers, NumClients, ReadPct, NumReads, Policy}) ->
   %io:format("Running for ~p seconds, with ~p servers, ~p clients. Gets: ~p%\n", [RunTime, NumServers, NumClients, ReadPct]),
   Oracle = oracle:start(),
   [ Oracle ! {start_server, node()} || _I <- lists:seq(1,NumServers) ],
   {_, Clients} = lists:foldl(
      fun(_, {Rand, Clients}) ->
            {_, NextRand} = random:uniform_s(Rand),
            {NextRand, [client:new(Oracle, Policy, NextRand, ReadPct, NumReads) | Clients]}
      end,
      {?SEED, []},
      lists:seq(1, NumClients)
   ),
   %timer:sleep(MinRunTime * ?SECOND),
   RawResults = pmap(
      fun(C) ->
            C ! {self(), stop_and_report},
            receive Stats -> Stats end
      end,
      Clients
   ),
   Oracle ! {self(), stop},
   receive
      oracle_stopped -> ok
   end,

   {Stale, Inconsistent, GetLatencies, PutLatencies} = lists:foldl(
      fun({{S, I}, G, P}, {Ss, Is, Gs, Ps}) ->
            {[S | Ss], [I | Is], G ++ Gs, P ++ Ps}
      end,
      {[], [], [], []},
      RawResults
   ),

   StaleStats =        basho_stats_sample:update_all(Stale,        basho_stats_sample:new()),
   InconsistentStats = basho_stats_sample:update_all(Inconsistent, basho_stats_sample:new()),
%   GetStats = basho_stats_histogram:update_all(GetLatencies, basho_stats_histogram:new(0, 5000000, 20000)),
%   PutStats = basho_stats_histogram:update_all(PutLatencies, basho_stats_histogram:new(0, 5000000, 20000)),
%   AllOpStats = basho_stats_histogram:update_all(PutLatencies, GetStats),
%
%   {AllOpMin, AllOpMean, AllOpMax, _, _} = basho_stats_histogram:summary_stats(AllOpStats),
%
%   TotalStale = lists:sum(Stale),
%   TotalInconsistent = lists:sum(Inconsistent),

   { Conf,
      {
%         basho_stats_histogram:observations(PutStats),
%         basho_stats_histogram:observations(GetStats),

         basho_stats_sample:mean(StaleStats),
         basho_stats_sample:sdev(StaleStats),

         basho_stats_sample:mean(InconsistentStats),
         basho_stats_sample:sdev(InconsistentStats)

%         AllOpMin,
%         AllOpMean,
%         basho_stats_histogram:quantile(0.50, AllOpStats),
%         basho_stats_histogram:quantile(0.95, AllOpStats),
%         basho_stats_histogram:quantile(0.99, AllOpStats),
%         AllOpMax
      }
   }.


write_results(Results, ExpName) ->
   Fname = "results/" ++ ExpName ++ ".csv",
   {ok, File} = file:open(Fname, [raw, binary, write]),
   ok = file:write(File, <<"Servers, Clients, ReadPct, NumReads, Policy, ">>),
%   ok = file:write(File, <<"NumPuts, NumGets, ">>),
   ok = file:write(File, <<"AvgStale, SDevStale, ">>),
   ok = file:write(File, <<"AvgInconsistent, SDevInconsistent\n">>),
%   ok = file:write(File, <<"Min, Mean, Median, 95th, 99th, Max">>),

   lists:foreach(
      fun( {{NumServers, NumClients, ReadPct, NumReads, Policy},
            {
%              NumPuts, NumGets,
              AvgStale, SDevStale,
              AvgInconsistent, SDevInconsistent
%              Min, Mean, Median, _95th, _99th, Max
           }} ) ->

            ok = file:write(File, io_lib:format("~w, ~w, ~w, ~w, ~w, ", [
                     NumServers,
                     NumClients,
                     ReadPct,
                     NumReads,
                     Policy
                  ])),

%            ok = file:write(File, io_lib:format("~w, ~w, ", [
%                     NumPuts,
%                     NumGets
%                  ])),

            ok = file:write(File, io_lib:format("~w, ~w, ", [
                     AvgStale,
                     SDevStale
                  ])),

            ok = file:write(File, io_lib:format("~w, ~w\n", [
                     AvgInconsistent,
                     SDevInconsistent
                  ])),
            ok

%            ok = file:write(File, io_lib:format("~w, ~.2f, ~.2f, ~.2f, ~.2f, ~w\n", [
%                     Min,
%                     Mean,
%                     Median,
%                     _95th,
%                     _99th,
%                     Max
%                  ]))
      end,
      lists:sort(Results)
   ),
   ok = file:close(File),
   io:format("Finished experiment: ~s. Results written at \"~s\"\n", [ExpName, Fname]).


pmap(F, L) -> 
   S = self(),
   Ref = erlang:make_ref(), 
   Pids = lists:map(fun(I) -> spawn(fun() -> do_f(S, Ref, F, I) end) end, L),
   gather(Pids, Ref).

do_f(Parent, Ref, F, I) ->
   Parent ! {self(), Ref, (catch F(I))}.

gather([Pid|T], Ref) ->
   receive {Pid, Ref, Ret} -> [Ret|gather(T, Ref)] end;
gather([], _) ->
   [].

