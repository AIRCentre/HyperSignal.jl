# Datastar action helpers. The user-visible win: instead of writing
#     data-on:submit="@post('/path', {contentType: 'form'})"
# they write
#     on(:submit, ds_post("/path"; form=true))
# and the lib emits the right attribute name + JS expression. Typos turn
# into method errors at the right call site, not silent client behavior.

"""
    DATASTAR_SUPPORTED_VERSION

The Datastar protocol/client version HyperSignal is built and tested against.
Pin your served `datastar.js` to this version; bumps land as one visible diff.
"""
const DATASTAR_SUPPORTED_VERSION = v"1.0.1"

"""
    DSAction(verb, url, form, extras)

A "Datastar request action" — verb + URL + options. Build via [`ds_get`](@ref),
[`ds_post`](@ref), [`ds_put`](@ref), or [`ds_delete`](@ref); pass to
[`on`](@ref) (or its `on_*` shorthands) to bind it to a DOM event. The
renderer formats the JS expression at the attribute boundary so the
verb/URL/options live in one place.

You rarely construct one directly — use the verb constructors.
"""
struct DSAction
    verb::Symbol
    url::String
    form::Bool
    extras::Vector{Pair{Symbol, Any}}
end

function _action(verb::Symbol, url::String; form::Bool=false, kwargs...)
    DSAction(verb, url, form, Pair{Symbol, Any}[k => v for (k, v) in pairs(kwargs)])
end

"""
    ds_get(url; form=false, kwargs...)

Build a `@get('url', {…})` Datastar action. Pass `form=true` to add
`contentType: 'form'` (Datastar will encode form fields as
`application/x-www-form-urlencoded`). Any further kwargs become
`{k: v}` entries on the JS options object.

# Examples
```jldoctest
julia> HyperSignal.action_js(ds_get("/api/refresh"))
"@get('/api/refresh')"

julia> HyperSignal.action_js(ds_get("/api/session/count"; form=true))
"@get('/api/session/count', {contentType: 'form'})"
```
"""
ds_get(url; kwargs...) = _action(:get, url; kwargs...)

"""
    ds_post(url; form=false, kwargs...)

Build a `@post('url', {…})` Datastar action. Pass `form=true` for the
common case of submitting a form; the rendered attribute is then
`@post('url', {contentType: 'form'})`. Pass to [`on`](@ref) (or
[`on_submit`](@ref) / [`on_click`](@ref)) to bind to a DOM event.

# Examples
```jldoctest
julia> HyperSignal.action_js(ds_post("/api/like"))
"@post('/api/like')"

julia> HyperSignal.action_js(ds_post("/session/new"; form=true))
"@post('/session/new', {contentType: 'form'})"
```
"""
ds_post(url; kwargs...) = _action(:post, url; kwargs...)

"""
    ds_put(url; form=false, kwargs...)

Build a `@put('url', {…})` Datastar action. See [`ds_post`](@ref).
"""
ds_put(url; kwargs...) = _action(:put, url; kwargs...)

"""
    ds_delete(url; form=false, kwargs...)

Build a `@delete('url', {…})` Datastar action. See [`ds_post`](@ref).
"""
ds_delete(url; kwargs...) = _action(:delete, url; kwargs...)

