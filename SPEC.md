# `gateway-shim@1.0`

`gateway-shim@1.0` is a HyperBEAM inbound request hook that performs
gateway-style path rewrites before a request is resolved.

## Request

The device exposes `request/3` for use in a node's inbound request hook chain.
The hook request is expected to contain:

```erlang
#{
    <<"request">> => Request,
    <<"body">> => SingletonBody
}
```

If `request` is absent or no route matches, the hook returns the hook request
without modification.

## Configuration

Routes can be configured in either of the following ways:

- Locally, through `routes` on the hook device.
- Globally, through the `gateway-shim-routes` node option.

Local configuration takes precedence. Routes are evaluated in order, and only
the first matching route is applied.

```erlang
#{
    <<"on">> =>
        #{
            <<"request">> =>
                #{
                    <<"device">> => <<"gateway-shim@1.0">>,
                    <<"routes">> => Routes
                }
        }
}
```

The route configuration may be a list, an AO-Core ordered list message, or a
single route. The values `false` and `undefined` disable rewriting.

## Route fields

Each route supports:

- `template`: The request template used to select the route through HyperBEAM
  template matching.
- `path`: The replacement path. If omitted, the request's current path is used.
- `strip-prefix`: The prefix removed from the selected path.
- `prefix`: The value prepended to the path.
- `match` and `with`: The regular expression and replacement applied
  globally.
- `suffix`: The value appended to the path.

Path transforms run in this order:

1. Select `path`.
2. Apply `strip-prefix`.
3. Apply `prefix`.
4. Apply `match` and `with`.
5. Apply `suffix`.

Route values are loaded through the HyperBEAM cache before use.

## Result

The device returns `{ok, HookRequest}`.

When a route changes the request path, the result contains the rewritten
request and a singleton body rebuilt with `hb_singleton:from/2`:

```erlang
#{
    <<"request">> => RewrittenRequest,
    <<"body">> => RebuiltSingletonBody
}
```

All request fields other than `path` are preserved.

## Example: Remove a Gateway Prefix

```erlang
#{
    <<"routes">> =>
        [
            #{
                <<"template">> => <<"^/_hb/">>,
                <<"match">> => <<"^/_hb">>,
                <<"with">> => <<"">>
            }
        ]
}
```

This rewrites `/_hb/~meta@1.0/info` to `/~meta@1.0/info`.

## Example: Gateway Upload Endpoint

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

Existing bundler transaction and item routes pass through unchanged. Every
other path is rewritten to the ANS-104 upload endpoint.
