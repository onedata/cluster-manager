%%%-------------------------------------------------------------------
%%% @author Michal Stanisz
%%% @copyright (C) 2019 ACK CYFRONET AGH
%%% This software is released under the MIT license
%%% cited in 'LICENSE.txt'.
%%% @end
%%%-------------------------------------------------------------------
%%% @doc
%%% This module is responsible for calculating cluster status based on
%%% healthcheck results of cluster nodes.
%%% @end
%%%-------------------------------------------------------------------
-module(cluster_status).
-author("Michal Stanisz").


-include("global_definitions.hrl").
-include_lib("ctool/include/logging.hrl").
-include_lib("ctool/include/global_definitions.hrl").

-export([get_cluster_status/1, get_cluster_status/2]).

-ifdef(TEST).
-export([calculate_cluster_status/5]).
-endif.

-type status() :: ok | out_of_sync | error | {error, ErrorDesc :: atom()}.
-type component() :: node_manager | cluster_manager_connection | dispatcher | workers | listeners.
-type component_status() :: {module(), status()}.
-type node_status() :: {node(), status(), [component_status()]}.

-export_type([status/0, component/0, component_status/0, node_status/0]).

-define(CLUSTER_STATUS_CACHING_TIME,
    application:get_env(?APP_NAME, cluster_status_caching_time, timer:minutes(5))).

-define(CLUSTER_COMPONENT_HEALTHCHECK_TIMEOUT,
    application:get_env(?APP_NAME, cluster_component_healthcheck_timeout, timer:seconds(10))).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Calculates cluster status based on healthcheck results received from node managers.
%% Saves result in cache when there was no error.
%% @end
%%--------------------------------------------------------------------
-spec get_cluster_status([node()]) -> {ok, {status(), [node_status()]}} | {error, term()}.
get_cluster_status(Nodes) ->
    GetStatus = fun() ->
        Status = get_cluster_status(Nodes, node_manager),
        case Status of
            % Save cluster status in cache, but only if there was no error
            {ok, {ok = _ClusterStatus, _NodeStatuses}} ->
                {true, Status, ?CLUSTER_STATUS_CACHING_TIME};
            _ ->
                {false, Status}
        end
    end,
    {ok, ClusterStatus} = simple_cache:get(cluster_status_cache, GetStatus),
    ClusterStatus.


%%--------------------------------------------------------------------
%% @doc
%% Calculates cluster status based on healthcheck results received from node managers.
%% @end
%%--------------------------------------------------------------------
-spec get_cluster_status([node()], component()) -> {ok, {status(), [node_status()]}} | {error, term()}.
get_cluster_status(AllNodes, NodeManager) ->
    FailedNodes = try
        consistent_hashing:get_failed_nodes()
    catch
        _:_ -> [] % Hashing ring not initialized
    end,

    try
        AliveNodes = AllNodes -- FailedNodes,
        NodeManagerStatuses = check_status(AliveNodes, FailedNodes, NodeManager),
        DispatcherStatuses = check_status(AliveNodes, FailedNodes, dispatcher),
        WorkerStatuses = check_status(AliveNodes, FailedNodes, workers),
        ListenerStatuses = check_status(AliveNodes, FailedNodes, listeners),
        ClusterStatus = calculate_cluster_status(AllNodes, NodeManagerStatuses, DispatcherStatuses,
            WorkerStatuses, ListenerStatuses),
        {ok, ClusterStatus}
    catch
        Type:Error ->
            ?error_stacktrace("Unexpected error during healthcheck: ~p:~p", [Type, Error]),
            {error, Error}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Orders node managers to perform healthchecks of given component.
%% Is run in parallel with one process per node.
%% @end
%%--------------------------------------------------------------------
-spec check_status([node()], [node()], component()) -> [{node(), component_status()}] | [{node(), [component_status()]}].
check_status(AliveNodes, FailedNodes, Component) ->
    AliveNodesStatus = utils:pmap(fun(Node) ->
        {Node, try
            Ans = gen_server:call({?NODE_MANAGER_NAME, Node}, {healthcheck, Component},
                ?CLUSTER_COMPONENT_HEALTHCHECK_TIMEOUT),
            ?debug("Healthcheck: ~p ~p, ans: ~p", [Component, Node, Ans]),
            Ans
        catch
            _:{{nodedown, _}, _} ->
                ?debug("Connection error to ~p at ~p: nodedown", [?NODE_MANAGER_NAME, Node]),
                [{Component, {error, nodedown}}];
            T:M ->
                ?debug("Connection error to ~p at ~p: ~p:~p", [?NODE_MANAGER_NAME, Node, T, M]),
                [{Component, {error, timeout}}]
        end}
    end, AliveNodes),

    FailedNodesStatus = lists:map(fun(Node) ->
        {Node, [{Component, {error, nodedown}}]}
    end, FailedNodes),

    AliveNodesStatus ++ FailedNodesStatus.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Creates a proper term expressing cluster health,
%% constructing it from statuses of all components in format:
%%    {ok, [{'worker@worker1',ok,
%%            [{node_manager,ok},
%%             {dispatcher,ok},
%%             {datastore_worker,ok},
%%             {tp_router,ok},
%%             {nagios_listener,ok}]
%%    }]}
%% @end
%%--------------------------------------------------------------------
-spec calculate_cluster_status([node()],
    NodeManagerStatuses ::[{node(), component_status()}],
    DispatcherStatuses :: [{node(), component_status()}],
    WorkerStatuses :: [{node(), [component_status()]}],
    ListenerStatuses :: [{node(), [component_status()]}]) -> {status(), [node_status()]}.
calculate_cluster_status(Nodes, NodeManagerStatuses, DispatcherStatuses, WorkerStatuses, ListenerStatuses) ->
    NodeStatuses = lists:map(fun(Node) ->
        % Get all statuses for this node
        % They are all in form:
        % {ModuleName, ok | out_of_sync | {error, atom()}}
        AllStatuses = lists:flatten([
            {?NODE_MANAGER_NAME, proplists:get_value(Node, NodeManagerStatuses)},
            {dispatcher, proplists:get_value(Node, DispatcherStatuses)},
            lists:usort(proplists:get_value(Node, WorkerStatuses)),
            lists:usort(proplists:get_value(Node, ListenerStatuses))
        ]),
        % Calculate status of the whole node - it's the same as the worst status of any child
        % if any node component has an error, node's status will be 'error'.
        NodeStatus = lists:foldl(fun({_, CurrentStatus}, Acc) ->
            get_worse_status(Acc, CurrentStatus)
        end, ok, AllStatuses),
        {Node, NodeStatus, AllStatuses}
    end, Nodes),
    % Calculate status of the whole application - it's the same as the worst status of any node
    % If any node has an error, app's status will be 'error'.
    AppStatus = lists:foldl(fun({_, CurrentStatus, _}, Acc) ->
        get_worse_status(Acc, CurrentStatus)
    end, ok, NodeStatuses),
    % Sort node statuses by node name
    ?debug("Cluster status: ~p", [AppStatus]),
    {AppStatus, lists:usort(NodeStatuses)}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Compares two statuses and returns worse one.
%% ok < out_of_sync < error
%% {error, Desc} is converted to error.
%% @end
%%--------------------------------------------------------------------
-spec get_worse_status(status(), status()) -> status().
get_worse_status(Status, {error, _}) ->
    get_worse_status(Status, error);
get_worse_status(ok, Any) -> Any;
get_worse_status(out_of_sync, error) -> error;
get_worse_status(out_of_sync, _) -> out_of_sync;
get_worse_status(_, _) -> error.
