%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2018-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_core_ff).

-export([direct_exchange_routing_v2_enable/1,
         listener_records_in_ets_enable/1,
         listener_records_in_ets_post_enable/1,
         tracking_records_in_ets_enable/1,
         tracking_records_in_ets_post_enable/1,
         mds_phase1_migration_enable/1,
         mds_phase1_migration_post_enable/1]).
-export([mds_migration_enable/2,
         mds_migration_post_enable/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-include("vhost.hrl").
-include("internal_user.hrl").

-rabbit_feature_flag(
   {classic_mirrored_queue_version,
    #{desc          => "Support setting version for classic mirrored queues",
      stability     => stable
     }}).

-rabbit_feature_flag(
   {quorum_queue,
    #{desc          => "Support queues of type `quorum`",
      doc_url       => "https://www.rabbitmq.com/quorum-queues.html",
      stability     => required
     }}).

-rabbit_feature_flag(
   {stream_queue,
    #{desc          => "Support queues of type `stream`",
      doc_url       => "https://www.rabbitmq.com/stream.html",
      stability     => stable,
      depends_on    => [quorum_queue]
     }}).

-rabbit_feature_flag(
   {implicit_default_bindings,
    #{desc          => "Default bindings are now implicit, instead of "
                       "being stored in the database",
      stability     => required
     }}).

-rabbit_feature_flag(
   {virtual_host_metadata,
    #{desc          => "Virtual host metadata (description, tags, etc)",
      stability     => required
     }}).

-rabbit_feature_flag(
   {maintenance_mode_status,
    #{desc          => "Maintenance mode status",
      stability     => required
     }}).

-rabbit_feature_flag(
    {user_limits,
     #{desc          => "Configure connection and channel limits for a user",
       stability     => required
     }}).

-rabbit_feature_flag(
   {stream_single_active_consumer,
    #{desc          => "Single active consumer for streams",
      doc_url       => "https://www.rabbitmq.com/stream.html",
      stability     => stable,
      depends_on    => [stream_queue]
     }}).

-rabbit_feature_flag(
    {feature_flags_v2,
     #{desc          => "Feature flags subsystem V2",
       stability     => stable
     }}).

-rabbit_feature_flag(
   {direct_exchange_routing_v2,
    #{desc       => "v2 direct exchange routing implementation",
      stability  => stable,
      depends_on => [feature_flags_v2, implicit_default_bindings],
      callbacks  => #{enable => {?MODULE, direct_exchange_routing_v2_enable}}
     }}).

-rabbit_feature_flag(
   {listener_records_in_ets,
    #{desc       => "Store listener records in ETS instead of Mnesia",
      stability  => stable,
      depends_on => [feature_flags_v2],
      callbacks  => #{enable =>
                      {?MODULE, listener_records_in_ets_enable},
                      post_enable =>
                      {?MODULE, listener_records_in_ets_post_enable}}
     }}).

-rabbit_feature_flag(
   {tracking_records_in_ets,
    #{desc          => "Store tracking records in ETS instead of Mnesia",
      stability     => stable,
      depends_on    => [feature_flags_v2],
      callbacks     => #{enable =>
                             {?MODULE, tracking_records_in_ets_enable},
                         post_enable =>
                             {?MODULE, tracking_records_in_ets_post_enable}}
     }}).

-rabbit_feature_flag(
   {raft_based_metadata_store_phase1,
    #{desc          => "Use the new Raft-based metadata store [phase 1]",
      doc_url       => "", %% TODO
      stability     => experimental,
      depends_on    => [feature_flags_v2,
                        maintenance_mode_status,
                        user_limits,
                        virtual_host_metadata,
                        tracking_records_in_ets,
                        listener_records_in_ets],
      callbacks     => #{enable =>
                             {?MODULE, mds_phase1_migration_enable},
                         post_enable =>
                             {?MODULE, mds_phase1_migration_post_enable}}
     }}).

%% -------------------------------------------------------------------
%% Direct exchange routing v2.
%% -------------------------------------------------------------------

