
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
         content/1,
         prepare/1
         ]).

-define(NIL, []).

-type str() :: atom() | string() | binary().

-type ann_key() :: str().
-type ann_value() :: str() | integer() | float() | [ann_value()].
-type protocol() :: module().
-type annotations() :: #{ann_key() => ann_value()}.

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
              state/0
              ]).

-type proto_state() :: term().
-type proto_content() :: term().
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
-callback init(term()) -> proto_state().

-callback size(proto_state()) ->
    {MetadataSize :: non_neg_integer(),
     PayloadSize :: non_neg_integer()}.

-callback set_property(property(), property_value(), proto_state()) ->
    proto_state().

%% strictly speaking properties ought to be immutable
-callback get_property(property(), proto_state()) ->
    {property_value(), proto_state()}.

%% Returns the message in it's protocol specific parsed container type
-callback content(proto_state()) ->
    proto_content().

%% all protocol must be able to convert to amqp (1.0)
-callback convert(protocol(), proto_state()) ->
    proto_state() | not_supported.

%%% API

-spec init(protocol(), term(), annotations()) -> state().
init(Proto, Data, Anns)
  when is_atom(Proto)
       andalso is_map(Anns) ->
    ProtoData = Proto:init(Data),
    #?MODULE{cfg = #cfg{protocol = Proto},
             data = ProtoData,
             annotations = Anns}.

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
    State.

-spec content(state()) -> term().
content(#?MODULE{cfg = #cfg{protocol = Proto},
                 data = Data}) ->
    Proto:content(Data).


-spec prepare(state()) -> state().
prepare(State) ->
    State.

%% INTERNAL

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
