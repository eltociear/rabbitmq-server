%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_store).

-include_lib("khepri/include/khepri.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include("amqqueue.hrl").

-export([list_exchanges/0, count_exchanges/0, list_exchange_names/0,
         update_exchange_decorators/1, update_exchange_scratch/2,
         create_exchange/2, list_exchanges/1, list_durable_exchanges/0,
         lookup_exchange/1, lookup_many_exchanges/1, peek_exchange_serial/2,
         next_exchange_serial/1, delete_exchange_in_khepri/3,
         delete_exchange_in_mnesia/3, delete_exchange/3,
         recover_exchanges/1, store_durable_exchanges/1, match_exchanges/1]).

-export([exists_binding/1, add_binding/2, delete_binding/2, list_bindings/1,
         list_bindings_for_source/1, list_bindings_for_destination/1,
         list_bindings_for_source_and_destination/2, list_explicit_bindings/0,
         recover_bindings/0, recover_bindings/1, delete_binding/1,
         index_route_table_definition/0, populate_index_route_table/0]).

%% TODO used by rabbit_policy, to become internal
-export([update_exchange_in_mnesia/2, update_exchange_in_khepri/2]).

%% TODO used by rabbit policy. to become internal
-export([list_exchanges_in_mnesia/1, list_queues_in_khepri_tx/1,
         list_queues_in_mnesia/1, update_queue_in_mnesia/2, update_queue_in_khepri/2]).
%% TODO used by topic exchange. Should it be internal?
-export([match_source_and_destination_in_khepri/2]).

-export([list_queues/0, list_queues/1, list_durable_queues/0, list_durable_queues/1,
         list_durable_queues_by_type/1, list_queue_names/0, count_queues/0, count_queues/1,
         delete_queue/2, internal_delete_queue/3, update_queue/2, lookup_queues/1,
         lookup_queue/1, lookup_durable_queue/1, delete_transient_queues/1,
         update_queue_decorators/1, not_found_or_absent_queue_dirty/1,
         lookup_durable_queues/1, exists_queue/1, list_queues_by_type/1]).

-export([store_queue/2, store_queues/1, store_queue_without_recover/2,
         store_queue_dirty/1]).

%% Routing. These functions are in the hot code path
-export([match_bindings/2, match_routing_key/3]).

-export([add_topic_trie_binding/4, delete_topic_trie_bindings_for_exchange/1,
         delete_topic_trie_bindings/1, route_delivery_for_exchange_type_topic/2]).

%% TODO maybe refactor after queues are migrated.
-export([store_durable_queue/1]).

%% TODO to become internal
-export([list_exchanges_in_khepri_tx/1,
         lookup_queue_in_khepri_tx/1]).

-export([mnesia_write_to_khepri/2,
         mnesia_delete_to_khepri/2,
         clear_data_in_khepri/1]).

-export([init/0, sync/0]).
-export([pre_import/0, post_import/0]).

-define(WAIT_SECONDS, 30).

%% Clustering used on the boot steps

init() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              recover_mnesia_tables(),
              rabbit_mnesia:init()
      end,
      fun() ->
              khepri_init()
      end).

khepri_init() ->
    case rabbit_khepri:members() of
        [] ->
            timer:sleep(1000),
            khepri_init();
        Members ->
            rabbit_log:warning("Found the following metadata store members: ~p", [Members])
    end.

sync() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_sup:start_child(mnesia_sync)
      end,
      fun() ->
              ok
      end).

pre_import() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              ok
      end,
      fun() ->
              rabbit_khepri:configure_snapshot_interval(409600000)
      end).

post_import() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              ok
      end,
      fun() ->
              rabbit_khepri:configure_snapshot_interval(4096)
      end).

%% Paths
%% --------------------------------------------------------------

%% Exchanges
khepri_exchanges_path() ->
    [?MODULE, exchanges].

khepri_exchange_path(#resource{virtual_host = VHost, name = Name}) ->
    [?MODULE, exchanges, VHost, Name].

khepri_exchange_serials_path() ->
    [?MODULE, exchanges_serials].

khepri_exchange_serial_path(#resource{virtual_host = VHost, name = Name}) ->
    [?MODULE, exchange_serials, VHost, Name].

%% Bindings

khepri_route_path(#binding{source = #resource{virtual_host = VHost, name = SrcName},
                           destination = #resource{kind = Kind, name = DstName},
                           key = RoutingKey}) ->
    [?MODULE, routes, VHost, SrcName, Kind, DstName, RoutingKey].

khepri_routes_path() ->
    [?MODULE, routes].

%% Routing optimisation, probably the most relevant on the hot code path.
%% It only needs to store a list of destinations to be used by rabbit_router.
%% Unless there is a high queue churn, this should barely change. Thus, the small
%% penalty for updates should be worth it.
khepri_routing_path() ->
    [?MODULE, routing].

khepri_routing_path(#binding{source = Src, key = RoutingKey}) ->
    khepri_routing_path(Src, RoutingKey).

khepri_routing_path(#resource{virtual_host = VHost, name = Name}, RoutingKey) ->
    [?MODULE, routing, VHost, Name, RoutingKey].

%% Queues
khepri_queues_path() ->
    [?MODULE, queues].

khepri_queue_path(#resource{virtual_host = VHost, name = Name}) ->
    [?MODULE, queues, VHost, Name].


khepri_exchange_type_topic_path(#resource{virtual_host = VHost, name = Name}) ->
    [?MODULE, topic_trie_binding, VHost, Name].

khepri_exchange_type_topic_path() ->
    [?MODULE, topic_trie_binding].

%% API
%% --------------------------------------------------------------
create_exchange(#exchange{name = XName} = X, PrePostCommitFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              execute_mnesia_transaction(
                fun() -> create_exchange_in_mnesia({rabbit_exchange, XName}, X) end,
                PrePostCommitFun)
      end,
      fun() ->
              PrePostCommitFun(create_exchange_in_khepri(khepri_exchange_path(XName), X),
                               all)
      end).

list_exchanges() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> list_in_mnesia(rabbit_exchange, #exchange{_ = '_'}) end,
      fun() -> list_in_khepri(khepri_exchanges_path() ++ [?STAR_STAR]) end).

count_exchanges() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> count_in_mnesia(rabbit_exchange) end,
      fun() -> count_in_khepri(khepri_exchanges_path()) end).

list_exchange_names() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              list_names_in_mnesia(rabbit_exchange)
      end,
      fun() ->
              case rabbit_khepri:match_and_get_data(khepri_exchanges_path() ++ [?STAR_STAR]) of
                  {ok, Map} ->
                      maps:fold(fun(_K, X, Acc) -> [X#exchange.name | Acc] end, [], Map);
                  _ ->
                      []
              end
      end).

list_exchanges(VHost) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              list_exchanges_in_mnesia(VHost)
      end,
      fun() ->
              list_in_khepri(khepri_exchanges_path() ++ [VHost, ?STAR_STAR])
      end).

%% TODO should be internal once rabbit_policy is migrated
list_exchanges_in_mnesia(VHost) ->
    Match = #exchange{name = rabbit_misc:r(VHost, exchange), _ = '_'},
    list_in_mnesia(rabbit_exchange, Match).

list_durable_exchanges() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              list_in_mnesia(rabbit_durable_exchange, #exchange{_ = '_'})
      end,
      fun() ->
              list_in_khepri(khepri_exchanges_path() ++ [?STAR_STAR])
      end).

match_exchanges(Pattern0) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              case mnesia:transaction(
                     fun() ->
                             mnesia:match_object(rabbit_exchange, Pattern0, read)
                     end) of
                  {atomic, Xs} -> Xs;
                  {aborted, Err} -> {error, Err}
              end
      end,
      fun() ->
              %% TODO error handling?
              Pattern = #if_data_matches{pattern = Pattern0},
              list_in_khepri(khepri_exchanges_path() ++ [?STAR, Pattern])
      end).

lookup_exchange(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> lookup({rabbit_exchange, Name}, mnesia) end,
      fun() -> lookup(khepri_exchange_path(Name), khepri) end).

lookup_many_exchanges(Names) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> lookup_many(rabbit_exchange, Names, mnesia) end,
      fun() -> lookup_many(fun khepri_exchange_path/1, Names, khepri) end).

%% TODO rabbit_policy:update_matched_objects_in_khepri
list_exchanges_in_khepri_tx(VHostPath) ->
    Path = khepri_exchanges_path() ++ [VHostPath, ?STAR_STAR],
    {ok, Map} = rabbit_khepri:tx_match_and_get_data(Path),
    maps:values(Map).

peek_exchange_serial(XName, LockType) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun() ->
                        peek_exchange_serial_in_mnesia(XName, LockType)
                end)
      end,
      fun() ->
              Path = khepri_exchange_serial_path(XName),
              case rabbit_khepri:get_data(Path) of
                  {ok, #exchange_serial{next = Serial}} ->
                      Serial;
                  _ ->
                      1
              end
      end).

peek_exchange_serial_in_mnesia(XName, LockType) ->
    case mnesia:read(rabbit_exchange_serial, XName, LockType) of
        [#exchange_serial{next = Serial}]  -> Serial;
        _                                  -> 1
    end.

next_exchange_serial(X) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(fun() ->
                                                             next_exchange_serial_in_mnesia(X)
                                                     end)
      end,
      fun() ->
              rabbit_khepri:transaction(fun() ->
                                                next_exchange_serial_in_khepri(X)
                                        end, rw)
      end).

