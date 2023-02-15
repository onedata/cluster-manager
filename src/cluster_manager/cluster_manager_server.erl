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

-include("node_management_protocol.hrl").
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
    current_step = init_connection :: cluster_init_step(),
    nodes_ready_in_step = [] :: [Node :: node()],
    in_progress_nodes = [] :: [Node :: node()],
    singleton_modules = [] :: [{Module :: atom(), Node :: node() | undefined}],
    node_states = [] :: [{Node :: node(), NodeState :: #node_state{}}],
    last_heartbeat = [] :: [{Node :: node(), Timestamp :: integer()}],
    lb_state = undefined :: load_balancing:load_balancing_state() | undefined,
    pending_recovery_acknowledgements = #{} :: pending_recovery_acknowledgements()
}).


-type state() :: #state{}.
-type cluster_init_step() :: ?INIT_CONNECTION | ?START_DEFAULT_WORKERS | ?PREPARE_FOR_UPGRADE
| ?UPGRADE_CLUSTER | ?START_CUSTOM_WORKERS | ?START_LISTENERS | ?CLUSTER_READY.
% stores information which nodes are yet to acknowledge a recovered node
-type pending_recovery_acknowledgements() :: #{node() => [node()]}.

-export_type([cluster_init_step/0]).

-define(STEP_TIMEOUT(Step),
    application:get_env(?APP_NAME, list_to_atom(atom_to_list(Step)++"_step_timeout"), timer:seconds(120))).
-define(KEY_ASSOCIATED_NODES, application:get_env(?APP_NAME, key_associated_nodes, 1)).

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
    State :: state(),
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
    State :: state()) -> Result when
    Result :: {reply, Reply, NewState}
    | {reply, Reply, NewState, Timeout}
    | {reply, Reply, NewState, hibernate}
    | {noreply, NewState}
    | {noreply, NewState, Timeout}
    | {noreply, NewState, hibernate}
    | {stop, Reason, Reply, NewState}
    | {stop, Reason, NewState},
    Reply :: term(),
    NewState :: state(),
    Timeout :: non_neg_integer() | infinity,
    Reason :: term().
