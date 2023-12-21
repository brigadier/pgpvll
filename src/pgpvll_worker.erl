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

-record(pgpvll_worker_state, {}).
-record(pg_conn, {conn = undefined, ref = undefined, error = undefined}).
-record(poolrec, {poolname,  n, connections={}, params}).
%%====================================================================



connect(PoolName, ConnParams) ->
	gen_server:call(?SERVER, {connect, PoolName, ConnParams}).


close(PoolName) ->
	gen_server:call(?SERVER, {close, PoolName}).


conn(PoolName) ->
	case ets:lookup(?PGTABLE, PoolName) of
		[] -> {error, pool_not_found};
		[#poolrec{n = N, connections = Connections}] ->
			I = rand:uniform(N),
			case element(I, Connections) of
				#pg_conn{conn = undefined, error = Reason}  ->
					{error, Reason};
				#pg_conn{conn = Conn}  ->
					{ok, Conn}
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
							   {keypos, 2}, {read_concurrency, true}]),

	{ok, Pools} = read_env_pools(),
	lists:foreach(
		fun({PoolName, ConnParams}) ->
			{ok, _PoolRec} = connect_pool(PoolName, ConnParams)
		end,
		Pools
	),

	{ok, #pgpvll_worker_state{}}.


handle_call({connect, PoolName, ConnParams}, _From, State = #pgpvll_worker_state{}) ->
	Reply = connect_pool(PoolName, ConnParams),

	{reply, Reply, State};

handle_call({close, PoolName}, _From, State = #pgpvll_worker_state{}) ->
	Reply = disconnect_pool(PoolName),
	{reply, Reply, State}.



handle_cast(_Request, State = #pgpvll_worker_state{}) ->
	{noreply, State}.



handle_info({{'DOWN', PoolName}, _MonRef, process, Connection, ExitReason} , State = #pgpvll_worker_state{}) ->
	?PRINT(down),
	case ets:lookup(?PGTABLE, PoolName) of
		[#poolrec{connections = ConnectionsTuple} = PoolRec] ->
			F = fun
					(#pg_conn{conn = Conn} = PGConn) when Conn == Connection ->
						TimerRef = initiate_reconnect(PoolName, ?MINDELAY),
						PGConn#pg_conn{conn = undefined, error = ExitReason, ref = TimerRef};
					(PGConn) ->
						PGConn
				end,
			Connections = list_to_tuple([F(C) || C <- tuple_to_list(ConnectionsTuple)]),
			PoolRec2 = PoolRec#poolrec{connections = Connections},
			true = ets:insert(?PGTABLE, PoolRec2);
		_ ->
			ok
	end,
	{noreply, State};

handle_info({timeout, TimerRef, {reconnect, PoolName, OldDelay}}, State = #pgpvll_worker_state{}) ->
	?PRINT(timeout),
	NewDelay = min(?MAXDELAY, OldDelay*2),
	case ets:lookup(?PGTABLE, PoolName) of
		[#poolrec{connections = ConnectionsTuple, params = ConnParams} = PoolRec] ->
			F = fun
					(#pg_conn{ref = Ref} = _PGConn) when Ref == TimerRef ->
						connect_one(PoolName, ConnParams, NewDelay);
					(PGConn) ->
						PGConn
				end,
			Connections = list_to_tuple([F(C) || C <- tuple_to_list(ConnectionsTuple)]),
			PoolRec2 = PoolRec#poolrec{connections = Connections},
			true = ets:insert(?PGTABLE, PoolRec2);
		_ ->
			ok
	end,
	{noreply, State};


handle_info(_Info, State = #pgpvll_worker_state{}) ->
	{noreply, State}.

terminate(_Reason, _State = #pgpvll_worker_state{}) ->
	L = ets:tab2list(?PGTABLE),
	lists:foreach(
		fun(#poolrec{poolname = PoolName, connections = ConTuple}) ->
			disconnect_pool(PoolName, ConTuple)
		end,
		L
	),
	ok.

code_change(_OldVsn, State = #pgpvll_worker_state{}, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

disconnect_pool(PoolName) ->
	case ets:lookup(?PGTABLE, PoolName) of
		[] -> {error, pool_not_found};
		[#poolrec{connections = ConTuple}] -> disconnect_pool(PoolName, ConTuple)
	end.

disconnect_pool(PoolName, ConTuple) ->
	Conns = tuple_to_list(ConTuple),
	ets:delete(?PGTABLE, PoolName),
	lists:foreach(
		fun
			(#pg_conn{conn = undefined}) -> ok;
			(#pg_conn{conn = Conn}) -> catch epgsql:close(Conn)
		end,
		Conns
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


connect_pool(PoolName, ConnParams) ->
	case ets:lookup(?PGTABLE, PoolName) of
		[] ->
			NWorkers = maps:get(n, ConnParams, ?NWORKERS),
			true = NWorkers > 0,
			Result = connect_n(PoolName, ConnParams, NWorkers),
			Return = lists:foldl(
				fun
					(#pg_conn{conn = undefined, error = Error}, {Good, Bad}) ->
						{Good, [Error | Bad]};
					(#pg_conn{conn = Conn}, {Good, Bad}) ->
						{[Conn | Good], Bad}
				end,
				{[], []},
				Result
			),


			PoolRec = #poolrec{
				params = ConnParams,
				poolname = PoolName,
				n = NWorkers,
				connections = erlang:list_to_tuple(Result)
			},
			true = ets:insert(?PGTABLE, PoolRec),
			{ok, Return};
		_ ->
			{error, pool_exists}

	end.



connect_n(_PoolName, _ConnParams,  0) -> [];

connect_n(PoolName, ConnParams, NWorkers) ->
	[connect_one(PoolName, ConnParams) |
			  connect_n(PoolName, ConnParams, NWorkers-1)].

connect_one(PoolName, ConnParams) ->
	connect_one(PoolName, ConnParams, ?MINDELAY).

connect_one(PoolName, ConnParams, Delay) ->
	case catch epgsql:connect(ConnParams) of
		{ok, Conn} ->
			MonitorRef = erlang:monitor(process, Conn, [{tag, {'DOWN', PoolName}}]),
			#pg_conn{conn = Conn, ref = MonitorRef};
		Else ->
			Ref = initiate_reconnect(PoolName, Delay),
			#pg_conn{ref = Ref, error = Else}
	end.


initiate_reconnect(PoolName, Delay) ->
	erlang:start_timer(Delay, self(), {reconnect, PoolName, Delay}).
