Havoc
======

A ChaosMonkey style application that can randomly kill processes, as well as
TCP and UDP connections.

Basic Usage
-----------
``` erlang
havoc:on().
```

This will use the default options. The following is a list of currently
allowed options

* `avg_wait` - The average amount of time you would like to wait between kills.
(default 5000)
* `deviation` - The deviation of time allowed between kills. (default 0.3)
* `process` - Whether or not to kill processes. (default true)
* `tcp` - Whether or not to kill TCP connections. (default false)
* `udp` - Whether or not to kill UDP connections. (default false)

You can specify options using `havoc:on/1`.

``` erlang
havoc:on([{avg_wait, 3000}, {deviation, 0.5}, process, tcp])
```

Build
-----

    $ rebar3 compile