next_exchange_serial_in_mnesia(#exchange{name = XName}) ->
    Serial = peek_exchange_serial_in_mnesia(XName, write),
    ok = mnesia:write(rabbit_exchange_serial,
                      #exchange_serial{name = XName, next = Serial + 1}, write),
    Serial.

next_exchange_serial_in_khepri(#exchange{name = XName}) ->
    Path = khepri_exchange_serial_path(XName),
    Extra = #{keep_while => #{khepri_exchange_path(XName) => #if_node_exists{exists = true}}},
    Serial = case khepri_tx:get(Path) of
                 {ok, #{Path := #{data := #exchange_serial{next = Serial0}}}} -> Serial0;
                 _ -> 1
             end,
    {ok, _} = khepri_tx:put(Path,
                            #exchange_serial{name = XName, next = Serial + 1},
                            Extra),
    Serial.

update_exchange_in_mnesia(Name, Fun) ->
    Table = {rabbit_exchange, Name},
    case lookup_tx_in_mnesia(Table) of
        [X] -> X1 = Fun(X),
               store_exchange_in_mnesia(X1);
        [] -> not_found
    end.

update_exchange_in_khepri(Name, Fun) ->
    Path = khepri_exchange_path(Name),
    case lookup_tx_in_khepri(Path) of
        [X] -> X1 = Fun(X),
               store_exchange_in_khepri(X1);
        [] -> not_found
    end.

update_exchange_decorators(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> update_exchange_decorators(Name, mnesia) end,
      fun() -> update_exchange_decorators(Name, khepri) end).

update_exchange_scratch(Name, ScratchFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun() ->
                        update_exchange_in_mnesia(Name, ScratchFun)
                end)
      end,
      fun() ->
              rabbit_khepri:transaction(
                fun() ->
                        update_exchange_in_khepri(Name, ScratchFun)
                end, rw)
      end).

store_durable_exchanges(Xs) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun () ->
                        [mnesia:write(rabbit_durable_exchange, X, write) || X <- Xs]
                end)
      end,
      fun() ->
              rabbit_khepri:transaction(
                fun() ->
                        [store_exchange_in_khepri(X) || X <- Xs]
                end, rw)
      end).

delete_exchange_in_mnesia(X = #exchange{name = XName}, OnlyDurable, RemoveBindingsForSource) ->
    ok = mnesia:delete({rabbit_exchange, XName}),
    mnesia:delete({rabbit_durable_exchange, XName}),
    remove_bindings_in_mnesia(X, OnlyDurable, RemoveBindingsForSource).

delete_exchange_in_khepri(X = #exchange{name = XName}, OnlyDurable, RemoveBindingsForSource) ->
    {ok, _} = khepri_tx:delete(khepri_exchange_path(XName)),
    remove_bindings_in_khepri(X, OnlyDurable, RemoveBindingsForSource).

delete_exchange(XName, IfUnused, PrePostCommitFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              DeletionFun = case IfUnused of
                                true  -> fun conditional_delete_exchange_in_mnesia/2;
                                false -> fun unconditional_delete_exchange_in_mnesia/2
                            end,
              execute_mnesia_transaction(
                fun() ->
                        case lookup_tx_in_mnesia({rabbit_exchange, XName}) of
                            [X] -> DeletionFun(X, false);
                            [] -> {error, not_found}
                        end
                end, PrePostCommitFun)
      end,
      fun() ->
              DeletionFun = case IfUnused of
                                true  -> fun conditional_delete_exchange_in_khepri/2;
                                false -> fun unconditional_delete_exchange_in_khepri/2
                            end,
              execute_khepri_transaction(
                fun() ->
                        case lookup_tx_in_khepri(khepri_exchange_path(XName)) of
                            [X] -> DeletionFun(X, false);
                            [] -> {error, not_found}
                        end
                end, PrePostCommitFun)
      end).

recover_exchanges(VHost) ->
   rabbit_khepri:try_mnesia_or_khepri(
     fun() -> recover_exchanges(VHost, mnesia) end,
     fun() -> recover_exchanges(VHost, khepri) end).

%% Bindings

exists_binding(#binding{source = SrcName,
                        destination = DstName} = Binding) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              binding_action_in_mnesia(
                Binding, fun (_Src, _Dst) ->
                                 rabbit_misc:const(mnesia:read({rabbit_route, Binding}) /= [])
                         end, fun not_found_or_absent_errs_in_mnesia/1)
      end,
      fun() ->
              Path = khepri_route_path(Binding),
              rabbit_khepri:transaction(
                fun () ->
                        case {lookup_resource_in_khepri_tx(SrcName),
                              lookup_resource_in_khepri_tx(DstName)} of
                            {[_Src], [_Dst]} ->
                                exists_binding_in_khepri(Path, Binding);
                            Errs -> not_found_errs_in_khepri(
                                      not_found(Errs, SrcName, DstName))
                        end
                end, ro)
      end).

add_binding(Binding, ChecksFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> add_binding_in_mnesia(Binding, ChecksFun) end,
      fun() -> add_binding_in_khepri(Binding, ChecksFun) end).

delete_binding(Binding, ChecksFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> remove_binding_in_mnesia(Binding, ChecksFun) end,
      fun() -> remove_binding_in_khepri(Binding, ChecksFun) end).

list_bindings(VHost) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              VHostResource = rabbit_misc:r(VHost, '_'),
              Match = #route{binding = #binding{source      = VHostResource,
                                                destination = VHostResource,
                                                _           = '_'},
                             _       = '_'},
              [B || #route{binding = B} <- list_in_mnesia(rabbit_route, Match)]
      end,
      fun() ->
              Path = khepri_routes_path() ++ [VHost, ?STAR_STAR],
              lists:foldl(fun(SetOfBindings, Acc) ->
                                  sets:to_list(SetOfBindings) ++ Acc
                          end, [], list_in_khepri(Path))
      end).

list_bindings_for_source(#resource{virtual_host = VHost, name = Name} = Resource) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              Route = #route{binding = #binding{source = Resource, _ = '_'}},
              [B || #route{binding = B} <- list_in_mnesia(rabbit_route, Route)]
      end,
      fun() ->
              Path = khepri_routes_path() ++ [VHost, Name, ?STAR_STAR],
              lists:foldl(fun(SetOfBindings, Acc) ->
                                  sets:to_list(SetOfBindings) ++ Acc
                          end, [], list_in_khepri(Path))
      end).

list_bindings_for_destination(#resource{virtual_host = VHost, name = Name,
                                        kind = Kind} = Resource) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              Route = rabbit_binding:reverse_route(#route{binding = #binding{destination = Resource,
                                                                             _ = '_'}}),
              [rabbit_binding:reverse_binding(B) ||
                  #reverse_route{reverse_binding = B} <- list_in_mnesia(rabbit_reverse_route, Route)]
      end,
      fun() ->
              Path = khepri_routes_path() ++ [VHost, ?STAR, Kind, Name, ?STAR_STAR],
              lists:foldl(fun(SetOfBindings, Acc) ->
                                  sets:to_list(SetOfBindings) ++ Acc
                          end, [], list_in_khepri(Path))
      end).

list_bindings_for_source_and_destination(SrcName, DstName) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              Route = #route{binding = #binding{source      = SrcName,
                                                destination = DstName,
                                                _           = '_'}},
              [B || #route{binding = B} <- list_in_mnesia(rabbit_route, Route)]
      end,
      fun() ->
              Values = match_source_and_destination_in_khepri(SrcName, DstName),
              lists:foldl(fun(SetOfBindings, Acc) ->
                                  sets:to_list(SetOfBindings) ++ Acc
                          end, [], Values)
      end).

list_explicit_bindings() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              mnesia:async_dirty(
                fun () ->
                        AllRoutes = mnesia:dirty_match_object(rabbit_route, #route{_ = '_'}),
                        [B || #route{binding = B} <- AllRoutes]
                end)
      end,
      fun() ->
              Condition = #if_not{condition = #if_name_matches{regex = "^$"}},
              Path = khepri_routes_path() ++ [?STAR, Condition, ?STAR_STAR],
              {ok, Data} = rabbit_khepri:match_and_get_data(Path),
              lists:foldl(fun(SetOfBindings, Acc) ->
                                  sets:to_list(SetOfBindings) ++ Acc
                          end, [], maps:values(Data))
      end).

recover_bindings() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> recover_bindings_in_mnesia() end,
      %% Nothing to do in khepri, single table storage
      fun() -> ok end).

recover_bindings(RecoverFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              [RecoverFun(Route, Src, Dst, fun recover_semi_durable_route_txn/3, mnesia) ||
                  #route{binding = #binding{destination = Dst,
                                            source = Src}} = Route <-
                      rabbit_misc:dirty_read_all(rabbit_semi_durable_route)]
      end,
      fun() ->
              ok
      end).

%% Implicit bindings are implicit as of rabbitmq/rabbitmq-server#1721.
delete_binding(Binding) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              delete_binding_in_mnesia(Binding)
      end,
      fun() ->
              delete_binding_in_khepri(Binding)
      end).

%% Queues
list_queues() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> list_queues_with_possible_retry_in_mnesia(
                 fun() ->
                         list_in_mnesia(rabbit_queue, amqqueue:pattern_match_all())
                 end)
      end,
      fun() -> list_queues_with_possible_retry_in_khepri(
                 fun() ->
                         list_in_khepri(khepri_queues_path() ++ [?STAR_STAR])
                 end)
      end).

list_durable_queues() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> list_queues_with_possible_retry_in_mnesia(
                 fun() ->
                         list_in_mnesia(rabbit_durable_queue, amqqueue:pattern_match_all())
                 end)
      end,
      fun() -> list_queues_with_possible_retry_in_khepri(
                 fun() ->
                         list_in_khepri(khepri_queues_path() ++ [?STAR_STAR])
                 end)
      end).

list_durable_queues_by_type(Type) ->
    Pattern = amqqueue:pattern_match_on_type(Type),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              list_in_mnesia(rabbit_durable_queue, Pattern)
      end,
      fun() ->
              list_in_khepri(khepri_queues_path() ++ [#if_data_matches{pattern = Pattern}])
      end).

list_queues_by_type(Type) ->
    Pattern = amqqueue:pattern_match_on_type(Type),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              list_in_mnesia(rabbit_queue, Pattern)
      end,
      fun() ->
              list_in_khepri(khepri_queues_path() ++ [#if_data_matches{pattern = Pattern}])
      end).

list_queues(VHost) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              list_queues_in_mnesia(VHost)
      end,
      fun() -> list_queues_with_possible_retry_in_khepri(
                 fun() ->
                         list_in_khepri(khepri_queues_path() ++ [VHost, ?STAR_STAR])
                 end)
      end).

%% TODO to become internal, used by rabbit_policy
list_queues_in_mnesia(VHost) ->
    list_queues_with_possible_retry_in_mnesia(
      fun() ->
              Pattern = amqqueue:pattern_match_on_name(rabbit_misc:r(VHost, queue)),
              list_in_mnesia(rabbit_queue, Pattern)
      end).

%% TODO to become internal, used by rabbit_policy
list_queues_in_khepri_tx(VHostPath) ->
    Path = khepri_queues_path(),
    {ok, Map} = rabbit_khepri:tx_match_and_get_data(Path ++ [VHostPath, ?STAR_STAR]),
    maps:values(Map).

list_durable_queues(VHost) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> list_queues_with_possible_retry_in_mnesia(
                 fun() ->
                         Pattern = amqqueue:pattern_match_on_name(rabbit_misc:r(VHost, queue)),
                         list_in_mnesia(rabbit_durable_queue, Pattern)
                 end)
      end,
      fun() -> list_queues_with_possible_retry_in_khepri(
                 fun() ->
                         list_in_khepri(khepri_queues_path() ++ [VHost, ?STAR_STAR])
                 end)
      end).

list_queue_names() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> list_names_in_mnesia(rabbit_queue) end,
      fun() ->
              case rabbit_khepri:match_and_get_data(khepri_queues_path() ++ [?STAR_STAR]) of
                  {ok, Map} ->
                      maps:fold(fun(_K, Q, Acc) -> [amqqueue:get_name(Q) | Acc] end, [], Map);
                  _ ->
                      []
              end
      end).

count_queues() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> count_in_mnesia(rabbit_queue) end,
      fun() -> count_in_khepri(khepri_queues_path()) end).