# Render a DSAction as the JS expression that goes inside data-on:* /
# data-action. Auto-escape on attribute values handles HTML-quoting; the
# JS-quoting (single-quote escape) is handled here so the JS string stays
# valid inside the attribute.
# Stream a DSAction as the JS expression that goes inside data-on:* /
# data-action. The JS-quoting (single-quote escape) is handled here so the
# JS string stays valid; the caller's `escval` handles HTML-quoting for the
# target medium. `escval(io, s)` writes `s` escaped for that medium — in the
# render hot path it is `escape_html` (each chunk streams straight into the
# response IO, with no intermediate String that escape_html would then have
# to re-walk); for the plain `action_js` String contract it is `print`.
function _action_js(io::IO, a::DSAction, escval::F) where {F}
    print(io, "@", a.verb, "(")
    escval(io, "'")
    # Escape the URL into its single-quoted JS string the same way extras
    # values are (see _js_str_escape): a raw `'` in the URL — e.g. an
    # unencoded query param like `?q=it's` — would otherwise close the JS
    # string early and break the action, and a raw `</script>` could close
    # an enclosing inline <script>. The escapes are transparent to the URL
    # the browser fetches (`\'`→`'`, `<\/`→`</` after JS parsing).
    escval(io, _js_str_escape(a.url))
    escval(io, "'")
    if a.form || !isempty(a.extras)
        print(io, ", {")
        first = true
        if a.form
            print(io, "contentType: ")
            escval(io, "'form'")
            first = false
        end
        for (k, v) in a.extras
            first || print(io, ", ")
            print(io, k, ": ")
            escval(io, _js_value(v))
            first = false
        end
        print(io, "}")
    end
    print(io, ")")
    nothing
end

_plain_chunk(io::IO, s) = print(io, s)

# Public String form (Base.show, doctests, the response/test boundary):
# byte-identical to the old buffered builder.
function action_js(a::DSAction)
    io = IOBuffer()
    _action_js(io, a, _plain_chunk)
    String(take!(io))
end

# 1-arg show on a DSAction: `string(a)` and `"$(a)"` return the JS
# expression that the renderer would emit. Symmetric with the
# Element/Frag/Raw show methods — every HyperSignal value prints as
# the thing the lib would actually put in the page, not a struct dump.
Base.show(io::IO, a::DSAction) = print(io, action_js(a))

_js_value(v::Bool)   = v ? "true" : "false"
# Non-finite floats: `string(Inf)`/`string(-Inf)` give `Inf`/`-Inf`, which are
# not JS literals (a bare `Inf` is a ReferenceError in the Datastar
# expression). Emit the JS globals instead. `NaN` already round-trips. Finite
# floats fall through to the generic `string(v)` and render identically.
_js_value(v::AbstractFloat) =
    isnan(v) ? "NaN" : isinf(v) ? (v > 0 ? "Infinity" : "-Infinity") : string(v)
_js_value(v::Number) = string(v)
# Escape a string for embedding inside a single-quoted JS string literal.
# Order matters: backslashes first (so we don't re-escape escapes we
# ourselves introduce), then single-quote (the string delimiter), then
# `</` (the HTML parser will close an enclosing <script> on `</script>`
# regardless of JS quoting — break the sequence at the HTML level by
# inserting a backslash, which the JS parser ignores). Finally the four JS
# line terminators (LF, CR, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH
# SEPARATOR): a raw one of these inside a single-quoted JS string is a
# SyntaxError, so a newline in a URL/extras value (a reflected query param,
# a multi-line search box) would silently break the whole action — escape
# them to their JS escapes, which round-trip to the same character after JS
# parsing. Shared by the URL and every extras value in action_js, and by
# response.jl's inline-<script> redirect.
_js_str_escape(s::AbstractString) =
    replace(s, "\\" => "\\\\", "'" => "\\'", "</" => "<\\/",
               "\n" => "\\n", "\r" => "\\r",
               "\u2028" => "\\u2028", "\u2029" => "\\u2029")
_js_value(v::String) = "'$(_js_str_escape(v))'"
# Structured option values (e.g. `headers=Dict(...)`,
# `filterSignals=(include=...)`) serialize as a JSON object/array literal —
# valid JS, which Julia's `repr` of a Dict/NamedTuple/Tuple/Vector is not.
# These extras land only in HTML attributes (data-on:*/data-action), where
# render's escape_html neutralizes `<`/`'`, so JSON's own quoting is enough.
_js_value(v::Union{AbstractDict, NamedTuple, AbstractVector, Tuple}) = JSON.json(v)
_js_value(v)         = string(v)  # fallback; caller's responsibility

