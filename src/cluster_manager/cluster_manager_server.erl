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
    nodes = [] :: [Node :: node()],
    uninitialized_nodes = [] :: [Node :: node()],
    singleton_modules = [] :: [{Module :: atom(), Node :: node() | undefined}],
    node_states = [] :: [{Node :: node(), NodeState :: #node_state{}}],
    last_heartbeat = [] :: [{Node :: node(), Timestamp :: integer()}],
    lb_state = undefined :: load_balancing:load_balancing_state() | undefined
}).

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
    gen_server:cast({global, ?CLUSTER_MANAGER}, stop).

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
%% ====================================================================
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
handle_call(get_nodes, _From, #state{nodes = Nodes} = State) ->
    Response = case is_cluster_ready(State) of
        true -> {ok, Nodes};
        false -> {error, cluster_not_ready}
    end,
    {reply, Response, State};
handle_call(get_current_time, _From, State) ->
    {reply, time_utils:system_time_millis(), State};
handle_call(get_node_to_sync, _From, State) ->
    Ans = get_node_to_sync(State),
    {reply, Ans, State};
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
handle_cast({init_ok, Node}, State) ->
    NewState = init_ok(State, Node),
    {noreply, NewState};
handle_cast({heartbeat, NodeState}, State) ->
    NewState = heartbeat(State, NodeState),
    {noreply, NewState};
handle_cast(update_advices, State) ->
    NewState = update_advices(State),
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
    gen_server:cast({global, ?CLUSTER_MANAGER}, Msg),
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
%% Receive heartbeat from node_manager
%% @end
%%--------------------------------------------------------------------
-spec cm_conn_req(State :: #state{}, SenderNode :: node()) -> NewState :: #state{}.
cm_conn_req(State = #state{uninitialized_nodes = InitNodes}, SenderNode) ->
    ?info("Connection request from node: ~p", [SenderNode]),
    case lists:member(SenderNode, get_all_nodes(State)) of
        true ->
            gen_server:cast({?NODE_MANAGER_NAME, SenderNode}, cm_conn_ack),
            State;
        false ->
            ?info("New node: ~p", [SenderNode]),
            try
                erlang:monitor_node(SenderNode, true),
                NewInitNodes = add_node_to_list(SenderNode, InitNodes),
                gen_server:cast({?NODE_MANAGER_NAME, SenderNode}, cm_conn_ack),
                State#state{uninitialized_nodes = NewInitNodes}
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
%% Receive acknowledgement of successful worker initialization on node.
%% @end
%%--------------------------------------------------------------------
-spec init_ok(State :: #state{}, SenderNode :: node()) -> #state{}.
init_ok(State = #state{nodes = InitializedNodes, uninitialized_nodes = UninitializedNodes}, SenderNode) ->
    ?info("Node ~p initialized successfully.", [SenderNode]),
    NewUninitializedNodes = lists:delete(SenderNode, UninitializedNodes),
    NewInitializedNodes = add_node_to_list(SenderNode, InitializedNodes),
    NewState = State#state{nodes = NewInitializedNodes, uninitialized_nodes = NewUninitializedNodes},
    case is_cluster_ready(NewState) of
        true -> on_cluster_ready(NewState);
        _ -> NewState
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Performs actions after all expected nodes are active.
%% Notifies nodes that cluster init is completed.
%% @end
%%--------------------------------------------------------------------
-spec on_cluster_ready(#state{}) -> #state{}.
on_cluster_ready(#state{nodes = Nodes} = State) ->
    create_hash_ring(Nodes),
    lists:foreach(fun(Node) ->
        gen_server:cast({?NODE_MANAGER_NAME, Node}, {cluster_init_finished, Nodes})
    end, Nodes),
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
    consistent_hasing:init(lists:usort(Nodes)),
    CHash = consistent_hasing:get_chash_ring(),
    lists:foreach(fun(Node) ->
        rpc:call(Node, consistent_hasing, set_chash_ring, [CHash])
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
    #state{nodes = Nodes,
        uninitialized_nodes = InitNodes,
        node_states = NodeStates,
        singleton_modules = Singletons
    } = State,
    ?error("Node down: ~p", [Node]),
    NewNodes = Nodes -- [Node],
    NewInitNodes = InitNodes -- [Node],
    NewNodeStates = proplists:delete(Node, NodeStates),
    NewSingletons = lists:map(fun({M, N}) ->
        case N of
            Node -> {M, undefined};
            _ -> {M, N}
        end
    end, Singletons),
    State#state{nodes = NewNodes,
        uninitialized_nodes = NewInitNodes,
        node_states = NewNodeStates,
        singleton_modules = NewSingletons
    }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get node that can be used by new nodes to synchronize with
%% (i. e. attach to mnesia cluster). This node should be one of active
%% nodes of existing cluster, or if there isn't any, the first of nodes
%% that are initializing.
%%
%% In some cases synchronization requires waiting for this node to finish
%% initialization process. It is up to caller to wait and ensure that he can
%% safely synchronize.
%% @end
%%--------------------------------------------------------------------
-spec get_node_to_sync(#state{}) -> {ok, node()} | {error, term()}.
get_node_to_sync(#state{nodes = [], uninitialized_nodes = []}) ->
    {error, no_nodes_connected};
get_node_to_sync(#state{nodes = [FirstNode | _]}) ->
    {ok, FirstNode};
get_node_to_sync(#state{uninitialized_nodes = [FirstInitNode | _]}) ->
    {ok, FirstInitNode}.

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
        {ok, N} ->
            N;
        _ ->
            exit(<<"The 'worker_num' env variable of cluster_manager ",
                "application is undefined. Refusing to initialize cluster.">>)
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check if number of nodes is correct (matches configured).
%% @end
%%--------------------------------------------------------------------
-spec is_cluster_ready(#state{}) -> boolean().
is_cluster_ready(#state{nodes = Nodes}) ->
    get_worker_num() == length(Nodes).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get all connected nodes
%% @end
%%--------------------------------------------------------------------
-spec get_all_nodes(#state{}) -> [node()].
get_all_nodes(#state{nodes = Nodes, uninitialized_nodes = InitNodes}) ->
    lists:usort(Nodes ++ InitNodes).
