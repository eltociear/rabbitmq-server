%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2011-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%
%% For the full spec see: https://www.rabbitmq.com/dlx.html
%%
-module(dead_lettering_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").

-compile([export_all, nowarn_export_all]).

-import(quorum_queue_utils, [wait_for_messages/2]).

all() ->
    [
     {group, dead_letter_tests}
    ].

groups() ->
    DeadLetterTests = [dead_letter_nack,
                       dead_letter_multiple_nack,
                       dead_letter_nack_requeue,
                       dead_letter_nack_requeue_multiple,
                       dead_letter_reject,
                       dead_letter_reject_many,
                       dead_letter_reject_requeue,
                       dead_letter_max_length_drop_head,
                       dead_letter_reject_requeue_reject_norequeue,
                       dead_letter_missing_exchange,
                       dead_letter_routing_key,
                       dead_letter_routing_key_header_CC,
                       dead_letter_routing_key_header_BCC,
                       dead_letter_routing_key_cycle_max_length,
                       dead_letter_routing_key_cycle_with_reject,
                       dead_letter_policy,
                       dead_letter_override_policy,
                       dead_letter_ignore_policy,
                       dead_letter_headers,
                       dead_letter_headers_reason_maxlen,
                       dead_letter_headers_cycle,
                       dead_letter_headers_BCC,
                       dead_letter_headers_CC,
                       dead_letter_headers_CC_with_routing_key,
                       dead_letter_headers_first_death,
                       dead_letter_headers_first_death_route,
                       dead_letter_ttl,
                       dead_letter_routing_key_cycle_ttl,
                       dead_letter_headers_reason_expired,
                       dead_letter_headers_reason_expired_per_message,
                       dead_letter_extra_bcc],
    DisabledMetricTests = [metric_maxlen,
                           metric_rejected,
                           metric_expired_queue_msg_ttl,
                           metric_expired_per_msg_msg_ttl],
    Opts = [shuffle],
    [
     {dead_letter_tests, Opts,
      [
       {classic_queue, Opts, [{at_most_once, Opts, [dead_letter_max_length_reject_publish_dlx | DeadLetterTests]},
                              {disabled, Opts, DisabledMetricTests}]},
       {mirrored_queue, Opts, [{at_most_once, Opts, [dead_letter_max_length_reject_publish_dlx | DeadLetterTests]},
                               {disabled, Opts, DisabledMetricTests}]},
       {quorum_queue, Opts, [{at_most_once, Opts, DeadLetterTests},
                             {disabled, Opts, DisabledMetricTests},
                             {at_least_once, Opts, DeadLetterTests --
                              [
                               %% dead-letter-strategy at-least-once is incompatible with overflow drop-head
                               dead_letter_max_length_drop_head,
                               dead_letter_routing_key_cycle_max_length,
                               dead_letter_headers_reason_maxlen,
                               %% tested separately in rabbit_fifo_dlx_integration_SUITE
                               dead_letter_missing_exchange
                              ]}
                            ]
       }]}].

suite() ->
    [
      {timetrap, {minutes, 8}}
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config0) ->
    rabbit_ct_helpers:log_environment(),
    Config = rabbit_ct_helpers:merge_app_env(
               Config0, {rabbit, [{dead_letter_worker_publisher_confirm_timeout, 2000}]}),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(classic_queue, Config) ->
    rabbit_ct_helpers:set_config(
      Config,
      [{queue_args, [{<<"x-queue-type">>, longstr, <<"classic">>}]},
       {queue_durable, false}]);
init_per_group(mirrored_queue, Config) ->
    rabbit_ct_broker_helpers:set_ha_policy(Config, 0, <<"^max_length.*queue">>,
        <<"all">>, [{<<"ha-sync-mode">>, <<"automatic">>}]),
    Config1 = rabbit_ct_helpers:set_config(
                Config, [{is_mirrored, true},
                         {queue_args, [{<<"x-queue-type">>, longstr, <<"classic">>}]},
                         {queue_durable, false}]),
    rabbit_ct_helpers:run_steps(Config1, []);
init_per_group(quorum_queue, Config) ->
    rabbit_ct_helpers:set_config(
      Config,
      [{queue_args, [{<<"x-queue-type">>, longstr, <<"quorum">>}]},
       {queue_durable, true}]);
init_per_group(at_most_once, Config) ->
    case outer_group_name(Config) of
        quorum_queue ->
            QueueArgs0 = rabbit_ct_helpers:get_config(Config, queue_args),
            QueueArgs = lists:keystore(<<"x-dead-letter-strategy">>,
                                       1,
                                       QueueArgs0,
                                       {<<"x-dead-letter-strategy">>, longstr, <<"at-most-once">>}),
            rabbit_ct_helpers:set_config(Config, {queue_args, QueueArgs});
        _ ->
            Config
    end;
init_per_group(at_least_once, Config) ->
    case outer_group_name(Config) of
        quorum_queue ->
            QueueArgs0 = rabbit_ct_helpers:get_config(Config, queue_args),
            QueueArgs1 = lists:keystore(<<"x-dead-letter-strategy">>,
                                        1,
                                        QueueArgs0,
                                        {<<"x-dead-letter-strategy">>, longstr, <<"at-least-once">>}),
            QueueArgs = lists:keystore(<<"x-overflow">>,
                                       1,
                                       QueueArgs1,
                                       {<<"x-overflow">>, longstr, <<"reject-publish">>}),
            Config1 = rabbit_ct_helpers:set_config(Config, {queue_args, QueueArgs}),
            case rabbit_ct_broker_helpers:enable_feature_flag(Config1, stream_queue) of
                ok ->
                    Config1;
                Skip ->
                    Skip
            end;
        _ ->
            Config
    end;
init_per_group(Group, Config) ->
    case lists:member({group, Group}, all()) of
        true ->
            ClusterSize = 3,
            Config1 = rabbit_ct_helpers:set_config(Config, [
                {rmq_nodename_suffix, Group},
                {rmq_nodes_count, ClusterSize}
              ]),
            rabbit_ct_helpers:run_steps(Config1,
              rabbit_ct_broker_helpers:setup_steps() ++
              rabbit_ct_client_helpers:setup_steps());
        false ->
            rabbit_ct_helpers:run_steps(Config, [])
    end.

end_per_group(Group, Config) ->
    case lists:member({group, Group}, all()) of
        true ->
            rabbit_ct_helpers:run_steps(Config,
              rabbit_ct_client_helpers:teardown_steps() ++
              rabbit_ct_broker_helpers:teardown_steps());
        false ->
            Config
    end.

init_per_testcase(Testcase, Config) ->
    Group = proplists:get_value(name, ?config(tc_group_properties, Config)),
    Q = rabbit_data_coercion:to_binary(io_lib:format("~p_~p", [Group, Testcase])),
    Q2 = rabbit_data_coercion:to_binary(io_lib:format("~p_~p_2", [Group, Testcase])),
    Q3 = rabbit_data_coercion:to_binary(io_lib:format("~p_~p_3", [Group, Testcase])),
    Policy = rabbit_data_coercion:to_binary(io_lib:format("~p_~p_policy", [Group, Testcase])),
    DLXExchange = rabbit_data_coercion:to_binary(io_lib:format("~p_~p_dlx_exchange",
                                                               [Group, Testcase])),
    Counters = get_global_counters(Config),
    Config1 = rabbit_ct_helpers:set_config(Config, [{dlx_exchange, DLXExchange},
                                                    {queue_name, Q},
                                                    {queue_name_dlx, Q2},
                                                    {queue_name_dlx_2, Q3},
                                                    {policy, Policy},
                                                    {counters, Counters}]),
    rabbit_ct_helpers:testcase_started(Config1, Testcase).

end_per_testcase(Testcase, Config) ->
    {_, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    amqp_channel:call(Ch, #'queue.delete'{queue = ?config(queue_name, Config)}),
    amqp_channel:call(Ch, #'queue.delete'{queue = ?config(queue_name_dlx, Config)}),
    amqp_channel:call(Ch, #'queue.delete'{queue = ?config(queue_name_dlx_2, Config)}),
    amqp_channel:call(Ch, #'exchange.delete'{exchange = ?config(dlx_exchange, Config)}),
    _ = rabbit_ct_broker_helpers:clear_policy(Config, 0, ?config(policy, Config)),
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Dead letter exchanges
%%
%% Messages are dead-lettered when:
%% 1) message is rejected with basic.reject or basic.nack with requeue=false
%% 2) message ttl expires
%% 3) queue length limit is exceeded (only drop-head implemented in quorum queues)
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% 1) message is rejected with basic.nack, requeue=false and multiple=false
dead_letter_nack(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    %% Consume them
    [DTag1, DTag2, DTag3] = consume(Ch, QName, [P1, P2, P3]),
    %% Nack the last one with multiple = false
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag3,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    %% Queue is empty
    consume_empty(Ch, QName),
    %% Consume the last message from the dead letter queue
    consume(Ch, DLXQName, [P3]),
    consume_empty(Ch, DLXQName),
    %% Nack the other two
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag2,
                                        multiple     = false,
                                        requeue      = false}),
    %% Queue is empty
    consume_empty(Ch, QName),
    %% Consume the first two messages from the dead letter queue
    consume(Ch, DLXQName, [P1, P2]),
    consume_empty(Ch, DLXQName),
    ?assertEqual(3, counted(messages_dead_lettered_rejected_total, Config)).

%% 1) message is rejected with basic.nack, requeue=false and multiple=true
dead_letter_multiple_nack(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    %% Consume them
    [_, _, DTag3] = consume(Ch, QName, [P1, P2, P3]),
    %% Nack the last one with multiple = true
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag3,
                                        multiple     = true,
                                        requeue      = false}),
    wait_for_messages(Config, [[DLXQName, <<"3">>, <<"3">>, <<"0">>]]),
    %% Consume the 3 messages from the dead letter queue
    consume(Ch, DLXQName, [P1, P2, P3]),
    consume_empty(Ch, DLXQName),
    %% Queue is empty
    consume_empty(Ch, QName),
    ?assertEqual(3, counted(messages_dead_lettered_rejected_total, Config)).

