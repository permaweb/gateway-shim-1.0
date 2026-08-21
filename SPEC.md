# `gateway-shim@1.0`

`gateway-shim@1.0` is a HyperBEAM inbound request hook that redirects bare
Arweave transaction IDs to isolated origins and performs gateway-style path
rewrites before a request is resolved.

## Request

The device exposes `request/3` for use in a node's inbound request hook chain.
The hook request is expected to contain:

```erlang
#{
    <<"request">> => Request,
    <<"body">> => SingletonBody
}
```

If `request` is absent, the hook returns the hook request without modification.

When the request path contains only a canonical 43-character Arweave
transaction ID and a host is present, the hook returns an HTTP 302 response to
`<base32-txid>.<node-host>`. The path is retained. Requests already using that
52-character Base32 subdomain are not redirected.

Before redirecting, the request host is compared case-insensitively with the
hostname in the `node-host` option. The exact TXID-specific Base32 subdomain is
also accepted as canonical. A missing, malformed, or mismatched `node-host`
returns HTTP 400. Redirect locations are built from this trusted hostname
rather than directly from the request host. If the request host contains a
port, it is validated separately from the hostname and retained in the
redirect location.

The redirect is enabled by default. It can be configured locally through
`txid-subdomain-redirect` or globally through
`gateway-shim-txid-subdomain-redirect`; local configuration takes precedence.
Setting the applicable value to `false` disables it. Paths such as
`/raw/TXID`, `/TXID/asset`, and device invocations are not redirected and
continue through the existing route logic.

## Configuration

Routes can be configured in either of the following ways:

- Locally, through `routes` on the hook device.
- Globally, through the `gateway-shim-routes` node option.

Local configuration takes precedence. Routes are evaluated in order, and only
the first matching route is applied.

```erlang
#{
    <<"node-host">> => <<"hb.example">>,
    <<"on">> =>
        #{
            <<"request">> =>
                #{
                    <<"device">> => <<"gateway-shim@1.0">>,
                    <<"txid-subdomain-redirect">> => true,
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

Query parameters in a rewritten path are synchronized with the parsed request
fields. When a route introduces `codec-device=ans104@1.0`, the shim also
re-decodes a preserved raw HTTP body as a verified ANS-104 item. This is
necessary because HyperBEAM normally selects the inbound body codec before
executing request hooks.

## Result

The device normally returns `{ok, HookRequest}`. A qualifying bare TXID path
returns `{error, Response}`, where `Response` has status 302 and a `location`
pointing to the canonical Base32 subdomain.

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
