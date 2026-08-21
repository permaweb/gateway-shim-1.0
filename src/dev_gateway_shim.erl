%%% @doc A request hook for gateway-style location path rewrites.
%%%
%%% `gateway-shim@1.0' redirects bare Arweave transaction ID paths to their
%%% isolated Base32 origins by default. It also applies the first matching
%%% route from an ordered list, allowing node operators to express simple
%%% gateway rewrites in HyperBEAM options instead of in a reverse proxy.
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

%% @doc Apply the TXID subdomain redirect or configured path rewrite routes.
request(Base, HookReq, Opts) ->
    ?event(gateway_shim, {request, {base, Base}, {hook_req, HookReq}}),
    case hb_maps:find(<<"request">>, HookReq, Opts) of
        {ok, Req} ->
            case txid_subdomain_redirect(Base, Req, Opts) of
                {redirect, URL} -> redirect_response(URL);
                {bad_request, Reason} -> bad_request_response(Reason);
                no_redirect ->
                    NewReq = rewrite_request(Base, Req, Opts),
                    {ok, update_hook_req(HookReq, Req, NewReq, Opts)}
            end;
        error ->
            {ok, HookReq}
    end.

%% @doc Redirect a bare TXID path unless the feature is disabled or canonical.
txid_subdomain_redirect(Base, Req, Opts) ->
    Enabled = hb_util:bool(
        option(
            Base,
            <<"txid-subdomain-redirect">>,
            <<"gateway-shim-txid-subdomain-redirect">>,
            true,
            Opts
        )
    ),
    ?event(error, {subdomain_redirect, {req, Req}}),
    Path = hb_maps:get(<<"path">>, Req, <<>>, Opts),
    Host = hb_maps:get(<<"host">>, Req, <<>>, Opts),
    case {Enabled, txid(Path)} of
        {true, {ok, NativeID}} ->
            B32 = b32_encode(NativeID),
            case validated_host(Host, B32, Opts) of
                {ok, canonical} -> no_redirect;
                {ok, NodeHost, Port} ->
                    {redirect, b32_url(B32, NodeHost, Port, Path)};
                {error, Reason} -> {bad_request, Reason}
            end;
        _ ->
            no_redirect
    end.

%% @doc Validate the request host against the configured public node host.
validated_host(Host, B32, Opts) ->
    case {normalize_request_host(Host), configured_node_host(Opts)} of
        {{ok, RequestHost, Port}, {ok, NodeHost}} ->
            CanonicalHost = <<B32/binary, ".", NodeHost/binary>>,
            case RequestHost of
                NodeHost -> {ok, NodeHost, Port};
                CanonicalHost -> {ok, canonical};
                _ -> {error, host_mismatch}
            end;
        {_, {error, _}} ->
            {error, node_host_not_configured};
        _ ->
            {error, invalid_host}
    end.

configured_node_host(Opts) ->
    normalize_node_host(hb_opts:get(node_host, undefined, Opts)).

normalize_node_host(RawNodeHost) when is_binary(RawNodeHost) ->
    URI = case binary:match(RawNodeHost, <<"://">>) of
        nomatch -> <<"//", RawNodeHost/binary>>;
        _ -> RawNodeHost
    end,
    try uri_string:parse(URI) of
        #{host := Host} when Host =/= <<>> -> normalize_dns_host(Host);
        _ -> {error, invalid_node_host}
    catch
        _:_ -> {error, invalid_node_host}
    end;
normalize_node_host(_) ->
    {error, invalid_node_host}.

normalize_request_host(Host) when is_binary(Host), Host =/= <<>> ->
    try uri_string:parse(<<"//", Host/binary>>) of
        URI = #{host := ParsedHost, path := <<>>} when ParsedHost =/= <<>> ->
            case maps:without([host, port, path], URI) of
                Remaining when map_size(Remaining) =:= 0 ->
                    case normalize_dns_host(ParsedHost) of
                        {ok, NormalizedHost} ->
                            {ok, NormalizedHost, maps:get(port, URI, undefined)};
                        Error -> Error
                    end;
                _ ->
                    {error, invalid_host}
            end;
        _ ->
            {error, invalid_host}
    catch
        _:_ -> {error, invalid_host}
    end;
normalize_request_host(_) ->
    {error, invalid_host}.

normalize_dns_host(Host) ->
    LowerHost = string:lowercase(Host),
    case binary:last(LowerHost) of
        $. when byte_size(LowerHost) > 1 ->
            {ok, binary:part(LowerHost, 0, byte_size(LowerHost) - 1)};
        _ ->
            {ok, LowerHost}
    end.

%% @doc Return the native ID only for a canonical, bare TXID path.
txid(<<"/", ID:43/binary>>) ->
    case hb_util:safe_decode(ID) of
        {ok, NativeID} when byte_size(NativeID) =:= 32 ->
            case hb_util:encode(NativeID) of
                ID -> {ok, NativeID};
                _ -> error
            end;
        _ -> error
    end;
txid(_) -> error.

%% @doc Base32-encode a native transaction ID as a DNS-safe label.
b32_encode(NativeID) ->
    hb_util:bin(
        string:replace(
            string:to_lower(hb_util:list(base32:encode(NativeID))),
            "=", "", all
        )
    ).

%% @doc Build a protocol-relative redirect URL, retaining the request port.
b32_url(B32, Host, Port, Path) ->
    Authority = case Port of
        undefined -> Host;
        _ -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>
    end,
    <<"//", B32/binary, ".", Authority/binary, Path/binary>>.

%% @doc Return the canonical-origin redirect as an HTTP response.
redirect_response(URL) ->
    ?event(gateway_shim, {txid_subdomain_redirect, {url, URL}}),
    {error, #{
        <<"status">> => 302,
        <<"location">> => URL,
        <<"body">> =>
            <<"Redirecting to canonical transaction subdomain: ", URL/binary>>
    }}.

%% @doc Reject a bare TXID request whose host is not the configured node host.
bad_request_response(Reason) ->
    ?event(gateway_shim, {txid_subdomain_redirect_rejected, {reason, Reason}}),
    {error, #{
        <<"status">> => 400,
        <<"body">> => <<"Request host does not match the configured node-host.">>
    }}.

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
    RoutedReq = sync_path_query(Req, RoutedPath, Opts),
    maybe_redecode_body(Req, RoutedReq, Opts).

%% @doc Keep parsed query fields synchronized with a rewritten path.
sync_path_query(Req, RoutedPath, Opts) ->
    OldPath = hb_maps:get(<<"path">>, Req, <<"/">>, Opts),
    OldQuery = path_query(OldPath),
    NewQuery = path_query(RoutedPath),
    WithoutOldQuery =
        hb_maps:without(
            hb_maps:keys(OldQuery, Opts),
            Req,
            Opts
        ),
    hb_maps:merge(
        WithoutOldQuery#{ <<"path">> => RoutedPath },
        NewQuery,
        Opts
    ).

path_query(Path) ->
    {ok, _Parts, Query} = hb_singleton:from_path(Path),
    Query.

%% @doc Re-decode a preserved raw HTTP body when a route introduces a codec.
%%
%% HTTP request codecs are normally selected before request hooks execute. If
%% the shim adds `codec-device=ans104@1.0' to the path, the original body has
%% already been decoded with the default codec. Re-decode the preserved raw
%% body so downstream devices receive the same signed message they would have
%% received had the codec been present on the original URL.
maybe_redecode_body(OldReq, NewReq, Opts) ->
    case {request_codec(OldReq, Opts), request_codec(NewReq, Opts)} of
        {Codec, Codec} ->
            NewReq;
        {_, <<"ans104@1.0">>} ->
            case hb_message:signers(NewReq, Opts) of
                [] -> redecode_ans104_body(NewReq, Opts);
                _ -> NewReq
            end;
        _ ->
            NewReq
    end.

