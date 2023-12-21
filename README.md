
# pgpvll
=====
It spells like 'pgpool' or 'pgpull'.

This app maintains pools of epgsql https://github.com/epgsql/epgsql postgres connections. Tt can handle multiple pools, each pool with multiple connections and would try to reestablish connection with increasing delays (the steps are 1 sec, 2,4,8,16,32 sec) on connection loss.

add to the rebar.config deps section
```
     {pgpvll, ".*", {git, "https://github.com/brigadier/pgpvll.git", {branch, "master"}}}
```
                         
The app does not serialise queries through gen_servers workers like real pools would do, so there's barely any overhead over plain epgsql queries. Instead it just stores epgsql connections in a protected ets table and returns a random connection each time your app asks for a connection. When connection is not established it might return an error tuple instead of handle. If some of connections in a given pool are dead and some alive it would not try to cherrypick the ones which are online but would return a random thing which might happen to be either a connection or an error tuple. It tries its best to purge stale connections and repalce them with errors but it is still possible that your code would get a valid connection pid and would then crash because this connection is dead.

The app can get pools from app config, from configurable callback or you can manually add and remove pools in runtime using dedicated functions. It is better to use app config and callback, as in these unlikely cases when the app would crash it will lose its state. When pools are configured in the app config or received via callback function the app would read them in its Init when it gets restarted after crash. In normal circumstances it shouldn't crash though except in the Init itself, so connecting in runtime should be still relatively safe.

You should not store these connections, the normal way is to get a new connection each time you initiate a new transaction.


## configuration
Connection options are the same as in pgpool with additionap parameter `n` (the number of connections in the pool) which should be  a positive integer if specified. By default it equals to 10.

example of configuration in config file, with two pools `foo` and `bar` and an optional callback `test, fync` wihch would be called as `test:func()` and should return a tuple `{ok, ListOfPools}`

```erlang
{pgpvll, [
   {poolsource, {test, func}},
   {pools,[
    {foo, #{
        host => "localhost",
        port => 5430,
        username => "ufoo",
        password => "",
        database => "dbfoo",
        timeout => 4000,
        n => 2
    }},
    {bar, #{
        host => "localhost",
        port => 5431,
        username => "ubar",
        password => "",
        database => "dbbar",
        timeout => 4000,
        n => 10
    }}
   ]}]}
```
   
## interface

```erlang
pgpvll:connect(Opts) ->
    pgpvll:connect(default, Opts).
connect(PoolName::any(), Opts::map()) - > {ok, [Conn::epgsql:connection(), {error, Reason :: epgsql:connect_error()]}|{error, message::any()}
```

This function would create a new pool. If the pool already exists it returns `{error, pool_alreeady_exists}`, otherwise an ok tuple with a list of connections and errors. Pay attention - even if it couldn't establish one or all connections the tuple will be still `{ok, ...}`. The connections in this list might be ignored, they are there for the case when you would want to check if everything is connected.
    
```erlang

pgpvll:close() ->
    close(default).

pgpvll:close(PoolName::any()) -> ok|{error, pool_not_found}
```

Closes all connections in the given pool and purges pool and everything related to it. If you need to use this pool again you have to call the `connect` function again.


```erlang
pgpvll:conn() ->
    conn(default).

conn(PoolName::any()) -> {ok, Conn::epgsql:connection()}|{error, Reason :: epgsql:connect_error()]|{error, pool_not_found}

```

Returns a random connection


# example of workflow

```
{ok, Conn} = pgpvll:conn(mypool),
epgsql:squery(Conn, "select * from table")

```

As you can see the only thing which you would change in your exicting app is how you get the epgsql connection handle.