handle_call(get_nodes, _From, #state{current_step = init_connection} = State) ->
    {reply, {error, cluster_not_initialized}, State};
handle_call(get_nodes, _From, State) ->
    {reply, {ok, get_all_nodes(State)}, State};

handle_call(get_current_time, _From, State) ->
    {reply, global_clock:timestamp_millis(), State};

handle_call(cluster_status, From, #state{current_step = cluster_ready} = State) ->
    % Spawn as getting cluster status could block cluster_manager
    % (procedure involves calls to all node_managers)
    spawn(fun() ->
        gen_server:reply(From, cluster_status:get_cluster_status(get_all_nodes(State)))
    end),
    {noreply, State};
handle_call(cluster_status, _From, State) ->
    {reply, {error, cluster_not_ready}, State};

handle_call(get_avg_mem_usage, _From, #state{node_states = NodeStates} = State) ->
    MemSum = lists:foldl(fun({_Node, NodeState}, Sum) ->
        Sum + NodeState#node_state.mem_usage
    end, 0, NodeStates),
    {reply, MemSum / max(1, length(NodeStates)), State};

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
-spec handle_cast(Request :: term(), State :: state()) -> Result when
    Result :: {noreply, NewState}
    | {noreply, NewState, Timeout}
    | {noreply, NewState, hibernate}
    | {stop, Reason :: term(), NewState},
    NewState :: state(),
    Timeout :: non_neg_integer() | infinity.
handle_cast({cm_conn_req, Node}, State) ->
    NewState = cm_conn_req(State, Node),
    {noreply, NewState};

handle_cast({cluster_init_step_report, Node, Step, success}, #state{current_step = Step} = State) ->
    NewState = mark_cluster_init_step_finished_for_node(Node, State),
    {noreply, NewState};

handle_cast({cluster_init_step_report, Node, Step, failure}, #state{current_step = Step} = State) ->
    NewState = handle_error(State, Node),
    {noreply, NewState};

handle_cast({cluster_init_step_report, Node, Step, Result}, State) ->
    ?error("Unexpected cluster_init_step_report (~w ~w ~w) while in state ~p", [
        Node, Step, Result, State
    ]),
    {noreply, State};

handle_cast(next_step, State) ->
    NewState = proceed_to_next_step(State),
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

handle_cast(?RECOVERY_INITIALIZED(Node), State) ->
    {noreply, handle_node_recovery_initialized(Node, State)};

handle_cast(?RECOVERY_ACKNOWLEDGED(AcknowledgingNode, RecoveredNode), State) ->
    {noreply, handle_recovery_ack(AcknowledgingNode, RecoveredNode, State)};

handle_cast(?RECOVERY_FINALIZED(Node), State) ->
    handle_node_recovery_finish(Node, State),
    {noreply, State};

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
-spec handle_info(Info :: timeout | term(), State :: state()) -> Result when
    Result :: {noreply, NewState}
    | {noreply, NewState, Timeout}
    | {noreply, NewState, hibernate}
    | {stop, Reason :: term(), NewState},
    NewState :: state(),
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
-spec terminate(Reason, State :: state()) -> Any :: term() when
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
-spec code_change(OldVsn, State :: state(), Extra :: term()) -> Result when
    Result :: {ok, NewState :: state()} | {error, Reason :: term()},
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
    erlang:monitor_node(SenderNode, true),
    case lists:member(SenderNode, get_all_nodes(State)) of
        true ->
            init_node_recovery(SenderNode),
            State;
        false ->
            ?info("New node: ~p", [SenderNode]),
            try
                NewInProgressNodes = add_node_to_list(SenderNode, InProgressNodes),
                gen_server:cast({?NODE_MANAGER_NAME, SenderNode}, ?INIT_STEP_MSG(?INIT_CONNECTION)),
                State#state{in_progress_nodes = NewInProgressNodes}
            catch
                Class:Reason:Stacktrace ->
                    ?warning_exception(
                        "Checking node ~p in cm failed", [SenderNode],
                        Class, Reason, Stacktrace
                    ),
                    State
            end
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Marks given node ready in given step. Informs cluster manager
%% when all nodes are ready to proceed to next step.
%% @end
%%--------------------------------------------------------------------
-spec mark_cluster_init_step_finished_for_node(node(), state()) -> state().
mark_cluster_init_step_finished_for_node(Node, State) ->
    #state{
        nodes_ready_in_step = ReadyNodes,
        in_progress_nodes = InProgressNodes,
        current_step = Step
    } = State,
    NewState = State#state{
        nodes_ready_in_step = add_node_to_list(Node, ReadyNodes),
        in_progress_nodes = lists:delete(Node, InProgressNodes)
    },
    case is_cluster_ready_in_step(NewState) of
        true ->
            ?info("Cluster init step '~s' complete", [Step]),
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
-spec proceed_to_next_step(state()) -> state().
proceed_to_next_step(#state{nodes_ready_in_step = Nodes, current_step = init_connection} = State) ->
    create_hash_ring(Nodes),
    proceed_to_next_step_common(State);
proceed_to_next_step(State) ->
    proceed_to_next_step_common(State).


%% @private
-spec proceed_to_next_step_common(state()) -> state().
proceed_to_next_step_common(#state{nodes_ready_in_step = Nodes, current_step = CurrentStep} = State) ->
    NextStep = get_next_step(CurrentStep),
    ?info("Starting new step: ~p", [NextStep]),

    gen_server:cast(self(), {check_step_finished, NextStep, ?STEP_TIMEOUT(NextStep) div 1000}),
    case NextStep of
        ?CLUSTER_READY ->
            State#state{current_step = NextStep};
        _ ->
            send_to_nodes(Nodes, ?INIT_STEP_MSG(NextStep)),
            State#state{nodes_ready_in_step = [], in_progress_nodes = Nodes, current_step = NextStep}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handles error on one of cluster's nodes.
%% @end
%%--------------------------------------------------------------------
-spec handle_error(state(), node()) -> state().
handle_error(#state{current_step = Step} = State, Node) ->
    force_stop_cluster(State, "Cluster init failure - error in step '~w' on node ~w", [Step, Node]).


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
    force_stop_cluster(State, "Cluster init failure - timeout in step '~w' on nodes: ~w", [Step, Nodes]);
check_step_finished(?CLUSTER_READY, State, Timeout) ->
    case cluster_status:get_cluster_status(get_all_nodes(State), cluster_manager_connection) of
        {ok, {ok, _NodeStatuses}} ->
            ?info("Cluster ready"),
            send_to_nodes(get_all_nodes(State), ?INIT_STEP_MSG(?CLUSTER_READY)),
            State;
        {ok, {GenericError, NodeStatuses}}  ->
            ?debug("Internal healthcheck failed: ~p", [{GenericError, NodeStatuses}]),
            erlang:send_after(timer:seconds(1), self(), {timer, {check_step_finished, ?CLUSTER_READY, Timeout - 1}}),
            State;
        Error ->
            force_stop_cluster(State, "Internal healthcheck failed: ~p", [Error])
    end;

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
    consistent_hashing:init(lists:usort(Nodes), ?KEY_ASSOCIATED_NODES),
    ?info("Hash ring initialized successfully.").


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Receive heartbeat from a node manager and store its state.
%% @end
%%--------------------------------------------------------------------
-spec heartbeat(State :: state(), NodeState :: #node_state{}) -> state().
heartbeat(#state{node_states = NodeStates, last_heartbeat = LastHeartbeat} = State, NodeState) ->
    #node_state{node = Node} = NodeState,
    ?debug("Heartbeat from node ~p", [Node]),
    NewNodeStates = [{Node, NodeState} | proplists:delete(Node, NodeStates)],
    NewLastHeartbeat = [{Node, global_clock:timestamp_millis()} | proplists:delete(Node, LastHeartbeat)],
    State#state{node_states = NewNodeStates, last_heartbeat = NewLastHeartbeat}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Calculate current load balancing advices, broadcast them and schedule next update.
%% @end
%%--------------------------------------------------------------------
-spec update_advices(State :: state()) -> state().
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
            Now = global_clock:timestamp_millis(),
            % Check which node managers are late with heartbeat ( > 2 * monitoring interval).
            % Assume full CPU usage on them.
            PrecheckedNodeStates = lists:map(
                fun(#node_state{node = Node} = NodeState) ->
                    LastHeartbeat = (Now -
                        proplists:get_value(Node, LastHeartbeats, global_clock:timestamp_millis())),
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
                    gen_server:cast({?NODE_MANAGER_NAME, Node}, ?UPDATE_LB_ADVICES(AdviceForDispatchers))
                end, AdvicesForDispatchers),
            State#state{lb_state = NewState}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Checks if singleton module can be started.
%% @end
%%--------------------------------------------------------------------
-spec register_singleton_module(Module :: atom(), Node :: node(), State :: state()) ->
    {ok | already_started, state()}.
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
-spec node_down(Node :: atom(), State :: state()) -> state().
node_down(Node, State) ->
    case consistent_hashing:get_nodes_assigned_per_label() of
        1 ->
            force_stop_cluster(State, "Node down: ~p. Stopping cluster", [Node]);
        _ ->
            ?error("Node down: ~p", [Node]),
            ok = consistent_hashing:report_node_failure(Node),
            send_to_nodes(get_all_nodes(State) -- [Node], ?NODE_DOWN(Node)),
            State
    end.

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
-spec is_cluster_ready_in_step(state()) -> boolean().
is_cluster_ready_in_step(#state{nodes_ready_in_step = Nodes}) ->
    get_worker_num() == length(Nodes).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get all connected nodes
%% @end
%%--------------------------------------------------------------------
-spec get_all_nodes(state()) -> [node()].
get_all_nodes(#state{nodes_ready_in_step = Nodes, in_progress_nodes = InProgressNodes}) ->
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


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Force stops all nodes in the cluster with given readable reason.
%% The cluster manager is not stopped and its state is reset.
%% @end
%%--------------------------------------------------------------------
-spec force_stop_cluster(state(), string(), list()) -> state().
force_stop_cluster(State, ReasonFormatString, ReasonFormatArgs) ->
    ReasonMsg = str_utils:format(ReasonFormatString, ReasonFormatArgs),
    ?critical(ReasonMsg),
    ?critical("Force stopping cluster..."),
    send_to_nodes(get_all_nodes(State), ?FORCE_STOP(ReasonMsg)),
    consistent_hashing:cleanup(),
    #state{nodes_ready_in_step = [], in_progress_nodes = []}.



%% @private
-spec get_next_step(cluster_init_step()) -> cluster_init_step().
get_next_step(?INIT_CONNECTION) -> ?START_DEFAULT_WORKERS;
get_next_step(?START_DEFAULT_WORKERS) -> ?PREPARE_FOR_UPGRADE;
get_next_step(?PREPARE_FOR_UPGRADE) -> ?UPGRADE_CLUSTER;
get_next_step(?UPGRADE_CLUSTER) -> ?START_CUSTOM_WORKERS;
get_next_step(?START_CUSTOM_WORKERS) -> ?START_LISTENERS;
get_next_step(?START_LISTENERS) -> ?CLUSTER_READY.

%%%===================================================================
%%% Node recovery handling
%%%===================================================================

-spec init_node_recovery(node()) -> ok.
init_node_recovery(Node) ->
    ok = consistent_hashing:report_node_recovery(Node),
    ok = consistent_hashing:replicate_ring_to_nodes([Node]),
    gen_server:cast({?NODE_MANAGER_NAME, Node}, ?INITIALIZE_RECOVERY),
    ?info("Recovery initialized on node: ~p", [Node]),
    ok.

-spec handle_node_recovery_initialized(node(), state()) -> state().
handle_node_recovery_initialized(Node, #state{pending_recovery_acknowledgements = AcknowledgementsMap} = State) ->
    OtherNodes = get_all_nodes(State) -- [Node],
    send_to_nodes(OtherNodes, ?NODE_UP(Node)),
    State#state{pending_recovery_acknowledgements = AcknowledgementsMap#{Node => OtherNodes}}.

-spec handle_recovery_ack(node(), node(), state()) -> state().
handle_recovery_ack(AcknowledgingNode, RecoveredNode,
    #state{pending_recovery_acknowledgements = AcknowledgementsMap} = State) ->
    PendingNodes = maps:get(RecoveredNode, AcknowledgementsMap, []),
    case lists:delete(AcknowledgingNode, PendingNodes) of
        [] ->
            gen_server:cast({?NODE_MANAGER_NAME, RecoveredNode}, ?FINALIZE_RECOVERY),
            State#state{pending_recovery_acknowledgements = maps:remove(RecoveredNode, AcknowledgementsMap)};
        StillPendingNodes ->
            State#state{pending_recovery_acknowledgements = AcknowledgementsMap#{RecoveredNode => StillPendingNodes}}
    end.

-spec handle_node_recovery_finish(node(), state()) -> ok.
handle_node_recovery_finish(Node, State) ->
    send_to_nodes(get_all_nodes(State) -- [Node], ?NODE_READY(Node)).