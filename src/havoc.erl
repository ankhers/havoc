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
                supervisor,
                process,
                tcp,
                udp,
                nodes,
                applications,
                otp_applications,
                supervisors,
                killable_callback,
                prekill_callback
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
%% kills. (default `5000')</li>
%% <li>`deviation' - The deviation of time allowed between kills.
%% (default `0.3')</li>
%% <li>`supervisor' - Whether or not to kill supervisors. (default `false')</li>
%% <li>`process' - Whether or not to kill processes. (default `true')</li>
%% <li>`tcp' - Whether or not to kill TCP connections. (default `false')</li>
%% <li>`udp' - Whether or not to kill UDP connections. (default `false')</li>
%% <li>`nodes' - Either a list of atom node names, or a single atom that is
%% accepted by `erlang:nodes/1'. (default `this')</li>
%% <li>`applications' - A list of application names that you want to
%% target. (defaults to all applications except `kernel' and `havoc')</li>
%% <li> `otp_applications' - A list of OTP applications that you would
%% like to target. (default `[]')</li>
%% <li>`supervisors' - A list of supervisors that you want to target.
%% Can be any valid supervisor reference. (defaults to all supervisors)</li>
%% <li>`killable_callback' - A `Fun' that gets called to decide if a `pid' or
%% `port' may be killed or not by returning `true' or `false'.</li>
%% <li>`prekill_callback' - A `Fun' that gets called just before killing.</li>
%% </ul>
%% @end
-spec on(list(term())) -> ok.
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
    Supervisor = proplists:get_bool(supervisor, Opts),
    Process =
        case proplists:lookup(process, Opts) of
            {process, Val} -> Val;
            none -> true
        end,
    Tcp = proplists:get_bool(tcp, Opts),
    Udp = proplists:get_bool(udp, Opts),
    Nodes = proplists:get_value(nodes, Opts, this),
    Applications = proplists:get_value(applications, Opts),
    OTPApplications = proplists:get_value(otp_applications, Opts, []),
    Supervisors = proplists:get_value(supervisors, Opts),
    KillableCallback = proplists:get_value(killable_callback, Opts, default_killable_callback()),
    PrekillCallback = proplists:get_value(prekill_callback, Opts, default_prekill_callback()),
    NewState = State#state{is_active = true, avg_wait = Wait,
                           deviation = Deviation, supervisor = Supervisor,
                           process = Process, tcp = Tcp,
                           udp = Udp, nodes = Nodes,
                           applications = Applications,
                           otp_applications = OTPApplications,
                           supervisors = Supervisors,
                           killable_callback = KillableCallback,
                           prekill_callback = PrekillCallback},
    self() ! kill_something,
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
-spec schedule(non_neg_integer(), number()) -> ok.
schedule(Wait, Deviation) ->
    case round(Wait * (1 + Deviation * (2 * rand:uniform() - 1))) of
        Delay when Delay > 0 -> erlang:send_after(Delay, self(), kill_something);
        _ -> self() ! kill_something
    end,
    ok.