count_queues(VHost) ->
    try
        list_queues_for_count(VHost)
    catch _:Err ->
            rabbit_log:error("Failed to fetch number of queues in vhost ~p:~n~p",
                             [VHost, Err]),
            0
    end.

delete_queue(QueueName, Reason) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              delete_queue_in_mnesia(QueueName, Reason)
      end,
      fun() ->
              delete_queue_in_khepri(QueueName, Reason)
      end).

internal_delete_queue(QueueName, OnlyDurable, Reason) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              internal_delete_queue_in_mnesia(QueueName, OnlyDurable, Reason)
      end,
      fun() ->
              internal_delete_queue_in_khepri(QueueName, OnlyDurable, Reason)
      end).

delete_transient_queues(Queues) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun () ->
                        [{QName, rabbit_binding:process_deletions(delete_transient_queue_in_mnesia(QName), true)}
                         || QName <- Queues]
                end)
      end,
      fun() ->
              []
      end).

store_durable_queue(Q) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun() ->
                        mnesia:write(rabbit_durable_queue, Q, write)
                end)
      end,
      fun() ->
              Path = khepri_queue_path(amqqueue:get_name(Q)),
              case rabbit_khepri:put(Path, Q) of
                  {ok, _} -> ok;
                  Error   -> Error
              end
      end).

lookup_queue(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> lookup({rabbit_queue, Name}, mnesia) end,
      fun() -> lookup(khepri_queue_path(Name), khepri) end).

lookup_durable_queue(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> lookup({rabbit_durable_queue, Name}, mnesia) end,
      fun() -> lookup(khepri_queue_path(Name), khepri) end).

%% TODO this should be internal, it's here because of mirrored queues
lookup_queue_in_khepri_tx(Name) ->
    lookup_tx_in_khepri(khepri_queue_path(Name)).

lookup_queues(Names) when is_list(Names) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> lookup_many(rabbit_queue, Names, mnesia) end,
      fun() -> lookup_many(fun khepri_queue_path/1, Names, khepri) end);
lookup_queues(Name) ->
    lookup_queue(Name).

lookup_durable_queues(Names) when is_list(Names) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> lookup_many(rabbit_durable_queue, Names, mnesia) end,
      fun() -> lookup_many(fun khepri_queue_path/1, Names, khepri) end);
lookup_durable_queues(Name) ->
    lookup_durable_queue(Name).

exists_queue(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              ets:member(rabbit_queue, Name)
      end,
      fun() ->
              rabbit_khepri:exists(khepri_queue_path(Name))
      end).

update_queue(Name, Fun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> rabbit_misc:execute_mnesia_transaction(
                 fun() ->
                         update_queue_in_mnesia(Name, Fun)
                 end)
      end,
      fun() -> rabbit_khepri:transaction(
                 fun() ->
                         update_queue_in_khepri(Name, Fun)
                 end, rw)
      end).

store_queue(DurableQ, Q) ->
    QName = amqqueue:get_name(Q),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun () ->
                        case ?amqqueue_is_durable(Q) of
                            true ->
                                ok = mnesia:write(rabbit_durable_queue, DurableQ, write);
                            false ->
                                ok
                        end,
                        ok = mnesia:write(rabbit_queue, Q, write)
                end)
      end,
      fun() ->
              Path = khepri_queue_path(QName),
              case rabbit_khepri:put(Path, Q) of
                  {ok, _} -> ok;
                  Error -> Error
              end
      end).

store_queue_without_recover(DurableQ, Q) ->
    QueueName = amqqueue:get_name(Q),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun () ->
                        case mnesia:wread({rabbit_queue, QueueName}) of
                            [] ->
                                case not_found_or_absent_queue_in_mnesia(QueueName) of
                                    not_found           ->
                                        case ?amqqueue_is_durable(Q) of
                                            true ->
                                                ok = mnesia:write(rabbit_durable_queue, DurableQ, write);
                                            false ->
                                                ok
                                        end,
                                        ok = mnesia:write(rabbit_queue, Q, write),
                                        {created, Q};
                                    {absent, _Q, _} = R ->
                                        R
                                end;
                            [ExistingQ] ->
                                {existing, ExistingQ}
                        end
                end)
      end,
      fun() ->
              Path = khepri_queue_path(QueueName),
              case rabbit_khepri:create(Path, Q) of
                  {ok, #{Path := #{data := ExistingQ}}} ->
                      {existing, ExistingQ};
                  _ ->
                      {created, Q}
              end
      end).

store_queue_dirty(Q) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              ok = mnesia:dirty_write(rabbit_queue, rabbit_queue_decorator:set(Q))
      end,
      fun() ->
              Path = khepri_queue_path(amqqueue:get_name(Q)),
              case rabbit_khepri:put(Path, Q) of
                  {ok, _} -> ok;
                  Error -> throw(Error)
              end
      end).

store_queues(Qs) ->
    %% TODO only durable or both?
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun() ->
                        [ok = mnesia:write(rabbit_durable_queue, Q, write) || Q <- Qs]
                end)
      end,
      fun() ->
              rabbit_khepri:transaction(
                fun() ->
                        [begin
                             Path = khepri_queue_path(amqqueue:get_name(Q)),
                             store_in_khepri(Path, Q)
                         end || Q <- Qs]
                end)
      end).

update_queue_decorators(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> update_queue_decorators_in_mnesia(Name) end,
      fun() -> update_queue_decorators_in_khepri(Name) end).


%% Routing - HOT CODE PATH

match_bindings(SrcName, Match) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              MatchHead = #route{binding = #binding{source      = SrcName,
                                                    _           = '_'}},
              Routes = ets:select(rabbit_route, [{MatchHead, [], [['$_']]}]),
              [Dest || [#route{binding = Binding = #binding{destination = Dest}}] <-
                           Routes, Match(Binding)]
      end,
      fun() ->
              Data = match_source_in_khepri(SrcName),
              Bindings = lists:foldl(fun(SetOfBindings, Acc) ->
                                             sets:to_list(SetOfBindings) ++ Acc
                                     end, [], maps:values(Data)),
              [Dest || Binding = #binding{destination = Dest} <- Bindings, Match(Binding)]
      end).

match_routing_key(SrcName, RoutingKeys, UseIndex) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              case UseIndex of
                  true ->
                      route_in_mnesia_v2(SrcName, RoutingKeys);
                  _ ->
                      route_in_mnesia_v1(SrcName, RoutingKeys)
              end
      end,
      fun() ->
              match_source_and_key_in_khepri(SrcName, RoutingKeys)
      end).

route_in_mnesia_v1(SrcName, [RoutingKey]) ->
    MatchHead = #route{binding = #binding{source      = SrcName,
                                          destination = '$1',
                                          key         = RoutingKey,
                                          _           = '_'}},
    ets:select(rabbit_route, [{MatchHead, [], ['$1']}]);
route_in_mnesia_v1(SrcName, [_|_] = RoutingKeys) ->
    %% Normally we'd call mnesia:dirty_select/2 here, but that is quite
    %% expensive for the same reasons as above, and, additionally, due to
    %% mnesia 'fixing' the table with ets:safe_fixtable/2, which is wholly
    %% unnecessary. According to the ets docs (and the code in erl_db.c),
    %% 'select' is safe anyway ("Functions that internally traverse over a
    %% table, like select and match, will give the same guarantee as
    %% safe_fixtable.") and, furthermore, even the lower level iterators
    %% ('first' and 'next') are safe on ordered_set tables ("Note that for
    %% tables of the ordered_set type, safe_fixtable/2 is not necessary as
    %% calls to first/1 and next/2 will always succeed."), which
    %% rabbit_route is.
    MatchHead = #route{binding = #binding{source      = SrcName,
                                          destination = '$1',
                                          key         = '$2',
                                          _           = '_'}},
    Conditions = [list_to_tuple(['orelse' | [{'=:=', '$2', RKey} ||
                                                RKey <- RoutingKeys]])],
    ets:select(rabbit_route, [{MatchHead, Conditions, ['$1']}]).

%% rabbit_router:match_routing_key/2 uses ets:select/2 to get destinations.
%% ets:select/2 is expensive because it needs to compile the match spec every
%% time and lookup does not happen by a hash key.
%%
%% In contrast, route_v2/2 increases end-to-end message sending throughput
%% (i.e. from RabbitMQ client to the queue process) by up to 35% by using ets:lookup_element/3.
%% Only the direct exchange type uses the rabbit_index_route table to store its
%% bindings by table key tuple {SourceExchange, RoutingKey}.
-spec route_in_mnesia_v2(rabbit_types:binding_source(), [rabbit_router:routing_key(), ...]) ->
    rabbit_router:match_result().
route_in_mnesia_v2(SrcName, [RoutingKey]) ->
    %% optimization
    destinations(SrcName, RoutingKey);
route_in_mnesia_v2(SrcName, [_|_] = RoutingKeys) ->
    lists:flatmap(fun(Key) ->
                          destinations(SrcName, Key)
                  end, RoutingKeys).

