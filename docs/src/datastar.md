# Datastar response shapes

HyperSignal targets the
[Datastar](https://data-star.dev) protocol pinned by
[`DATASTAR_SUPPORTED_VERSION`](@ref) (`v"1.0.1"`). The client reads one
of four response `Content-Type`s coming back from a handler:

| Content-Type | HyperSignal helper | Purpose |
| --- | --- | --- |
| `text/html; charset=utf-8` | [`html_response`](@ref) / [`fragment_response`](@ref) | Full page or morph-target HTML |
| `application/json; charset=utf-8` | [`signals_response`](@ref) | Patch JSON signals |
| `text/javascript; charset=utf-8` | [`script_response`](@ref) | Append a `<script>` tag and run it |
| `text/event-stream` | _(future — see open issues)_ | Buffered or streaming SSE |

This page documents the two non-streaming JSON / JS shapes. SSE lands
in a follow-up.

## `signals_response`

```julia
signals_response((; count=3, label="hi"))
```

Encodes the argument with `JSON.json` and returns an `HTTP.Response`
with `Content-Type: application/json; charset=utf-8`. Pass anything
`JSON.jl` knows how to encode (NamedTuple, Dict, struct).

Set `only_if_missing=true` to attach the
`datastar-only-if-missing: true` header — the Datastar client will
skip the merge for any signal that already exists on the page (useful
when a handler is hydrating defaults).

```julia
# Hydrate defaults the first time the page asks; do nothing on reload.
signals_response((; filter="all", page=1); only_if_missing=true)
```

## `script_response`

```julia
script_response("alert('hi')")
```

Returns `Content-Type: text/javascript; charset=utf-8` with the
argument as the body, byte-for-byte. The Datastar client appends a
`<script>` tag containing the body and runs it.

The body is **not** escaped — the caller owns the trust boundary. See
[Security › `script_response` — verbatim JS](security.md#script_response-verbatim-js).
For values, prefer `JSON.json(x)` over hand-quoting:

```julia
using JSON
script_response("window.dispatchEvent(new CustomEvent('row-saved', {detail: $(JSON.json(row))}))")
```

The `script_attributes` keyword controls the
`datastar-script-attributes` header, which the Datastar client copies
onto the inserted `<script>` tag. A `String` passes through verbatim;
anything else is JSON-encoded.

```julia
script_response("doStuff()"; script_attributes=(; type="module", defer=true))
# datastar-script-attributes: {"type":"module","defer":true}
```
