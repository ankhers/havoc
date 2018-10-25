%%%-------------------------------------------------------------------
%% @doc havoc
%% @end
%%%-------------------------------------------------------------------

-module(havoc).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([on/0, on/1, off/0]).

%% GenServer callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-record(state, {is_active = false,
                avg_wait,
                deviation,
                process,
                tcp,
                udp
               }).

-define(TCP_NAME, "tcp_inet").
-define(UDP_NAME, "udp_inet").

%%====================================================================
%% API functions
%%====================================================================
%% @private
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, ok, []).

%% @doc Begin to wreak havoc on your system using the default options.
%% @end
-spec on() -> ok.
on() ->
    gen_server:call(?SERVER, {on, []}).

%% @doc Begin to wreak havoc on your system.
%% @param Opts A proplist that accepts the following options.
%% <ul>
%% <li>`avg_wait' - The average amount of time you would like to wait between
%% kills. (default 5000)</li>
%% <li>`deviation' - The deviation of time allowed between kills.
%% (default 0.3)</li>
%% <li>`process' - Whether or not to kill processes. (default true)</li>
%% <li>`tcp' - Whether or not to kill TCP connections. (default false)</li>
%% <li>`udp' - Whether or not to kill UDP connections. (default false)</li>
%% </ul>
%% @end
-spec on(list(term)) -> ok.
on(Opts) ->
    gen_server:call(?SERVER, {on, Opts}).

%% @doc Stops killing things within your system.
-spec off() -> ok.
off() ->
    gen_server:call(?SERVER, off).

%%====================================================================
%% GenServer callbacks
%%====================================================================

%% @private
init(ok) ->
    {ok, #state{}}.

%% @private
handle_call({on, Opts}, _From, #state{is_active = false} = State) ->
    Wait = proplists:get_value(avg_wait, Opts, 5000),
    Deviation = proplists:get_value(deviation, Opts, 0.3),
    Process = proplists:get_bool(process, Opts),
    Tcp = proplists:get_bool(tcp, Opts),
    Udp = proplists:get_bool(udp, Opts),
    NewState = State#state{is_active = true, avg_wait = Wait,
                           deviation = Deviation, process = Process, tcp = Tcp,
                           udp = Udp},
    schedule(Wait, Deviation),
    {reply, ok, NewState};
handle_call(off, _From, #state{is_active = true} = State) ->
    {reply, ok, State#state{is_active = false}};
handle_call(_Msg, _From, State) ->
    {noreply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(kill_something, #state{is_active = true} = State) ->
    try_kill_one(State),
    schedule(State#state.avg_wait, State#state.deviation),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal functions
%%====================================================================
-spec schedule(non_neg_integer(), non_neg_integer()) -> reference().
schedule(Wait, Deviation) ->
    Diff = round(Wait * Deviation),
    Interval = rand:uniform(Diff * 2) + Wait - Diff,
    erlang:send_after(Interval, self(), kill_something).

-spec try_kill_one(#state{}) -> {ok, term()} | {error, nothing_to_kill}.
try_kill_one(State) ->
    Processes = process_list(State#state.process),
    Tcp = tcp_list(State#state.tcp),
    Udp = udp_list(State#state.udp),
    Shuffled = shuffle(Processes ++ Tcp ++ Udp),
    kill_one(Shuffled).

-spec process_list(boolean()) -> list(pid()).
process_list(true) ->
    processes();
process_list(false) ->
    [].

-spec tcp_list(boolean()) -> list(port()).
tcp_list(true) ->
    lists:filter(fun (Port) -> erlang:port_info(Port, name) =:= {name, ?TCP_NAME} end, erlang:ports());
tcp_list(false) ->
    [].

-spec udp_list(boolean()) -> list(port()).
udp_list(true) ->
    lists:filter(fun (Port) -> erlang:port_info(Port, name) =:= {name, ?UDP_NAME} end, erlang:ports());
udp_list(false) ->
    [].


-spec shuffle(list()) -> list().
shuffle(L) ->
    Shuffled = lists:sort([{rand:uniform(), X} || X <- L]),
    [X || {_, X} <- Shuffled].

-spec kill_one(list(pid())) -> {ok, term()} | {error, nothing_to_kill}.
kill_one([]) -> {error, nothing_to_kill};
kill_one([H | T]) ->
    case is_killable(H) of
        true ->
            kill(H);
        false ->
            kill_one(T)
    end.

%% http://erlang.org/doc/apps/
-define(OTP_APPS, [asn1, common_test, compiler, crypto, debugger, dialyzer,
                   diameter, edoc, eldap, erl_docgen, erl_interface, erts, et,
                   eunit, ftp, hipe, inets, jinterface, kernel, megaco, mnesia,
                   observer, odbc, os_mon, otp_mibs, parsetools, public_key,
                   reltool, runtime_tools, sasl, snmp, ssh, ssl, stdlib,
                   syntax_tools, tftp, tools, wx, xmerl]).

-spec is_killable(pid() | port()) -> boolean().
is_killable(Pid) when is_pid(Pid) ->
    App = case application:get_application(Pid) of
              {ok, A} -> A;
              undefined -> undefined
          end,
    not(erts_internal:is_system_process(Pid))
        andalso not(lists:member(App, ?OTP_APPS))
        andalso not(lists:member(App, [kernel, havoc]))
        andalso not(is_shell(Pid))
        andalso not(is_supervisor(Pid));
is_killable(Port) when is_port(Port) ->
    true.

-spec kill(pid() | port()) -> term().
kill(Pid) when is_pid(Pid) ->
    erlang:monitor(process, Pid),
    exit(Pid, havoc),
    receive
        {'DOWN', _, process, Pid, Reason} ->
            {ok, Reason}
    after 500 ->
            exit(Pid, kill),
            receive
                {'DOWN', _, process, Pid, Reason} ->
                    {ok, Reason}
            end
    end;
kill(Port) when is_port(Port) ->
    case erlang:port_info(Port, name) of
        {name, ?TCP_NAME} ->
            gen_tcp:close(Port);
        {name, ?UDP_NAME} ->
            gen_udp:close(Port)
    end.

-spec is_shell(pid()) -> boolean().
is_shell(Pid) ->
    case erlang:process_info(Pid, group_leader) of
        undefined -> false;
        {group_leader, Leader} ->
            case lists:keyfind(shell, 1, group:interfaces(Leader)) of
                {shell, Pid} -> true;
                {shell, Shell} ->
                    case erlang:process_info(Shell, dictionary) of
                        {dictionary, Dict} ->
                            proplists:get_value(evaluator, Dict) =:= Pid;
                        undefined -> false
                    end;
                false -> false
            end
    end.

-spec is_supervisor(pid()) -> boolean().
is_supervisor(Pid) ->
    Init =
        case erlang:process_info(Pid, initial_call) of
            {initial_call, I} -> I;
            undefined -> process_dead
        end,
    Translate =
        case Init of
            {proc_lib, init_p, 5} ->
                proc_lib:translate_initial_call(Pid);
            _ -> Init
        end,
    case Translate of
        {supervisor, _, _} -> true;
        _ -> false
    end.
