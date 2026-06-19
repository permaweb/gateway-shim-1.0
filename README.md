# Gateway Shim

This repository contains the HyperBEAM package for `gateway-shim@1.0`.

## Behavior

`gateway-shim@1.0` is an inbound request hook for gateway-style path rewrites.
It does nothing unless routes are configured. When multiple routes are
configured, it applies only the first matching route.

Routes can be configured locally on the hook device through `routes` or
globally through the `gateway-shim-routes` node option. Local configuration
takes precedence.

Each route supports:

- `template`: The request template used to select the route.
- `path`: The replacement path. It defaults to the request's current path.
- `strip-prefix`: The prefix removed from the selected path.
- `prefix`: The value prepended to the path.
- `match` and `with`: The regular expression and replacement applied globally.
- `suffix`: The value appended to the path.

Path transforms run in this order:

1. `path`
2. `strip-prefix`
3. `prefix`
4. `match` / `with`
5. `suffix`

When a route changes the request, the hook also rebuilds the singleton `body`
from the rewritten request.

Rewritten query parameters are synchronized with the parsed request. If a
route introduces `codec-device=ans104@1.0`, the shim re-decodes the preserved
raw body as a verified ANS-104 item before forwarding it downstream.

## Configuration

Configure the hook on inbound requests:

```erlang
#{
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
}
```

This rewrites `/_hb/~meta@1.0/info` to `/~meta@1.0/info`.

The following gateway configuration preserves existing bundler routes and
rewrites every other path to the ANS-104 upload endpoint:

```erlang
#{
    <<"gateway-shim-routes">> =>
        [
            #{ <<"template">> => <<"^/~bundler@1\\.0/tx">> },
            #{ <<"template">> => <<"^/~bundler@1\\.0/item">> },
            #{
                <<"template">> => <<"^/">>,
                <<"path">> =>
                    <<"/~bundler@1.0/tx?codec-device=ans104@1.0">>
            }
        ]
}
```

## Build

```sh
rebar3 compile
```

## Package

```sh
rebar3 device package
rebar3 device verify
```

The device specification is [SPEC.md](./SPEC.md). The implementation is the
packaged BEAM archive produced by Forge.

## Published Package

The current specification and implementation were published with the
repository-local HyperBEAM key.

```text
device publish: gateway-shim@1.0

spec=4yczHYcefJIc5l_e9hj3wiv41Zbey_oEMWQpqCIas2E

impl=9KJV5upD_GA0DzBYwVc0YZCJmzq7r6kiGf3ypsc_iM0

signer=EvuAtMHsi4bPMlacqZMUtXJPy46sGB--zaYDzgYjDUQ
```

- [Device specification](https://arweave.net/4yczHYcefJIc5l_e9hj3wiv41Zbey_oEMWQpqCIas2E)
- [Device implementation](https://arweave.net/9KJV5upD_GA0DzBYwVc0YZCJmzq7r6kiGf3ypsc_iM0)
- [Standalone `SPEC.md`](https://arweave.net/LWxVM1NkGpLgAS0x81IngYW2rpIJlUCx6q_zX-s-w9Y)

## Test

```sh
rebar3 device test
rebar3 eunit-all
```

## Local Node

```sh
rebar3 device local
```

## Publish

```sh
rebar3 device publish --key wallet.json
```

## License

This package is licensed under the [MIT License](./LICENSE).
