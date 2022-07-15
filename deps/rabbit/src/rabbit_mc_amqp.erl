-module(rabbit_mc_amqp).
-behaviour(mc).

% -include_lib("rabbit_common/include/rabbit_framing.hrl").
-include_lib("amqp10_common/include/amqp10_framing.hrl").
% -include_lib("rabbit_common/include/rabbit.hrl").

-export([
         init/1,
         init_amqp/1,
         size/1,
         get_property/2,
         convert/2,
         serialize/2
        ]).

-type maybe(T) :: T | undefined.
-type amqp10_data() :: #'v1_0.data'{} |
                       [#'v1_0.amqp_sequence'{} | #'v1_0.data'{}] |
                       #'v1_0.amqp_value'{}.
-record(msg,
        {
         header :: maybe(#'v1_0.header'{}),
         % delivery_annotations :: maybe(#'v1_0.delivery_annotations'{}),
         message_annotations :: maybe(#'v1_0.message_annotations'{}),
         properties :: maybe(#'v1_0.properties'{}),
         application_properties :: maybe(#'v1_0.application_properties'{}),
         data :: maybe(amqp10_data())
         % footer :: maybe(#'v1_0.footer'{})
         }).

-opaque state() :: #msg{}.

-export_type([
              state/0
             ]).

%% mc implementation
init(Sections) when is_list(Sections) ->
    Msg = decode(Sections, #msg{}),
    Anns = recover_annotations(Msg),
    {Msg, Anns};
init(#msg{} = Msg) ->
    Anns = recover_annotations(Msg),
    {Msg, Anns}.

init_amqp(Sections) ->
    element(1, init(Sections)).

size(#msg{data = #'v1_0.data'{content = Data}}) ->
    MetaSize = 0,
    {MetaSize, iolist_size(Data)}.

get_property(durable, Msg) ->
    case Msg of
        #msg{header = #'v1_0.header'{durable = Durable}}
          when is_atom(Durable) ->
            {Durable, Msg};
        _ ->
            %% fallback in case the source protocol was AMQP 0.9.1
            case message_annotation(<<"x-basic-delivery-mode">>, Msg, 2) of
                {ubyte, 2} ->
                    true;
                _ ->
                    false
            end
    end;
get_property(ttl, Msg) ->
    case Msg of
        #msg{header = #'v1_0.header'{ttl = Ttl}} ->
            {Ttl, Msg};
        _ ->
            %% fallback in case the source protocol was AMQP 0.9.1
            case message_annotation(<<"x-basic-expiration">>, Msg, 2) of
                {utf8, Expiration}  ->
                    {ok, Ttl} = rabbit_basic:parse_expiration(Expiration),
                    {Ttl, Msg};
                _ ->
                    {undefined, Msg}
            end
    end;
get_property(_P, Msg) ->
    {undefined, Msg}.

convert(?MODULE, Msg) ->
    Msg;
convert(TargetProto, #msg{header = Header,
                          message_annotations = MA,
                          properties = P,
                          application_properties = AP,
                          data = Data}) ->
    Sections = [Header, MA, P, AP, Data],
    TargetProto:init_amqp(Sections).

serialize(#msg{header = Header,
               message_annotations = MA0,
               properties = P,
               application_properties = AP,
               data = Data}, Anns) ->
    Exchange = maps:get(exchange, Anns),
    [RKey | _] = maps:get(routing_keys, Anns),

    %% any x-* annotations get added as message annotations
    AnnsToAdd = maps:filter(
                  fun (<<"x-", _Rest/binary>>, _Val) ->
                          true;
                      (_, _) ->
                          false
                  end, Anns),

    MA = add_message_annotations(
           AnnsToAdd#{<<"x-exchange">> => wrap(Exchange),
                      <<"x-routing-key">> => wrap(RKey)}, MA0),
    [encode_bin(Header),
     encode_bin(MA),
     encode_bin(P),
     encode_bin(AP),
     encode_bin(Data)].

%% internal
%%

encode_bin(undefined) ->
    <<>>;
encode_bin(Section) ->
    case is_empty(Section) of
        true ->
            <<>>;
        false ->
            amqp10_framing:encode_bin(Section)
    end.

is_empty(#'v1_0.properties'{message_id = undefined,
                            user_id = undefined,
                            to = undefined,
                            % subject = wrap(utf8, RKey),
                            reply_to = undefined,
                            correlation_id = undefined,
                            content_type = undefined,
                            content_encoding = undefined,
                            creation_time = undefined}) ->
    true;
is_empty(#'v1_0.application_properties'{content = []}) ->
    true;
is_empty(#'v1_0.message_annotations'{content = []}) ->
    true;
is_empty(_) ->
    false.


message_annotation(_Key, #msg{message_annotations = undefined},
                  Default) ->
    Default;
message_annotation(Key, #msg{message_annotations =
                             #'v1_0.message_annotations'{content = Content}},
                   Default)
  when is_binary(Key) ->
    %% the section record format really is terrible
    case lists:search(fun ({{symbol, K}, _}) -> K == Key end, Content) of
        {value, {_K, V}} ->
            V;
        false ->
            Default
    end.

decode([], Acc) ->
    Acc;
decode([#'v1_0.header'{} = H | Rem], Msg) ->
    decode(Rem, Msg#msg{header = H});
decode([#'v1_0.message_annotations'{} = MA | Rem], Msg) ->

    decode(Rem, Msg#msg{message_annotations = MA});
decode([#'v1_0.properties'{} = P | Rem], Msg) ->
    decode(Rem, Msg#msg{properties = P});
decode([#'v1_0.application_properties'{} = AP | Rem], Msg) ->
    decode(Rem, Msg#msg{application_properties = AP});
decode([#'v1_0.data'{} = D | Rem], Msg) ->
    decode(Rem, Msg#msg{data = D}).

add_message_annotations(Anns, MA0) ->
    Content = maps:fold(
                fun (K, {T, V}, Acc) ->
                        map_add(symbol, K, T, V, Acc)
                end,
                case MA0 of
                    undefined -> [];
                    #'v1_0.message_annotations'{content = C} -> C
                end,
                Anns),
    #'v1_0.message_annotations'{content = Content}.

map_add(_T, _Key, _Type, undefined, Acc) ->
    Acc;
map_add(KeyType, Key, Type, Value, Acc) ->
    [{wrap(KeyType, Key), wrap(Type, Value)} | Acc].

wrap(_Type, undefined) ->
    undefined;
wrap(Type, Val) ->
    {Type, Val}.

wrap(undefined) ->
    undefined;
wrap(Val) when is_binary(Val) ->
    %% assume string value
    {utf8, Val};
wrap(Val) when is_integer(Val) ->
    %% assume string value
    {uint, Val}.

recover_annotations(#msg{message_annotations = MA}) ->
    Content = MA#'v1_0.message_annotations'.content,
    lists:foldl(
      fun ({{symbol, <<"x-routing-key">>},
            {utf8, Key}}, Acc) ->
              Acc#{routing_keys => [Key]};
          ({{symbol, <<"x-exchange">>},
            {utf8, Exchange}}, Acc) ->
              Acc#{exchange => Exchange};
          (_, Acc) ->
              Acc
      end, #{}, Content).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
