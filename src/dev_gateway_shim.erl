%%% @doc A request hook for gateway-style location path rewrites.
%%%
%%% `gateway-shim@1.0' is a no-op unless routes are configured. It applies
%%% the first matching route from an ordered list, allowing node operators to
%%% express simple gateway rewrites in HyperBEAM options instead of in a
%%% reverse proxy.
%%%
%%% Routes can be configured on the hook device with `routes', or globally
%%% with the `gateway-shim-routes' node option. Local configuration takes
%%% precedence.
%%%
%%% Each route supports:
%%%
%%% * `template': request template used to select the route.
%%% * `path': replacement path, defaulting to the current request path.
%%% * `strip-prefix': prefix removed from the selected path.
%%% * `prefix': value prepended to the path.
%%% * `match' and `with': global regular-expression replacement.
%%% * `suffix': value appended to the path.
%%%
%%% Path transforms run in this order: `path', `strip-prefix', `prefix',
%%% `match' / `with', and `suffix'. When a route changes the request, the
%%% hook rebuilds the singleton `body' from the rewritten request.
%%%
%%% Example:
%%%
%%% ```erlang
%%% #{
%%%   <<"gateway-shim-routes">> => [
%%%     #{ <<"template">> => <<"^/~bundler@1\\.0/tx">> },
%%%     #{ <<"template">> => <<"^/~bundler@1\\.0/item">> },
%%%     #{
%%%       <<"template">> => <<"^/">>,
%%%       <<"path">> => <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>
%%%     }
%%%   ]
%%% }
%%% ```
-module(dev_gateway_shim).
-implements(<<"gateway-shim@1.0">>).
-specification("../SPEC.md").
-export([request/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

%% @doc Apply configured inbound path rewrite routes.
request(Base, HookReq, Opts) ->
    ?event(gateway_shim, {request, {base, Base}, {hook_req, HookReq}}),
    case hb_maps:find(<<"request">>, HookReq, Opts) of
        {ok, Req} ->
            NewReq = rewrite_request(Base, Req, Opts),
            {ok, update_hook_req(HookReq, Req, NewReq, Opts)};
        error ->
            {ok, HookReq}
    end.

%% @doc Apply the first matching inbound rewrite route, if one is configured.
rewrite_request(Base, Req, Opts) ->
    rewrite(Req, routes(Base, Opts), Opts).

rewrite(Req, [], _Opts) ->
    Req;
rewrite(Req, [Route | Rest], Opts) ->
    Template = hb_maps:get(<<"template">>, Route, #{}, Opts),
    case hb_util:template_matches(Req, Template, Opts) of
        true ->
            NewReq = apply_route(Req, Route, Opts),
            ?event(
                gateway_shim,
                {
                    rewritten,
                    {template, Template},
                    {from, hb_maps:get(<<"path">>, Req, <<"/">>, Opts)},
                    {to, hb_maps:get(<<"path">>, NewReq, <<"/">>, Opts)}
                }
            ),
            NewReq;
        false -> rewrite(Req, Rest, Opts)
    end.

%% @doc Apply a route's path transforms.
apply_route(Req, Route, Opts) ->
    Path = hb_maps:get(<<"path">>, Req, <<"/">>, Opts),
    RoutedPath =
        apply_path_suffix(
            Route,
            apply_path_replace(
                Route,
                apply_path_prefix(
                    Route,
                    apply_path_strip(
                        Route,
                        route_path(Route, Path, Opts),
                        Opts
                    ),
                    Opts
                ),
                Opts
            ),
            Opts
        ),
    Req#{ <<"path">> => RoutedPath }.

route_path(Route, Default, Opts) ->
    hb_cache:ensure_loaded(hb_maps:get(<<"path">>, Route, Default, Opts), Opts).

apply_path_strip(Route, Path, Opts) ->
    case hb_maps:find(<<"strip-prefix">>, Route, Opts) of
        {ok, Prefix} -> strip_prefix(Path, hb_cache:ensure_loaded(Prefix, Opts));
        error -> Path
    end.

apply_path_prefix(Route, Path, Opts) ->
    case hb_maps:find(<<"prefix">>, Route, Opts) of
        {ok, Prefix} ->
            LoadedPrefix = hb_cache:ensure_loaded(Prefix, Opts),
            <<LoadedPrefix/binary, Path/binary>>;
        error -> Path
    end.

apply_path_replace(Route, Path, Opts) ->
    case {hb_maps:find(<<"match">>, Route, Opts), hb_maps:find(<<"with">>, Route, Opts)} of
        {{ok, Match}, {ok, With}} ->
            re:replace(
                Path,
                hb_cache:ensure_loaded(Match, Opts),
                hb_cache:ensure_loaded(With, Opts),
                [global, {return, binary}]
            );
        _ -> Path
    end.

apply_path_suffix(Route, Path, Opts) ->
    case hb_maps:find(<<"suffix">>, Route, Opts) of
        {ok, Suffix} ->
            LoadedSuffix = hb_cache:ensure_loaded(Suffix, Opts),
            <<Path/binary, LoadedSuffix/binary>>;
        error -> Path
    end.

%% @doc Update the hook request and reparse the body when the singleton changed.
update_hook_req(HookReq, Req, Req, _Opts) ->
    HookReq;
update_hook_req(HookReq, _OldReq, NewReq, Opts) ->
    HookReq#{
        <<"request">> => NewReq,
        <<"body">> => hb_singleton:from(NewReq, Opts)
    }.

%% @doc Remove a prefix from a path, preserving a leading slash.
strip_prefix(Prefix, Prefix) ->
    <<"/">>;
strip_prefix(Path, Prefix) ->
    case Path of
        <<Prefix:(byte_size(Prefix))/binary, "/", Rest/binary>> ->
            <<"/", Rest/binary>>;
        <<Prefix:(byte_size(Prefix))/binary, Rest/binary>> ->
            Rest;
        _ ->
            Path
    end.

routes(Base, Opts) ->
    maybe_list(option(Base, <<"routes">>, <<"gateway-shim-routes">>, [], Opts), Opts).

option(Base, LocalKey, GlobalKey, Default, Opts) ->
    hb_maps:get(LocalKey, Base, hb_opts:get(GlobalKey, Default, Opts), Opts).

maybe_list(false, _Opts) ->
    [];
maybe_list(undefined, _Opts) ->
    [];
maybe_list(List, _Opts) when is_list(List) ->
    List;
maybe_list(Msg, Opts) when is_map(Msg) ->
    case hb_util:is_ordered_list(Msg, Opts) of
        true -> hb_util:message_to_ordered_list(Msg, Opts);
        false -> [Msg]
    end;
maybe_list(Item, _Opts) ->
    [Item].

%%% Tests

rewrite_route_test() ->
    Base =
        #{
            <<"routes">> =>
                [
                    #{
                        <<"template">> => <<"^/_hb/">>,
                        <<"match">> => <<"^/_hb">>,
                        <<"with">> => <<"">>
                    }
                ]
        },
    HookReq =
        #{
            <<"request">> =>
                #{
                    <<"method">> => <<"GET">>,
                    <<"path">> => <<"/_hb/~meta@1.0/info">>
                },
            <<"body">> => []
        },
    {ok, Res} = request(Base, HookReq, #{}),
    Req = hb_maps:get(<<"request">>, Res),
    ?assertEqual(<<"/~meta@1.0/info">>, hb_maps:get(<<"path">>, Req)),
    ?assertEqual(hb_singleton:from(Req, #{}), hb_maps:get(<<"body">>, Res)).

global_routes_test() ->
    HookReq =
        #{
            <<"request">> =>
                #{
                    <<"method">> => <<"GET">>,
                    <<"path">> => <<"/upload">>
                },
            <<"body">> => []
        },
    Opts =
        #{
            <<"gateway-shim-routes">> =>
                [
                    #{
                        <<"template">> => <<"^/upload">>,
                        <<"path">> => <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>
                    }
                ]
        },
    {ok, Res} = request(#{}, HookReq, Opts),
    Req = hb_maps:get(<<"request">>, Res),
    ?assertEqual(
        <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>,
        hb_maps:get(<<"path">>, Req)
    ),
    ?assertEqual(hb_singleton:from(Req, Opts), hb_maps:get(<<"body">>, Res)).

upload_location_rewrite_test() ->
    UploadPath = <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>,
    Base =
        #{
            <<"routes">> =>
                [
                    #{ <<"template">> => <<"^/~bundler@1\\.0/tx">> },
                    #{ <<"template">> => <<"^/~bundler@1\\.0/item">> },
                    #{
                        <<"template">> => <<"^/">>,
                        <<"path">> => UploadPath
                    }
                ]
        },
    RewriteReq =
        #{
            <<"request">> =>
                #{
                    <<"method">> => <<"POST">>,
                    <<"path">> => <<"/">>
                },
            <<"body">> => []
        },
    {ok, RewriteRes} = request(Base, RewriteReq, #{}),
    Rewritten = hb_maps:get(<<"request">>, RewriteRes),
    ?assertEqual(UploadPath, hb_maps:get(<<"path">>, Rewritten)),
    ?assertEqual(hb_singleton:from(Rewritten, #{}), hb_maps:get(<<"body">>, RewriteRes)),
    PassthroughReq =
        #{
            <<"request">> =>
                #{
                    <<"method">> => <<"POST">>,
                    <<"path">> => <<"/~bundler@1.0/item">>
                },
            <<"body">> => []
        },
    {ok, PassthroughRes} = request(Base, PassthroughReq, #{}),
    Passthrough = hb_maps:get(<<"request">>, PassthroughRes),
    ?assertEqual(<<"/~bundler@1.0/item">>, hb_maps:get(<<"path">>, Passthrough)).

no_matching_route_test() ->
    Base = #{ <<"routes">> => [#{ <<"template">> => <<"^/upload">> }] },
    HookReq =
        #{
            <<"request">> =>
                #{
                    <<"method">> => <<"GET">>,
                    <<"path">> => <<"/other">>
                },
            <<"body">> => []
        },
    {ok, HookReq} = request(Base, HookReq, #{}).

http_rewrite_test() ->
    Opts =
        #{
            <<"port">> => 0,
            <<"on">> =>
                #{
                    <<"request">> =>
                        #{
                            <<"device">> => <<"gateway-shim@1.0">>,
                            <<"routes">> =>
                                [
                                    #{
                                        <<"template">> => <<"^/_hb/">>,
                                        <<"match">> => <<"^/_hb">>,
                                        <<"with">> => <<"">>
                                    }
                                ]
                        }
                }
        },
    Node = hb_http_server:start_node(Opts),
    ?assertMatch(
        {ok, #{ <<"initialized">> := true }},
        hb_http:get(Node, <<"/_hb/~meta@1.0/info">>, Opts)
    ).
