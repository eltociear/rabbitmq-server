-module(rabbit_mc_amqp_legacy).
-behaviour(mc).

% -include_lib("rabbit_common/include/rabbit_framing.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([
         init/1,
         size/1,
         set_property/3,
         get_property/2,
         content/1
        ]).


-opaque state() :: #content{}.

-export_type([
              state/0
             ]).

%% mc implementation
init(#content{} = Content) ->
    Content.

size(#content{payload_fragments_rev = Payload}) ->
    %% TODO: properties size
    {0, iolist_size(Payload)}.

set_property(_P, _V, C) ->
    C.

get_property(_P, C) ->
    {undefined, C}.

content(C) ->
    C.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