%% 1) message is rejected with basic.nack, requeue=true and multiple=false. Dead-lettering does not take place
dead_letter_nack_requeue(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    %% Consume them
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    [_, _, DTag3] = consume(Ch, QName, [P1, P2, P3]),
    %% Queue is empty
    consume_empty(Ch, QName),
    %% Nack the last one with multiple = false
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag3,
                                        multiple     = false,
                                        requeue      = true}),
    %% Consume the last message from the queue
    wait_for_messages(Config, [[QName, <<"3">>, <<"1">>, <<"2">>]]),
    consume(Ch, QName, [P3]),
    consume_empty(Ch, QName),
    %% Dead letter queue is empty
    consume_empty(Ch, DLXQName),
    ?assertEqual(0, counted(messages_dead_lettered_rejected_total, Config)).

%% 1) message is rejected with basic.nack, requeue=true and multiple=true. Dead-lettering does not take place
dead_letter_nack_requeue_multiple(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    %% Consume them
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    [_, _, DTag3] = consume(Ch, QName, [P1, P2, P3]),
    %% Queue is empty
    consume_empty(Ch, QName),
    %% Nack the last one with multiple = true
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag3,
                                        multiple     = true,
                                        requeue      = true}),
    %% Consume the three messages from the queue
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    consume(Ch, QName, [P1, P2, P3]),
    consume_empty(Ch, QName),
    %% Dead letter queue is empty
    consume_empty(Ch, DLXQName),
    ?assertEqual(0, counted(messages_dead_lettered_rejected_total, Config)).

%% 1) message is rejected with basic.reject, requeue=false
dead_letter_reject(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    %% Consume the first message
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    [DTag] = consume(Ch, QName, [P1]),
    %% Reject it
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag,
                                          requeue      = false}),
    %% Consume it from the dead letter queue
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    _ = consume(Ch, DLXQName, [P1]),
    consume_empty(Ch, DLXQName),
    %% Consume the last two from the queue
    _ = consume(Ch, QName, [P2, P3]),
    consume_empty(Ch, QName),
    ?assertEqual(1, counted(messages_dead_lettered_rejected_total, Config)).