request_codec(Req, Opts) ->
    case hb_maps:find(<<"codec-device">>, Req, Opts) of
        {ok, Codec} ->
            Codec;
        error ->
            Path = hb_maps:get(<<"path">>, Req, <<"/">>, Opts),
            case hb_maps:get(
                <<"codec-device">>,
                path_query(Path),
                undefined,
                Opts
            ) of
                undefined ->
                    content_type_codec(
                        hb_maps:get(
                            <<"content-type">>,
                            Req,
                            undefined,
                            Opts
                        )
                    );
                Codec ->
                    Codec
            end
    end.

content_type_codec(<<"application/ans104", _/binary>>) ->
    <<"ans104@1.0">>;
content_type_codec(_) ->
    undefined.

redecode_ans104_body(Req, Opts) ->
    case hb_maps:find(<<"body">>, Req, Opts) of
        {ok, Body} when is_binary(Body) ->
            try
                Item = ar_bundles:deserialize(Body),
                true = ar_bundles:verify_item(Item),
                Decoded =
                    hb_message:convert(
                        Item,
                        <<"structured@1.0">>,
                        <<"ans104@1.0">>,
                        Opts
                    ),
                merge_decoded_request(Req, Decoded, Opts)
            catch
                Class:Reason ->
                    erlang:error(
                        {gateway_shim_codec_decode_failed,
                            <<"ans104@1.0">>,
                            Class,
                            Reason}
                    )
            end;
        _ ->
            Req
    end.

