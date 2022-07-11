
-module(mc).

-export([
         init/3,
         size/1,


         get_annotation/2,
         convert/2,
         content/1
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


get_annotation(Key, #?MODULE{annotations = Anns}) ->
    maps:get(Key, Anns, undefined).

convert(Proto, #?MODULE{cfg = #cfg{protocol = Proto}} = State) ->
    State.

content(#?MODULE{cfg = #cfg{protocol = Proto},
                 data = Data}) ->
    Proto:content(Data).

%% INTERNAL

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
