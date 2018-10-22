%%%-------------------------------------------------------------------
%% @doc havoc
%% @end
%%%-------------------------------------------------------------------

-module(havoc).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([on/0]).

%% GenServer callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-record(state, {is_active = false,
                avg_wait
               }).

-define(DEFAULT_OPTS, [{avg_wait, 5000}]).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, ok, []).

on() ->
    gen_server:call(havoc, {on, []}).

%%====================================================================
%% GenServer callbacks
%%====================================================================

init(ok) ->
    {ok, #state{}}.

handle_call({on, Opts}, _From, #state{is_active = false} = State) ->
    Wait = proplists:get_value(avg_wait, Opts, 5000),
    NewState = State#state{is_active = true, avg_wait = Wait},
    schedule(Wait),
    {reply, ok, NewState};
handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(kill_something, #state{is_active = true} = State) ->
    try_kill_one(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal functions
%%====================================================================
-spec schedule(non_neg_integer()) -> reference().
schedule(Wait) ->
    erlang:send_after(Wait, self(), kill_something).

try_kill_one() ->
    Processes = shuffle(erlang:processes()),
    kill_one(Processes).

-spec shuffle(list()) -> list().
shuffle(L) ->
    Shuffled = lists:sort([{rand:uniform(), X} || X <- L]),
    [X || {_, X} <- Shuffled].

kill_one([]) -> {error, nothing_to_kill};
kill_one([Pid | T]) ->
    App = case application:get_application(Pid) of
              {ok, A} -> A;
              undefined -> undefined
          end,
    case is_killable(Pid, App) of
        true ->
            kill(Pid);
        false ->
            kill_one(T)
    end.

-spec is_killable(pid(), atom()) -> boolean().
is_killable(Pid, App) ->
    not(erts_internal:is_system_process(Pid))
        andalso not(lists:member(App, [kernel, havoc])).

kill(Pid) ->
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
    end.