"""
    on(event::Symbol, action; debounce=nothing, window=false) -> Attribute

Bind a value to a DOM event. `action` is either a [`DSAction`](@ref) (the
renderer formats it as `@verb('url', {…})`) or an `AbstractString` (a raw
JS expression — useful for client-side toggles like
`"\$open = !\$open"`). Returns an [`Attribute`](@ref) you drop into a tag's
positional args.

Modifiers:
- `debounce=N` (ms) — appends `__debounce.Nms`. Use for change events on
  inputs that should ignore mid-word typing.
- `window=true` — appends `__window`. Routes the listener to `window`
  instead of the element, so global hotkeys reach it without focus.
- `prevent=true` — appends `__prevent`. Calls `event.preventDefault()`
  before running `action`. Defaults to `true` for `:submit` so a form
  bound to a Datastar action doesn't also trigger the native
  navigation; pass `prevent=false` to opt out.
- `stop=true` — appends `__stop`. Calls `event.stopPropagation()`.
- `outside=true` — appends `__outside`. Routes the listener to `document`
  and only fires when the event target is NOT inside the bound element
  (the click-outside-to-close pattern).

# Examples
```jldoctest
julia> on(:click, ds_post("/api/x"; form=true)).key
Symbol("data-on:click")

julia> on(:submit, ds_post("/save")).key                    # auto __prevent on :submit
Symbol("data-on:submit__prevent")

julia> on(:submit, ds_post("/save"); prevent=false).key     # opt-out
Symbol("data-on:submit")

julia> on(:change, ds_get("/c"); debounce=300).key
Symbol("data-on:change__debounce.300ms")

julia> on(:keydown, "\$open = true"; window=true).key
Symbol("data-on:keydown__window")
```
"""
function on(event::Symbol, action::Union{DSAction, AbstractString};
            debounce::Union{Nothing, Int}=nothing, window::Bool=false,
            prevent::Union{Nothing, Bool}=nothing,
            stop::Bool=false, outside::Bool=false)
    do_prevent = isnothing(prevent) ? (event === :submit) : prevent
    parts = String["data-on:", String(event)]
    window && push!(parts, "__window")
    outside && push!(parts, "__outside")
    do_prevent && push!(parts, "__prevent")
    stop && push!(parts, "__stop")
    isnothing(debounce) || push!(parts, "__debounce.$(debounce)ms")
    Attribute(Symbol(join(parts)), action)
end

"""
    on_interval(action; ms=5000) -> Attribute

Run `action` (a [`DSAction`](@ref) or raw JS expression) on a recurring
interval. Renders as `data-on-interval__duration.Nms="…"`. The default
5-second cadence matches the dashboard-stats polling pattern in this
codebase.

`data-on-interval` is a Datastar plugin distinct from `data-on:event` —
it doesn't take an event name, only a duration modifier.

# Examples
```julia
section(id="dataset-stats",
    on_interval(ds_get("/api/dashboard/stats"); ms=5000),
    …)
```
"""
on_interval(action::Union{DSAction, AbstractString}; ms::Int=5000) =
    Attribute(Symbol("data-on-interval__duration.", ms, "ms"), action)

"""
    on_click(action; debounce=nothing)
    on_submit(action; debounce=nothing)

Single-event shorthands for [`on(:click, action)`](@ref on) /
[`on(:submit, action)`](@ref on). Read better than `on(:click, …)` in
component bodies that bind exactly one event.

# Examples
```julia
button("Dismiss", on_click(ds_post("/api/dismiss")))
form(on_submit(ds_post("/save"; form=true)), …)
```
"""
on_click(action::Union{DSAction, AbstractString}; kwargs...)  = on(:click, action; kwargs...)
@doc (@doc on_click)
on_submit(action::Union{DSAction, AbstractString}; kwargs...) = on(:submit, action; kwargs...)

