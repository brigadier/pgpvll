%%%-------------------------------------------------------------------
%%% @author evgeny
%%% @copyright (C) 2023, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 21. дек. 2023 12:57
%%%-------------------------------------------------------------------
-module(pgpvll).

%% API
-export([connect/1, connect/2, close/0, close/1, conn/0, conn/1]).

connect(Opts) ->
	connect(default, Opts).

connect(PoolName, Opts) ->
	pgpvll_worker:connect(PoolName, Opts).


close() ->
	close(default).

close(PoolName) ->
	pgpvll_worker:close(PoolName).


conn() ->
	conn(default).

conn(PoolName) ->
	pgpvll_worker:conn(PoolName).