%% 1) Many messages are rejected. They get dead-lettered in correct order.
dead_letter_reject_many(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    %% Publish 100 messages
    Payloads = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, 100)),
    publish(Ch, QName, Payloads),
    wait_for_messages(Config, [[QName, <<"100">>, <<"100">>, <<"0">>]]),

    %% Reject all messages using same consumer
    amqp_channel:subscribe(Ch, #'basic.consume'{queue = QName}, self()),
    CTag = receive #'basic.consume_ok'{consumer_tag = C} -> C end,
    [begin
         receive {#'basic.deliver'{consumer_tag = CTag, delivery_tag = DTag}, #amqp_msg{payload = P}} ->
                     amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag, requeue = false})
         after 5000 ->
                   amqp_channel:call(Ch, #'basic.cancel'{consumer_tag = CTag}),
                   exit(timeout)
         end
     end || P <- Payloads],
    amqp_channel:call(Ch, #'basic.cancel'{consumer_tag = CTag}),

    %% Consume all messages from dead letter queue in correct order (i.e. from payload <<1>> to <<100>>)
    wait_for_messages(Config, [[DLXQName, <<"100">>, <<"100">>, <<"0">>]]),
    _ = consume(Ch, DLXQName, Payloads),
    consume_empty(Ch, DLXQName),
    ?assertEqual(100, counted(messages_dead_lettered_rejected_total, Config)).

%% 1) Message is rejected with basic.reject, requeue=true. Dead-lettering does not take place.
dead_letter_reject_requeue(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    %% Setting a delivery-limit will cause a quorum queue to requeue at the head of the queue
    %% (same behaviour as in classic queues).
    ok = rabbit_ct_broker_helpers:set_policy(Config, 0, ?config(policy, Config), QName,
                                             <<"queues">>, [{<<"delivery-limit">>, 50}]),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    %% Consume the first one
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    [DTag] = consume(Ch, QName, [P1]),
    %% Reject the first one
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag,
                                          requeue      = true}),
    %% Consume the three messages from the queue
    wait_for_messages(Config, [[QName, <<"3">>, <<"3">>, <<"0">>]]),
    _ = consume(Ch, QName, [P1, P2, P3]),
    consume_empty(Ch, QName),
    %% Dead letter is empty
    consume_empty(Ch, DLXQName),
    ?assertEqual(0, counted(messages_dead_lettered_rejected_total, Config)).

%% 2) Message ttl expires
dead_letter_ttl(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName, [{<<"x-message-ttl">>, long, 1}]),

    %% Publish message
    P1 = <<"msg1">>,
    publish(Ch, QName, [P1]),
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    consume_empty(Ch, QName),
    [_] = consume(Ch, DLXQName, [P1]),
    ?assertEqual(1, counted(messages_dead_lettered_expired_total, Config)).

%% 3) The queue length limit is exceeded, message dropped is dead lettered.
%% Default strategy: drop-head
dead_letter_max_length_drop_head(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),

    declare_dead_letter_queues(Ch, Config, QName, DLXQName, [{<<"x-max-length">>, long, 1}]),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    %% Consume the last one from the queue (max-length = 1)
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    _ = consume(Ch, QName, [P3]),
    consume_empty(Ch, QName),
    %% Consume the dropped ones from the dead letter queue
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"2">>, <<"0">>]]),
    _ = consume(Ch, DLXQName, [P1, P2]),
    consume_empty(Ch, DLXQName),
    ?assertEqual(2, counted(messages_dead_lettered_maxlen_total, Config)).

%% https://github.com/rabbitmq/rabbitmq-server/issues/4940
dead_letter_reject_requeue_reject_norequeue(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P = <<"msg">>,
    publish(Ch, QName, [P]),

    %% Reject with requeue
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag0] = consume(Ch, QName, [P]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"0">>, <<"1">>]]),
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag0,
                                          requeue      = true}),

    %% If QName is a quorum queue, Ra log contains #requeue{} command
    %% instead of #enqueue{} command because no delivery-limit is set.
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),

    %% Reject without requeue
    [DTag1] = consume(Ch, QName, [P]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"0">>, <<"1">>]]),
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag1,
                                          requeue      = false}),
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    _ = consume(Ch, DLXQName, [P]),
    consume_empty(Ch, DLXQName),
    consume_empty(Ch, QName),
    ?assertEqual(1, counted(messages_dead_lettered_rejected_total, Config)).

%% Another strategy: reject-publish-dlx
dead_letter_max_length_reject_publish_dlx(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),

    declare_dead_letter_queues(Ch, Config, QName, DLXQName,
                               [{<<"x-max-length">>, long, 1},
                                {<<"x-overflow">>, longstr, <<"reject-publish-dlx">>}]),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    P3 = <<"msg3">>,

    %% Publish 3 messages
    publish(Ch, QName, [P1, P2, P3]),
    %% Consume the first one from the queue (max-length = 1)
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    _ = consume(Ch, QName, [P1]),
    consume_empty(Ch, QName),
    %% Consume the dropped ones from the dead letter queue
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"2">>, <<"0">>]]),
    _ = consume(Ch, DLXQName, [P2, P3]),
    consume_empty(Ch, DLXQName),
    ?assertEqual(2, counted(messages_dead_lettered_maxlen_total, Config)).

%% Dead letter exchange does not have to be declared when the queue is declared, but it should
%% exist by the time messages need to be dead-lettered; if it is missing then, the messages will
%% be silently dropped.
dead_letter_missing_exchange(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    DLXExchange = <<"dlx-exchange-2">>,
    #'exchange.delete_ok'{} = amqp_channel:call(Ch, #'exchange.delete'{exchange = DLXExchange}),

    DeadLetterArgs = [{<<"x-max-length">>, long, 1},
                      {<<"x-dead-letter-exchange">>, longstr, DLXExchange},
                      {<<"x-dead-letter-routing-key">>, longstr, DLXQName}],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,

    %% Publish one message
    publish(Ch, QName, [P1]),
    %% Consume it
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag] = consume(Ch, QName, [P1]),
    %% Reject it
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag,
                                          requeue      = false}),
    wait_for_messages(Config, [[QName, <<"0">>, <<"0">>, <<"0">>]]),
    %% Message is not in the dead letter queue (exchange does not exist)
    consume_empty(Ch, DLXQName),

    %% Declare the dead-letter exchange
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    %% Publish another message
    publish(Ch, QName, [P2]),
    %% Consume it
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag2] = consume(Ch, QName, [P2]),
    %% Reject it
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag2,
                                          requeue      = false}),
    %% Consume the rejected message from the dead letter queue
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P2}} =
    amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    consume_empty(Ch, DLXQName),
    ?assertEqual(1, counted(messages_dead_lettered_rejected_total, Config)).