destinations(SrcName, RoutingKey) ->
    %% Prefer try-catch block over checking Key existence with ets:member/2.
    %% The latter reduces throughput by a few thousand messages per second because
    %% of function db_member_hash in file erl_db_hash.c.
    %% We optimise for the happy path, that is the binding / table key is present.
    try
        ets:lookup_element(rabbit_index_route,
                           {SrcName, RoutingKey},
                           #index_route.destination)
    catch
        error:badarg ->
            []
    end.

%% Exchange type topic
add_topic_trie_binding(XName, RoutingKey, Destination, Args) ->
    Path = khepri_exchange_type_topic_path(XName) ++ split_topic_trie_key(RoutingKey),
    Binding = #{destination => Destination, arguments => Args},
    rabbit_khepri:transaction(
      fun() ->
              Set0 = case khepri_tx:get(Path) of
                         {ok, #{Path := #{data := S}}} -> S;
                         _ -> sets:new()
                     end,
              Set = sets:add_element(Binding, Set0),
              {ok, _} = khepri_tx:put(Path, Set),
              ok
      end, rw).

add_topic_trie_binding_tx(XName, RoutingKey, Destination, Args) ->
    Path = khepri_exchange_type_topic_path(XName) ++ split_topic_trie_key(RoutingKey),
    Binding = #{destination => Destination, arguments => Args},
    Set0 = case khepri_tx:get(Path) of
               {ok, #{Path := #{data := S}}} -> S;
               _ -> sets:new()
           end,
    Set = sets:add_element(Binding, Set0),
    {ok, _} = khepri_tx:put(Path, Set).

route_delivery_for_exchange_type_topic(XName, RoutingKey) ->
    Words = lists:map(fun(W) -> #if_any{conditions = [W, <<"*">>]} end,
                      split_topic_trie_key(RoutingKey)),
    Root = khepri_exchange_type_topic_path(XName),
    Path = Root ++ Words,
    Fanout = Root ++ [<<"#">>],
    Map = rabbit_khepri:transaction(
            fun() ->
                    case khepri_tx:get(Fanout, #{expect_specific_node => true}) of
                        {ok, #{Fanout := #{data := _}} = Map} ->
                            Map;
                        _ ->
                            case khepri_tx:get(Path) of
                                {ok, Map} -> Map;
                                _ -> #{}
                            end
                    end
            end, ro),
    maps:fold(fun(_, #{data := Data}, Acc) ->
                      Bindings = sets:to_list(Data),
                      [maps:get(destination, B) || B <- Bindings] ++ Acc;
                 (_, _, Acc) ->
                      Acc
              end, [], Map).

delete_topic_trie_bindings_for_exchange(XName) ->
    {ok, _} = rabbit_khepri:delete(khepri_exchange_type_topic_path(XName)),
    ok.

delete_topic_trie_bindings(Bs) ->
    %% Let's handle bindings data outside of the transaction for efficiency
    Data = [begin
                Path = khepri_exchange_type_topic_path(X) ++ split_topic_trie_key(K),
                {Path, #{destination => D, arguments => Args}}
            end || #binding{source = X, key = K, destination = D, args = Args} <- Bs],
    rabbit_khepri:transaction(
      fun() ->
              [begin
                   case khepri_tx:get(Path) of
                       {ok, #{Path := #{data := Set0,
                                        child_list_length := Children}}} ->
                           Set = sets:del_element(Binding, Set0),
                           case {Children, sets:size(Set)} of
                               {0, 0} ->
                                   khepri_tx:delete(Path),
                                   %% TODO can we use a keep_while condition?
                                   remove_path_if_empty(lists:droplast(Path));
                               _ ->
                                   khepri_tx:put(Path, Set)
                           end;
                       _ ->
                           ok
                   end
               end || {Path, Binding} <- Data]
      end, rw),
    ok.

%% Feature flags
%% --------------------------------------------------------------

mnesia_write_to_khepri(rabbit_queue, Qs) ->
    rabbit_khepri:transaction(
      fun() ->
              [begin
                   Path = khepri_queue_path(amqqueue:get_name(Q)),
                   case khepri_tx:create(Path, Q) of
                       {ok, _} -> ok;
                       Error -> throw(Error)
                   end
               end || Q <- Qs]
      end, rw);
mnesia_write_to_khepri(rabbit_durable_queue, _Qs) ->
    %% All durable queues are on the `rabbit_queue` table too
    ok;
%% Mnesia contains two tables if an exchange has been recovered:
%% rabbit_exchange (ram) and rabbit_durable_exchange (disc).
%% As all data in Khepri is persistent, there is no point on
%% having ram and data entries.
%% How do we then transform data from mnesia to khepri when
%% the feature flag is enabled?
%% Let's create the Khepri entry from the ram table.
mnesia_write_to_khepri(rabbit_exchange, Exchanges) ->
    rabbit_khepri:transaction(
      fun() ->
              [khepri_create_tx(khepri_exchange_path(Exchange#exchange.name), Exchange)
               || Exchange <- Exchanges]
      end, rw);                       
mnesia_write_to_khepri(rabbit_durable_exchange, _Exchange0) ->
    ok;
mnesia_write_to_khepri(rabbit_exchange_serial, Exchanges) ->
    rabbit_khepri:transaction(
      fun() ->
              [begin
                   #exchange_serial{name = Resource} = Exchange,              
                   Path = khepri_path:combine_with_conditions(khepri_exchange_serial_path(Resource),
                                                              [#if_node_exists{exists = false}]),
                   Extra = #{keep_while => #{khepri_exchange_path(Resource) => #if_node_exists{exists = true}}},
                   case khepri_tx:put(Path, Exchange, Extra) of
                       {ok, _} -> ok;
                       Error -> throw(Error)
                   end
               end || Exchange <- Exchanges]
      end, rw);
mnesia_write_to_khepri(rabbit_route, Routes)->
    rabbit_khepri:transaction(
      fun() ->
              [begin
                   #route{binding = Binding} = Route,
                   Path = khepri_route_path(Binding),
                   add_binding_tx(Path, Binding)
               end || Route <- Routes]
      end, rw);
mnesia_write_to_khepri(rabbit_durable_route, _)->
    ok;
mnesia_write_to_khepri(rabbit_semi_durable_route, _)->
    ok;
mnesia_write_to_khepri(rabbit_reverse_route, _) ->
    ok;
mnesia_write_to_khepri(rabbit_topic_trie_binding, TrieBindings0) ->
    %% There isn't enough information to rebuild the tree as the routing key is split
    %% along the trie tree on mnesia. But, we can query the bindings table (migrated
    %% previosly) and migrate the entries that match this <X, D> combo.
    %% Multiple bindings to the same exchange/destination combo need to be migrated only once.
    %% Remove here the duplicates and use a temporary ets table to keep track of those already
    %% migrated to really speed up things.
    Table = ensure_topic_migration_ets(),
    TrieBindings1 =
        lists:uniq([{X, D} || #topic_trie_binding{trie_binding = #trie_binding{exchange_name = X,
                                                                               destination   = D}}
                                  <- TrieBindings0]),
    TrieBindings = lists:filter(fun({X, D}) ->
                                        ets:insert_new(Table, {{X, D}, empty})
                                end, TrieBindings1),
    rabbit_khepri:transaction(
      fun() ->
              [begin
                   Values = match_source_and_destination_in_khepri_tx(X, D),
                   Bindings = lists:foldl(fun(SetOfBindings, Acc) ->
                                                  sets:to_list(SetOfBindings) ++ Acc
                                          end, [], Values),
                   [add_topic_trie_binding_tx(X, K, D, Args) || #binding{key = K,
                                                                         args = Args} <- Bindings]
               end || {X, D} <- TrieBindings]
      end);
mnesia_write_to_khepri(rabbit_topic_trie_node, _) ->
    %% Nothing to do, the `rabbit_topic_trie_binding` is enough to perform the migration
    %% as Khepri stores each topic binding as a single path
    ok;
mnesia_write_to_khepri(rabbit_topic_trie_edge, _) ->
    %% Nothing to do, the `rabbit_topic_trie_binding` is enough to perform the migration
    %% as Khepri stores each topic binding as a single path
    ok.

ensure_topic_migration_ets() ->
    Tab = rabbit_topic_trie_binding_migration_table,
    case ets:whereis(Tab) of
        undefined ->
            ets:new(Tab, [public, named_table]);
        Tid ->
            Tid
    end.

mnesia_delete_to_khepri(rabbit_queue, Q) when ?is_amqqueue(Q) ->
    khepri_delete(khepri_queue_path(amqqueue:get_name(Q)));
mnesia_delete_to_khepri(rabbit_queue, Name) when is_record(Name, resource) ->
    khepri_delete(khepri_queue_path(Name));
mnesia_delete_to_khepri(rabbit_durable_queue, Q) when ?is_amqqueue(Q) ->
    khepri_delete(khepri_queue_path(amqqueue:get_name(Q)));
mnesia_delete_to_khepri(rabbit_durable_queue, Name) when is_record(Name, resource) ->
    khepri_delete(khepri_queue_path(Name));
mnesia_delete_to_khepri(rabbit_exchange, Exchange) when is_record(Exchange, exchange) ->
    khepri_delete(khepri_exchange_path(Exchange#exchange.name));
mnesia_delete_to_khepri(rabbit_exchange, Name) ->
    khepri_delete(khepri_exchange_path(Name));
mnesia_delete_to_khepri(rabbit_durable_exchange, Exchange)
  when is_record(Exchange, exchange) ->
    khepri_delete(khepri_exchange_path(Exchange#exchange.name));
mnesia_delete_to_khepri(rabbit_durable_exchange, Name) ->
    khepri_delete(khepri_exchange_path(Name));
mnesia_delete_to_khepri(rabbit_exchange_serial, ExchangeSerial)
  when is_record(ExchangeSerial, exchange_serial) ->
    khepri_delete(khepri_exchange_serial_path(ExchangeSerial#exchange_serial.name));
mnesia_delete_to_khepri(rabbit_exchange_serial, Name) ->
    khepri_delete(khepri_exchange_serial_path(Name));
mnesia_delete_to_khepri(rabbit_route, Route) when is_record(Route, route) ->
    khepri_delete(khepri_route_path(Route#route.binding));
mnesia_delete_to_khepri(rabbit_route, Name) ->
    khepri_delete(khepri_route_path(Name));
mnesia_delete_to_khepri(rabbit_durable_route, Route) when is_record(Route, route) ->
    khepri_delete(khepri_route_path(Route#route.binding));
mnesia_delete_to_khepri(rabbit_durable_route, Name) ->
    khepri_delete(khepri_route_path(Name));
mnesia_delete_to_khepri(rabbit_semi_durable_route, Route) when is_record(Route, route) ->
    khepri_delete(khepri_route_path(Route#route.binding));
mnesia_delete_to_khepri(rabbit_semi_durable_route, Name) ->
    khepri_delete(khepri_route_path(Name));
mnesia_delete_to_khepri(rabbit_topic_trie_binding, #topic_trie_binding{}) ->
    %% TODO No routing keys here, how do we do? Use the node_id to search on the tree?
    %% Can we still query mnesia content?
    ok;
mnesia_delete_to_khepri(rabbit_topic_trie_node, #topic_trie_node{}) ->
    %% TODO see above
    ok;
mnesia_delete_to_khepri(rabbit_topic_trie_edge, #topic_trie_edge{}) ->
    %% TODO see above
    ok.

clear_data_in_khepri(rabbit_queue) ->
    khepri_delete(khepri_queues_path());
clear_data_in_khepri(rabbit_durable_queue) ->
    khepri_delete(khepri_queues_path());
clear_data_in_khepri(rabbit_exchange) ->
    khepri_delete(khepri_exchanges_path());
%% There is a single khepri entry for exchanges and it should be already deleted
clear_data_in_khepri(rabbit_durable_exchange) ->
    ok;
clear_data_in_khepri(rabbit_exchange_serial) ->
    khepri_delete(khepri_exchange_serials_path());
clear_data_in_khepri(rabbit_route) ->
    khepri_delete(khepri_routes_path()),
    khepri_delete(khepri_routing_path());
%% There is a single khepri entry for routes and it should be already deleted
clear_data_in_khepri(rabbit_durable_route) ->
    ok;
clear_data_in_khepri(rabbit_semi_durable_route) ->
    ok;
clear_data_in_khepri(rabbit_reverse_route) ->
    ok;
clear_data_in_khepri(rabbit_topic_trie_binding) ->
    khepri_delete(khepri_exchange_type_topic_path());
%% There is a single khepri entry for topics and it should be already deleted
clear_data_in_khepri(rabbit_topic_trie_node) ->
    ok;
clear_data_in_khepri(rabbit_topic_trie_edge) ->
    ok.

%% Internal
%% -------------------------------------------------------------
list_in_mnesia(Table, Match) ->
    %% Not dirty_match_object since that would not be transactional when used in a
    %% tx context
    mnesia:async_dirty(fun () -> mnesia:match_object(Table, Match, read) end).

list_in_khepri(Path) ->
    list_in_khepri(Path, #{}).

list_in_khepri(Path, Options) ->
    case rabbit_khepri:match_and_get_data(Path, Options) of
        {ok, Map} -> maps:values(Map);
        _         -> []
    end.

list_in_khepri_tx(Path) ->
    case rabbit_khepri:tx_match_and_get_data(Path) of
        {ok, Map} -> maps:values(Map);
        _         -> []
    end.

count_in_mnesia(Table) ->
    mnesia:table_info(Table, size).

count_in_khepri(Path) ->
    case rabbit_khepri:match(Path ++ [?STAR_STAR]) of
        {ok, Map} -> maps:size(Map);
        _            -> 0
    end.

list_names_in_mnesia(Table) ->
    mnesia:dirty_all_keys(Table).

lookup(Name, mnesia) ->
    rabbit_misc:dirty_read(Name);
lookup(Path, khepri) ->
    case rabbit_khepri:get_data(Path) of
        {ok, X} -> {ok, X};
        _ -> {error, not_found}
    end.

lookup_many(Table, [Name], mnesia) -> ets:lookup(Table, Name);
lookup_many(Table, Names, mnesia) when is_list(Names) ->
    %% Normally we'd call mnesia:dirty_read/1 here, but that is quite
    %% expensive for reasons explained in rabbit_misc:dirty_read/1.
    lists:append([ets:lookup(Table, Name) || Name <- Names]);
lookup_many(Fun, Names, khepri) when is_list(Names) ->
    lists:foldl(fun(Name, Acc) ->
                        case lookup(Fun(Name), khepri) of
                            {ok, X} -> [X | Acc];
                            _ -> Acc
                        end
                end, [], Names).

update_exchange_decorators(Name, mnesia) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() ->
              case mnesia:wread({rabbit_exchange, Name}) of
                  [X] -> store_ram_exchange(X),
                         ok;
                  []  -> ok
              end
      end);
update_exchange_decorators(#resource{virtual_host = VHost, name = Name} = XName, khepri) ->
    Path = khepri_exchange_path(XName),
    retry(
      fun () ->
              case rabbit_khepri:get(Path) of
                  {ok, #{data := X, payload_version := Vsn}} ->
                      X1 = rabbit_exchange_decorator:set(X),
                      Conditions = #if_all{conditions = [Name, #if_payload_version{version = Vsn}]},
                      UpdatePath = khepri_exchanges_path() ++ [VHost, Conditions],
                      case rabbit_khepri:put(UpdatePath, X1) of
                          {ok, _} -> ok;
                          Err -> Err
                      end;
                  _ ->
                      ok
              end
      end).

store_exchange_in_mnesia(X = #exchange{durable = true}) ->
    mnesia:write(rabbit_durable_exchange, X#exchange{decorators = undefined},
                 write),
    store_ram_exchange(X);
store_exchange_in_mnesia(X = #exchange{durable = false}) ->
    store_ram_exchange(X).

store_exchange_in_khepri(X) ->
    Path = khepri_exchange_path(X#exchange.name),
    {ok, _} = khepri_tx:put(Path, X),
    X.

store_ram_exchange(X) ->
    X1 = rabbit_exchange_decorator:set(X),
    ok = mnesia:write(rabbit_exchange, X1, write),
    X1.

create_exchange_in_mnesia(Name, X) ->
    case lookup_tx_in_mnesia(Name) of
        [] ->
            {new, store_exchange_in_mnesia(X)};
        [ExistingX] ->
            {existing, ExistingX}
    end.

create_exchange_in_khepri(Path, X) ->
    case rabbit_khepri:create(Path, X) of
        {ok, _} ->
            {new, X};
        {error, {mismatching_node, #{node_props := #{data := ExistingX}}}} ->
            {existing, ExistingX}
    end.

execute_mnesia_transaction(TxFun, PrePostCommitFun) ->
    case mnesia:is_transaction() of
        true  -> throw(unexpected_transaction);
        false -> ok
    end,
    PrePostCommitFun(rabbit_misc:execute_mnesia_transaction(
                       fun () ->
                               Result = TxFun(),
                               PrePostCommitFun(Result, true)
                       end), false).

execute_khepri_transaction(TxFun, PostCommitFun) ->
    execute_khepri_transaction(TxFun, PostCommitFun, #{}).

execute_khepri_transaction(TxFun, PostCommitFun, Options) ->
    case khepri_tx:is_transaction() of
        true  -> throw(unexpected_transaction);
        false -> ok
    end,
    PostCommitFun(rabbit_khepri:transaction(
                    fun () ->
                            TxFun()
                    end, rw, Options), all).

remove_bindings_in_mnesia(X = #exchange{name = XName}, OnlyDurable, RemoveBindingsForSource) ->
    Bindings = case RemoveBindingsForSource of
                   true  -> remove_bindings_for_source_in_mnesia(XName);
                   false -> []
               end,
    {deleted, X, Bindings, remove_bindings_for_destination_in_mnesia(XName, OnlyDurable, fun remove_routes/1)}.

remove_bindings_in_khepri(X = #exchange{name = XName}, OnlyDurable, RemoveBindingsForSource) ->
    Bindings = case RemoveBindingsForSource of
                   true  -> remove_bindings_for_source_in_khepri(XName);
                   false -> []
               end,
    {deleted, X, Bindings, remove_bindings_for_destination_in_khepri(XName, OnlyDurable)}.

map_create_tx(true) -> transaction;
map_create_tx(false) -> none.
    
recover_exchanges(VHost, mnesia) ->
    rabbit_misc:table_filter(
      fun (#exchange{name = XName}) ->
              XName#resource.virtual_host =:= VHost andalso
                  mnesia:read({rabbit_exchange, XName}) =:= []
      end,
      fun (X, Tx) ->
      X1 = case Tx of
                       true  -> store_exchange_in_mnesia(X);
                       false -> rabbit_exchange_decorator:set(X)
                   end,
              %% TODO how do we guarantee that lower down the callback
              %% we use the right transaction type? mnesia/khepri
              rabbit_exchange:callback(X1, create, map_create_tx(Tx), [X1])
      end,
      rabbit_durable_exchange);
recover_exchanges(VHost, khepri) ->
    %% Transient exchanges are deprecated in Khepri, all exchanges are recovered
    Exchanges0 = list_in_khepri(khepri_exchanges_path() ++ [VHost, ?STAR_STAR],
                                #{timeout => infinity}),
    Exchanges = [rabbit_exchange_decorator:set(X) || X <- Exchanges0],

    rabbit_khepri:transaction(
      fun() ->
              [_ = store_exchange_in_khepri(X) || X <- Exchanges]
      end, rw, #{timeout => infinity}),
    %% TODO once mnesia is gone, this callback should go back to `rabbit_exchange`
    [begin
         rabbit_exchange:callback(X, create, [transaction, none], [X])
     end || X <- Exchanges],
    Exchanges.

lookup_tx_in_mnesia(Name) ->
    mnesia:wread(Name).

lookup_tx_in_khepri(Path) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := X}}} -> [X];
        _ -> []
    end.

binding_action_in_mnesia(#binding{source      = SrcName,
                                  destination = DstName}, Fun, ErrFun) ->
    SrcTable = table_for_resource(SrcName),
    DstTable = table_for_resource(DstName),
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case {mnesia:read({SrcTable, SrcName}),
                    mnesia:read({DstTable, DstName})} of
                  {[Src], [Dst]} -> Fun(Src, Dst);
                  {[],    [_]  } -> ErrFun([SrcName]);
                  {[_],   []   } -> ErrFun([DstName]);
                  {[],    []   } -> ErrFun([SrcName, DstName])
              end
      end).

table_for_resource(#resource{kind = exchange}) -> rabbit_exchange;
table_for_resource(#resource{kind = queue})    -> rabbit_queue.

lookup_resources(Src, Dst) ->
    rabbit_khepri:transaction(
      fun() ->
              {lookup_resource_in_khepri_tx(Src), lookup_resource_in_khepri_tx(Dst)}
      end, ro).

lookup_resource_in_khepri_tx(#resource{kind = queue} = Name) ->
    lookup_tx_in_khepri(khepri_queue_path(Name));
lookup_resource_in_khepri_tx(#resource{kind = exchange} = Name) ->
    lookup_tx_in_khepri(khepri_exchange_path(Name)).

exists_binding_in_khepri(Path, Binding) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set}}} ->
            sets:is_element(Binding, Set);
        _ ->
            false
    end.

not_found({[], [_]}, SrcName, _) ->
    [SrcName];
not_found({[_], []}, _, DstName) ->
    [DstName];
not_found({[], []}, SrcName, DstName) ->
    [SrcName, DstName].

not_found_or_absent_errs_in_mnesia(Names) ->
    Errs = [not_found_or_absent_in_mnesia(Name) || Name <- Names],
    rabbit_misc:const({error, {resources_missing, Errs}}).

not_found_errs_in_khepri(Names) ->
    Errs = [{not_found, Name} || Name <- Names],
    {error, {resources_missing, Errs}}.

absent_errs_only_in_mnesia(Names) ->
    Errs = [E || Name <- Names,
                 {absent, _Q, _Reason} = E <- [not_found_or_absent_in_mnesia(Name)]],
    rabbit_misc:const(case Errs of
                          [] -> ok;
                          _  -> {error, {resources_missing, Errs}}
                      end).

not_found_or_absent_in_mnesia(#resource{kind = exchange} = Name) ->
    {not_found, Name};
not_found_or_absent_in_mnesia(#resource{kind = queue}    = Name) ->
    case not_found_or_absent_queue_in_mnesia(Name) of
        not_found                 -> {not_found, Name};
        {absent, _Q, _Reason} = R -> R
    end.

not_found_or_absent_queue_in_mnesia(Name) ->
    %% NB: we assume that the caller has already performed a lookup on
    %% rabbit_queue and not found anything
    case mnesia:read({rabbit_durable_queue, Name}) of
        []  -> not_found;
        [Q] -> {absent, Q, nodedown} %% Q exists on stopped node
    end.

not_found_or_absent_queue_dirty(Name) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> not_found_or_absent_queue_dirty_in_mnesia(Name) end,
      %% There are no transient queues in Khepri. Any queue missing from the table is gone
      fun() -> not_found end).

not_found_or_absent_queue_dirty_in_mnesia(Name) ->
    %% We should read from both tables inside a tx, to get a
    %% consistent view. But the chances of an inconsistency are small,
    %% and only affect the error kind.
    case rabbit_misc:dirty_read({rabbit_durable_queue, Name}) of
        {error, not_found} -> not_found;
        {ok, Q}            -> {absent, Q, nodedown}
    end.

serial_in_mnesia(false, _) ->
    none;
serial_in_mnesia(true, X) ->
    next_exchange_serial_in_mnesia(X).

serial_in_khepri(false, _) ->
    none;
serial_in_khepri(true, X) ->
    next_exchange_serial_in_khepri(X).

bindings_data(Path) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set}}} ->
            Set;
        _ ->
            sets:new()
    end.

add_binding_tx(Path, Binding) ->
    Set = bindings_data(Path),
    {ok, _} = khepri_tx:put(Path, sets:add_element(Binding, Set)),
    add_routing(Binding),
    ok.

add_routing(#binding{destination = Dst} = Binding) ->
    Path = khepri_routing_path(Binding),
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Data}}} ->
            {ok, _} = khepri_tx:put(Path, sets:add_element(Dst, Data));
        _ ->
            {ok, _} = khepri_tx:put(Path, sets:add_element(Dst, sets:new()))
    end.

add_binding_in_mnesia(Binding, ChecksFun) ->
    binding_action_in_mnesia(
      Binding,
      fun (Src, Dst) ->
              case ChecksFun(Src, Dst) of
                  {ok, BindingType} ->
                      case mnesia:read({rabbit_route, Binding}) of
                          []  ->
                              ok = sync_route(#route{binding = Binding}, BindingType,
                                              should_index_table(Src), fun mnesia:write/3),
                              rabbit_exchange:callback(Src, add_binding, transaction, [Src, Binding]),
                              MaybeSerial = rabbit_exchange:serialise_events(Src),
                              Serial = serial_in_mnesia(MaybeSerial, Src),
                              fun () ->
                                      rabbit_exchange:callback(Src, add_binding, Serial, [Src, Binding])
                              end;
                          [_] -> fun () -> ok end
                      end;
                  {error, _} = Err ->
                      rabbit_misc:const(Err)
              end
      end, fun not_found_or_absent_errs_in_mnesia/1).

add_binding_in_khepri(#binding{source = SrcName,
                               destination = DstName} = Binding, ChecksFun) ->
    case lookup_resources(SrcName, DstName) of
        {[Src], [Dst]} ->
            case ChecksFun(Src, Dst) of
                {ok, _BindingType} ->
                    Path = khepri_route_path(Binding),
                    MaybeSerial = rabbit_exchange:serialise_events(Src),
                    Serial = rabbit_khepri:transaction(
                               fun() ->
                                       case khepri_tx:get(Path) of
                                           {ok, #{Path := #{data := Set}}} ->
                                               case sets:is_element(Binding, Set) of
                                                   true ->
                                                       already_exists;
                                                   false ->
                                                       {ok, _} = khepri_tx:put(Path, sets:add_element(Binding, Set)),
                                                       add_routing(Binding),
                                                       serial_in_khepri(MaybeSerial, Src)
                                               end;
                                           _ ->
                                               {ok, _} = khepri_tx:put(Path, sets:add_element(Binding, sets:new())),
                                               add_routing(Binding),
                                               serial_in_khepri(MaybeSerial, Src)
                                       end
                               end, rw),
                    case Serial of
                        already_exists -> ok;
                        _ ->
                            rabbit_exchange:callback(Src, add_binding, [transaction, Serial], [Src, Binding])
                    end,
                    ok;
                {error, _} = Err ->
                    Err
            end;
        Errs ->
            not_found_errs_in_khepri(not_found(Errs, SrcName, DstName))
    end.

remove_binding_in_mnesia(Binding, ChecksFun) ->
    binding_action_in_mnesia(
      Binding,
      fun (Src, Dst) ->
              lock_resource(Src, read),
              lock_resource(Dst, read),
              case mnesia:read(rabbit_route, Binding, write) of
                  [] -> case mnesia:read(rabbit_durable_route, Binding, write) of
                            [] -> rabbit_misc:const(ok);
                            %% We still delete the binding and run
                            %% all post-delete functions if there is only
                            %% a durable route in the database
                            _  -> remove_binding_in_mnesia(Src, Dst, Binding)
                        end;
                  _  -> case ChecksFun(Dst) of
                            ok               -> remove_binding_in_mnesia(Src, Dst, Binding);
                            {error, _} = Err -> rabbit_misc:const(Err)
                        end
              end
      end, fun absent_errs_only_in_mnesia/1).

remove_binding_in_mnesia(Src, Dst, B) ->
    ok = sync_route(#route{binding = B}, rabbit_binding:binding_type(Src, Dst),
                    should_index_table(Src), fun delete/3),
    Deletions0 = maybe_auto_delete_exchange_in_mnesia(
                   B#binding.source, [B], rabbit_binding:new_deletions(), false),
    Deletions = rabbit_binding:process_deletions(Deletions0, true),
    fun() -> rabbit_binding:process_deletions(Deletions, false) end.

sync_route(Route, durable, ShouldIndexTable, Fun) ->
    ok = Fun(rabbit_durable_route, Route, write),
    sync_route(Route, semi_durable, ShouldIndexTable, Fun);

sync_route(Route, semi_durable, ShouldIndexTable, Fun) ->
    ok = Fun(rabbit_semi_durable_route, Route, write),
    sync_route(Route, transient, ShouldIndexTable, Fun);

sync_route(Route, transient, ShouldIndexTable, Fun) ->
    sync_transient_route(Route, ShouldIndexTable, Fun).

sync_transient_route(Route, ShouldIndexTable, Fun) ->
    ok = Fun(rabbit_route, Route, write),
    ok = Fun(rabbit_reverse_route, rabbit_binding:reverse_route(Route), write),
    sync_index_route(Route, ShouldIndexTable, Fun).

sync_index_route(Route, true, Fun) ->
    %% Do not block as blocking will cause a dead lock when
    %% function rabbit_binding:populate_index_route_table/0
    %% (i.e. feature flag migration) runs in parallel.
    case rabbit_feature_flags:is_enabled(direct_exchange_routing_v2, non_blocking) of
        true ->
            ok = Fun(rabbit_index_route, rabbit_binding:index_route(Route), write);
        _ ->
            ok
    end;
sync_index_route(_, _, _) ->
    ok.

remove_transient_routes(Routes) ->
    lists:map(fun(#route{binding = #binding{source = Src} = Binding} = Route) ->
                      {ok, X} = lookup_exchange(Src),
                      ok = sync_transient_route(Route, should_index_table(X), fun delete/3),
                      Binding
              end, Routes).

remove_routes(Routes) ->
    remove_routes(Routes, undefined).

remove_routes(Routes, ShouldIndexTable) ->
    %% This partitioning allows us to suppress unnecessary delete
    %% operations on disk tables, which require an fsync.
    {RamRoutes, DiskRoutes} =
        lists:partition(fun (R) -> mnesia:read(
                                     rabbit_durable_route, R#route.binding, read) == [] end,
                        Routes),
    {RamOnlyRoutes, SemiDurableRoutes} =
        lists:partition(fun (R) -> mnesia:read(
                                     rabbit_semi_durable_route, R#route.binding, read) == [] end,
                        RamRoutes),
    %% Of course the destination might not really be durable but it's
    %% just as easy to try to delete it from the semi-durable table
    %% than check first
    [ok = sync_route(R, durable, ShouldIndexTable, fun delete/3) ||
        R <- DiskRoutes],
    [ok = sync_route(R, semi_durable, ShouldIndexTable, fun delete/3) ||
        R <- SemiDurableRoutes],
    [ok = sync_route(R, transient, ShouldIndexTable, fun delete/3) ||
        R <- RamOnlyRoutes],
    case ShouldIndexTable of
        B when is_boolean(B) ->
            ok;
        undefined ->
            [begin
                 case lookup_exchange(Src) of
                     {ok, X} ->
                         ok = sync_index_route(R, should_index_table(X), fun delete/3);
                     _ ->
                         ok
                 end
             end || #route{binding = #binding{source = Src}} = R <- Routes]
    end,
    [R#route.binding || R <- Routes].

delete(Tab, #route{binding = B}, LockKind) ->
    mnesia:delete(Tab, B, LockKind);
delete(Tab, #reverse_route{reverse_binding = B}, LockKind) ->
    mnesia:delete(Tab, B, LockKind);
delete(Tab, #index_route{} = Record, LockKind) ->
    mnesia:delete_object(Tab, Record, LockKind).

remove_binding_in_khepri(#binding{source = SrcName,
                                  destination = DstName} = Binding, ChecksFun) ->
    Path = khepri_route_path(Binding),
    case rabbit_khepri:transaction(
           fun () ->
                   case {lookup_resource_in_khepri_tx(SrcName),
                         lookup_resource_in_khepri_tx(DstName)} of
                       {[_Src], [Dst]} ->
                           case exists_binding_in_khepri(Path, Binding) of
                               false ->
                                   ok;
                               true ->
                                   case ChecksFun(Dst) of
                                       ok ->
                                           ok = delete_binding_in_khepri(Binding),
                                           ok = delete_routing(Binding),
                                           maybe_auto_delete_exchange_in_khepri(Binding#binding.source, [Binding], rabbit_binding:new_deletions(), false);
                                       {error, _} = Err ->
                                           Err
                                   end
                           end;
                       _Errs ->
                           %% No absent queues, always present on disk
                           ok
                   end
           end) of
        ok ->
            ok;
        {error, _} = Err ->
            Err;
        Deletions ->
            rabbit_binding:process_deletions(Deletions, false)
    end.

-spec index_route_table_definition() -> list(tuple()).
index_route_table_definition() ->
    maps:to_list(
      #{
        record_name => index_route,
        attributes  => record_info(fields, index_route),
        type => bag,
        ram_copies => rabbit_nodes:all(),
        storage_properties => [{ets, [{read_concurrency, true}]}]
       }).

populate_index_route_table() ->
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              mnesia:lock({table, rabbit_route}, read),
              mnesia:lock({table, rabbit_index_route}, write),
              Routes = rabbit_misc:dirty_read_all(rabbit_route),
              lists:foreach(fun(#route{binding = #binding{source = Exchange}} = Route) ->
                                    case lookup_exchange(Exchange) of
                                        {ok, X} ->
                                            case should_index_table(X) of
                                                true ->
                                                    mnesia:dirty_write(rabbit_index_route,
                                                                       rabbit_binding:index_route(Route));
                                                false ->
                                                    ok
                                            end;
                                        _ ->
                                            ok
                                    end
                            end, Routes)
      end).

%% Only the direct exchange type uses the rabbit_index_route table to store its
%% bindings by table key tuple {SourceExchange, RoutingKey}.
%% Other built-in exchange types lookup destinations by SourceExchange, and
%% therefore will not need to read from the rabbit_index_route index table.
%% Therefore, we avoid inserting and deleting into rabbit_index_route for other exchange
%% types. This reduces write lock conflicts on the same tuple {SourceExchange, RoutingKey}
%% reducing the number of restarted Mnesia transactions.
should_index_table(#exchange{name = #resource{name = Name},
                      type = direct})
  when Name =/= <<>> ->
    true;
should_index_table(_) ->
    false.

maybe_auto_delete_exchange_in_mnesia(XName, Bindings, Deletions, OnlyDurable) ->
    {Entry, Deletions1} =
        case mnesia:read({case OnlyDurable of
                              true  -> rabbit_durable_exchange;
                              false -> rabbit_exchange
                          end, XName}) of
            []  -> {{undefined, not_deleted, Bindings}, Deletions};
            [X] -> case maybe_auto_delete_exchange_in_mnesia(X, OnlyDurable) of
                       not_deleted ->
                           {{X, not_deleted, Bindings}, Deletions};
                       {deleted, Deletions2} ->
                           {{X, deleted, Bindings},
                            rabbit_binding:combine_deletions(Deletions, Deletions2)}
                   end
        end,
    rabbit_binding:add_deletion(XName, Entry, Deletions1).

maybe_auto_delete_exchange_in_khepri(XName, Bindings, Deletions, OnlyDurable) ->
    {Entry, Deletions1} =
        case maybe_auto_delete_exchange_in_khepri(XName, OnlyDurable) of
            {not_deleted, X} ->
                {{X, not_deleted, Bindings}, Deletions};
            {deleted, X, Deletions2} ->
                {{X, deleted, Bindings},
                 rabbit_binding:combine_deletions(Deletions, Deletions2)}
        end,
    rabbit_binding:add_deletion(XName, Entry, Deletions1).

maybe_auto_delete_exchange_in_khepri(XName, OnlyDurable) ->
    case lookup_tx_in_khepri(khepri_exchange_path(XName)) of
        [] ->
            {not_deleted, undefined};
        [#exchange{auto_delete = false} = X] ->
            {not_deleted, X};
        [#exchange{auto_delete = true} = X] ->
            case conditional_delete_exchange_in_khepri(X, OnlyDurable) of
                {error, in_use}             -> {not_deleted, X};
                {deleted, X, [], Deletions} -> {deleted, X, Deletions}
            end
    end.

-spec maybe_auto_delete_exchange_in_mnesia
        (rabbit_types:exchange(), boolean())
        -> 'not_deleted' | {'deleted', rabbit_binding:deletions()}.
maybe_auto_delete_exchange_in_mnesia(#exchange{auto_delete = false}, _OnlyDurable) ->
    not_deleted;
maybe_auto_delete_exchange_in_mnesia(#exchange{auto_delete = true} = X, OnlyDurable) ->
    case conditional_delete_exchange_in_mnesia(X, OnlyDurable) of
        {error, in_use}             -> not_deleted;
        {deleted, X, [], Deletions} -> {deleted, Deletions}
    end.

conditional_delete_exchange_in_khepri(X = #exchange{name = XName}, OnlyDurable) ->
    case binding_has_for_source_in_khepri(XName) of
        false  -> delete_exchange_in_khepri(X, OnlyDurable, false);
        true   -> {error, in_use}
    end.

conditional_delete_exchange_in_mnesia(X = #exchange{name = XName}, OnlyDurable) ->
    case binding_has_for_source_in_mnesia(XName) of
        false  -> delete_exchange_in_mnesia(X, OnlyDurable, false);
        true   -> {error, in_use}
    end.

unconditional_delete_exchange_in_mnesia(X, OnlyDurable) ->
    delete_exchange_in_mnesia(X, OnlyDurable, true).

unconditional_delete_exchange_in_khepri(X, OnlyDurable) ->
    delete_exchange_in_khepri(X, OnlyDurable, true).

delete_binding_in_mnesia(Binding) ->
    mnesia:dirty_delete(rabbit_durable_route, Binding),
    mnesia:dirty_delete(rabbit_semi_durable_route, Binding),
    mnesia:dirty_delete(rabbit_reverse_route,
                        rabbit_binding:reverse_binding(Binding)),
    mnesia:dirty_delete(rabbit_route, Binding).

delete_binding_in_khepri(Binding) ->
    Path = khepri_route_path(Binding),
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set0}}} ->
            Set = sets:del_element(Binding, Set0),
            case sets:is_empty(Set) of
                true ->
                    {ok, _} = khepri_tx:delete(Path);
                false ->
                    {ok, _} = khepri_tx:put(Path, Set)
            end;
        _ ->
            ok
    end,
    ok.

delete_routing(#binding{destination = Dst} = Binding) ->
    Path = khepri_routing_path(Binding),
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Data0}}} ->
            Data = sets:del_element(Dst, Data0),
            case sets:is_empty(Data) of
                true ->
                    {ok, _} = khepri_tx:delete(Path);
                false ->
                    {ok, _} = khepri_tx:put(Path, Data)
            end;
        _ ->
            ok
    end,
    ok.

%% Instead of locking entire table on remove operations we can lock the
%% affected resource only.
lock_resource(Name) -> lock_resource(Name, write).

lock_resource(Name, LockKind) ->
    mnesia:lock({global, Name, mnesia:table_info(rabbit_route, where_to_write)},
                LockKind).

-spec binding_has_for_source_in_mnesia(rabbit_types:binding_source()) -> boolean().

binding_has_for_source_in_mnesia(SrcName) ->
    Match = #route{binding = #binding{source = SrcName, _ = '_'}},
    %% we need to check for semi-durable routes (which subsumes
    %% durable routes) here too in case a bunch of routes to durable
    %% queues have been removed temporarily as a result of a node
    %% failure
    contains(rabbit_route, Match) orelse
        contains(rabbit_semi_durable_route, Match).

contains(Table, MatchHead) ->
    continue(mnesia:select(Table, [{MatchHead, [], ['$_']}], 1, read)).

continue('$end_of_table')    -> false;
continue({[_|_], _})         -> true;
continue({[], Continuation}) -> continue(mnesia:select(Continuation)).

binding_has_for_source_in_khepri(SrcName) ->
    maps:size(match_source_in_khepri_tx(SrcName)) > 0.

match_source_in_khepri_tx(#resource{virtual_host = VHost, name = Name}) ->
    Path = khepri_routes_path() ++ [VHost, Name, ?STAR_STAR],
    {ok, Map} = rabbit_khepri:tx_match_and_get_data(Path),
    Map.

match_source_in_khepri(#resource{virtual_host = VHost, name = Name}) ->
    Path = khepri_routes_path() ++ [VHost, Name, ?STAR_STAR],
    {ok, Map} = rabbit_khepri:match_and_get_data(Path),
    Map.

match_source_and_key_in_khepri(Src, ['_']) ->
    Path = khepri_routing_path(Src, ?STAR_STAR),
    case rabbit_khepri:match_and_get_data(Path) of
        {ok, Map} ->
            maps:fold(fun(_, Dsts, Acc) ->
                              sets:to_list(Dsts) ++ Acc
                      end, [], Map);
        {error, {node_not_found, _}} ->
            []
    end;
match_source_and_key_in_khepri(Src, RoutingKeys) ->
    lists:foldl(
      fun(RK, Acc) ->
              Path = khepri_routing_path(Src, RK),
              %% Don't use transaction if we want to hit the cache
              case rabbit_khepri:get_data(Path) of
                  {ok, Dsts} ->
                      sets:to_list(Dsts) ++ Acc;
                  {error, {node_not_found, _}} ->
                      Acc
              end
      end, [], RoutingKeys).

match_destination_in_khepri(#resource{virtual_host = VHost, kind = Kind, name = Name}) ->
    Path = khepri_routes_path() ++ [VHost, ?STAR, Kind, Name, ?STAR_STAR],
    {ok, Map} = rabbit_khepri:tx_match_and_get_data(Path),
    Map.

match_source_and_destination_in_khepri(#resource{virtual_host = VHost, name = Name},
                                       #resource{kind = Kind, name = DstName}) ->
    Path = khepri_routes_path() ++ [VHost, Name, Kind, DstName, ?STAR_STAR],
    list_in_khepri(Path).

match_source_and_destination_in_khepri_tx(#resource{virtual_host = VHost, name = Name},
                                       #resource{kind = Kind, name = DstName}) ->
    Path = khepri_routes_path() ++ [VHost, Name, Kind, DstName, ?STAR_STAR],
    list_in_khepri_tx(Path).

remove_bindings_for_destination_in_mnesia(DstName, OnlyDurable, Fun) ->
    lock_resource(DstName),
    MatchFwd = #route{binding = #binding{destination = DstName, _ = '_'}},
    MatchRev = rabbit_binding:reverse_route(MatchFwd),
    Routes = case OnlyDurable of
                 false ->
                        [rabbit_binding:reverse_route(R) ||
                              R <- mnesia:dirty_match_object(
                                     rabbit_reverse_route, MatchRev)];
                 true  -> lists:usort(
                            mnesia:dirty_match_object(
                              rabbit_durable_route, MatchFwd) ++
                                mnesia:dirty_match_object(
                                  rabbit_semi_durable_route, MatchFwd))
             end,
    Bindings = Fun(Routes),
    rabbit_binding:group_bindings_fold(fun maybe_auto_delete_exchange_in_mnesia/4,
                                       lists:keysort(#binding.source, Bindings), OnlyDurable).

remove_bindings_for_destination_in_mnesia(DstName, OnlyDurable) ->
    remove_bindings_for_destination_in_mnesia(DstName, OnlyDurable, fun remove_routes/1).

remove_bindings_for_destination_in_khepri(DstName, OnlyDurable) ->
    BindingsMap =
        case OnlyDurable of
            false ->
                TransientBindingsMap = match_destination_in_khepri(DstName),
                maps:foreach(fun(K, _V) -> khepri_tx:delete(K) end, TransientBindingsMap),
                TransientBindingsMap;
            true  ->
                BindingsMap0 = match_destination_in_khepri(DstName),
                maps:foreach(fun(K, _V) -> khepri_tx:delete(K) end, BindingsMap0),
                BindingsMap0
        end,
    Bindings = maps:fold(fun(_, Set, Acc) ->
                                 sets:to_list(Set) ++ Acc
                         end, [], BindingsMap),
    rabbit_binding:group_bindings_fold(fun maybe_auto_delete_exchange_in_khepri/4,
                                       lists:keysort(#binding.source, Bindings), OnlyDurable).

remove_bindings_for_source_in_mnesia(#exchange{name = SrcName} = SrcX) ->
    remove_bindings_for_source_in_mnesia(SrcName, should_index_table(SrcX));
remove_bindings_for_source_in_mnesia(SrcName) ->
    remove_bindings_for_source_in_mnesia(SrcName, undefined).

-spec remove_bindings_for_source_in_mnesia(rabbit_types:binding_source(),
                                           boolean() | undefined) -> [rabbit_types:binding()].
remove_bindings_for_source_in_mnesia(SrcName, ShouldIndexTable) ->
    lock_resource(SrcName),
    Match = #route{binding = #binding{source = SrcName, _ = '_'}},
    remove_routes(
      lists:usort(
        mnesia:dirty_match_object(rabbit_route, Match) ++
            mnesia:dirty_match_object(rabbit_semi_durable_route, Match)),
      ShouldIndexTable).

remove_bindings_for_source_in_khepri(SrcName) ->
    Bindings = match_source_in_khepri_tx(SrcName),
    maps:foreach(fun(K, _V) -> khepri_tx:delete(K) end, Bindings),
    maps:fold(fun(_, Set, Acc) ->
                      sets:to_list(Set) ++ Acc
              end, [], Bindings).

-spec remove_transient_bindings_for_destination_in_mnesia(rabbit_types:binding_destination()) -> rabbit_binding:deletions().
remove_transient_bindings_for_destination_in_mnesia(DstName) ->
    remove_bindings_for_destination_in_mnesia(DstName, false, fun remove_transient_routes/1).

recover_bindings_in_mnesia() ->
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              mnesia:lock({table, rabbit_durable_route}, read),
              mnesia:lock({table, rabbit_semi_durable_route}, write),
              Routes = rabbit_misc:dirty_read_all(rabbit_durable_route),
              Fun = fun(Route) ->
                            mnesia:dirty_write(rabbit_semi_durable_route, Route)
                    end,
              lists:foreach(Fun, Routes),
              ok
    end).

recover_semi_durable_route_txn(#route{binding = B} = Route, X, mnesia) ->
    MaybeSerial = rabbit_exchange:serialise_events(X),
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              case mnesia:read(rabbit_semi_durable_route, B, read) of
                  [] -> no_recover;
                  _  -> ok = sync_transient_route(Route, should_index_table(X), fun mnesia:write/3),
                        serial_in_mnesia(MaybeSerial, X)
              end
      end,
      fun (no_recover, _) -> ok;
          (_Serial, true) -> rabbit_exchange:callback(X, add_binding, transaction, [X, B]);
          (Serial, false) -> rabbit_exchange:callback(X, add_binding, Serial, [X, B])
      end);
recover_semi_durable_route_txn(_Path, _X, khepri) ->
    ok.

list_queues_with_possible_retry_in_mnesia(Fun) ->
    %% amqqueue migration:
    %% The `rabbit_queue` or `rabbit_durable_queue` tables
    %% might be migrated between the time we query the pattern
    %% (with the `amqqueue` module) and the time we call
    %% `mnesia:dirty_match_object()`. This would lead to an empty list
    %% (no object matching the now incorrect pattern), not a Mnesia
    %% error.
    %%
    %% So if the result is an empty list and the version of the
    %% `amqqueue` record changed in between, we retry the operation.
    %%
    %% However, we don't do this if inside a Mnesia transaction: we
    %% could end up with a live lock between this started transaction
    %% and the Mnesia table migration which is blocked (but the
    %% rabbit_feature_flags lock is held).
    AmqqueueRecordVersion = amqqueue:record_version_to_use(),
    case Fun() of
        [] ->
            case mnesia:is_transaction() of
                true ->
                    [];
                false ->
                    case amqqueue:record_version_to_use() of
                        AmqqueueRecordVersion -> [];
                        _                     -> Fun()
                    end
            end;
        Ret ->
            Ret
    end.

list_queues_with_possible_retry_in_khepri(Fun) ->
    %% See equivalent `list_queues_with_possible_retry_in_mnesia` first.
    %% Not sure how much of this is possible in Khepri, as there is no dirty read,
    %% but the amqqueue record migration is still happening.
    %% Let's retry just in case
    AmqqueueRecordVersion = amqqueue:record_version_to_use(),
    case Fun() of
        [] ->
            case khepri_tx:is_transaction() of
                true ->
                    [];
                false ->
                    case amqqueue:record_version_to_use() of
                        AmqqueueRecordVersion -> [];
                        _                     -> Fun()
                    end
            end;
        Ret ->
            Ret
    end.

list_queues_for_count(VHost) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              %% this is certainly suboptimal but there is no way to count
              %% things using a secondary index in Mnesia. Our counter-table-per-node
              %% won't work here because with master migration of mirrored queues
              %% the "ownership" of queues by nodes becomes a non-trivial problem
              %% that requires a proper consensus algorithm.
              list_queues_with_possible_retry_in_mnesia(
                fun() ->
                        length(mnesia:dirty_index_read(rabbit_queue,
                                                       VHost,
                                                       amqqueue:field_vhost()))
                end)
      end,
      fun() -> list_queues_with_possible_retry_in_khepri(
                 fun() ->
                         count_in_khepri(khepri_queues_path() ++ [VHost])
                 end)
      end).

internal_delete_queue_in_mnesia(QueueName, OnlyDurable, Reason) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    case Reason of
        auto_delete ->
            case mnesia:wread({rabbit_durable_queue, QueueName}) of
                []  -> ok;
                [_] -> ok = mnesia:delete({rabbit_durable_queue, QueueName})
            end;
        _ ->
            mnesia:delete({rabbit_durable_queue, QueueName})
    end,
    %% we want to execute some things, as decided by rabbit_exchange,
    %% after the transaction.
    remove_bindings_for_destination_in_mnesia(QueueName, OnlyDurable).

internal_delete_queue_in_khepri(QueueName, OnlyDurable, _Reason) ->
    Path = khepri_queue_path(QueueName),
    case khepri_tx:delete(Path) of
        {ok, #{Path := _}} ->
            %% we want to execute some things, as decided by rabbit_exchange,
            %% after the transaction.
            remove_bindings_for_destination_in_khepri(QueueName, OnlyDurable);
        {ok, _} ->
            ok
    end.

delete_queue_in_mnesia(QueueName, Reason) ->
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              case {mnesia:wread({rabbit_queue, QueueName}),
                    mnesia:wread({rabbit_durable_queue, QueueName})} of
                  {[], []} ->
                      ok;
                  _ ->
                      Deletions0 = internal_delete_queue_in_mnesia(QueueName, false, Reason),
                      rabbit_binding:process_deletions(Deletions0, true)
              end
      end).

delete_queue_in_khepri(Name, Reason) ->
    rabbit_khepri:transaction(
      fun () ->
              internal_delete_queue_in_khepri(Name, false, Reason)
      end, rw).

delete_transient_queue_in_mnesia(QName) ->
    ok = mnesia:delete({rabbit_queue, QName}),
    remove_transient_bindings_for_destination_in_mnesia(QName).

update_queue_in_mnesia(Name, Fun) ->
    case mnesia:wread({rabbit_queue, Name}) of
        [Q] ->
            Durable = amqqueue:is_durable(Q),
            Q1 = Fun(Q),
            ok = mnesia:write(rabbit_queue, Q1, write),
            case Durable of
                true -> ok = mnesia:write(rabbit_durable_queue, Q1, write);
                _    -> ok
            end,
            Q1;
        [] ->
            not_found
    end.

update_queue_in_khepri(Name, Fun) ->
    Path = khepri_queue_path(Name),
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Q}}} ->
            Q1 = Fun(Q),
            {ok, _} = khepri_tx:put(Path, Q1),
            Q1;
        _  ->
            not_found
    end.

update_queue_decorators_in_mnesia(Name) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() ->
              case mnesia:wread({rabbit_queue, Name}) of
                  [Q] -> ok = mnesia:write(rabbit_queue, rabbit_queue_decorator:set(Q), write);
                  []  -> ok
              end
      end).

update_queue_decorators_in_khepri(Name) ->
    Path = khepri_queue_path(Name),
    %% Decorators are stored on an ETS table, we need to query them before the transaction.
    %% Also, to verify which ones are active could lead to any kind of side-effects.
    %% Thus it needs to be done outside of the transaction
    Decorators = case rabbit_khepri:get_data(Path) of
                     {ok, Q} ->
                         rabbit_queue_decorator:active(Q);
                     _ ->
                         []
                 end,
    rabbit_khepri:transaction(
      fun() ->
              case khepri_tx:get(Path) of
                  {ok, #{Path := #{data := Q0}}} ->
                      Q1 = amqqueue:reset_mirroring_and_decorators(Q0),
                      Q2 = amqqueue:set_decorators(Q1, Decorators),
                      store_in_khepri(Path, Q2),
                      ok;
                  _  ->
                      ok
              end
      end, rw).

store_in_khepri(Path, Value) ->
    case khepri_tx:put(Path, Value) of
        {ok, _} -> ok;
        Error   -> khepri_tx:abort(Error)
    end.

split_topic_trie_key(Key) ->
    Words = split_topic_trie_key(Key, [], []),
    [list_to_binary(W) || W <- Words].

split_topic_trie_key(<<>>, [], []) ->
    [];
split_topic_trie_key(<<>>, RevWordAcc, RevResAcc) ->
    lists:reverse([lists:reverse(RevWordAcc) | RevResAcc]);
split_topic_trie_key(<<$., Rest/binary>>, RevWordAcc, RevResAcc) ->
    split_topic_trie_key(Rest, [], [lists:reverse(RevWordAcc) | RevResAcc]);
split_topic_trie_key(<<C:8, Rest/binary>>, RevWordAcc, RevResAcc) ->
    split_topic_trie_key(Rest, [C | RevWordAcc], RevResAcc).

%% TODO use keepwhile instead?
remove_path_if_empty([?MODULE, _]) ->
    ok;
remove_path_if_empty(Path) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set,
                         child_list_length := Children}}} ->
            case {Children, sets:size(Set)} of
                {0, 0} ->
                    khepri_tx:delete(Path),
                    remove_path_if_empty(lists:droplast(Path));
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

retry(Fun) ->
    Until = erlang:system_time(millisecond) + (?WAIT_SECONDS * 1000),
    retry(Fun, Until).

retry(Fun, Until) ->
    case Fun() of
        ok -> ok;
        {error, Reason} ->
            case erlang:system_time(millisecond) of
                V when V >= Until ->
                    throw({error, Reason});
                _ ->
                    retry(Fun, Until)
            end
    end.

khepri_create_tx(Path, Value) ->
    case khepri_tx:create(Path, Value) of
        {ok, _} -> ok;
        {error, {mismatching_node, _}} -> ok;
        Error -> throw(Error)
    end.

khepri_delete(Path) ->
    case rabbit_khepri:delete(Path) of
        {ok, _} -> ok;
        Error -> throw(Error)
    end.

recover_mnesia_tables() ->
    %% A failed migration can leave tables in read-only mode before enabling
    %% the feature flag. See rabbit_core_ff:final_sync_from_mnesia_to_khepri/2
    %% Unlock them here as mnesia is still fully functional.
    Tables = rabbit_channel_tracking:get_all_tracked_channel_table_names_for_node(node())
        ++ rabbit_connection_tracking:get_all_tracked_connection_table_names_for_node(node())
        ++ [Table || {Table, _} <- rabbit_table:definitions()],
    [mnesia:change_table_access_mode(Table, read_write) || Table <- Tables],
    ok.
