-module(exp).
-export([
      readpct/5, readpct/6,
      scale_clients/5, scale_clients/6
   ]).

-include("pileus.hrl").

-define(NUM_COLUMNS, 12).
-define(STATS_NAMES, [
      "Stale",
      "Inconsistent",
      "StaleCounts",
      "Gets",
      "Puts"
   ]).



readpct(NumServers, NumClients, NumReads, Policy, ExpName) ->
   Results = pmap(
      fun(ReadPct) ->
            run_exp({NumServers, NumClients, ReadPct, NumReads, Policy})
      end,
      lists:seq(5, 100, 5)
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
   Oracle = oracle:start(),
   MasterTable = ets:new(master_table, [ bag, public, {write_concurrency, true}, {read_concurrency, true} ]),
   [ Oracle ! {start_server, MasterTable} || _I <- lists:seq(1,NumServers) ],
   {_, Clients} = lists:foldl(
      fun(_, {Rand, Clients}) ->
            {_, NextRand} = random:uniform_s(Rand),
            {NextRand, [client:new(Oracle, Policy, NextRand, ReadPct, NumReads) | Clients]}
      end,
      {?SEED, []},
      lists:seq(1, NumClients)
   ),
   RawResults = pmap(
      fun(C) ->
            C ! {self(), stop_and_report},
            C ! {self(), stop_and_report},
            C ! {self(), stop_and_report},
            C ! {self(), stop_and_report},
            receive Stats -> Stats end
      end,
      Clients
   ),
   Oracle ! {self(), stop},
   receive
      oracle_stopped -> ok
   end,

   ets:delete(MasterTable),

      AllStats = lists:map(
      fun(Values) ->
            Stats = basho_stats_sample:update_all(Values, basho_stats_sample:new()),
            {basho_stats_sample:mean(Stats) , basho_stats_sample:sdev(Stats)}
      end,

      lists:foldl(
         fun(ClientResults, ClientsAcc) ->
               lists:map(
                  fun
                     ({CR, CA}) when is_list(CR) -> CR ++ CA;
                     ({CR, CA}) -> [CR | CA]
                  end,

                  lists:zip(ClientResults, ClientsAcc)
               )
         end,
         lists:duplicate(length(?STATS_NAMES), []),
         RawResults
      )
   ),

   {Conf, AllStats}.


write_results(Results, ExpName) ->
   Fname = "results/" ++ ExpName ++ ".csv",
   {ok, File} = file:open(Fname, [raw, binary, write]),
   ok = file:write(File, <<"Servers, Clients, ReadPct, NumReads, Policy">>),

   lists:foreach(
      fun(StatsName) ->
            file:write(File, io_lib:format(", Avg~s, SDev~s", [StatsName, StatsName]))
      end,
      ?STATS_NAMES
   ),

   ok = file:write(File, <<"\n">>),

   lists:foreach(
      fun( {{NumServers, NumClients, ReadPct, NumReads, Policy}, RunResults} ) ->
            ok = file:write(File, io_lib:format("~w, ~w, ~w, ~w, ~w", [
                     NumServers,
                     NumClients,
                     ReadPct,
                     NumReads,
                     Policy
                  ])),

            lists:foreach(
               fun
                  ({'NaN', 'NaN'}) ->
                     ok = file:write(File, <<", NaN, NaN">>);
                  ({Avg, SDev}) ->
                     ok = file:write(File, io_lib:format(", ~.5f, ~.5f", [Avg, SDev]))
               end,
               RunResults
            ),

            ok = file:write(File, <<"\n">>)
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

