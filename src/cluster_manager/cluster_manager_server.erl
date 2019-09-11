%%%-------------------------------------------------------------------
%%% @author Michal Wrzeszcz
%%% @author Tomasz Lichon
%%% @copyright (C) 2013 ACK CYFRONET AGH
%%% This software is released under the MIT license
%%% cited in 'LICENSE.txt'.
%%% @end
%%%-------------------------------------------------------------------
%%% @doc
%%% This module coordinates central cluster.
%%% Cluster initialization is divided into steps. For each step cluster
%%% manager waits for all nodes to be ready before informing node managers
%%% to move to the next one.
%%% @end
%%%-------------------------------------------------------------------
-module(cluster_manager_server).
-author("Michal Wrzeszcz").
-author("Tomasz Lichon").

-behaviour(gen_server).

-include("global_definitions.hrl").
-include_lib("ctool/include/logging.hrl").
-include_lib("ctool/include/monitoring/monitoring.hrl").
-include_lib("ctool/include/global_definitions.hrl").

%% API
-export([start_link/0, stop/0]).

%% gen_event callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

%% This record is used by cm (it contains its state). It describes
%% nodes, dispatchers and workers in cluster. It also contains reference
%% to process used to monitor if nodes are alive.
-record(state, {
    current_step = init :: cluster_init_step(),
    ready_nodes = [] :: [Node :: node()],
    in_progress_nodes = [] :: [Node :: node()],
    singleton_modules = [] :: [{Module :: atom(), Node :: node() | undefined}],
    node_states = [] :: [{Node :: node(), NodeState :: #node_state{}}],
    last_heartbeat = [] :: [{Node :: node(), Timestamp :: integer()}],
    lb_state = undefined :: load_balancing:load_balancing_state() | undefined
}).


-type state() :: #state{}.
-type cluster_init_step() :: init | start_default_workers | start_custom_workers
| upgrade_cluster | start_listeners | ready.

-export_type([cluster_init_step/0]).

-define(STEP_TIMEOUT(Step),
    application:get_env(?APP_NAME, list_to_atom(atom_to_list(Step)++"_step_timeout"), timer:seconds(10))).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts cluster manager
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> Result when
    Result :: {ok, Pid}
    | ignore
    | {error, Error},
    Pid :: pid(),
    Error :: {already_started, Pid} | term().
start_link() ->
    case gen_server:start_link(?MODULE, [], []) of
        {ok, Pid} ->
            global:re_register_name(?CLUSTER_MANAGER, Pid),
            {ok, Pid};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% Stops the server
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok.
stop() ->
    gen_server:cast(self(), stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> Result when
    Result :: {ok, State}
    | {ok, State, Timeout}
    | {ok, State, hibernate}
    | {stop, Reason :: term()}
    | ignore,
    State :: term(),
    Timeout :: non_neg_integer() | infinity.
init(_) ->
    process_flag(trap_exit, true),
    gen_server:cast(self(), update_advices),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: term()) -> Result when
    Result :: {reply, Reply, NewState}
    | {reply, Reply, NewState, Timeout}
    | {reply, Reply, NewState, hibernate}
    | {noreply, NewState}
    | {noreply, NewState, Timeout}
    | {noreply, NewState, hibernate}
    | {stop, Reason, Reply, NewState}
    | {stop, Reason, NewState},
    Reply :: term(),
    NewState :: term(),
    Timeout :: non_neg_integer() | infinity,
    Reason :: term().
handle_call(get_nodes, _From, #state{current_step = Step, ready_nodes = Nodes} = State) ->
    Response = case Step of
        ready -> {ok, Nodes};
        _ -> {error, cluster_not_ready}
    end,
    {reply, Response, State};

handle_call(get_current_time, _From, State) ->
    {reply, time_utils:system_time_millis(), State};

handle_call(cluster_status, _From, #state{current_step = Step} = State) ->
    Response = case Step of
        ready -> cluster_status:get_cluster_status(get_all_nodes(State));
        _ -> {error, cluster_not_ready}
    end,
    {reply, Response, State};

handle_call(get_avg_mem_usage, _From, #state{node_states = NodeStates} = State) ->
    MemSum = lists:foldl(fun({_Node, NodeState}, Sum) ->
        Sum + NodeState#node_state.mem_usage
    end, 0, NodeStates),
    {reply, MemSum/max(1, length(NodeStates)), State};

handle_call({register_singleton_module, Module, Node}, _From, State) ->
    {Ans, NewState} = register_singleton_module(Module, Node, State),
    {reply, Ans, NewState};

handle_call(_Request, _From, State) ->
    ?log_bad_request(_Request),
    {reply, wrong_request, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) -> Result when
    Result :: {noreply, NewState}
    | {noreply, NewState, Timeout}
    | {noreply, NewState, hibernate}
    | {stop, Reason :: term(), NewState},
    NewState :: term(),
    Timeout :: non_neg_integer() | infinity.
handle_cast({cm_conn_req, Node}, State) ->
    NewState = cm_conn_req(State, Node),
    {noreply, NewState};

handle_cast({Step, Node}, #state{current_step = Step} = State) ->
    NewState = mark_cluster_init_step_finished_for_node(Node, State),
    {noreply, NewState};

handle_cast({cluster_init_step_failure, Node}, State) ->
    NewState = handle_error(State, Node),
    {noreply, NewState};

handle_cast(next_step, State) ->
    NewState = handle_next_step(State),
    {noreply, NewState};

handle_cast({heartbeat, NodeState}, State) ->
    NewState = heartbeat(State, NodeState),
    {noreply, NewState};

handle_cast(update_advices, State) ->
    NewState = update_advices(State),
    {noreply, NewState};

handle_cast({check_step_finished, Step, Timeout}, State) ->
    NewState = check_step_finished(Step, State, Timeout),
    {noreply, NewState};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Request, State) ->
    ?log_bad_request(_Request),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout | term(), State :: term()) -> Result when
    Result :: {noreply, NewState}
    | {noreply, NewState, Timeout}
    | {noreply, NewState, hibernate}
    | {stop, Reason :: term(), NewState},
    NewState :: term(),
    Timeout :: non_neg_integer() | infinity.
handle_info({timer, Msg}, State) ->
    gen_server:cast(self(), Msg),
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    NewState = node_down(Node, State),
    {noreply, NewState};

handle_info(_Request, State) ->
    ?log_bad_request(_Request),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason, State :: term()) -> Any :: term() when
    Reason :: normal
    | shutdown
    | {shutdown, term()}
    | term().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn, State :: term(), Extra :: term()) -> Result when
    Result :: {ok, NewState :: term()} | {error, Reason :: term()},
    OldVsn :: Vsn | {down, Vsn},
    Vsn :: term().
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Receive connection request from node_manager
%% @end
%%--------------------------------------------------------------------
-spec cm_conn_req(State :: state(), SenderNode :: node()) -> NewState :: state().
cm_conn_req(State = #state{in_progress_nodes = InProgressNodes}, SenderNode) ->
    ?info("Connection request from node: ~p", [SenderNode]),
    case lists:member(SenderNode, get_all_nodes(State)) of
        true ->
            State;
        false ->
            ?info("New node: ~p", [SenderNode]),
            try
                erlang:monitor_node(SenderNode, true),
                NewInProgressNodes = add_node_to_list(SenderNode, InProgressNodes),
                gen_server:cast({?NODE_MANAGER_NAME, SenderNode}, {cluster_init_step, init}),
                State#state{in_progress_nodes = NewInProgressNodes}
            catch
                _:Error ->
                    ?warning_stacktrace("Checking node ~p, in cm failed with error: ~p",
                        [SenderNode, Error]),
                    State
            end
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Marks given node finished in given step. Informs cluster manager
%% when all nodes are ready to go to next step.
%% @end
%%--------------------------------------------------------------------
-spec mark_cluster_init_step_finished_for_node(node(), state()) -> state().
mark_cluster_init_step_finished_for_node(Node, State) ->
    #state{
        ready_nodes = ReadyNodes,
        in_progress_nodes = InProgressNodes,
        current_step = Step
    } = State,
    NewState = State#state{
        ready_nodes = add_node_to_list(Node, ReadyNodes),
        in_progress_nodes = lists:delete(Node, InProgressNodes)
    },
    case is_cluster_ready_in_step(NewState) of
        true ->
            ?info("Cluster init step '~p' complete", [Step]),
            gen_server:cast(self(), next_step),
            NewState;
        false ->
            NewState
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Moves cluster to next step. Informs all cluster nodes.
%% @end
%%--------------------------------------------------------------------
-spec handle_next_step(state()) -> state().
handle_next_step(#state{ready_nodes = Nodes, current_step = start_default_workers} = State) ->
    create_hash_ring(Nodes),
    handle_next_step_internal(State);
handle_next_step(State) ->
    handle_next_step_internal(State).


%% @private
-spec handle_next_step_internal(state()) -> state().
handle_next_step_internal(#state{ready_nodes = Nodes, current_step = CurrentStep} = State) ->
    NextStep = get_next_step(CurrentStep),
    ?info("Starting new step: ~p", [NextStep]),

    gen_server:cast(self(), {check_step_finished, NextStep, ?STEP_TIMEOUT(NextStep) div 1000}),
    case NextStep of
        ready -> State#state{current_step = NextStep};
        _ ->
            send_to_nodes(Nodes, {cluster_init_step, NextStep}),
            State#state{ready_nodes = [], in_progress_nodes = Nodes, current_step = NextStep}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handles error on one of cluster's nodes.
%% @end
%%--------------------------------------------------------------------
-spec handle_error(state(), node()) -> state().
handle_error(#state{current_step = Step} = State, Node) ->
    ?critical("Cluster init failure on node ~p, step '~p'. Stopping cluster.", [Node, Step]),
    send_to_nodes(get_all_nodes(State), force_stop),
    #state{}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Checks whether given step is finished.
%% Stops all cluster nodes when cluster initialization is not finished in given step.
%% In ready step checks cluster status.
%% @end
%%--------------------------------------------------------------------
-spec check_step_finished(cluster_init_step(), state(), Timeout :: non_neg_integer()) -> state().
check_step_finished(Step, #state{in_progress_nodes = Nodes} = State, 0) ->
    ?critical("Cluster init failure - timeout during step '~p'. Stopping cluster. Offending nodes: ~p", [Step, Nodes]),
    send_to_nodes(get_all_nodes(State), force_stop),
    #state{};
check_step_finished(ready, State, Timeout) ->
    case cluster_status:get_cluster_status(get_all_nodes(State), cluster_manager_connection) of
        {ok, {ok, _NodeStatuses}} ->
            ?info("Cluster ready"),
            send_to_nodes(get_all_nodes(State), {cluster_init_step, ready});
        {ok, {GenericError, NodeStatuses}}  ->
            ?debug("Internal healthcheck failed: ~p", [{GenericError, NodeStatuses}]),
            erlang:send_after(timer:seconds(1), self(), {timer, {check_step_finished, ready, Timeout-1}});
        Error ->
            ?error("Internal healthcheck failed: ~p", [Error]),
            gen_server:cast(self(), cluster_init_step_failure)
    end,
    State;

check_step_finished(Step, #state{current_step = Step} = State, Timeout) ->
    case is_cluster_ready_in_step(State) of
        true -> State;
        false ->
            erlang:send_after(timer:seconds(1), self(),
                {timer, {check_step_finished, Step, Timeout - 1}}),
            State
    end;
check_step_finished(Step, #state{current_step = CurrentStep} = State, _Timeout)
    when Step =/= CurrentStep ->
    % Cluster already in next step
    State.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Creates hash ring if all cluster nodes have been successfully initialized.
%% @end
%%--------------------------------------------------------------------
-spec create_hash_ring([node()]) -> ok.
create_hash_ring(Nodes) ->
    ?info("Initializing Hash Ring."),
    consistent_hashing:init(lists:usort(Nodes)),
    CHash = consistent_hashing:get_chash_ring(),
    lists:foreach(fun(Node) ->
        rpc:call(Node, consistent_hashing, set_chash_ring, [CHash])
    end, Nodes),
    ?info("Hash ring initialized successfully.").


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Receive heartbeat from a node manager and store its state.
%% @end
%%--------------------------------------------------------------------
-spec heartbeat(State :: #state{}, NodeState :: #node_state{}) -> #state{}.
heartbeat(#state{node_states = NodeStates, last_heartbeat = LastHeartbeat} = State, NodeState) ->
    #node_state{node = Node} = NodeState,
    ?debug("Heartbeat from node ~p", [Node]),
    NewNodeStates = [{Node, NodeState} | proplists:delete(Node, NodeStates)],
    NewLastHeartbeat = [{Node, erlang:monotonic_time(milli_seconds)} | proplists:delete(Node, LastHeartbeat)],
    State#state{node_states = NewNodeStates, last_heartbeat = NewLastHeartbeat}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Calculate current load balancing advices, broadcast them and schedule next update.
%% @end
%%--------------------------------------------------------------------
-spec update_advices(State :: #state{}) -> #state{}.
update_advices(#state{node_states = NodeStatesMap, last_heartbeat = LastHeartbeats, lb_state = LBState,
    singleton_modules = Singletons} = State) ->
    ?debug("Updating load balancing advices"),
    {ok, Interval} = application:get_env(?APP_NAME, lb_advices_update_interval),
    erlang:send_after(Interval, self(), {timer, update_advices}),
    case NodeStatesMap of
        [] ->
            State;
        _ ->
            {_, NodeStates} = lists:unzip(NodeStatesMap),
            Now = erlang:monotonic_time(milli_seconds),
            % Check which node managers are late with heartbeat ( > 2 * monitoring interval).
            % Assume full CPU usage on them.
            PrecheckedNodeStates = lists:map(
                fun(#node_state{node = Node} = NodeState) ->
                    LastHeartbeat = (Now -
                        proplists:get_value(Node, LastHeartbeats, erlang:monotonic_time(milli_seconds))),
                    case LastHeartbeat > 2 * Interval of
                        true -> NodeState#node_state{cpu_usage = 100.0};
                        false -> NodeState
                    end
                end, NodeStates),
            {AdvicesForDispatchers, NewState} =
                load_balancing:advices_for_dispatchers(PrecheckedNodeStates, LBState, Singletons),
            % Send LB advices
            lists:foreach(
                fun({Node, AdviceForDispatchers}) ->
                    gen_server:cast({?NODE_MANAGER_NAME, Node}, {update_lb_advices, AdviceForDispatchers})
                end, AdvicesForDispatchers),
            State#state{lb_state = NewState}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Checks if singleton module can be started.
%% @end
%%--------------------------------------------------------------------
-spec register_singleton_module(Module :: atom(), Node :: node(), State :: #state{}) ->
    {ok | already_started, #state{}}.
register_singleton_module(Module, Node, #state{singleton_modules = Singletons} = State) ->
    UsedNode = proplists:get_value(Module, Singletons),
    case UsedNode of
        Node ->
            {ok, State};
        undefined ->
            NewSingletons = [{Module, Node} | proplists:delete(Module, Singletons)],
            {ok, State#state{singleton_modules = NewSingletons}};
        _ ->
            {already_started, State}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Delete node from active nodes list, change state num and inform everone
%% @end
%%--------------------------------------------------------------------
-spec node_down(Node :: atom(), State :: #state{}) -> #state{}.
node_down(Node, State) ->
    #state{ready_nodes = Nodes,
        in_progress_nodes = InProgressNodes,
        node_states = NodeStates,
        singleton_modules = Singletons
    } = State,
    ?error("Node down: ~p", [Node]),
    NewNodes = Nodes -- [Node],
    NewInProgressNodes = InProgressNodes -- [Node],
    NewNodeStates = proplists:delete(Node, NodeStates),
    NewSingletons = lists:map(fun({M, N}) ->
        case N of
            Node -> {M, undefined};
            _ -> {M, N}
        end
    end, Singletons),
    State#state{ready_nodes = NewNodes,
        in_progress_nodes = NewInProgressNodes,
        node_states = NewNodeStates,
        singleton_modules = NewSingletons
    }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add node to list if it's not there
%% @end
%%--------------------------------------------------------------------
-spec add_node_to_list(node(), [node()]) -> [node()].
add_node_to_list(Node, List) ->
    case lists:member(Node, List) of
        true -> List;
        false -> List ++ [Node]
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get number of workers in cluster
%% @end
%%--------------------------------------------------------------------
-spec get_worker_num() -> non_neg_integer().
get_worker_num() ->
    case application:get_env(?APP_NAME, worker_num) of
        {ok, N} when is_integer(N) ->
            N;
        _ ->
            exit(<<"The 'worker_num' env variable of cluster_manager ",
                "application is undefined. Refusing to initialize cluster.">>)
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check if number of ready nodes is correct (matches configured).
%% @end
%%--------------------------------------------------------------------
-spec is_cluster_ready_in_step(#state{}) -> boolean().
is_cluster_ready_in_step(#state{ready_nodes = Nodes}) ->
    get_worker_num() == length(Nodes).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get all connected nodes
%% @end
%%--------------------------------------------------------------------
-spec get_all_nodes(#state{}) -> [node()].
get_all_nodes(#state{ready_nodes = Nodes, in_progress_nodes = InProgressNodes}) ->
    lists:usort(Nodes ++ InProgressNodes).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Sends given message to node manager on all given nodes.
%% @end
%%--------------------------------------------------------------------
-spec send_to_nodes([node()], any()) -> ok.
send_to_nodes(Nodes, Msg) ->
    lists:foreach(fun(Node) ->
        gen_server:cast({?NODE_MANAGER_NAME, Node}, Msg)
    end, Nodes).


%% @private
-spec get_next_step(cluster_init_step()) -> cluster_init_step().
get_next_step(init) -> start_default_workers;
get_next_step(start_default_workers) -> start_custom_workers;
get_next_step(start_custom_workers) -> upgrade_cluster;
get_next_step(upgrade_cluster) -> start_listeners;
get_next_step(start_listeners) -> ready.
