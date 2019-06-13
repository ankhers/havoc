Havoc
======

A ChaosMonkey style application that can randomly kill processes, as well as
TCP and UDP connections. Inspired by [dLuna/chaos_monkey](https://github.com/dLuna/chaos_monkey).

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
* `supervisor` - Whether or not to kill supervisors. (default false)
* `process` - Whether or not to kill processes. (default true)
* `tcp` - Whether or not to kill TCP connections. (default false)
* `udp` - Whether or not to kill UDP connections. (default false)
* `nodes` - Either a list of atoms for node names, or any value that
  `erlang:nodes/1` accepts.
* `applications` - A list of application names that you want to target.
  (defaults to all applications except `kernel` and `havoc`)
* `supervisors` - A list of supervisors that you want to target. Can be any
  valid supervisor reference. (defaults to all supervisors)
* `killable_callback` - A `Fun` that gets called to decide if a `pid` or
  `port` may be killed or not by returning `true` or `false`.
* `prekill_callback` - A `Fun` that gets called just before killing.

You can specify options using `havoc:on/1`.

``` erlang
havoc:on([{avg_wait, 3000}, {deviation, 0.5}, process, tcp])
```

Build
-----

    $ rebar3 compile