"""
    on_change_debounced(action; ms=300) -> Attribute

Shorthand for `on(:change, action; debounce=ms)`. The default 300ms is
the cadence used across this codebase for form-driven live updates —
short enough to feel instant, long enough to ignore mid-word typing.

# Examples
```julia
form(on_change_debounced(ds_get("/api/preview"; form=true)),
     input(type="text", name="query"))
```
"""
on_change_debounced(action::Union{DSAction, AbstractString}; ms::Int=300) =
    on(:change, action; debounce=ms)

"""
    ds_indicator() -> Attribute

Mark an element as a Datastar request indicator. The element becomes
visible while a Datastar action initiated under it is in flight, and
hides again on completion — Datastar adds/removes the visibility via
the `data-indicator` attribute the renderer emits.

# Examples
```julia
button("Save", on_click(ds_post("/api/save")),
    span(class="spinner", ds_indicator(), "…"))
```
"""
ds_indicator() = Attribute(Symbol("data-indicator"), true)

"""
    ds_indicator(signal::AbstractString) -> Attribute

Mark an element as the indicator for a *named* in-flight signal. Datastar
sets `signal` to true while requests under this scope are in flight, so
sibling elements can `ds_show("\$signal")` a spinner or grey out a panel
without each having to track the request lifecycle themselves.
"""
ds_indicator(signal::AbstractString) =
    Attribute(Symbol("data-indicator"), String(signal))

"""
    ds_ignore_morph() -> Attribute

Tell Datastar's morph algorithm to leave this element's subtree alone
across fragment swaps. Useful for inputs the user is currently typing in
or focused elements you don't want re-rendered.

# Examples
```julia
input(type="text", name="search", ds_ignore_morph())
```
"""
ds_ignore_morph() = Attribute(Symbol("data-ignore-morph"), true)

"""
    ds_bind(signal::AbstractString) -> Attribute

Two-way bind an input to a Datastar signal: the input's value mirrors
`signal`, and edits flow back. Returns the `data-bind="signal"` attribute.

# Examples
```julia
input(type="text", ds_bind("query"))
```
"""
ds_bind(signal::AbstractString) = Attribute(Symbol("data-bind"), signal)

"""
    ds_signal(name::AbstractString, value) -> Attribute

Initialize a Datastar signal on this element. Renders as the keyed
`data-signals:<name>="value"` form. Note Datastar's kebab→camel mapping:
`ds_signal("my-signal", …)` creates the signal `\$mySignal`.

# Examples
```julia
div(ds_signal("count", 0), ds_text("count"))   # signal "count" starts at 0
```
"""
ds_signal(name::AbstractString, value) = Attribute(Symbol("data-signals:", name), value)

"""
    ds_signals(state) -> Attribute

Initialize a whole Datastar signals object on this element. `state` is
anything JSON-encodable — typically a `NamedTuple` or `Dict` of signal
name → initial value. Renders as `data-signals='{...}'` after attribute
escape (the JSON's `"` round-trip cleanly through `&quot;`).

Use this in place of [`ds_signal`](@ref) when one element seeds several
signals at once (e.g. a card with `showDetails` + `confirmDialogOpen` +
…); the JSON encoding catches the kinds of typos that hand-written
`{"x": false, "y": false}` strings drop into client-side silence.

# Examples
```jldoctest
julia> a = ds_signals((showDetails=false, count=0));

julia> a.value
"{\\"showDetails\\":false,\\"count\\":0}"

julia> a.key
Symbol("data-signals")
```
"""
ds_signals(state) = Attribute(Symbol("data-signals"), JSON.json(state))

