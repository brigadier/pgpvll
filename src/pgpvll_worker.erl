%%%-------------------------------------------------------------------
%%% @author evgeny
%%% @copyright (C) 2023, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(pgpvll_worker).

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
		 code_change/3]).
-export([conn/1, connect/2, close/1]).


-include("pgpvll_common.hrl").

-define(SERVER, ?MODULE).

-define(MINDELAY, 1000). %1 sec
-define(MAXDELAY, 32000). %32 sec
-define(PGTABLE, '_pgpwll_pgtable_').
-define(NWORKERS, 10).

-record(pgpvll_worker_state, {pools = #{}}).
-record(pg_conn, {conn = undefined, ref = undefined, error = undefined}).
-record(poolrec, {poolname,  n, connections={}, opts}).
%%====================================================================



connect(PoolName, Opts) ->
	gen_server:call(?SERVER, {connect, PoolName, Opts}).


close(PoolName) ->
	gen_server:call(?SERVER, {close, PoolName}).


conn(PoolName) ->
	case ets:lookup(?PGTABLE, PoolName) of
		[] -> {error, pool_not_found};
		[{_, N, Connections}] ->
			I = rand:uniform(N),
			case element(I, Connections) of
				Conn when is_pid(Conn) -> {ok, Conn};
				Else -> Else
			end
	end.

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
	process_flag(trap_exit, true),
	_Table = ets:new(?PGTABLE, [set, named_table, protected,
								{keypos, 1}, {read_concurrency, true}]),

	{ok, Pools} = read_env_pools(),
	PoolsMap = lists:foldl(
		fun({PoolName, Opts}, Acc) ->
			case maps:is_key(PoolName, Acc) of
				true ->
					error({PoolName, exists});
				_ ->
					{ok, PoolRec} = connect_pool(PoolName, Opts),
					Acc#{PoolName => PoolRec}
			end
		end,
		#{},
		Pools
	),

	{ok, #pgpvll_worker_state{pools = PoolsMap}}.


handle_call({connect, PoolName, Opts}, _From, State = #pgpvll_worker_state{pools = PoolsMap}) ->

	case maps:is_key(PoolName, PoolsMap) of
		true ->
			{reply, {error, pool_already_exists}, State};
		false ->
			{ok, #poolrec{connections = Connections} = PoolRec} = connect_pool(PoolName, Opts),

			Reply = lists:map(
				fun
					(#pg_conn{conn = undefined, error = Error}) -> Error;
					(#pg_conn{conn = Conn}) -> Conn
				end,
				Connections
			),
			{reply, {ok, Reply}, State#pgpvll_worker_state{pools = PoolsMap#{PoolName => PoolRec}}}
	end;



handle_call({close, PoolName}, _From, State = #pgpvll_worker_state{pools = PoolsMap}) ->
	case PoolsMap of
		#{PoolName := PoolRec} ->
			ok = disconnect_pool(PoolRec),
			{reply, ok, State#pgpvll_worker_state{pools = maps:remove(PoolName, PoolsMap)}};
		_ ->
			{reply, {error, pool_not_found}, State}
	end.


handle_cast(_Request, State = #pgpvll_worker_state{}) ->
	{noreply, State}.



handle_info({{'DOWN', PoolName}, _MonRef, process, Connection, ExitReason} ,
			State = #pgpvll_worker_state{pools = PoolsMap}) ->
	case PoolsMap of
		#{PoolName := #poolrec{connections = Connections} = PoolRec} ->
			F = fun
					(#pg_conn{conn = Conn} = PGConn) when Conn == Connection ->
						TimerRef = initiate_reconnect(PoolName, ?MINDELAY),
						PGConn#pg_conn{conn = undefined, error = ExitReason, ref = TimerRef};
					(PGConn) ->
						PGConn
				end,
			Connections2 = [F(C) || C <- Connections],
			PoolRec2 = PoolRec#poolrec{connections = Connections2},
			ok = ets_store(PoolRec2),
			{noreply, State#pgpvll_worker_state{pools = PoolsMap#{PoolName => PoolRec2}}};

		_ ->
			{noreply, State}
	end;


handle_info({timeout, TimerRef, {reconnect, PoolName, OldDelay}},
			State = #pgpvll_worker_state{pools = PoolsMap}) ->
	NewDelay = min(?MAXDELAY, OldDelay * 2),
	case PoolsMap of
		#{PoolName := #poolrec{connections = Connections, opts = Opts} = PoolRec} ->
			F = fun
					(#pg_conn{ref = Ref} = _PGConn) when Ref == TimerRef ->
						connect_one(PoolName, Opts, NewDelay);
					(PGConn) ->
						PGConn
				end,
			Connections2 = [F(C) || C <- Connections],
			PoolRec2 = PoolRec#poolrec{connections = Connections2},
			ok = ets_store(PoolRec2),
			{noreply, State#pgpvll_worker_state{pools = PoolsMap#{PoolName => PoolRec2}}};
		_ ->
			{noreply, State}
	end;



handle_info(_Info, State = #pgpvll_worker_state{}) ->
	{noreply, State}.

terminate(_Reason, _State = #pgpvll_worker_state{pools = PoolsMap}) ->
	maps:foreach(
		fun(_PoolName, PoolRec) ->
			disconnect_pool(PoolRec)
		end,
		PoolsMap
	),
	ok.

code_change(_OldVsn, State = #pgpvll_worker_state{}, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

disconnect_pool(#poolrec{connections = Connections, poolname = PoolName} = _PoolRec) ->
	ets:delete(?PGTABLE, PoolName),
	lists:foreach(
		fun
			(#pg_conn{conn = undefined}) -> ok;
			(#pg_conn{conn = Conn}) -> catch epgsql:close(Conn)
		end,
		Connections
	).

read_env_pools() ->
	ExternalPools = case application:get_env(pgpvll, poolsource) of
						{ok, ExtVal} ->
							{Mod, Fun} = ExtVal,
							{ok, Pools} = Mod:Fun(),
							Pools;
						_ ->
							[]
					end,
	case application:get_env(pgpvll, pools) of
		{ok, PoolsVal} ->
			{ok, PoolsVal ++ ExternalPools};
		_ ->
			{ok, ExternalPools}
	end.


connect_pool(PoolName, Opts) ->
	NWorkers = maps:get(n, Opts, ?NWORKERS),
	true = NWorkers > 0,
	Result = connect_n(PoolName, Opts, NWorkers),



	PoolRec = #poolrec{
		opts = Opts,
		poolname = PoolName,
		n = NWorkers,
		connections = Result
	},
	ok = ets_store(PoolRec),

	{ok, PoolRec}.


ets_store(#poolrec{poolname = PoolName, connections = Connections, n = N}) ->
	T = list_to_tuple(lists:map(
		fun
			(#pg_conn{conn = undefined, error = Error}) -> Error;
			(#pg_conn{conn = Conn}) -> Conn
		end,
		Connections
	)),
	true = ets:insert(?PGTABLE, {PoolName, N, T}),
	ok.

connect_n(_PoolName, _Opts, 0) -> [];

connect_n(PoolName, Opts, NWorkers) ->
	[connect_one(PoolName, Opts) |
			  connect_n(PoolName, Opts, NWorkers-1)].

connect_one(PoolName, Opts) ->
	connect_one(PoolName, Opts, ?MINDELAY).

connect_one(PoolName, Opts, Delay) ->
	case catch epgsql:connect(Opts) of
		{ok, Conn} ->
			MonitorRef = erlang:monitor(process, Conn, [{tag, {'DOWN', PoolName}}]),
			#pg_conn{conn = Conn, ref = MonitorRef};
		Else ->
			Ref = initiate_reconnect(PoolName, Delay),
			#pg_conn{ref = Ref, error = Else}
	end.


initiate_reconnect(PoolName, Delay) ->
	erlang:start_timer(Delay, self(), {reconnect, PoolName, Delay}).