%%
%% ROUTING
%%
%% Dead-lettered messages are routed to their dead letter exchange either:
%% with the routing key specified for the queue they were on; or,
%% if this was not set, (3) with the same routing keys they were originally published with.
%% (4) This includes routing keys added by the CC and BCC headers.
%%
%% 3) All previous tests used a specific key, test the original ones now.
dead_letter_routing_key(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use a specific key
    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,

    %% Publish, consume and nack the first message
    publish(Ch, QName, [P1]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag1] = consume(Ch, QName, [P1]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    case group_name(Config) of
        at_most_once ->
            %% Both queues are empty as the message could not been routed in the dlx exchange
            wait_for_messages(Config, [[QName, <<"0">>, <<"0">>, <<"0">>]]);
        at_least_once ->
            wait_for_messages(Config, [[QName, <<"1">>, <<"0">>, <<"0">>]])
    end,
    consume_empty(Ch, QName),
    consume_empty(Ch, DLXQName),
    %% Bind the dlx queue with the original queue routing key
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = QName}),
    %% Publish, consume and nack the second message
    publish(Ch, QName, [P2]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag2] = consume(Ch, QName, [P2]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag2,
                                        multiple     = false,
                                        requeue      = false}),
    %% Message can now be routed using the recently binded key
    case group_name(Config) of
        at_most_once ->
            wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
            consume(Ch, DLXQName, [P2]);
        at_least_once ->
            wait_for_messages(Config, [[DLXQName, <<"2">>, <<"2">>, <<"0">>]]),
            consume(Ch, DLXQName, [P1, P2]),
            ?assertEqual(2, counted(messages_dead_lettered_confirmed_total, Config))
    end,
    consume_empty(Ch, QName),
    ?assertEqual(2, counted(messages_dead_lettered_rejected_total, Config)).

%% 4a) If a specific routing key was not set for the queue, use routing keys added by the
%%    CC and BCC headers
dead_letter_routing_key_header_CC(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use a specific key
    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    CCHeader = {<<"CC">>, array, [{longstr, DLXQName}]},

    %% Publish, consume and nack two messages, one with CC header
    publish(Ch, QName, [P1]),
    publish(Ch, QName, [P2], [CCHeader]),
    wait_for_messages(Config, [[QName, <<"2">>, <<"2">>, <<"0">>]]),
    [_, DTag2] = consume(Ch, QName, [P1, P2]),
    %% P2 is also published to the DLX queue because of the binding to the default exchange
    [_] = consume(Ch, DLXQName, [P2]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag2,
                                        multiple     = true,
                                        requeue      = false}),
    %% The second message should have been routed using the CC header
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"1">>, <<"1">>]]),
    consume_empty(Ch, QName),
    consume(Ch, DLXQName, [P2]),
    consume_empty(Ch, DLXQName).

%% 4b) If a specific routing key was not set for the queue, use routing keys added by the
%%    CC and BCC headers
dead_letter_routing_key_header_BCC(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use a specific key
    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    BCCHeader = {<<"BCC">>, array, [{longstr, DLXQName}]},

    %% Publish, consume and nack two messages, one with BCC header
    publish(Ch, QName, [P1]),
    publish(Ch, QName, [P2], [BCCHeader]),
    wait_for_messages(Config, [[QName, <<"2">>, <<"2">>, <<"0">>]]),
    [_, DTag2] = consume(Ch, QName, [P1, P2]),
    %% P2 is also published to the DLX queue because of the binding to the default exchange
    [_] = consume(Ch, DLXQName, [P2]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag2,
                                        multiple     = true,
                                        requeue      = false}),
    %% The second message should have been routed using the BCC header
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"1">>, <<"1">>]]),
    consume_empty(Ch, QName),
    consume(Ch, DLXQName, [P2]),
    consume_empty(Ch, DLXQName).

%% It is possible to form a cycle of message dead-lettering. For instance,
%% this can happen when a queue dead-letters messages to the default exchange without
%% specifying a dead-letter routing key (5). Messages in such cycles (i.e. messages that
%% reach the same queue twice) will be dropped if there was no rejections in the entire cycle.
%% i.e. x-message-ttl (7), x-max-length (6)
%%
%% 6) Message is dead lettered due to queue length limit, and then dropped by the broker as it is
%%    republished to the same queue.
dead_letter_routing_key_cycle_max_length(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    QName = ?config(queue_name, Config),

    DeadLetterArgs = [{<<"x-max-length">>, long, 1},
                      {<<"x-dead-letter-exchange">>, longstr, <<>>}],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,

    %% Publish messages, consume and acknowledge the second one (x-max-length = 1)
    publish(Ch, QName, [P1, P2]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag] = consume(Ch, QName, [P2]),
    consume_empty(Ch, QName),
    amqp_channel:cast(Ch, #'basic.ack'{delivery_tag = DTag}),
    %% Queue is empty, P1 has not been republished in a loop
    wait_for_messages(Config, [[QName, <<"0">>, <<"0">>, <<"0">>]]),
    consume_empty(Ch, QName),
    ?assertEqual(1, counted(messages_dead_lettered_maxlen_total, Config)).

%% 7) Message is dead lettered due to message ttl.
dead_letter_routing_key_cycle_ttl(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    QName = ?config(queue_name, Config),

    DeadLetterArgs = [{<<"x-message-ttl">>, long, 1},
                      {<<"x-dead-letter-exchange">>, longstr, <<>>}],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,

    %% Publish messages
    publish(Ch, QName, [P1, P2]),
    wait_for_messages(Config, [[QName, <<"0">>, <<"0">>, <<"0">>]]),
    consume_empty(Ch, QName),
    ?assertEqual(2, counted(messages_dead_lettered_expired_total, Config)).

%% 5) Messages continue to be republished as there are manual rejections
dead_letter_routing_key_cycle_with_reject(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    QName = ?config(queue_name, Config),

    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, <<>>}],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),

    P = <<"msg1">>,

    %% Publish message
    publish(Ch, QName, [P]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag] = consume(Ch, QName, [P]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag1] = consume(Ch, QName, [P]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Message its being republished
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [_] = consume(Ch, QName, [P]),
    ?assertEqual(2, counted(messages_dead_lettered_rejected_total, Config)).

%%
%% For any given queue, a DLX can be defined by clients using the queue's arguments,
%% or in the server using policies (8). In the case where both policy and arguments specify a DLX,
%% the one specified in arguments overrules the one specified in policy (9).
%%
%% 8) Use server policies
dead_letter_policy(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args0 = ?config(queue_args, Config),
    %% declaring a quorum queue with x-dead-letter-strategy without defining a DLX will fail
    Args = proplists:delete(<<"x-dead-letter-strategy">>, Args0),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use arguments
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = Args,
                                                                   durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName,
                                                                   durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,

    %% Publish 2 messages
    publish(Ch, QName, [P1, P2]),
    %% Consume them
    wait_for_messages(Config, [[QName, <<"2">>, <<"2">>, <<"0">>]]),
    [DTag1, DTag2] = consume(Ch, QName, [P1, P2]),
    %% Nack the first one with multiple = false
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Only one message unack left in the queue
    wait_for_messages(Config, [[QName, <<"1">>, <<"0">>, <<"1">>]]),
    consume_empty(Ch, QName),
    consume_empty(Ch, DLXQName),

    %% Set a policy
    ok = rabbit_ct_broker_helpers:set_policy(Config, 0, ?config(policy, Config), QName,
                                             <<"queues">>,
                                             [{<<"dead-letter-exchange">>, DLXExchange},
                                              {<<"dead-letter-routing-key">>, DLXQName}]),
    timer:sleep(1000),
    %% Nack the second message
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag2,
                                        multiple     = false,
                                        requeue      = false}),
    %% Queue is empty
    wait_for_messages(Config, [[QName, <<"0">>, <<"0">>, <<"0">>]]),
    consume_empty(Ch, QName),
    %% Consume the message from the dead letter queue
    consume(Ch, DLXQName, [P2]),
    consume_empty(Ch, DLXQName).