"""
    parse_signals(req_or_body) -> Dict{String, Any}

Decode the Datastar signals payload from a request body. Datastar's
default action mode (`@post('/x')` without `contentType: 'form'`) sends
the active signals object as a JSON body. Pass either an
`HTTP.Request`, a `Vector{UInt8}`, or an `AbstractString` — the helper
normalizes the input and returns the parsed object as a
`Dict{String, Any}`. Empty bodies map to an empty dict so a route can
guard cleanly.

For form-encoded posts (`@post('/x', {contentType: 'form'})`), use the
service's `parse_form_body` instead — Datastar treats form-mode and
JSON-mode as distinct wire formats, and so does this lib.

# Examples
```julia
function handle_increment(req::HTTP.Request)
    sig = parse_signals(req)
    n = Int(get(sig, "count", 0)) + 1
    fragment_response(div(id="counter", n), "#counter")
end
```
"""
parse_signals(req::HTTP.Request) = parse_signals(req.body)
parse_signals(body::AbstractVector{UInt8}) =
    isempty(body) ? Dict{String, Any}() : parse_signals(String(body))
parse_signals(io::IO) = parse_signals(read(io))
function parse_signals(body::AbstractString)
    isempty(body) && return Dict{String, Any}()
    parsed = try
        JSON.parse(String(body))
    catch err
        # JSON.jl raises ArgumentError with a position-tagged message;
        # re-throw with the call site's name so a panicked handler log
        # makes the source of the failure obvious. Truncate the body
        # snippet so a giant malformed payload doesn't flood logs.
        snippet = SubString(body, 1, min(lastindex(body), 80))
        throw(ArgumentError("parse_signals: invalid JSON body (first 80 chars: $(repr(snippet))) — $(err)"))
    end
    parsed isa AbstractDict ? Dict{String, Any}(parsed) :
        throw(ArgumentError("parse_signals: expected a JSON object at the top level, got $(typeof(parsed))"))
end

"""
    ds_show(expr::AbstractString) -> Attribute

Show this element only when the JS expression `expr` is truthy. Renders
as `data-show="expr"`.

# Examples
```julia
p(ds_show("count > 0"), "You have items.")
```
"""
ds_show(expr::AbstractString) = Attribute(Symbol("data-show"), expr)

"""
    ds_text(expr::AbstractString) -> Attribute

Set this element's text content from the JS expression `expr`. Renders
as `data-text="expr"`. Use this instead of templating a value into a
string when the value is a Datastar signal that may change client-side.

# Examples
```julia
span(ds_text("count"))    # text content tracks the signal "count"
```
"""
ds_text(expr::AbstractString) = Attribute(Symbol("data-text"), expr)

"""
    ds_json_signals() -> Attribute
    ds_json_signals(filter::AbstractString) -> Attribute

Set this element's text content to a live, JSON-stringified view of the
Datastar signal store — the standard in-page signal debugger. Drop a
`pre(ds_json_signals())` onto a page during development and it tracks the
store reactively as signals change. Renders as the bare `data-json-signals`
attribute (no value).

Pass `filter` — a Datastar filter-object JS expression such as
`"{include: /user/}"` or `"{exclude: /temp\$/}"` — to scope the output to
matching signal names. Renders as `data-json-signals="<filter>"`.

# Examples
```jldoctest
julia> a = ds_json_signals();

julia> (a.key, a.value)
(Symbol("data-json-signals"), true)

julia> b = ds_json_signals("{include: /user/}");

julia> b.value
"{include: /user/}"
```
"""
ds_json_signals() = Attribute(Symbol("data-json-signals"), true)
ds_json_signals(filter::AbstractString) =
    Attribute(Symbol("data-json-signals"), String(filter))

"""
    ds_ref(name::AbstractString) -> Attribute

Mark this element with a Datastar ref so other Datastar expressions can
reach it as `\$<name>` (e.g. `\$btnNext.click()`). Renders as
`data-ref="name"`.

# Examples
```julia
button(ds_ref("btnNext"), "Next")
# Elsewhere: data-on:keydown__window="if(event.key==='ArrowRight') \$btnNext.click()"
```
"""
ds_ref(name::AbstractString) = Attribute(Symbol("data-ref"), String(name))