-spec direct_exchange_routing_v2_enable(Args) -> Ret when
      Args :: rabbit_feature_flags:enable_callback_args(),
      Ret :: rabbit_feature_flags:enable_callback_ret().
direct_exchange_routing_v2_enable(#{feature_name := FeatureName}) ->
    TableName = rabbit_index_route,
    ok = rabbit_table:wait([rabbit_route], _Retry = true),
    try
        ok = rabbit_table:create(
               TableName, rabbit_table:rabbit_index_route_definition()),
        case rabbit_table:ensure_table_copy(TableName, node(), ram_copies) of
            ok ->
                ok = rabbit_binding:populate_index_route_table();
            {error, Err} = Error ->
                rabbit_log_feature_flags:error(
                  "Feature flags: `~s`: failed to add copy of table ~s to "
                  "node ~p: ~p",
                  [FeatureName, TableName, node(), Err]),
                Error
        end
    catch throw:{error, Reason} ->
              rabbit_log_feature_flags:error(
                "Feature flags: `~s`: enable callback failure: ~p",
                [FeatureName, Reason]),
              {error, Reason}
    end.

%% -------------------------------------------------------------------
%% Listener records moved from Mnesia to ETS.
%% -------------------------------------------------------------------

listener_records_in_ets_enable(#{feature_name := FeatureName}) ->
    try
        rabbit_misc:execute_mnesia_transaction(
          fun () ->
                  mnesia:lock({table, rabbit_listener}, read),
                  Listeners = mnesia:select(
                                rabbit_listener, [{'$1',[],['$1']}]),
                  lists:foreach(
                    fun(Listener) ->
                            ets:insert(rabbit_listener_ets, Listener)
                    end, Listeners)
          end)
    catch
        throw:{error, {no_exists, rabbit_listener}} ->
            ok;
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error(
              "Feature flags: `~s`: failed to migrate Mnesia table: ~p",
              [FeatureName, Reason]),
            {error, Reason}
    end.

listener_records_in_ets_post_enable(#{feature_name := FeatureName}) ->
    try
        case mnesia:delete_table(rabbit_listener) of
            {atomic, ok} ->
                ok;
            {aborted, {no_exists, _}} ->
                ok;
            {aborted, Err} ->
                rabbit_log_feature_flags:error(
                  "Feature flags: `~s`: failed to delete Mnesia table: ~p",
                  [FeatureName, Err]),
                ok
        end
    catch
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error(
              "Feature flags: `~s`: failed to delete Mnesia table: ~p",
              [FeatureName, Reason]),
            ok
    end.

tracking_records_in_ets_enable(#{feature_name := FeatureName}) ->
    try
        rabbit_connection_tracking:migrate_tracking_records(),
        rabbit_channel_tracking:migrate_tracking_records()
    catch
        throw:{error, {no_exists, _}} ->
            ok;
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error("Enabling feature flag ~s failed: ~p",
                                           [FeatureName, Reason]),
            {error, Reason}
    end.

tracking_records_in_ets_post_enable(#{feature_name := FeatureName}) ->
    try
        [delete_table(FeatureName, Tab) ||
            Tab <- rabbit_connection_tracking:get_all_tracked_connection_table_names_for_node(node())],
        [delete_table(FeatureName, Tab) ||
            Tab <- rabbit_channel_tracking:get_all_tracked_channel_table_names_for_node(node())]
    catch
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error("Enabling feature flag ~s failed: ~p",
                                           [FeatureName, Reason]),
            %% adheres to the callback interface
            ok
    end.

delete_table(FeatureName, Tab) ->
    case mnesia:delete_table(Tab) of
        {atomic, ok} ->
            ok;
        {aborted, {no_exists, _}} ->
            ok;
        {aborted, Err} ->
            rabbit_log_feature_flags:error("Enabling feature flag ~s failed to delete mnesia table ~p: ~p",
                                           [FeatureName, Tab, Err]),
            %% adheres to the callback interface
            ok
    end.

%% -------------------------------------------------------------------
%% Raft-based metadata store (phase 1).
%% -------------------------------------------------------------------

%% Phase 1 covers the migration of the following data:
%%     * virtual hosts
%%     * users and their permissions
%%     * runtime parameters
%% They all depend on each others in Mnesia transactions. That's why they must
%% be migrated atomically.

%% This table order is important. For instance, user permissions depend on
%% both vhosts and users to exist in the metadata store.

%% TODO should they be integrated on phase1?
-define(MDS_PHASE2_TABLES, [{rabbit_queue, rabbit_store},
                            {rabbit_durable_queue, rabbit_store},
                            {rabbit_exchange, rabbit_store},
                            {rabbit_durable_exchange, rabbit_store},
                            {rabbit_exchange_serial, rabbit_store},
                            {rabbit_route, rabbit_store},
                            {rabbit_durable_route, rabbit_store},
                            {rabbit_semi_durable_route, rabbit_store},
                            {rabbit_reverse_route, rabbit_store},
                            {rabbit_topic_trie_binding, rabbit_store},
                            {rabbit_topic_trie_node, rabbit_store},
                            {rabbit_topic_trie_edge, rabbit_store}]).

-define(MDS_PHASE1_TABLES, [{rabbit_vhost, rabbit_vhost},
                            {rabbit_user, rabbit_auth_backend_internal},
                            {rabbit_user_permission, rabbit_auth_backend_internal},
                            {rabbit_topic_permission, rabbit_auth_backend_internal},
                            {rabbit_runtime_parameters, rabbit_runtime_parameters}]
        ++ ?MDS_PHASE2_TABLES).

mds_phase1_migration_enable(#{feature_name := FeatureName}) ->
    %% Channel and connection tracking are core features with difference:
    %% tables cannot be predeclared as they include the node name
    Tables = ?MDS_PHASE1_TABLES,
    global:set_lock({FeatureName, self()}),
    Ret = case rabbit_khepri:is_ready() of
              true -> ok;
              false -> mds_migration_enable(FeatureName, Tables)
          end,
    global:del_lock({FeatureName, self()}),
    Ret.

mds_phase1_migration_post_enable(#{feature_name := FeatureName}) ->
    %% Channel and connection tracking are core features with difference:
    %% tables cannot be predeclared as they include the node name
    Tables = ?MDS_PHASE1_TABLES,
    mds_migration_post_enable(FeatureName, Tables).

mds_migration_enable(FeatureName, TablesAndOwners) ->
    case ensure_khepri_cluster_matches_mnesia(FeatureName) of
        ok ->
            migrate_tables_to_khepri(FeatureName, TablesAndOwners);
        Error ->
            Error
    end.

mds_migration_post_enable(FeatureName, TablesAndOwners) ->
    ?assert(rabbit_khepri:is_enabled(non_blocking)),
    {Tables, _} = lists:unzip(TablesAndOwners),
    empty_unused_mnesia_tables(FeatureName, Tables).

ensure_khepri_cluster_matches_mnesia(FeatureName) ->
    %% The ff controller has already ensure that all Mnesia nodes are running.
    ?LOG_DEBUG(
       "Feature flag `~s`:   ensure Khepri Ra system is running",
       [FeatureName]),
    ok = rabbit_khepri:setup(),
    AllMnesiaNodes = lists:sort(rabbit_mnesia:cluster_nodes(all)),
    %% This is the first time Khepri will be used for real. Therefore
    %% we need to make sure the Khepri cluster matches the Mnesia
    %% cluster.
    ?LOG_DEBUG(
       "Feature flag `~s`:   updating the Khepri cluster to match "
       "the Mnesia cluster",
       [FeatureName]),
    case expand_khepri_cluster(FeatureName, AllMnesiaNodes) of
        ok ->
            ok;
        Error ->
            ?LOG_ERROR(
               "Feature flag `~s`:   failed to migrate from Mnesia "
               "to Khepri: failed to create Khepri cluster: ~p",
               [FeatureName, Error]),
            Error
    end.

expand_khepri_cluster(FeatureName, AllMnesiaNodes) ->
    %% All Mnesia nodes are running (this is a requirement to enable this
    %% feature flag). We use this unique list of nodes to find the largest
    %% Khepri clusters among all of them.
    %%
    %% The idea is that at the beginning, each Mnesia node will also be an
    %% unclustered Khepri node. Therefore, the first node in the sorted list
    %% of Mnesia nodes will be picked (a "cluster" with 1 member, but the
    %% "largest" at the beginning).
    %%
    %% After the first nodes join that single node, its cluster will grow and
    %% will continue to be the largest.
    %%
    %% This function is executed on the node enabling the feature flag. It will
    %% take care of adding all nodes in the Mnesia cluster to a Khepri cluster
    %% (except those which are already part of it).
    %%
    %% This should avoid the situation where a large established cluster is
    %% reset and joins a single new/empty node.
    %%
    %% Also, we only consider Khepri clusters which are in use (i.e. the
    %% feature flag is enabled). Here is an example:
    %%     - Node2 is the only node in the Mnesia cluster at the time the
    %%       feature flag is enabled. It joins no other node and runs its own
    %%       one-node Khepri cluster.
    %%     - Node1 joins the Mnesia cluster which is now Node1 + Node2. Given
    %%       the sorting, Khepri clusters will be [[Node1], [Node2]] when
    %%       sorted by name and size. With this order, Node1 should "join"
    %%       itself. But the feature is not enabled yet on this node,
    %%       therefore, we skip this cluster to consider the following one,
    %%       [Node2].
    KhepriCluster = find_largest_khepri_cluster(FeatureName),
    NodesToAdd = AllMnesiaNodes -- KhepriCluster,
    ?LOG_DEBUG(
       "Feature flags `~s`:   selected Khepri cluster: ~p",
       [FeatureName, KhepriCluster]),
    ?LOG_DEBUG(
       "Feature flags `~s`:   Mnesia nodes to add to the Khepri cluster "
       "above: ~p",
       [FeatureName, NodesToAdd]),
    add_nodes_to_khepri_cluster(FeatureName, KhepriCluster, NodesToAdd).

add_nodes_to_khepri_cluster(FeatureName, KhepriCluster, [Node | Rest]) ->
    add_node_to_khepri_cluster(FeatureName, KhepriCluster, Node),
    add_nodes_to_khepri_cluster(FeatureName, KhepriCluster, Rest);
add_nodes_to_khepri_cluster(_FeatureName, _KhepriCluster, []) ->
    ok.

add_node_to_khepri_cluster(FeatureName, KhepriCluster, Node) ->
    ?assertNotEqual([], KhepriCluster),
    case lists:member(Node, KhepriCluster) of
        true ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   node ~p is already a member of "
               "the largest cluster: ~p",
               [FeatureName, Node, KhepriCluster]),
            ok;
        false ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   adding node ~p to the largest "
               "Khepri cluster found among Mnesia nodes: ~p",
               [FeatureName, Node, KhepriCluster]),
            case rabbit_khepri:add_member(Node, KhepriCluster) of
                ok                   -> ok;
                {ok, already_member} -> ok
            end
    end.

find_largest_khepri_cluster(FeatureName) ->
    case list_all_khepri_clusters(FeatureName) of
        [] ->
            [node()];
        KhepriClusters ->
            KhepriClustersBySize = sort_khepri_clusters_by_size(
                                     KhepriClusters),
            ?LOG_DEBUG(
               "Feature flag `~s`:   existing Khepri clusters (sorted by "
               "size): ~p",
               [FeatureName, KhepriClustersBySize]),
            LargestKhepriCluster = hd(KhepriClustersBySize),
            LargestKhepriCluster
    end.

list_all_khepri_clusters(FeatureName) ->
    MnesiaNodes = lists:sort(rabbit_mnesia:cluster_nodes(all)),
    ?LOG_DEBUG(
       "Feature flag `~s`:   querying the following Mnesia nodes to learn "
       "their Khepri cluster membership: ~p",
       [FeatureName, MnesiaNodes]),
    KhepriClusters = lists:foldl(
                       fun(MnesiaNode, Acc) ->
                               case khepri_cluster_on_node(MnesiaNode) of
                                   []        -> Acc;
                                   Cluster   -> Acc#{Cluster => true}
                               end
                       end, #{}, MnesiaNodes),
    lists:sort(maps:keys(KhepriClusters)).

sort_khepri_clusters_by_size(KhepriCluster) ->
    lists:sort(
      fun(A, B) -> length(A) >= length(B) end,
      KhepriCluster).

khepri_cluster_on_node(Node) ->
    lists:sort(
      rabbit_misc:rpc_call(Node, rabbit_khepri, nodes_if_khepri_enabled, [])).

migrate_tables_to_khepri(FeatureName, TablesAndOwners) ->
    {Tables, _} = lists:unzip(TablesAndOwners),
    rabbit_table:wait(Tables, _Retry = true),
    ?LOG_NOTICE(
       "Feature flag `~s`:   starting migration from Mnesia "
       "to Khepri; expect decrease in performance and "
       "increase in memory footprint",
       [FeatureName]),
    Pid = spawn(
            fun() ->
                    migrate_tables_to_khepri_run(FeatureName, TablesAndOwners)
            end),
    MonitorRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MonitorRef, process, Pid, normal} ->
            ?LOG_NOTICE(
               "Feature flag `~s`:   migration from Mnesia to Khepri "
               "finished",
               [FeatureName]),
            rabbit_khepri:set_ready(),
            ok;
        {'DOWN', MonitorRef, process, Pid, Info} ->
            ?LOG_ERROR(
               "Feature flag `~s`:   "
               "failed to migrate Mnesia tables to Khepri:~n  ~p",
               [FeatureName, Info]),
            {error, {migration_failure, Info}}
    end.

migrate_tables_to_khepri_run(FeatureName, TablesAndOwners) ->
    %% Clear data in Khepri which could come from a previously aborted copy
    %% attempt. The table list order is important so we need to reverse that
    %% order to clear the data.
    ?LOG_DEBUG(
       "Feature flag `~s`:   clear data from any aborted migration attempts "
       "(if any)",
       [FeatureName]),
    ok = clear_data_from_previous_attempt(FeatureName, lists:reverse(TablesAndOwners)),

    {Tables, _} = lists:unzip(TablesAndOwners),
    %% Subscribe to Mnesia events: we want to know about all writes and
    %% deletions happening in parallel to the copy we are about to start.
    ?LOG_DEBUG(
       "Feature flag `~s`:   subscribe to Mnesia writes",
       [FeatureName]),
    ok = subscribe_to_mnesia_changes(FeatureName, Tables),

    %% Copy from Mnesia to Khepri. Tables are copied in a specific order to
    %% make sure that if term A depends on term B, term B was copied before.
    ?LOG_DEBUG(
       "Feature flag `~s`:   copy records from Mnesia to Khepri",
       [FeatureName]),
    ok = copy_from_mnesia_to_khepri(FeatureName, TablesAndOwners),

    %% Mnesia transaction to handle received Mnesia events and tables removal.
    ?LOG_DEBUG(
       "Feature flag `~s`:   final sync and Mnesia table removal",
       [FeatureName]),
    ok = final_sync_from_mnesia_to_khepri(FeatureName, TablesAndOwners),

    %% Unsubscribe to Mnesia events. All Mnesia tables are synchronized and
    %% read-only at this point.
    ?LOG_DEBUG(
       "Feature flag `~s`:   unsubscribe to Mnesia writes",
       [FeatureName]),
    ok = unsubscribe_to_mnesia_changes(FeatureName, Tables).

clear_data_from_previous_attempt(
  FeatureName, [{Table, Mod} | Rest]) ->
    ok = Mod:clear_data_in_khepri(Table),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(_, []) ->
    ok.

subscribe_to_mnesia_changes(FeatureName, [Table | Rest]) ->
    ?LOG_DEBUG(
       "Feature flag `~s`:     subscribe to writes to ~s",
       [FeatureName, Table]),
    case mnesia:subscribe({table, Table, detailed}) of
        {ok, _} -> subscribe_to_mnesia_changes(FeatureName, Rest);
        {error, {not_active_local, _}} ->
            rabbit_log:warning("Feature flag `~s`: table ~s doesn't have a local copy. Until ff v2 is merged it won't be migrated", [FeatureName, Table]);
        Error   -> Error
    end;
subscribe_to_mnesia_changes(_, []) ->
    ok.

unsubscribe_to_mnesia_changes(FeatureName, [Table | Rest]) ->
    ?LOG_DEBUG(
       "Feature flag `~s`:     unsubscribe to writes to ~s",
       [FeatureName, Table]),
    case mnesia:unsubscribe({table, Table, detailed}) of
        {ok, _} -> unsubscribe_to_mnesia_changes(FeatureName, Rest);
        Error   -> Error
    end;
unsubscribe_to_mnesia_changes(_, []) ->
    ok.

copy_from_mnesia_to_khepri(
  FeatureName, [{Table, Mod} | Rest]) ->
    Fun = fun(Entries) ->
                  Mod:mnesia_write_to_khepri(Table, Entries)
          end,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(_, []) ->
    ok.

do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun) ->
    Count = mnesia:table_info(Table, size),
    ?LOG_DEBUG(
       "Feature flag `~s`:     table ~s: about ~b record(s) to copy",
       [FeatureName, Table, Count]),
    Batch = application:get_env(rabbit, khepri_migration_batch, 1000),
    Cont = mnesia:async_dirty(
             fun () ->
                     mnesia:select(Table, [{'$1',[],['$1']}], Batch, read) end),
    do_copy_from_mnesia_to_khepri(
      FeatureName, Table, Cont, Fun, Count, 0).

do_copy_from_mnesia_to_khepri(
  FeatureName, Table, '$end_of_table', _, Count, Copied) ->
    ?LOG_DEBUG(
       "Feature flag `~s`:     table ~s: copy of ~b record(s) (out of ~b "
       "initially) finished",
       [FeatureName, Table, Copied, Count]),
    ok;
do_copy_from_mnesia_to_khepri(
  FeatureName, Table, {Records, Cont}, Fun, Count, Copied) ->
    %% TODO: Batch several records in a single Khepri insert.
    %% TODO: Can/should we parallelize?
    case Copied rem 100 of
        0 ->
            ?LOG_DEBUG(
               "Feature flag `~s`:     table ~s: copying record ~b/~b",
               [FeatureName, Table, Copied, Count]);
        _ ->
            ok
    end,
    %% rabbit_listener is a bag, so this query might return a list of records
    Fun(Records),
    Next = mnesia:async_dirty(fun() -> mnesia:select(Cont) end),
    do_copy_from_mnesia_to_khepri(
      FeatureName, Table, Next, Fun, Count, Copied + length(Records)).

final_sync_from_mnesia_to_khepri(FeatureName, TablesAndOwners) ->
    %% Switch all tables to read-only. All concurrent and future Mnesia
    %% transaction involving a write to one of them will fail with the
    %% `{no_exists, Table}` exception.
    {Tables, _} = lists:unzip(TablesAndOwners),
    lists:foreach(
      fun(Table) ->
              ?LOG_DEBUG(
                 "Feature flag `~s`:     switch table ~s to read-only",
                 [FeatureName, Table]),
                 case mnesia:change_table_access_mode(Table, read_only) of
                     {atomic, ok} -> ok;
                     {aborted, {already_exists, _, read_only}} -> ok
                 end
      end, Tables),

    %% During the first round of copy, we received all write events as
    %% messages (parallel writes were authorized). Now, we want to consume
    %% those messages to record the writes we probably missed.
    ok = consume_mnesia_events(FeatureName, TablesAndOwners),

    ok.

consume_mnesia_events(FeatureName, TablesAndOwners) ->
    {_, Count} = erlang:process_info(self(), message_queue_len),
    ?LOG_DEBUG(
       "Feature flag `~s`:     handling queued Mnesia events "
       "(about ~b events)",
       [FeatureName, Count]),
    consume_mnesia_events(FeatureName, TablesAndOwners, Count, 0).

consume_mnesia_events(FeatureName, TablesAndOwners, Count, Handled) ->
    %% TODO: Batch several events in a single Khepri command.
    Handled1 = Handled + 1,
    receive
        {mnesia_table_event, {write, Table, NewRecord, _, _}} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:       handling event ~b/~b (write)",
               [FeatureName, Handled1, Count]),
            handle_mnesia_write(Table, NewRecord, TablesAndOwners),
            consume_mnesia_events(FeatureName, TablesAndOwners, Count, Handled1);
        {mnesia_table_event, {delete, Table, {Table, Key}, _, _}} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:       handling event ~b/~b (delete)",
               [FeatureName, Handled1, Count]),
            handle_mnesia_delete(Table, Key, TablesAndOwners),
            consume_mnesia_events(FeatureName, TablesAndOwners, Count, Handled1);
        {mnesia_table_event, {delete, Table, Record, _, _}} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:       handling event ~b/~b (delete)",
               [FeatureName, Handled1, Count]),
            handle_mnesia_delete(Table, Record, TablesAndOwners),
            consume_mnesia_events(FeatureName, TablesAndOwners, Count, Handled1)
    after 0 ->
              {_, MsgCount} = erlang:process_info(self(), message_queue_len),
              ?LOG_DEBUG(
                 "Feature flag `~s`:     ~b messages remaining",
                 [FeatureName, MsgCount]),
              %% TODO: Wait for confirmation from Khepri.
              ok
    end.

%% TODO handle mnesia_runtime_parameters, rabbit_amqqueue, rabbit_exchange, rabbit_binding,
%% rabbit_exchange_type_topic
handle_mnesia_write(Table, NewRecord, TablesAndOwners) ->
    {_, Mod} = lists:keyfind(Table, 1, TablesAndOwners),
    Mod:mnesia_write_to_khepri(Table, NewRecord).

%% TODO handle mnesia_runtime_parameters, rabbit_amqqueue, rabbit_exchange, rabbit_binding,
%% rabbit_exchange_type_topic
handle_mnesia_delete(Table, Key, TablesAndOwners) ->
    {Mod, _} = lists:keyfind(Table, 1, TablesAndOwners),
    Mod:mnesia_delete_to_khepri(Table, Key).

%% We can't remove unused tables at this point yet. The reason is that tables
%% are synchronized before feature flags in `rabbit_mnesia`. So if a node is
%% already using Khepri and another node wants to join him, but is using Mnesia
%% only, it will hang while trying to sync the dropped tables.
%%
%% We can't simply reverse the two steps (i.e. synchronize feature flags before
%% tables) because some feature flags like `quorum_queue` need tables to modify
%% their schema.
%%
%% Another solution would be to have two groups of feature flags, depending on
%% whether a feature flag should be synchronized before or after Mnesia
%% tables.
%%
%% But for now, let's just empty the tables, add a forged record to mark them
%% as migrated and leave them around.