%% 9) Argument overrides server policy
dead_letter_override_policy(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),

    %% Set a policy, it creates a cycle but message will be republished with the nack.
    %% Good enough for this test.
    ok = rabbit_ct_broker_helpers:set_policy(Config, 0, ?config(policy, Config), QName,
                                             <<"queues">>,
                                             [{<<"dead-letter-exchange">>, <<>>},
                                              {<<"dead-letter-routing-key">>, QName}]),

    %% Declare arguments override the policy and set routing queue
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    P1 = <<"msg1">>,

    publish(Ch, QName, [P1]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag1] = consume(Ch, QName, [P1]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Queue is empty
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    consume_empty(Ch, QName),
    [_] = consume(Ch, DLXQName, [P1]).

%% 9) Policy is set after have declared a queue with dead letter arguments. Policy will be
%%    overridden/ignored.
dead_letter_ignore_policy(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),

    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    %% Set a policy
    ok = rabbit_ct_broker_helpers:set_policy(Config, 0, ?config(policy, Config), QName,
                                             <<"queues">>,
                                             [{<<"dead-letter-exchange">>, <<>>},
                                              {<<"dead-letter-routing-key">>, QName}]),

    P1 = <<"msg1">>,

    publish(Ch, QName, [P1]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag1] = consume(Ch, QName, [P1]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Message is in the dead letter queue, original queue is empty
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    [_] = consume(Ch, DLXQName, [P1]),
    consume_empty(Ch, QName).

%%
%% HEADERS
%%
%% The dead-lettering process adds an array to the header of each dead-lettered message named
%% x-death (10). This array contains an entry for each dead lettering event containing:
%% queue, reason, time, exchange, routing-keys, count
%%  original-expiration (14) (if the message was dead-letterered due to per-message TTL)
%% New entries are prepended to the beginning of the x-death array.
%% Reason is one of the following: rejected (11), expired (12), maxlen (13)
%%
%% 10) and 11) Check all x-death headers, reason rejected
dead_letter_headers(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    %% Publish and nack a message
    P1 = <<"msg1">>,
    publish(Ch, QName, [P1]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag1] = consume(Ch, QName, [P1]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Consume and check headers
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    {array, [{table, Death}]} = rabbit_misc:table_lookup(Headers, <<"x-death">>),
    ?assertEqual({longstr, QName}, rabbit_misc:table_lookup(Death, <<"queue">>)),
    ?assertEqual({longstr, <<"rejected">>}, rabbit_misc:table_lookup(Death, <<"reason">>)),
    ?assertMatch({timestamp, _}, rabbit_misc:table_lookup(Death, <<"time">>)),
    ?assertEqual({longstr, <<>>}, rabbit_misc:table_lookup(Death, <<"exchange">>)),
    ?assertEqual({long, 1}, rabbit_misc:table_lookup(Death, <<"count">>)),
    ?assertEqual({array, [{longstr, QName}]}, rabbit_misc:table_lookup(Death, <<"routing-keys">>)).

%% 12) Per-queue message ttl has expired
dead_letter_headers_reason_expired(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName, [{<<"x-message-ttl">>, long, 1}]),

    %% Publish a message
    P1 = <<"msg1">>,
    publish(Ch, QName, [P1]),
    %% Consume and check headers
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    {array, [{table, Death}]} = rabbit_misc:table_lookup(Headers, <<"x-death">>),
    ?assertEqual({longstr, <<"expired">>}, rabbit_misc:table_lookup(Death, <<"reason">>)),
    ?assertMatch(undefined, rabbit_misc:table_lookup(Death, <<"original-expiration">>)).

%% 14) Per-message TTL has expired, original-expiration is added to x-death array
dead_letter_headers_reason_expired_per_message(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName),

    %% Publish a message
    P1 = <<"msg1">>,
    amqp_channel:call(Ch, #'basic.publish'{routing_key = QName},
                      #amqp_msg{payload = P1,
                                props = #'P_basic'{expiration = <<"1">>}}),
    %% publish another message to ensure the queue performs message expirations
    publish(Ch, QName, [<<"msg2">>]),
    %% Consume and check headers
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    {array, [{table, Death}]} = rabbit_misc:table_lookup(Headers, <<"x-death">>),
    ?assertEqual({longstr, <<"expired">>}, rabbit_misc:table_lookup(Death, <<"reason">>)),
    ?assertMatch({longstr, <<"1">>}, rabbit_misc:table_lookup(Death, <<"original-expiration">>)).

%% 13) Message expired with maxlen reason
dead_letter_headers_reason_maxlen(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    declare_dead_letter_queues(Ch, Config, QName, DLXQName, [{<<"x-max-length">>, long, 1}]),

    P1 = <<"msg1">>,
    P2 = <<"msg2">>,
    publish(Ch, QName, [P1, P2]),
    %% Consume and check reason header
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    {array, [{table, Death}]} = rabbit_misc:table_lookup(Headers, <<"x-death">>),
    ?assertEqual({longstr, <<"maxlen">>}, rabbit_misc:table_lookup(Death, <<"reason">>)).

%% In case x-death already contains an entry with the same queue and dead lettering reason,
%% its count field will be incremented and it will be moved to the beginning of the array
dead_letter_headers_cycle(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    QName = ?config(queue_name, Config),

    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, <<>>}],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),

    P = <<"msg1">>,

    %% Publish message
    publish(Ch, QName, [P]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag] = consume(Ch, QName, [P]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{delivery_tag = DTag1}, #amqp_msg{payload = P,
                                                      props = #'P_basic'{headers = Headers1}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = QName}),
    {array, [{table, Death1}]} = rabbit_misc:table_lookup(Headers1, <<"x-death">>),
    ?assertEqual({long, 1}, rabbit_misc:table_lookup(Death1, <<"count">>)),

    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Message its being republished
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P,
                                  props = #'P_basic'{headers = Headers2}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = QName}),
    {array, [{table, Death2}]} = rabbit_misc:table_lookup(Headers2, <<"x-death">>),
    ?assertEqual({long, 2}, rabbit_misc:table_lookup(Death2, <<"count">>)).

%% Dead-lettering a message modifies its headers:
%% the exchange name is replaced with that of the latest dead-letter exchange,
%% the routing key may be replaced with that specified in a queue performing dead lettering,
%% if the above happens, the CC header will also be removed (15) and
%% the BCC header will be removed as per Sender-selected distribution (16)
%%
%% CC header is kept if no dead lettering routing key is provided
dead_letter_headers_CC(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use a specific key for dead lettering, the CC header is passed
    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    P1 = <<"msg1">>,
    CCHeader = {<<"CC">>, array, [{longstr, DLXQName}]},
    publish(Ch, QName, [P1], [CCHeader]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    %% Message is published to both queues because of CC header and DLX queue bound to both
    %% exchanges
    {#'basic.get_ok'{delivery_tag = DTag1}, #amqp_msg{payload = P1,
                                                      props = #'P_basic'{headers = Headers1}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = QName}),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers2}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    %% We check the headers to ensure no dead lettering has happened
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers1, <<"x-death">>)),
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers2, <<"x-death">>)),

    %% Nack the message so it now gets dead lettered
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"1">>, <<"1">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers3}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    consume_empty(Ch, QName),
    ?assertEqual({array, [{longstr, DLXQName}]}, rabbit_misc:table_lookup(Headers3, <<"CC">>)),
    ?assertMatch({array, _}, rabbit_misc:table_lookup(Headers3, <<"x-death">>)).