"""
    ds_attr(name::AbstractString, expr::AbstractString) -> Attribute

Reactively bind a DOM attribute to a Datastar expression: as `expr`
changes (because a signal it reads changes), the attribute updates.
Renders as `data-attr:NAME="expr"`. Truthy → attribute set; falsy →
attribute removed.

# Examples
```julia
# Open/close a <dialog> from a signal
dialog(ds_attr("open", "\$dialogOpen"), …)

# Disable a button while a request is in flight
button(ds_attr("disabled", "\$saving"), "Save")
```
"""
ds_attr(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-attr:", name), String(expr))

"""
    ds_class(name::AbstractString, expr::AbstractString) -> Attribute

Toggle a CSS class reactively. Renders as `data-class:NAME="expr"` — when
`expr` evaluates truthy Datastar adds the class, when falsy it removes
it. Pair-style sibling of [`ds_attr`](@ref); use `ds_class` when the
target is a class on `class=`, `ds_attr` when the target is any other
attribute.

# Examples
```julia
# Drop the `.outline` class from the active view-toggle button
button(class="grid-toggle", ds_class("outline", "\$view !== 'grid'"), "Grid")
```
"""
ds_class(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-class:", name), String(expr))

"""
    ds_computed(name::AbstractString, expr::AbstractString) -> Attribute

Declare a read-only derived signal computed from a Datastar expression.
The computed signal `name` re-evaluates whenever any signal `expr` reads
changes. Renders as `data-computed:NAME="expr"`. Reach it elsewhere as
`\$NAME` (totals, validation flags, formatted strings). Use this instead
of recomputing the same expression at every read site.

Datastar camel-cases hyphenated signal names, so `ds_computed("full-name", …)`
is read as `\$fullName`; prefer camelCase names to avoid surprise.

# Examples
```julia
# A line-item total that tracks its inputs; read elsewhere as \$total
div(ds_computed("total", "\$price * \$qty"),
    span(ds_text("\$total")))
```
"""
ds_computed(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-computed:", name), String(expr))

"""
    ds_style(name::AbstractString, expr::AbstractString) -> Attribute

Set an inline CSS style property reactively. Renders as
`data-style:NAME="expr"` — Datastar evaluates `expr` and writes the result
to `element.style.NAME`, keeping it in sync as the signals it reads change.
The reactive-binding sibling of [`ds_class`](@ref) (toggle a class) and
[`ds_attr`](@ref) (bind any attribute); reach for `ds_style` when the value
is a dynamic dimension/color/transform that isn't expressible as a static
class.

# Examples
```julia
# Drive a progress bar's width from a signal (0–100)
div(class="bar", ds_style("width", "\$pct + '%'"))

# Hide via inline display rather than a class
div(ds_style("display", "\$hiding && 'none'"))
```
"""
ds_style(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-style:", name), String(expr))

"""
    ds_effect(expr::AbstractString) -> Attribute

Run a Datastar JS effect: a side-effecting expression that re-evaluates
whenever the signals it reads change. Useful for "imperative bridge"
moments where you have to call a DOM method from signal state (e.g.
`\$dialog.showModal()`). Renders as `data-effect="expr"`.

# Examples
```julia
# Open or close a dialog as `\$dialogOpen` changes
div(ds_effect("\$dialogOpen ? \$dlg.showModal() : \$dlg.close()"))
```
"""
ds_effect(expr::AbstractString) = Attribute(Symbol("data-effect"), String(expr))

"""
    ds_init(action_or_expr) -> Attribute

Run an action or JS expression once when this element is inserted into
the DOM. Pass a [`DSAction`](@ref) for an HTTP fetch, or an
`AbstractString` for a raw JS expression. Renders as `data-init="…"`.

# Examples
```julia
# Fetch the first card on element insert
div(id="card-container",
    ds_init(ds_get("/api/review/card?session_id=\$(id)")),
    …)

# Or initialise a signal from a JS computation
div(ds_signals((width=0,)), ds_init("\$width = window.innerWidth"))
```
"""
ds_init(action::Union{DSAction, AbstractString}) =
    Attribute(Symbol("data-init"), action)
