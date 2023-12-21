%%%-------------------------------------------------------------------
%% @doc pgpvll top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(pgpvll_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_all,
                 intensity => 2,
                 period => 5},

    AChild = #{id => 'pgpvll_worker',
			   start => {'pgpvll_worker', start_link, []},
			   restart => permanent,
			   shutdown => 5000,
			   type => worker,
			   modules => ['pgpvll_worker']},

    ChildSpecs = [AChild],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