%% 15) CC header is removed when routing key is specified
dead_letter_headers_CC_with_routing_key(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use a specific key for dead lettering, the CC header is passed
    DeadLetterArgs = [{<<"x-dead-letter-routing-key">>, longstr, DLXQName},
                      {<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    P1 = <<"msg1">>,
    CCHeader = {<<"CC">>, array, [{longstr, DLXQName}]},
    publish(Ch, QName, [P1], [CCHeader]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    %% Message is published to both queues because of CC header and DLX queue bound to both
    %% exchanges
    {#'basic.get_ok'{delivery_tag = DTag1}, #amqp_msg{payload = P1,
                                                      props = #'P_basic'{headers = Headers1}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = QName}),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers2}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    %% We check the headers to ensure no dead lettering has happened
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers1, <<"x-death">>)),
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers2, <<"x-death">>)),

    %% Nack the message so it now gets dead lettered
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"1">>, <<"1">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers3}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    consume_empty(Ch, QName),
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers3, <<"CC">>)),
    ?assertMatch({array, _}, rabbit_misc:table_lookup(Headers3, <<"x-death">>)).

%% 16) the BCC header will always be removed
dead_letter_headers_BCC(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Do not use a specific key for dead lettering
    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    P1 = <<"msg1">>,
    BCCHeader = {<<"BCC">>, array, [{longstr, DLXQName}]},
    publish(Ch, QName, [P1], [BCCHeader]),
    %% Message is published to both queues because of BCC header and DLX queue bound to both
    %% exchanges
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{delivery_tag = DTag1}, #amqp_msg{payload = P1,
                                                      props = #'P_basic'{headers = Headers1}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = QName}),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers2}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    %% We check the headers to ensure no dead lettering has happened
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers1, <<"x-death">>)),
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers2, <<"x-death">>)),

    %% Nack the message so it now gets dead lettered
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[DLXQName, <<"2">>, <<"1">>, <<"1">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers3}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    consume_empty(Ch, QName),
    ?assertEqual(undefined, rabbit_misc:table_lookup(Headers3, <<"BCC">>)),
    ?assertMatch({array, _}, rabbit_misc:table_lookup(Headers3, <<"x-death">>)).

