%%%-------------------------------------------------------------------
%% @doc pgpvll public API
%% @end
%%%-------------------------------------------------------------------

-module(pgpvll_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    pgpvll_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
