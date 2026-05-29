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
| `text/event-stream` | [`sse_response`](@ref) / [`sse_stream`](@ref) | Buffered or streaming SSE |

This page documents all four shapes: the non-streaming HTML / JSON / JS
responses first, then the buffered and streaming SSE forms.

## `fragment_response` — HTML morph

```julia
fragment_response(body; selector=nothing, mode=nothing,
                  view_transition=false, status=200, headers=[])
```

Sends `text/html` with the Datastar fragment-control headers. Use it
for any handler that swaps a fragment of an existing page (the common
case for `@get`/`@post` actions). The positional
`fragment_response(body, "#sel")` form is preserved.

### `mode` — swap mode

`mode` maps to the `datastar-mode` response header. `nothing` (the
default) omits the header so the Datastar client falls back to its
own default, `outer`. Unknown symbols throw `ArgumentError`.

| `mode`     | Effect on the morph target |
| ---------- | -------------------------- |
| `:outer`   | Replace the target element (including itself) — Datastar default |
| `:inner`   | Replace the target's children, keep the element |
| `:replace` | Replace the target with the response, no morph diff |
| `:prepend` | Insert the response as the target's first children |
| `:append`  | Insert the response as the target's last children |
| `:before`  | Insert the response immediately before the target |
| `:after`   | Insert the response immediately after the target |
| `:remove`  | Remove the target; the response body is ignored client-side |

```julia
# Replace just the children of #count without re-rendering the wrapper.
fragment_response(span("3"); selector="#count", mode=:inner)
```

### `view_transition` — animate the swap

```julia
fragment_response(card_html; selector="#card", mode=:outer,
                  view_transition=true)
```

`view_transition=true` adds `datastar-use-view-transition: true`, so
the Datastar client wraps the DOM change in a
[View Transition](https://developer.mozilla.org/en-US/docs/Web/API/View_Transitions_API).
Default is `false` (header omitted).

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

## `sse_response` — buffered SSE (multi-event)

When one HTTP response needs to ship more than one Datastar event —
typically an HTML patch *and* a signal patch in the same round trip —
emit a `text/event-stream` body via `sse_response`. This helper is
**buffered**: it builds the whole body in memory and sends it as one
response. Long-lived streaming (progress bars, server push) is a
separate concern handled by a different helper.

```julia
sse_response([
    patch_elements(div(id="card", "Saved"); selector="#card", mode=:inner),
    patch_signals((; saved_at=time())),
])
```

### Event constructors

`patch_elements(body; selector=nothing, mode=nothing, view_transition=false)`
builds a `datastar-patch-elements` event. `body` is rendered the same
way as for [`html_response`](@ref); multi-line HTML is split into one
`data: elements …` line per source line. `mode` accepts the same
fragment-swap symbols as [`fragment_response`](@ref) — unknown
symbols throw `ArgumentError`.

`patch_signals(signals; only_if_missing=false)` builds a
`datastar-patch-signals` event. `signals` is JSON-encoded with
`JSON.json`. `only_if_missing=true` mirrors the
`datastar-only-if-missing` header of [`signals_response`](@ref) but
expressed as the SSE `onlyIfMissing` data line.

### Response headers

`sse_response` sets `Content-Type: text/event-stream; charset=utf-8`,
`Cache-Control: no-cache`, and `Connection: keep-alive`. Extra
headers passed via `headers=…` are appended.

### Security note

The `elements` HTML is escape-walked by `render` like any other
HyperSignal body. The `selector` is written verbatim into the SSE
line — sanitize before passing if it can contain user input. See
[Security › SSE responses](security.md#sse-responses).

## `sse_stream` — streaming SSE (long-running tasks)

`sse_response` buffers every event into a single `Response`, so the
client sees nothing until the handler returns. For a progress bar, a
multi-stage job, or any server-pushed UI that must trickle, use
`sse_stream` instead. It returns an HTTP.jl stream handler that
opens a chunked `text/event-stream` response and flushes each event
the moment your code emits it.

```julia
using HTTP, HyperSignal
HyperSignal.@using_tags  # for div

HTTP.serve(
    sse_stream() do writer
        for i in 1:5
            writer(patch_elements(
                div(id="progress", "step \$i of 5");
                selector="#progress", mode=:inner,
            ))
            sleep(0.5)
        end
        writer(patch_signals((; done=true)))
    end,
    "127.0.0.1", 8080; stream=true,
)
```

The handler must be registered with `HTTP.serve(...; stream=true)` —
that is the HTTP.jl mode that exposes the per-connection
`HTTP.Stream` `sse_stream` writes into. The same response headers as
`sse_response` are set automatically (`Content-Type`,
`Cache-Control`, `Connection`); `status` and `headers` kwargs work
the same way. Each `writer(event)` call encodes the event with the
shared SSE encoder and pushes one chunk; events already flushed
remain visible to the client even if your task throws partway
through.