%% Three top-level headers are added for the very first dead-lettering event.
%% They are
%% x-first-death-reason, x-first-death-queue, x-first-death-exchange
%% They have the same values as the reason, queue, and exchange fields of the
%% original
%% dead lettering event. Once added, these headers are never modified.
dead_letter_headers_first_death(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    DLXQName = ?config(queue_name_dlx, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Let's create a small dead-lettering loop QName -> DLXQName -> QName
    DeadLetterArgs = [{<<"x-dead-letter-routing-key">>, longstr, DLXQName},
                      {<<"x-dead-letter-exchange">>, longstr, DLXExchange}],
    DLXDeadLetterArgs = [{<<"x-dead-letter-routing-key">>, longstr, QName},
                         {<<"x-dead-letter-exchange">>, longstr, <<>>}],
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName, arguments = DeadLetterArgs ++ Args, durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable, arguments = DLXDeadLetterArgs}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}),

    %% Publish and nack a message
    P1 = <<"msg1">>,
    publish(Ch, QName, [P1]),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    [DTag1] = consume(Ch, QName, [P1]),
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag1,
                                        multiple     = false,
                                        requeue      = false}),
    %% Consume and check headers
    wait_for_messages(Config, [[DLXQName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{delivery_tag = DTag2}, #amqp_msg{payload = P1,
                                                      props = #'P_basic'{headers = Headers}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = DLXQName}),
    ?assertEqual({longstr, <<"rejected">>},
                 rabbit_misc:table_lookup(Headers, <<"x-first-death-reason">>)),
    ?assertEqual({longstr, QName},
                 rabbit_misc:table_lookup(Headers, <<"x-first-death-queue">>)),
    ?assertEqual({longstr, <<>>},
                 rabbit_misc:table_lookup(Headers, <<"x-first-death-exchange">>)),
    %% Nack the message again so it gets dead lettered to the initial queue. x-first-death
    %% headers should not change
    amqp_channel:cast(Ch, #'basic.nack'{delivery_tag = DTag2,
                                        multiple     = false,
                                        requeue      = false}),
    wait_for_messages(Config, [[QName, <<"1">>, <<"1">>, <<"0">>]]),
    {#'basic.get_ok'{}, #amqp_msg{payload = P1,
                                  props = #'P_basic'{headers = Headers2}}} =
        amqp_channel:call(Ch, #'basic.get'{queue = QName}),
    ?assertEqual({longstr, <<"rejected">>},
                 rabbit_misc:table_lookup(Headers2, <<"x-first-death-reason">>)),
    ?assertEqual({longstr, QName},
                 rabbit_misc:table_lookup(Headers2, <<"x-first-death-queue">>)),
    ?assertEqual({longstr, <<>>},
                 rabbit_misc:table_lookup(Headers2, <<"x-first-death-exchange">>)).

%% Test that headers exchange's x-match binding argument set to all-with-x and any-with-x
%% works as expected. The use case being tested here:
%% Route dead-letter messages to different target queues
%% according to first death reason and first death queue.
dead_letter_headers_first_death_route(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName1 = ?config(queue_name, Config),
    QName2 = <<"dead_letter_headers_first_death_route_source_queue_2">>,
    DLXExpiredQName = ?config(queue_name_dlx, Config),
    DLXRejectedQName = ?config(queue_name_dlx_2, Config),
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange,
                                                                         type = <<"headers">>}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName1,
                                                                   arguments = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange} | Args],
                                                                   durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName2,
                                                                   arguments = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange} | Args],
                                                                   durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXExpiredQName,
                                                                   durable = Durable}),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXRejectedQName,
                                                                   durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXExpiredQName,
                                                             exchange    = DLXExchange,
                                                             arguments = [{<<"x-match">>, longstr, <<"all-with-x">>},
                                                                          {<<"x-first-death-reason">>, longstr, <<"expired">>},
                                                                          {<<"x-first-death-queue">>, longstr, QName1}]
                                                            }),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXRejectedQName,
                                                             exchange    = DLXExchange,
                                                             arguments = [{<<"x-match">>, longstr, <<"any-with-x">>},
                                                                          {<<"x-first-death-reason">>, longstr, <<"rejected">>}]
                                                            }),
    %% Send 1st message to 1st source queue and let it expire.
    P1 = <<"msg1">>,
    amqp_channel:call(Ch, #'basic.publish'{routing_key = QName1},
                      #amqp_msg{payload = P1,
                                props = #'P_basic'{expiration = <<"0">>}}),
    %% The 1st message gets dead-lettered to DLXExpiredQName.
    wait_for_messages(Config, [[DLXExpiredQName, <<"1">>, <<"1">>, <<"0">>]]),
    _ = consume(Ch, DLXExpiredQName, [P1]),
    consume_empty(Ch, DLXExpiredQName),
    wait_for_messages(Config, [[QName1, <<"0">>, <<"0">>, <<"0">>]]),
    %% Send 2nd message to 2nd source queue and let it expire.
    P2 = <<"msg2">>,
    amqp_channel:call(Ch, #'basic.publish'{routing_key = QName2},
                      #amqp_msg{payload = P2,
                                props = #'P_basic'{expiration = <<"0">>}}),
    %% Send 2nd message should not be routed by the dead letter headers exchange.
    rabbit_ct_helpers:consistently(?_assertEqual(#'basic.get_empty'{},
                                                 amqp_channel:call(Ch, #'basic.get'{queue = DLXExpiredQName}))),
    %% Send and reject the 3rd message.
    P3 = <<"msg3">>,
    publish(Ch, QName2, [P3]),
    timer:sleep(1000),
    [DTag] = consume(Ch, QName2, [P3]),
    amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag,
                                          requeue      = false}),
    %% The 3rd message gets dead-lettered to DLXRejectedQName.
    wait_for_messages(Config, [[DLXRejectedQName, <<"1">>, <<"1">>, <<"0">>]]),
    _ = consume(Ch, DLXRejectedQName, [P3]),
    consume_empty(Ch, DLXRejectedQName),
    _ = amqp_channel:call(Ch, #'queue.delete'{queue = QName2}),
    ok.

%% Route dead-letter messages also to extra BCC queues of target queues.
dead_letter_extra_bcc(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    SourceQ = ?config(queue_name, Config),
    TargetQ = ?config(queue_name_dlx, Config),
    ExtraBCCQ = ?config(queue_name_dlx_2, Config),
    Durable = ?config(queue_durable, Config),
    declare_dead_letter_queues(Ch, Config, SourceQ, TargetQ, [{<<"x-message-ttl">>, long, 0}]),
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = ExtraBCCQ,
                                                                   durable = Durable}),
    rabbit_ct_broker_helpers:rpc(Config, 0, ?MODULE, set_queue_options,
                                 [TargetQ, #{extra_bcc => ExtraBCCQ}]),
    %% Publish message
    P = <<"msg">>,
    publish(Ch, SourceQ, [P]),
    wait_for_messages(Config, [[TargetQ, <<"1">>, <<"1">>, <<"0">>],
                               [ExtraBCCQ, <<"1">>, <<"1">>, <<"0">>]]),
    consume_empty(Ch, SourceQ),
    [_] = consume(Ch, TargetQ, [P]),
    [_] = consume(Ch, ExtraBCCQ, [P]),
    ok.

set_queue_options(QName, Options) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() ->
              rabbit_amqqueue:update(rabbit_misc:r(<<"/">>, queue, QName),
                                     fun(Q) ->
                                             amqqueue:set_options(Q, Options)
                                     end)
      end).

metric_maxlen(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    #'queue.declare_ok'{} = amqp_channel:call(
                              Ch, #'queue.declare'{queue = QName,
                                                   arguments = [{<<"x-max-length">>, long, 1},
                                                                {<<"x-overflow">>, longstr, <<"drop-head">>} |
                                                                ?config(queue_args, Config)],
                                                   durable = ?config(queue_durable, Config)}),
    %% Publish 1000 messages
    Payloads = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, 1000)),
    publish(Ch, QName, Payloads),
    ?awaitMatch(999, counted(messages_dead_lettered_maxlen_total, Config), 3000, 300).

metric_rejected(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    #'queue.declare_ok'{} = amqp_channel:call(
                              Ch, #'queue.declare'{queue = QName,
                                                   arguments = ?config(queue_args, Config),
                                                   durable = ?config(queue_durable, Config)}),
    %% Publish 1000 messages
    Payloads = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, 1000)),
    publish(Ch, QName, Payloads),
    wait_for_messages(Config, [[QName, <<"1000">>, <<"1000">>, <<"0">>]]),

    %% Reject all messages using same consumer
    amqp_channel:subscribe(Ch, #'basic.consume'{queue = QName}, self()),
    CTag = receive #'basic.consume_ok'{consumer_tag = C} -> C end,
    [begin
         receive {#'basic.deliver'{consumer_tag = CTag, delivery_tag = DTag}, #amqp_msg{payload = P}} ->
                     amqp_channel:cast(Ch, #'basic.reject'{delivery_tag = DTag, requeue = false})
         after 5000 ->
                   amqp_channel:call(Ch, #'basic.cancel'{consumer_tag = CTag}),
                   exit(timeout)
         end
     end || P <- Payloads],
    amqp_channel:call(Ch, #'basic.cancel'{consumer_tag = CTag}),
    ?awaitMatch(1000, counted(messages_dead_lettered_rejected_total, Config), 3000, 300).

metric_expired_queue_msg_ttl(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    #'queue.declare_ok'{} = amqp_channel:call(
                              Ch, #'queue.declare'{queue = QName,
                                                   arguments = [{<<"x-message-ttl">>, long, 0} |
                                                                ?config(queue_args, Config)],
                                                   durable = ?config(queue_durable, Config)}),
    %% Publish 1000 messages
    Payloads = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, 1000)),
    publish(Ch, QName, Payloads),
    ?awaitMatch(1000, counted(messages_dead_lettered_expired_total, Config), 3000, 300).

metric_expired_per_msg_msg_ttl(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    QName = ?config(queue_name, Config),
    #'queue.declare_ok'{} = amqp_channel:call(
                              Ch, #'queue.declare'{queue = QName,
                                                   arguments = ?config(queue_args, Config),
                                                   durable = ?config(queue_durable, Config)}),
    %% Publish 1000 messages
    Payloads = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, 1000)),
    [amqp_channel:call(Ch, #'basic.publish'{routing_key = QName},
                       #amqp_msg{payload = Payload,
                                 props = #'P_basic'{expiration = <<"0">>}})
     || Payload <- Payloads],
    ?awaitMatch(1000, counted(messages_dead_lettered_expired_total, Config), 3000, 300).

%%%%%%%%%%%%%%%%%%%%%%%%
%% Test helpers
%%%%%%%%%%%%%%%%%%%%%%%%
declare_dead_letter_queues(Ch, Config, QName, DLXQName) ->
    declare_dead_letter_queues(Ch, Config, QName, DLXQName, []).

declare_dead_letter_queues(Ch, Config, QName, DLXQName, ExtraArgs) ->
    Args = ?config(queue_args, Config),
    Durable = ?config(queue_durable, Config),
    DLXExchange = ?config(dlx_exchange, Config),

    %% Declare DLX exchange
    #'exchange.declare_ok'{} = amqp_channel:call(Ch, #'exchange.declare'{exchange = DLXExchange}),

    %% Declare queue
    DeadLetterArgs = [{<<"x-dead-letter-exchange">>, longstr, DLXExchange},
                      {<<"x-dead-letter-routing-key">>, longstr, DLXQName}],
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = QName,
                                                                   arguments = DeadLetterArgs ++ Args ++ ExtraArgs,
                                                                   durable = Durable}),
    %% Declare and bind DLX queue
    #'queue.declare_ok'{} = amqp_channel:call(Ch, #'queue.declare'{queue = DLXQName, durable = Durable}),
    #'queue.bind_ok'{} = amqp_channel:call(Ch, #'queue.bind'{queue       = DLXQName,
                                                             exchange    = DLXExchange,
                                                             routing_key = DLXQName}).