merge_decoded_request(Req, Decoded, Opts) ->
    RoutedPath = hb_maps:get(<<"path">>, Req, <<"/">>, Opts),
    DecodedPath = hb_maps:get(<<"path">>, Decoded, RoutedPath, Opts),
    Method = hb_maps:get(<<"method">>, Req, <<"GET">>, Opts),
    (hb_maps:merge(Req, Decoded, Opts))#{
        <<"method">> => Method,
        <<"path">> => DecodedPath
    }.

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

bare_txid_subdomain_redirect_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, <<"hb.example">>),
    ?assertMatch(
        {error, #{
            <<"status">> := 302,
            <<"location">> :=
                <<"//222pf3qefyv5ssoj3ffkqijbwrrotwlfq34ghk2wrzexmifgnmnq.hb.example/",
                    ID/binary>>
        }},
        request(#{}, HookReq, txid_opts())
    ).

txid_subdomain_redirect_preserves_request_port_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, <<"hb.example:8734">>),
    ?assertMatch(
        {error, #{
            <<"status">> := 302,
            <<"location">> :=
                <<"//222pf3qefyv5ssoj3ffkqijbwrrotwlfq34ghk2wrzexmifgnmnq.hb.example:8734/",
                    ID/binary>>
        }},
        request(#{}, HookReq, (txid_opts())#{ <<"port">> => 9999 })
    ).

txid_subdomain_redirect_toggle_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, <<"hb.example">>),
    ?assertEqual(
        {ok, HookReq},
        request(#{ <<"txid-subdomain-redirect">> => false }, HookReq, #{})
    ),
    ?assertEqual(
        {ok, HookReq},
        request(
            #{},
            HookReq,
            #{ <<"gateway-shim-txid-subdomain-redirect">> => false }
        )
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 302 }},
        request(
            #{ <<"txid-subdomain-redirect">> => true },
            HookReq,
            (txid_opts())#{
                <<"gateway-shim-txid-subdomain-redirect">> => false
            }
        )
    ).

txid_subdomain_redirect_host_mismatch_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, <<"attacker.example">>),
    ?assertEqual(
        {error, #{
            <<"status">> => 400,
            <<"body">> =>
                <<"Request host does not match the configured node-host.">>
        }},
        request(#{}, HookReq, txid_opts())
    ).

txid_subdomain_redirect_requires_node_host_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, <<"hb.example">>),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        request(#{}, HookReq, #{ <<"only">> => local })
    ).

