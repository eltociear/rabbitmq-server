-module(mc).

-export([
         init/3,
         size/1,


         get_annotation/2,
         set_annotation/3,
         %% properties
         is_persistent/1,
         ttl/1,
         %%
         convert/2,
         protocol_state/1,
         serialize/1,
         prepare/1
         ]).

-define(NIL, []).
-include_lib("amqp10_common/include/amqp10_framing.hrl").

-type str() :: atom() | string() | binary().

-type ann_key() :: str().
-type ann_value() :: str() | integer() | float() | [ann_value()].
-type protocol() :: module().
-type annotations() :: #{ann_key() => ann_value()}.

-type amqp_message_section() ::
    #'v1_0.header'{} |
    #'v1_0.delivery_annotations'{} |
    #'v1_0.message_annotations'{} |
    #'v1_0.properties'{} |
    #'v1_0.application_properties'{} |
    #'v1_0.data'{} |
    #'v1_0.amqp_sequence'{} |
    #'v1_0.amqp_value'{} |
    #'v1_0.footer'{}.

%% the protocol module must implement the mc behaviour
-record(cfg, {protocol :: module()}).

-record(?MODULE, {cfg :: #cfg{},
                  %% protocol specific data term
                  data :: term(),
                  %% any annotations done by the broker itself
                  %% such as recording the exchange / routing keys used
                  annotations = #{} :: annotations()}).

-opaque state() :: #?MODULE{}.

-export_type([
              state/0,
              amqp_message_section/0
              ]).

-type proto_state() :: term().
-type property() :: user_id |
                    reply_to |
                    message_id |
                    ttl |
                    priority |
                    durable
                    . %% etc
-type property_value() :: undefined |
                          string() |
                          binary() |
                          integer() |
                          float() |
                          boolean().

%% behaviour callbacks for protocol specific implementation
%% returns a map of additional annotations to merge into the
%% protocol generic annotations map
-callback init(term()) ->
    {proto_state(), annotations()}.

-callback init_amqp([amqp_message_section()]) -> proto_state().

-callback size(proto_state()) ->
    {MetadataSize :: non_neg_integer(),
     PayloadSize :: non_neg_integer()}.

%% strictly speaking properties ought to be immutable
-callback get_property(property(), proto_state()) ->
    {property_value(), proto_state()}.

%% all protocol must be able to convert to amqp (1.0)
-callback convert(protocol(), proto_state()) ->
    proto_state() | not_supported.

%% serialize the data into the protocol's binary format
-callback serialize(proto_state(), annotations()) ->
    iodata().

%%% API

-spec init(protocol(), term(), annotations()) -> state().
init(Proto, Data, Anns)
  when is_atom(Proto)
       andalso is_map(Anns) ->
    {ProtoData, AddAnns} = Proto:init(Data),
    #?MODULE{cfg = #cfg{protocol = Proto},
             data = ProtoData,
             %% not sure what the precedence rule should be for annotations
             %% that are explicitly passed vs annotations that are recovered
             %% from the protocol parsing
             annotations = maps:merge(AddAnns, Anns)}.

-spec size(state()) ->
    {MetadataSize :: non_neg_integer(),
     PayloadSize :: non_neg_integer()}.
size(#?MODULE{cfg = #cfg{protocol = Proto},
              data = Data}) ->
    Proto:size(Data).


-spec get_annotation(ann_key(), state()) -> ann_value() | undefined.
get_annotation(Key, #?MODULE{annotations = Anns}) ->
    maps:get(Key, Anns, undefined).

-spec set_annotation(ann_key(), ann_value(), state()) ->
    state().
set_annotation(Key, Value, #?MODULE{annotations = Anns} = State) ->
    State#?MODULE{annotations = maps:put(Key, Value, Anns)}.

-spec is_persistent(state()) -> boolean().
is_persistent(#?MODULE{cfg = #cfg{protocol = Proto},
                       data = Data}) ->
    {Result, _} = Proto:get_property(durable, Data),
    Result.

-spec ttl(state()) -> boolean().
ttl(#?MODULE{cfg = #cfg{protocol = Proto},
                       data = Data}) ->
    {Result, _} = Proto:get_property(ttl, Data),
    Result.

-spec convert(protocol(), state()) -> state().
convert(Proto, #?MODULE{cfg = #cfg{protocol = Proto}} = State) ->
    State;
convert(TargetProto, #?MODULE{cfg = #cfg{protocol = Proto},
                              data = Data} = State) ->
    case Proto:convert(TargetProto, Data) of
        not_implemented ->
            %% convert to 1.0 then try again
            AmqpData = Proto:convert(rabbit_mc_amqp, Data),
            %% init the target from a list of amqp sections
            State#?MODULE{cfg = #cfg{protocol = TargetProto},
                          data = TargetProto:init_amqp(AmqpData)};
        TargetState ->
            State#?MODULE{cfg = #cfg{protocol = TargetProto},
                          data = TargetState}
    end.

-spec protocol_state(state()) -> term().
protocol_state(#?MODULE{cfg = #cfg{protocol = _Proto},
                 data = Data}) ->
    Data.


-spec prepare(state()) -> state().
prepare(State) ->
    State.

-spec serialize(state()) -> iodata().
serialize(#?MODULE{cfg = #cfg{protocol = Proto},
                   annotations = Anns,
                   data = Data}) ->
    Proto:serialize(Data, Anns).

%% INTERNAL

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