publish(Ch, QName, Payloads) ->
    [amqp_channel:call(Ch, #'basic.publish'{routing_key = QName}, #amqp_msg{payload = Payload})
     || Payload <- Payloads].

publish(Ch, QName, Payloads, Headers) ->
    [amqp_channel:call(Ch, #'basic.publish'{routing_key = QName},
                       #amqp_msg{payload = Payload,
                                 props = #'P_basic'{headers = Headers}})
     || Payload <- Payloads].

consume(Ch, QName, Payloads) ->
    [begin
         {#'basic.get_ok'{delivery_tag = DTag}, #amqp_msg{payload = Payload}} =
         amqp_channel:call(Ch, #'basic.get'{queue = QName}),
         DTag
     end || Payload <- Payloads].

consume_empty(Ch, QName) ->
    #'basic.get_empty'{} = amqp_channel:call(Ch, #'basic.get'{queue = QName}).

sync_mirrors(QName, Config) ->
    case ?config(is_mirrored, Config) of
        true ->
            rabbit_ct_broker_helpers:rabbitmqctl(Config, 0, [<<"sync_queue">>, QName]);
        _ -> ok
    end.

get_global_counters(Config) ->
    rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_global_counters, overview, []).

%% Returns the delta of Metric between testcase start and now.
counted(Metric, Config) ->
    QueueType = queue_type(outer_group_name(Config)),
    Strategy = group_name(Config),
    OldCounters = ?config(counters, Config),
    Counters = get_global_counters(Config),
    metric(QueueType, Strategy, Metric, Counters) -
    metric(QueueType, Strategy, Metric, OldCounters).

metric(QueueType, Strategy, Metric, Counters) ->
    Metrics = maps:get([{queue_type, QueueType}, {dead_letter_strategy, Strategy}], Counters),
    maps:get(Metric, Metrics).

group_name(Config) ->
    proplists:get_value(name, ?config(tc_group_properties, Config)).

outer_group_name(Config) ->
    [{name, Name} | _] = hd(?config(tc_group_path, Config)),
    Name.

queue_type(quorum_queue) ->
    rabbit_quorum_queue;
queue_type(_) ->
    rabbit_classic_queue.