-spec try_kill_one(#state{}) -> {ok, term()} | {error, nothing_to_kill}.
try_kill_one(State) ->
    case shuffle_nodes(State#state.nodes) of
        [] -> nil; % Nothing to do.
        [Node | _Rest] ->
            Processes = process_list(State#state.process, Node),
            Tcp = tcp_list(State#state.tcp, Node),
            Udp = udp_list(State#state.udp, Node),
            Shuffled = shuffle(Processes ++ Tcp ++ Udp),
            kill_one(Shuffled, State)
    end.

-spec shuffle_nodes(list(node()) | atom()) -> [node()].
shuffle_nodes(L) when is_list(L) ->
    shuffle(L);
shuffle_nodes(A) when is_atom(A) ->
    shuffle(nodes(A)).

-spec process_list(boolean(), node()) -> list(pid()).
process_list(true, Node) ->
    rpc:call(Node, erlang, processes, []);
process_list(false, _Node) ->
    [].

-spec tcp_list(boolean(), node()) -> list(port()).
tcp_list(true, Node) ->
    Ports = rpc:call(Node, erlang, ports, []),
    lists:filter(fun (Port) -> erlang:port_info(Port, name) =:= {name, ?TCP_NAME} end, Ports);
tcp_list(false, _Node) ->
    [].

-spec udp_list(boolean(), node()) -> list(port()).
udp_list(true, Node) ->
    Ports = rpc:call(Node, erlang, ports, []),
    lists:filter(fun (Port) -> erlang:port_info(Port, name) =:= {name, ?UDP_NAME} end, Ports);
udp_list(false, _Node) ->
    [].


-spec shuffle(list()) -> list().
shuffle(L) ->
    Shuffled = lists:sort([{rand:uniform(), X} || X <- L]),
    [X || {_, X} <- Shuffled].

-spec kill_one(list(pid()), #state{}) -> {ok, term()} | {error, nothing_to_kill}.
kill_one([], _State) -> {error, nothing_to_kill};
kill_one([H | T], State) ->
    case
        is_killable(H, State) andalso
        killable_callback(State#state.killable_callback, H)
    of
        true ->
            prekill_callback(State#state.prekill_callback, H),
            kill(H);
        false ->
            kill_one(T, State)
    end.

-spec killable_callback(fun((PidOrPort) -> Result), PidOrPort) -> Result
    when PidOrPort :: pid() | port(),
         Result :: boolean().
killable_callback(Fun, PidOrPort) when is_function(Fun, 1) ->
    Fun(PidOrPort).

-spec default_killable_callback() -> fun((pid() | port()) -> true).
default_killable_callback() -> fun(_X) -> true end.

-spec prekill_callback(fun((PidOrPort) -> any()), PidOrPort) -> ok
    when PidOrPort :: pid() | port().
prekill_callback(Fun, PidOrPort) when is_function(Fun, 1) ->
    Fun(PidOrPort),
    ok.

-spec default_prekill_callback() -> fun((pid() | port()) -> ok).
default_prekill_callback() -> fun(_X) -> ok end.

%% http://erlang.org/doc/apps/
-define(OTP_APPS, [asn1, common_test, compiler, crypto, debugger, dialyzer,
                   diameter, edoc, eldap, erl_docgen, erl_interface, erts, et,
                   eunit, ftp, hipe, inets, jinterface, kernel, megaco, mnesia,
                   observer, odbc, os_mon, otp_mibs, parsetools, public_key,
                   reltool, runtime_tools, sasl, snmp, ssh, ssl, stdlib,
                   syntax_tools, tftp, tools, wx, xmerl]).

-spec is_killable(pid() | port(), #state{}) -> boolean().
is_killable(Pid, State) when is_pid(Pid) ->
    App = case application:get_application(Pid) of
              {ok, A} -> A;
              undefined -> undefined
          end,

    Module = get_initial_call_module(Pid),

    not(erts_internal:is_system_process(Pid))
        andalso not(is_application_controller(Pid))
        andalso Module =/= application_master
        andalso not(lists:member(App, ?OTP_APPS -- State#state.otp_applications))
        andalso not(lists:member(App, [kernel, havoc]))
        andalso not(is_shell(Pid))
        andalso (Module =/= supervisor
            orelse State#state.supervisor
            andalso not(is_application_top_supervisor(Pid)))
        andalso app_killable(App, State#state.applications)
        andalso supervisor_killable(Pid, State#state.supervisors);
is_killable(Port, _State) when is_port(Port) ->
    true.

-spec app_killable(atom(), undefined | [atom()]) -> boolean().
app_killable(_App, undefined) ->
    true;
app_killable(App, Applications) ->
    lists:member(App, Applications).

-spec supervisor_killable(pid(), undefined | [supervisor:sup_ref()]) -> boolean().
supervisor_killable(_Pid, undefined) ->
    true;
supervisor_killable(Pid, Supervisors) ->
    lists:any(fun(Sup) ->
                  supervisor_killable1(Pid, supervisor:which_children(Sup))
              end, Supervisors).

supervisor_killable1(_, []) ->
    false;
supervisor_killable1(Pid, [{_, Pid, _, _}|_]) ->
    true;
supervisor_killable1(Pid, [{_, SupPid, supervisor, _}|Children]) ->
    supervisor_killable1(Pid, Children ++ supervisor:which_children(SupPid));
supervisor_killable1(Pid, [_|Children]) ->
    supervisor_killable1(Pid, Children).

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
    {connected, Pid} = erlang:port_info(Port, connected),
    {ok, [{active, Active}]} = inet:getopts(Port, [active]),
    Msg = case erlang:port_info(Port, name) of
        {name, ?TCP_NAME} ->
            gen_tcp:close(Port),
            {tcp_closed, Port};
        {name, ?UDP_NAME} ->
            gen_udp:close(Port),
            {udp_closed, Port}
    end,
    if Active /= false ->
            Pid ! Msg
    end,
    ok.

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

-spec get_initial_call_module(pid()) -> module() | undefined.
get_initial_call_module(Pid) ->
    case erlang:process_info(Pid, initial_call) of
        {initial_call, {proc_lib, init_p, 5}} ->
            {Module, _, _} = proc_lib:translate_initial_call(Pid),
            Module;
        {initial_call, {Module, _, _}} ->
            Module;
        _ ->
            undefined
    end.

-spec is_application_top_supervisor(pid()) -> boolean().
is_application_top_supervisor(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dict} ->
            case lists:keyfind('$ancestors', 1, Dict) of
                {'$ancestors', [Ancestor]} when is_pid(Ancestor) ->
                    application_master =:= get_initial_call_module(Ancestor);
                _ ->
                    false
            end;
        _ ->
            false
    end.

-spec is_application_controller(pid()) -> boolean().
is_application_controller(Pid) ->
    Pid =:= whereis(application_controller).
