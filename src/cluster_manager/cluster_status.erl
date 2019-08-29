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

-type status() :: ok | out_of_sync | {error, ErrorDesc :: atom()}.
-type component_status() :: {module(), status()}.
-type node_status() :: {node(), status(), [component_status()]}.

-export_type([status/0, component_status/0, node_status/0]).

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
    CachingTime = application:get_env(?APP_NAME, cluster_status_caching_time, timer:minutes(5)),
    GetStatus = fun() ->
        Status = get_cluster_status(Nodes, node_manager),
        case Status of
            % Save cluster state in cache, but only if there was no error
            {ok, {ok, _}} ->
                {true, Status, CachingTime};
            _ ->
                {false, Status}
        end
    end,
    {ok, ClusterStatus} = simple_cache:get(cluster_status_cache, GetStatus),
    ClusterStatus.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Calculates cluster status based on healthcheck results received from node managers.
%% @end
%%--------------------------------------------------------------------
-spec get_cluster_status([node()], atom()) -> {ok, {status(), [node_status()]}} | {error, term()}.
get_cluster_status(Nodes, NodeManager) ->
    try
        NodeManagerStatuses = check_status(Nodes, NodeManager),
        DispatcherStatuses = check_status(Nodes, dispatcher),
        WorkerStatuses = check_status(Nodes, workers),
        ListenerStatuses = check_status(Nodes, listeners),
        ClusterStatus = calculate_cluster_status(Nodes, NodeManagerStatuses, DispatcherStatuses,
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
-spec check_status([node()], atom()) -> [{node(), component_status()}] | [{node(), [component_status()]}].
check_status(Nodes, Component) ->
    Timeout = application:get_env(?APP_NAME, cluster_status_caching_time, timer:seconds(10)),
    utils:pmap(
        fun(Node) ->
            Result =
                try
                    Ans = gen_server:call({?NODE_MANAGER_NAME, Node}, {healthcheck, Component}, Timeout),
                    ?debug("Healthcheck: ~p ~p, ans: ~p", [Component, Node, Ans]),
                    Ans
                catch T:M ->
                    ?debug("Connection error to ~p at ~p: ~p:~p", [?NODE_MANAGER_NAME, Node, T, M]),
                    {error, timeout}
                end,
            {Node, Result}
        end, Nodes).


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
    NodeStatuses =
        lists:map(
            fun(Node) ->
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
                % ok < out_of_sync < error
                % i. e. if any node component has an error, node's status will be 'error'.
                NodeStatus = lists:foldl(
                    fun({_, CurrentStatus}, Acc) ->
                        case {Acc, CurrentStatus} of
                            {ok, {error, _}} -> error;
                            {ok, OkOrOOS} -> OkOrOOS;
                            {out_of_sync, {error, _}} -> error;
                            {out_of_sync, _} -> out_of_sync;
                            _ -> error
                        end
                    end, ok, AllStatuses),
                {Node, NodeStatus, AllStatuses}
            end, Nodes),
    % Calculate status of the whole application - it's the same as the worst status of any node
    % ok > out_of_sync > Other (any other atom means an error)
    % If any node has an error, app's status will be 'error'.
    AppStatus = lists:foldl(
        fun({_, CurrentStatus, _}, Acc) ->
            case {Acc, CurrentStatus} of
                {ok, Any} -> Any;
                {out_of_sync, ok} -> out_of_sync;
                {out_of_sync, Any} -> Any;
                _ -> error
            end
        end, ok, NodeStatuses),
    % Sort node statuses by node name
    ?debug("Cluster status: ~p", [AppStatus]),
    {AppStatus, lists:usort(NodeStatuses)}.