empty_unused_mnesia_tables(FeatureName, [Table | Rest]) ->
    %% The feature flag is enabled at this point. It means there should be no
    %% code trying to read or write the Mnesia tables.
    case mnesia:change_table_access_mode(Table, read_write) of
        {atomic, ok} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   dropping content from unused Mnesia "
               "table ~s",
               [FeatureName, Table]),
            ok = empty_unused_mnesia_table(Table);
        {aborted, {already_exists, Table, _}} ->
            %% Another node is already taking care of this table.
            ?LOG_DEBUG(
               "Feature flag `~s`:   Mnesia table ~s already emptied",
               [FeatureName, Table]),
            ok
    end,
    empty_unused_mnesia_tables(FeatureName, Rest);
empty_unused_mnesia_tables(FeatureName, []) ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   done with emptying unused Mnesia tables",
               [FeatureName]),
            ok.

empty_unused_mnesia_table(Table) ->
    FirstKey = mnesia:dirty_first(Table),
    empty_unused_mnesia_table(Table, FirstKey).

empty_unused_mnesia_table(_Table, '$end_of_table') ->
    ok;
empty_unused_mnesia_table(Table, Key) ->
    NextKey = mnesia:dirty_next(Table, Key),
    ok = mnesia:dirty_delete(Table, Key),
    empty_unused_mnesia_table(Table, NextKey).
