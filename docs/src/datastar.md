# Datastar

HyperSignal targets the [Datastar](https://data-star.dev) protocol
pinned by [`DATASTAR_SUPPORTED_VERSION`](@ref) (`v"1.0.1"`). A Datastar
app has two halves: attributes and actions you put *into* the page to
wire up reactivity, and the response shapes a handler sends *back*. This
page covers both — actions/signals first, then the HTML / JSON / JS /
SSE responses.

The client reads one of four response `Content-Type`s coming back from a
handler:

| Content-Type | HyperSignal helper | Purpose |
| --- | --- | --- |
| `text/html; charset=utf-8` | [`html_response`](@ref) / [`fragment_response`](@ref) | Full page or morph-target HTML |
| `application/json; charset=utf-8` | [`signals_response`](@ref) | Patch JSON signals |
| `text/javascript; charset=utf-8` | [`script_response`](@ref) | Append a `<script>` tag and run it |
| `text/event-stream` | [`sse_response`](@ref) / [`sse_stream`](@ref) | Buffered or streaming SSE |

The response section documents all four shapes: the non-streaming HTML /
JSON / JS responses first, then the buffered and streaming SSE forms.

Every response helper on this page sets its `Content-Type` (and
`sse_response`/`sse_stream` also set `Cache-Control: no-cache` and
`Connection: keep-alive`) as a *default*. If you pass a header in
`headers=…` whose name matches one of these (case-insensitively), your
value wins and the library default is dropped — you always get exactly
one `Content-Type` / `Cache-Control` / `Connection` line on the wire,
never a duplicate.

## Actions and events

A `@verb('url', {…})` Datastar action is built with [`ds_get`](@ref) /
[`ds_post`](@ref) / [`ds_put`](@ref) / [`ds_delete`](@ref) and bound to a
DOM event with [`on`](@ref) (or an `on_*` shorthand). The library formats
the JS expression at the attribute boundary, so the verb, URL, and
options live in one place and a typo is a Julia method error rather than
silent client behavior. Pass `form=true` for a form post; it adds
`contentType: 'form'` so Datastar URL-encodes the fields.

```julia
julia> render(form(on_submit(ds_post("/save"; form=true)),
                   input(type="text", ds_bind("query")),
                   button("Save", type="submit")))
"<form data-on:submit__prevent=\"@post(&#39;/save&#39;, {contentType: &#39;form&#39;})\"><input type=\"text\" data-bind=\"query\"><button type=\"submit\">Save</button></form>"
```

[`on(event, action)`](@ref on) returns an [`Attribute`](@ref) you drop
into a tag. `action` is a [`DSAction`](@ref) or a raw JS string (e.g.
`"\$open = !\$open"` for a client-side toggle). The single-event
shorthands read better when a tag binds exactly one event:

- [`on_click(action)`](@ref on_click) → `on(:click, action)`
- [`on_submit(action)`](@ref on_submit) → `on(:submit, action)`
- [`on_change_debounced(action; ms=300)`](@ref on_change_debounced) → `on(:change, action; debounce=ms)`
- [`on_interval(action; ms=5000)`](@ref on_interval) → `data-on-interval` polling (no event name)

`on()` modifiers (rendered in a fixed order regardless of kwarg order):

| Modifier | Renders | Effect |
| --- | --- | --- |
| `window=true` | `__window` | Listen on `window` (global hotkeys without focus) |
| `outside=true` | `__outside` | Listen on `document`; fire only when the target is outside the element (click-outside-to-close) |
| `prevent=true` | `__prevent` | `event.preventDefault()`. Defaults to `true` for `:submit`; pass `prevent=false` to opt out |
| `stop=true` | `__stop` | `event.stopPropagation()` |
| `debounce=N` | `__debounce.Nms` | Debounce by N ms (e.g. change events that should ignore mid-word typing) |

```julia
on(:change, ds_get("/c"); debounce=300).key   # Symbol("data-on:change__debounce.300ms")
on(:keydown, "\$open = true"; window=true).key # Symbol("data-on:keydown__window")
```

## Signals and reactive attributes

Signals are Datastar's reactive state. Seed one signal with
[`ds_signal(name, value)`](@ref ds_signal) (rendered as the keyed
`data-signals:<name>` form), or seed several at once with
[`ds_signals(state)`](@ref ds_signals) from a `NamedTuple`/`Dict` — the
JSON encoding catches the typos a hand-written `{"x":false}` string drops
into client-side silence. Datastar camel-cases hyphenated names, so
`ds_signal("my-signal", …)` is read as `\$mySignal`.

```julia
julia> render(div(ds_signal("count", 0), ds_text("count")))
"<div data-signals:count=\"0\" data-text=\"count\"></div>"

julia> render(div(ds_signals((showDetails=false, count=0))))
"<div data-signals=\"{&quot;showDetails&quot;:false,&quot;count&quot;:0}\"></div>"
```

The reactive attribute helpers (all return an [`Attribute`](@ref)):

| Helper | Renders | Use |
| --- | --- | --- |
| [`ds_bind(signal)`](@ref ds_bind) | `data-bind` | Two-way bind an input to a signal |
| [`ds_show(expr)`](@ref ds_show) | `data-show` | Show element when `expr` is truthy |
| [`ds_text(expr)`](@ref ds_text) | `data-text` | Set text content from `expr` |
| [`ds_attr(name, expr)`](@ref ds_attr) | `data-attr:NAME` | Bind any DOM attribute reactively |
| [`ds_class(name, expr)`](@ref ds_class) | `data-class:NAME` | Toggle a CSS class reactively |
| [`ds_style(name, expr)`](@ref ds_style) | `data-style:NAME` | Set an inline style property reactively |
| [`ds_computed(name, expr)`](@ref ds_computed) | `data-computed:NAME` | Read-only derived signal |
| [`ds_effect(expr)`](@ref ds_effect) | `data-effect` | Run a side-effecting expression on signal change |
| [`ds_init(action_or_expr)`](@ref ds_init) | `data-init` | Run an action/expression on element insert |
| [`ds_ref(name)`](@ref ds_ref) | `data-ref` | Name an element so `\$name` reaches it |
| [`ds_indicator()` / `ds_indicator(signal)`](@ref ds_indicator) | `data-indicator` | Mark an in-flight request indicator |
| [`ds_ignore_morph()`](@ref ds_ignore_morph) | `data-ignore-morph` | Leave a subtree untouched across morphs |
| [`ds_json_signals()` / `ds_json_signals(filter)`](@ref ds_json_signals) | `data-json-signals` | In-page signal-store debugger |

```julia
julia> render(div(class="bar", ds_style("width", "\$pct + '%'")))
"<div class=\"bar\" data-style:width=\"\$pct + &#39;%&#39;\"></div>"

julia> render(pre(ds_json_signals()))   # drop on a page to watch the store live
"<pre data-json-signals></pre>"
```

## Reading signals back: `parse_signals`

A non-form action (`@post('/x')` without `contentType: 'form'`) sends the
active signals object as a JSON body. [`parse_signals`](@ref) decodes it
from an `HTTP.Request`, `Vector{UInt8}`, `IO`, or `String` and returns a
`Dict{String, Any}`. An empty body maps to an empty dict so a route can
guard cleanly; a non-object or malformed body throws `ArgumentError`
(malformed JSON includes a truncated snippet of the offending payload).

```julia
function handle_increment(req::HTTP.Request)
    sig = parse_signals(req)
    n = Int(get(sig, "count", 0)) + 1
    fragment_response(div(id="counter", n), "#counter")
end
```

For form-mode posts (`ds_post("/x"; form=true)`), Datastar sends
URL-encoded fields, not JSON — use your service's `parse_form_body` for
those.

## `html_response` — full page

```julia
html_response(body; status=200, headers=[])
```

Renders `body` and wraps it in an `HTTP.Response` with
`Content-Type: text/html; charset=utf-8`. Use it for full-page GETs;
reach for [`fragment_response`](@ref) when you're swapping part of an
already-rendered page.

```julia
html_response(p("ok"))                       # 200, <p>ok</p>
html_response(p("created"); status=201,      # custom status + header
              headers=["X-Tag" => "v1"])
```

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

## Redirects

Datastar can't follow an HTTP `303` from a form submit it owns — its
morph algorithm replaces the target instead of navigating. Two helpers
cover the two redirect cases.

### `redirect_via_fragment` — navigate from a Datastar form

```julia
redirect_via_fragment(selector, location; cookies=String[], wrapper_tag=:div)
```

Wraps a tiny `<script>window.location='…'</script>` in the morph target
so a Datastar `@post` form can navigate after success (e.g. login →
dashboard). The helper *renders the morph target itself* with `id` set
to the selector, so `selector` **must** be a single `"#id"` — a class,
compound, or whitespace selector throws `ArgumentError`. Single quotes,
backslashes, and `</` in `location` are escaped.

Pass `cookies` as a vector of complete `Set-Cookie` header values to set
the session cookie *and* navigate in one response (the post-login flow).
Use `wrapper_tag` when the morph target isn't a `<div>` (e.g. `:li`).

```julia
# Login handler: set the session cookie and morph #login-form into a
# client-side redirect to /dashboard.
redirect_via_fragment("#login-form", "/dashboard";
    cookies=["sid=$token; HttpOnly; Path=/; SameSite=Lax"])
# => 200 text/html, header  datastar-selector: #login-form
#    body  <div id="login-form"><script>window.location='/dashboard'</script></div>
```

### `redirect_to` — plain `303` for non-Datastar flows

```julia
redirect_to(location; cookies=String[])
```

A plain HTTP `303` with a `Location` header — for a normal (non-Datastar)
form POST, a logout link, or direct navigation. `cookies` attaches
`Set-Cookie` values the same way as `redirect_via_fragment`.

```julia
redirect_to("/dashboard"; cookies=["sid=$token; HttpOnly; Path=/"])
# => 303, header  Location: /dashboard
```

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
[Security › `script_response` — verbatim JS](security.md#script_response-—-verbatim-JS).
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
`Cache-Control: no-cache`, and `Connection: keep-alive` as defaults.
Extra headers passed via `headers=…` are appended; one whose name
matches a default (case-insensitively) overrides it rather than
duplicating it (see the note in the intro).

### Security note

The `elements` HTML is escape-walked by `render` like any other
HyperSignal body. The `selector` is written verbatim into the SSE
line — sanitize before passing if it can contain user input. See
[Security › SSE responses](security.md#SSE-responses).

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
