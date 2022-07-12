-module(rabbit_mc_amqp_legacy).
-behaviour(mc).

-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([
         init/1,
         size/1,
         set_property/3,
         get_property/2,
         content/1,
         convert/2
        ]).

-define(HEADER_GUESS_SIZE, 100). %% see determine_persist_to/2

-opaque state() :: #content{}.

-export_type([
              state/0
             ]).

%% mc implementation
init(#content{} = Content) ->
    %% TODO header routes
    strip_header(Content, ?DELETED_HEADER).

size(#content{properties_bin = PropsBin,
              properties = Props,
              payload_fragments_rev = Payload}) ->
    MetaSize = case is_binary(PropsBin) of
                   true ->
                       byte_size(PropsBin);
                   false ->
                       #'P_basic'{headers = Hs} = Props,
                       case Hs of
                           undefined -> 0;
                           _ -> length(Hs)
                       end * ?HEADER_GUESS_SIZE
               end,
    {MetaSize, iolist_size(Payload)}.

set_property(_P, _V, C) ->
    C.

get_property(durable,
             #content{properties = #'P_basic'{delivery_mode = Mode}} = C) ->
    {Mode == 2, C};
get_property(ttl, #content{properties = Props} = C) ->
    {ok, MsgTTL} = rabbit_basic:parse_expiration(Props),
    {MsgTTL, C};
get_property(_P, C) ->
    {undefined, C}.

content(C) ->
    C.

convert(?MODULE, C) ->
    C.

%% internal

strip_header(#content{properties = #'P_basic'{headers = undefined}}
             = DecodedContent, _Key) ->
    DecodedContent;
strip_header(#content{properties = Props = #'P_basic'{headers = Headers}}
             = DecodedContent, Key) ->
    case lists:keysearch(Key, 1, Headers) of
        false          -> DecodedContent;
        {value, Found} -> Headers0 = lists:delete(Found, Headers),
                          rabbit_binary_generator:clear_encoded_content(
                            DecodedContent#content{
                              properties = Props#'P_basic'{
                                             headers = Headers0}})
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
