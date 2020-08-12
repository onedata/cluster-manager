%%%-------------------------------------------------------------------
%%% @author Michał Wrzeszcz
%%% @copyright (C) 2020 ACK CYFRONET AGH
%%% This software is released under the MIT license
%%% cited in 'LICENSE.txt'.
%%% @end
%%%-------------------------------------------------------------------
%%% @doc
%%% This file contains definition of protocol between
%%% node_manager and cluster_manager_server.
%%% @end
%%%-------------------------------------------------------------------
-ifndef(NODE_MANAGEMENT_PROTOCOL_HRL).
-define(NODE_MANAGEMENT_PROTOCOL_HRL, 1).

% Node start protocol - generic message
-define(INIT_STEP_MSG(Step), {cluster_init_step, Step}).
% Node start protocol - steps
% NOTE: upon any change, adjust env names related to timeouts in app.config
-define(INIT_CONNECTION, init_connection).
-define(START_DEFAULT_WORKERS, start_default_workers).
-define(START_UPGRADE_ESSENTIAL_WORKERS, start_upgrade_essential_workers).
-define(UPGRADE_CLUSTER, upgrade_cluster).
-define(START_CUSTOM_WORKERS, start_custom_workers).
-define(DB_AND_WORKERS_READY, db_and_workers_ready).
-define(START_LISTENERS, start_listeners).
-define(CLUSTER_READY, cluster_ready).

% Broadcasting node failure/recovery (sent by cluster_manager_server to node_managers)
-define(NODE_DOWN(Node), {node_down, Node}).
-define(NODE_UP(Node), {node_up, Node}). % Failed node is up again but it is not initialized (modules are not ready)
-define(NODE_READY(Node), {node_ready, Node}). % $ Node is ready to work (modules have started)

% Node restart protocol
-define(INITIALIZE_RECOVERY, initialize_recovery).
-define(RECOVERY_INITIALIZED(Node), {recovery_initialized, Node}).
-define(RECOVERY_ACKNOWLEDGED(SenderNode, RestartedNode), {recovery_acknowledged, SenderNode, RestartedNode}).
-define(FINALIZE_RECOVERY, finalize_recovery).
-define(RECOVERY_FINALIZED(Node), {recovery_finished, Node}).

% Other management messages
-define(UPDATE_LB_ADVICES(AdviceForDispatchers), {update_lb_advices, AdviceForDispatchers}).
-define(FORCE_STOP(ReasonMsg), {force_stop, ReasonMsg}).

-endif.