txid_subdomain_redirect_normalizes_node_host_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, <<"HB.EXAMPLE.">>),
    ?assertMatch(
        {error, #{
            <<"status">> := 302,
            <<"location">> :=
                <<"//222pf3qefyv5ssoj3ffkqijbwrrotwlfq34ghk2wrzexmifgnmnq.hb.example/",
                    _/binary>>
        }},
        request(
            #{},
            HookReq,
            #{ <<"only">> => local, <<"node-host">> => <<"https://hb.example">> }
        )
    ).

non_bare_txid_paths_are_unchanged_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    lists:foreach(
        fun(Path) ->
            HookReq = txid_hook_request(Path, <<"hb.example">>),
            ?assertEqual({ok, HookReq}, request(#{}, HookReq, #{}))
        end,
        [
            <<"/raw/", ID/binary>>,
            <<"/", ID/binary, "/asset.png">>,
            <<"/~arweave@2.9/raw=", ID/binary>>
        ]
    ).

canonical_txid_subdomain_is_unchanged_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    Host =
        <<"222pf3qefyv5ssoj3ffkqijbwrrotwlfq34ghk2wrzexmifgnmnq.hb.example">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, Host),
    ?assertEqual({ok, HookReq}, request(#{}, HookReq, txid_opts())).

canonical_txid_subdomain_with_port_is_unchanged_test() ->
    ID = <<"1rTy7gQuK9lJydlKqCEhtGLp2WWG-GOrVo5JdiCmaxs">>,
    Host =
        <<"222pf3qefyv5ssoj3ffkqijbwrrotwlfq34ghk2wrzexmifgnmnq.hb.example:8734">>,
    HookReq = txid_hook_request(<<"/", ID/binary>>, Host),
    ?assertEqual({ok, HookReq}, request(#{}, HookReq, txid_opts())).

txid_opts() ->
    #{ <<"only">> => local, <<"node-host">> => <<"hb.example">> }.

txid_hook_request(Path, Host) ->
    #{
        <<"request">> => #{ <<"path">> => Path, <<"host">> => Host },
        <<"body">> => []
    }.

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

ans104_query_rewrite_redecodes_body_test() ->
    Opts =
        #{
            <<"priv-wallet">> => ar_wallet:new(),
            <<"store">> => [hb_test_utils:test_store()]
        },
    Signed =
        hb_message:commit(
            #{ <<"body">> => <<"blocks.csv">> },
            Opts,
            #{ <<"device">> => <<"ans104@1.0">>, <<"bundle">> => true }
        ),
    Encoded =
        hb_message:convert(
            Signed,
            #{ <<"device">> => <<"ans104@1.0">>, <<"bundle">> => true },
            <<"structured@1.0">>,
            Opts
        ),
    RawBody = ar_bundles:serialize(Encoded),
    Base =
        #{
            <<"routes">> =>
                [
                    #{
                        <<"template">> => <<"^/~bundler@1\\.0/tx">>,
                        <<"path">> =>
                            <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>
                    }
                ]
        },
    RawReq =
        #{
            <<"method">> => <<"POST">>,
            <<"path">> => <<"/~bundler@1.0/tx">>,
            <<"body">> => RawBody
        },
    HookReq =
        #{
            <<"request">> => RawReq,
            <<"body">> => hb_singleton:from(RawReq, Opts)
        },
    {ok, Res} = request(Base, HookReq, Opts),
    Rewritten = hb_maps:get(<<"request">>, Res),
    ?assertEqual(
        <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>,
        hb_maps:get(<<"path">>, Rewritten)
    ),
    ?assertEqual(
        <<"ans104@1.0">>,
        hb_maps:get(<<"codec-device">>, Rewritten)
    ),
    ?assertNotEqual([], hb_message:signers(Rewritten, Opts)),
    ?assert(hb_message:verify(Rewritten, all, Opts)),
    RewrittenBody = hb_maps:get(<<"body">>, Res),
    BundlerReq = lists:last(RewrittenBody),
    ?assertNotEqual([], hb_message:signers(BundlerReq, Opts)),
    ?assert(hb_message:verify(BundlerReq, all, Opts)),
    ?assertEqual(
        hb_singleton:from(Rewritten, Opts),
        RewrittenBody
    ).

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
