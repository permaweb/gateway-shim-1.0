%%% @doc Test vectors for the `gateway-shim@1.0' preloaded package.
-module(hb_gateway_shim_test_vectors).
-include_lib("eunit/include/eunit.hrl").

opts() ->
    hb:init(),
    #{
        <<"load-remote-devices">> => false,
        <<"priv-wallet">> => ar_wallet:new(),
        <<"store">> => [hb_test_utils:test_store()]
    }.

base(Routes) ->
    #{
        <<"device">> => <<"gateway-shim@1.0">>,
        <<"routes">> => Routes
    }.

request(Path) ->
    #{
        <<"path">> => <<"request">>,
        <<"request">> =>
            #{
                <<"method">> => <<"GET">>,
                <<"path">> => Path
            },
        <<"body">> => []
    }.

packaged_path_rewrite_vector_test() ->
    Opts = opts(),
    Base =
        base(
            [
                #{
                    <<"template">> => <<"^/_hb/">>,
                    <<"match">> => <<"^/_hb">>,
                    <<"with">> => <<"">>
                }
            ]
        ),
    {ok, Res} =
        hb_ao:resolve(
            Base,
            request(<<"/_hb/~meta@1.0/info">>),
            Opts
        ),
    Rewritten = hb_maps:get(<<"request">>, Res),
    ?assertEqual(<<"/~meta@1.0/info">>, hb_maps:get(<<"path">>, Rewritten)).

first_matching_route_wins_vector_test() ->
    Opts = opts(),
    UploadPath = <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>,
    Base =
        base(
            [
                #{ <<"template">> => <<"^/~bundler@1\\.0/tx">> },
                #{ <<"template">> => <<"^/">>, <<"path">> => UploadPath }
            ]
        ),
    {ok, Passthrough} =
        hb_ao:resolve(
            Base,
            request(<<"/~bundler@1.0/tx">>),
            Opts
        ),
    PassthroughReq = hb_maps:get(<<"request">>, Passthrough),
    ?assertEqual(
        <<"/~bundler@1.0/tx">>,
        hb_maps:get(<<"path">>, PassthroughReq)
    ),
    {ok, Rewritten} =
        hb_ao:resolve(
            Base,
            request(<<"/upload">>),
            Opts
        ),
    RewrittenReq = hb_maps:get(<<"request">>, Rewritten),
    ?assertEqual(UploadPath, hb_maps:get(<<"path">>, RewrittenReq)).
