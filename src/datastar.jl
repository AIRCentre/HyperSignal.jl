"""
    DATASTAR_SUPPORTED_VERSION

The Datastar protocol/client version HyperSignal is built and tested against.
Pin your served `datastar.js` to this version; bumps land as one visible diff.
"""
const DATASTAR_SUPPORTED_VERSION = v"1.0.4"

"""
    DSAction(verb, url, form, extras)

A Datastar request action: verb + URL + options. Build via [`ds_get`](@ref),
[`ds_post`](@ref), [`ds_put`](@ref) or [`ds_delete`](@ref); bind with
[`on`](@ref) or its `on_*` shorthands. The renderer writes the JS
expression at the attribute boundary.
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

# JS-quoting here; `escval` adds the medium's quoting: `escape_html` streams
# each chunk into the response IO on the render path (no intermediate String
# to re-walk), `print` for `action_js`.
function _action_js(io::IO, a::DSAction, escval::F) where {F}
    print(io, "@", a.verb, "(")
    escval(io, "'")
    # A raw `'` in the URL (`?q=it's`) would end the JS string early.
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

function action_js(a::DSAction)
    io = IOBuffer()
    _action_js(io, a, _plain_chunk)
    String(take!(io))
end

Base.show(io::IO, a::DSAction) = print(io, action_js(a))

_js_value(v::Bool)   = v ? "true" : "false"
# Bare `Inf` is a ReferenceError in JS; `NaN` already matches.
_js_value(v::AbstractFloat) =
    isnan(v) ? "NaN" : isinf(v) ? (v > 0 ? "Infinity" : "-Infinity") : string(v)
_js_value(v::Number) = string(v)
# For a '…' JS literal. `</` → `<\/`: the HTML parser closes an inline
# <script> on `</script>` whatever the JS quoting; after `<!--<script` it
# skips the real `</script>`, hence `<!--` → `<\!--`. Raw LF, CR, U+2028 and
# U+2029 inside a JS string are SyntaxErrors.
_js_str_escape(s::AbstractString) =
    replace(s, "\\" => "\\\\", "'" => "\\'", "</" => "<\\/", "<!--" => "<\\!--",
               "\n" => "\\n", "\r" => "\\r",
               "\u2028" => "\\u2028", "\u2029" => "\\u2029")
_js_value(v::AbstractString) = "'$(_js_str_escape(v))'"
# `repr` of a Dict/NamedTuple is not JS; JSON is. Extras only land in HTML
# attributes, where escape_html covers `<` and `'`.
_js_value(v::Union{AbstractDict, NamedTuple, AbstractVector, Tuple}) = JSON.json(v)
_js_value(v)         = string(v)  # not JS-escaped

# A signal path as Datastar reads it after `$`: dot-separated identifiers.
# Hyphens are rejected because Datastar camel-cases them at declaration, so
# `$my-signal` would read `$my` minus `signal`.
const _SIGNAL_PATH = r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$"

function _signal_path(sig::Symbol)
    s = String(sig)
    occursin(_SIGNAL_PATH, s) || throw(ArgumentError(
        "signal name must be an identifier or dotted path such as :count or " *
        "Symbol(\"form.email\") (camelCase, no hyphens); got $(repr(sig))"))
    s
end
_signal_ref(sig::Symbol) = "\$" * _signal_path(sig)

"""
    DSExpr <: AbstractString

A Datastar expression built by [`@ds_str`](@ref). As an `AbstractString`
it is accepted wherever an expression string is (`on`, `ds_show`, …).
Spliced into another `ds"…"`, it is inserted verbatim, not quoted.
"""
struct DSExpr <: AbstractString
    s::String
end
Base.String(e::DSExpr) = e.s
Base.ncodeunits(e::DSExpr) = ncodeunits(e.s)
Base.codeunit(e::DSExpr) = codeunit(e.s)
Base.codeunit(e::DSExpr, i::Integer) = codeunit(e.s, i)
Base.isvalid(e::DSExpr, i::Integer) = isvalid(e.s, i)
Base.iterate(e::DSExpr, i::Integer=1) = iterate(e.s, i)

# _ds_parse's quote tracking can be fooled (a quote inside a regex literal),
# so a splice must stay inert inside any JS string: `"`, backtick and `$`
# are escaped too. Those escapes are no-ops in a JS string, and in JSON these
# characters only occur inside strings. Other types go through JSON, not
# `_js_value`'s `string(v)`, so `nothing` or a Symbol can't land as a bare
# identifier.
_ds_splice(x::Union{Bool, Number}) = _js_value(x)
_ds_splice(x::AbstractString) =
    "'" * replace(_js_str_escape(x), "\"" => "\\\"", "`" => "\\`", "\$" => "\\\$") * "'"
_ds_splice(x) = replace(JSON.json(x), "'" => "\\'", "`" => "\\`", "\$" => "\\\$")
_ds_splice(x::DSExpr) = x.s
_ds_splice(a::DSAction) = action_js(a)

# Split a ds"…" body into literal Strings and Julia Exprs to splice. Only
# `$(` starts a splice: Datastar signal names never begin with `(`. Quotes
# are tracked so a splice can't land inside a JS string literal, where its
# own quotes would end the string early.
function _ds_parse(s::AbstractString)
    parts = Any[]
    buf = IOBuffer()
    quote_char = nothing
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        nxt = nextind(s, i)
        if c == '\\'
            if quote_char === nothing && nxt <= lastindex(s) && s[nxt] == '$'
                throw(ArgumentError("ds\"…\": `\\\$` is not needed; write \$name " *
                                    "for a signal or \$(expr) to splice a Julia value"))
            end
            # Copy a JS escape pair whole so `\'` doesn't toggle the quote state.
            print(buf, c)
            if nxt <= lastindex(s)
                print(buf, s[nxt])
                nxt = nextind(s, nxt)
            end
            i = nxt
            continue
        elseif c in ('\'', '"', '`')
            if quote_char === nothing
                quote_char = c
            elseif quote_char == c
                quote_char = nothing
            end
        elseif c == '$' && startswith(SubString(s, nxt), "\$(")
            print(buf, "\$(")
            i = nextind(s, nextind(s, nxt))
            continue
        elseif c == '$' && nxt <= lastindex(s) && s[nxt] == '('
            quote_char === nothing || throw(ArgumentError(
                "ds\"…\": \$(…) inside a JS string literal would add a second " *
                "set of quotes; write 'Hi, ' + \$(name) instead"))
            ex, i = Meta.parseatom(s, nxt)
            if ex isa Expr && ex.head in (:incomplete, :error)
                throw(ArgumentError("ds\"…\": unclosed or invalid \$(…) in $(repr(s))"))
            end
            position(buf) > 0 && push!(parts, String(take!(buf)))
            push!(parts, ex)
            continue
        end
        print(buf, c)
        i = nxt
    end
    quote_char === nothing ||
        throw(ArgumentError("ds\"…\": unterminated $(quote_char) string in $(repr(s))"))
    position(buf) > 0 && push!(parts, String(take!(buf)))
    parts
end

"""
    ds"…" -> DSExpr

Write a Datastar expression without escaping `\$`. Unlike a Julia string,
`\$name` is **not** interpolated: it stays a Datastar signal reference.
`\$(expr)` evaluates the Julia `expr` and inserts it as a JS literal, the
same way [`DSAction`](@ref) options are written: strings single-quoted and
escaped (`"`, backtick and `\$` too), numbers and booleans as-is, `Dict`/`NamedTuple`/`Vector` as JSON,
anything else via `JSON.json`. A [`DSAction`](@ref)
or another `ds"…"` is inserted verbatim. Write `\$\$(` for a literal `\$(`.

A misplaced splice fails when the code loads: `\\\$` (not needed here) and
`\$(…)` inside a JS `'…'`/`"…"` string (it would add quotes; concatenate
with `+` instead).

# Examples
```jldoctest
julia> n = 3;

julia> ds"\$count = \$count + \$(n)"
"\\\$count = \\\$count + 3"

julia> s = "it's";

julia> render(button(on(:click, ds"\$label = \$(s)")))
"<button data-on:click=\\"\\\$label = &#39;it\\\\&#39;s&#39;\\"></button>"
```
"""
macro ds_str(s)
    parts = _ds_parse(s)
    all(p -> p isa String, parts) && return DSExpr(join(parts))
    args = [p isa String ? p : :(_ds_splice($(esc(p)))) for p in parts]
    :(DSExpr(string($(args...))))
end

"""
    on(event::Symbol, action; debounce=nothing, window=false,
       prevent=nothing, stop=false, outside=false) -> Attribute

Bind `action` to a DOM event: a [`DSAction`](@ref) (rendered as
`@verb('url', {…})`) or a raw JS expression string (`"\$open = !\$open"`).
Returns an [`Attribute`](@ref) for a tag's positional args.

Modifiers:
- `debounce=N` (ms) — appends `__debounce.Nms`.
- `window=true` — appends `__window`: listener on `window`, so global
  hotkeys fire without focus.
- `prevent=true` — appends `__prevent` (`event.preventDefault()`).
  Defaults to `true` for `:submit` so the native navigation doesn't also
  run; `prevent=false` opts out.
- `stop=true` — appends `__stop`. Calls `event.stopPropagation()`.
- `outside=true` — appends `__outside`: fires only when the event target is
  outside the element (click-outside-to-close).

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
interval. Renders as `data-on-interval__duration.Nms="…"`.
`data-on-interval` takes no event name, only a duration.

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
    on_click(action; kwargs...)
    on_submit(action; kwargs...)

Shorthands for [`on(:click, action; kwargs...)`](@ref on) /
[`on(:submit, action; kwargs...)`](@ref on); same keywords.

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

Shorthand for `on(:change, action; debounce=ms)`. 300 ms ignores
mid-word typing and still feels instant.

# Examples
```julia
form(on_change_debounced(ds_get("/api/preview"; form=true)),
     input(type="text", name="query"))
```
"""
on_change_debounced(action::Union{DSAction, AbstractString}; ms::Int=300) =
    on(:change, action; debounce=ms)

"""
    ds_indicator(signal::AbstractString) -> Attribute
    ds_indicator(signal::Symbol) -> Attribute

Datastar sets the named signal to true while a request from this
element is in flight, so any element can `ds_show` it as a spinner.
Datastar rejects `data-indicator` without a signal, so there is no
zero-argument form.

# Examples
```julia
button("Save", on_click(ds_post("/api/save")), ds_indicator(:saving))
span(class="spinner", ds_show(:saving), "…")
```
"""
ds_indicator(signal::AbstractString) =
    Attribute(Symbol("data-indicator"), String(signal))
ds_indicator(signal::Symbol) = ds_indicator(_signal_path(signal))

"""
    ds_ignore_morph() -> Attribute

Datastar's morph leaves this element's subtree alone across fragment swaps
(inputs mid-edit, focused elements).

# Examples
```julia
input(type="text", name="search", ds_ignore_morph())
```
"""
ds_ignore_morph() = Attribute(Symbol("data-ignore-morph"), true)

"""
    ds_bind(signal::AbstractString) -> Attribute
    ds_bind(signal::Symbol) -> Attribute

Two-way bind an input to a Datastar signal: the input's value mirrors
`signal`, and edits flow back. Returns the `data-bind="signal"` attribute.

# Examples
```julia
input(type="text", ds_bind(:query))
```
"""
ds_bind(signal::AbstractString) = Attribute(Symbol("data-bind"), String(signal))
ds_bind(signal::Symbol) = ds_bind(_signal_path(signal))

"""
    ds_signal(name::AbstractString, value) -> Attribute

Initialize a Datastar signal on this element. Renders as the keyed
`data-signals:<name>="value"` form. Note Datastar's kebab→camel mapping:
`ds_signal("my-signal", …)` creates the signal `\$mySignal`.

# Examples
```julia
div(ds_signal("count", 0), ds_text(:count))   # signal "count" starts at 0
```
"""
ds_signal(name::AbstractString, value) = Attribute(Symbol("data-signals:", name), value)

"""
    ds_signals(state) -> Attribute

Initialize several signals on this element. `state` is anything
JSON-encodable, typically a `NamedTuple` or `Dict` of name → initial value.
Renders as `data-signals="{…}"`, JSON `"` escaped to `&quot;`. Use over
[`ds_signal`](@ref) when one element seeds several signals: the encoder
can't produce the malformed JSON a hand-written string can.

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
    ds_show(expr::AbstractString) -> Attribute
    ds_show(signal::Symbol) -> Attribute

Show this element only when the JS expression `expr` is truthy. Renders
as `data-show="expr"`. A `Symbol` names one signal: `ds_show(:open)`
renders `data-show="\$open"`.

# Examples
```julia
p(ds_show(ds"\$count > 0"), "You have items.")
```
"""
ds_show(expr::AbstractString) = Attribute(Symbol("data-show"), String(expr))
ds_show(signal::Symbol) = ds_show(_signal_ref(signal))

"""
    ds_text(expr::AbstractString) -> Attribute
    ds_text(signal::Symbol) -> Attribute

Set this element's text content from the JS expression `expr`. Renders
as `data-text="expr"`; Datastar re-evaluates it when the signals `expr`
reads change.

# Examples
```julia
span(ds_text(:count))    # text content tracks the signal "count"
```
"""
ds_text(expr::AbstractString) = Attribute(Symbol("data-text"), String(expr))
ds_text(signal::Symbol) = ds_text(_signal_ref(signal))

"""
    ds_json_signals() -> Attribute
    ds_json_signals(filter::AbstractString) -> Attribute

Set this element's text content to the live JSON of all signals — an
in-page debugger (`pre(ds_json_signals())`). Renders as the bare
`data-json-signals` attribute.

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

Expose this element to Datastar expressions as `\$<name>`
(`\$btnNext.click()`). Renders as `data-ref="name"`.

# Examples
```julia
button(ds_ref("btnNext"), "Next")
# Elsewhere: data-on:keydown__window="if(event.key==='ArrowRight') \$btnNext.click()"
```
"""
ds_ref(name::AbstractString) = Attribute(Symbol("data-ref"), String(name))

"""
    ds_attr(name::AbstractString, expr::AbstractString) -> Attribute
    ds_attr(name::AbstractString, signal::Symbol) -> Attribute

Bind a DOM attribute to a Datastar expression; it updates as the signals
`expr` reads change. Renders as `data-attr:NAME="expr"`. Truthy → set;
falsy → removed.

# Examples
```julia
# Open/close a <dialog> from a signal
dialog(ds_attr("open", :dialogOpen), …)

# Disable a button while a request is in flight
button(ds_attr("disabled", :saving), "Save")
```
"""
ds_attr(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-attr:", name), String(expr))
ds_attr(name::AbstractString, signal::Symbol) = ds_attr(name, _signal_ref(signal))

"""
    ds_class(name::AbstractString, expr::AbstractString) -> Attribute
    ds_class(name::AbstractString, signal::Symbol) -> Attribute

Toggle a CSS class: added while `expr` is truthy, removed while falsy.
Renders as `data-class:NAME="expr"`. For other attributes use
[`ds_attr`](@ref).

# Examples
```julia
# Drop the `.outline` class from the active view-toggle button
button(class="grid-toggle", ds_class("outline", ds"\$view !== 'grid'"), "Grid")
```
"""
ds_class(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-class:", name), String(expr))
ds_class(name::AbstractString, signal::Symbol) = ds_class(name, _signal_ref(signal))

"""
    ds_computed(name::AbstractString, expr::AbstractString) -> Attribute
    ds_computed(name::AbstractString, signal::Symbol) -> Attribute

Declare a read-only signal `name` derived from `expr`; it re-evaluates when
any signal `expr` reads changes. Renders as `data-computed:NAME="expr"`;
read it as `\$NAME`. Datastar camel-cases hyphens: `"full-name"` is read
as `\$fullName`.

# Examples
```julia
# A line-item total that tracks its inputs; read elsewhere as \$total
div(ds_computed("total", ds"\$price * \$qty"),
    span(ds_text(:total)))
```
"""
ds_computed(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-computed:", name), String(expr))
ds_computed(name::AbstractString, signal::Symbol) = ds_computed(name, _signal_ref(signal))

"""
    ds_style(name::AbstractString, expr::AbstractString) -> Attribute
    ds_style(name::AbstractString, signal::Symbol) -> Attribute

Bind an inline style property: Datastar writes `expr`'s value to
`element.style.NAME` as the signals it reads change. Renders as
`data-style:NAME="expr"`. See also [`ds_class`](@ref), [`ds_attr`](@ref).

# Examples
```julia
# Drive a progress bar's width from a signal (0–100)
div(class="bar", ds_style("width", ds"\$pct + '%'"))

# Hide via inline display rather than a class
div(ds_style("display", ds"\$hiding && 'none'"))
```
"""
ds_style(name::AbstractString, expr::AbstractString) =
    Attribute(Symbol("data-style:", name), String(expr))
ds_style(name::AbstractString, signal::Symbol) = ds_style(name, _signal_ref(signal))

"""
    ds_effect(expr::AbstractString) -> Attribute

Run a side-effecting JS expression whenever the signals it reads change,
e.g. to call a DOM method from signal state. Renders as
`data-effect="expr"`.

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

# HTTP 1.x: `req.body` is bytes. HTTP 2.x: `BytesBody` (bytes in `.data`;
# `String(::BytesBody)` iterates byte by byte) or `EmptyBody` (no `.data`).
_request_body_bytes(b::AbstractVector{UInt8}) = b
_request_body_bytes(b) = hasproperty(b, :data) ? b.data : UInt8[]

"""
    parse_signals(req_or_body) -> Dict{String, Any}

Decode the JSON signals body that Datastar's default action mode sends
(`@post('/x')` without `contentType: 'form'`). Accepts an `HTTP.Request`,
bytes, an `IO` or an `AbstractString`. An empty body → empty `Dict`;
invalid JSON or a non-object → `ArgumentError`.

Form-encoded posts (`contentType: 'form'`) are a different wire format:
use your HTTP framework's form parser.

# Examples
```julia
function handle_increment(req::HTTP.Request)
    sig = parse_signals(req)
    n = Int(get(sig, "count", 0)) + 1
    fragment_response(div(id="counter", n), "#counter")
end
```
"""
parse_signals(req::HTTP.Request) = parse_signals(_request_body_bytes(req.body))
parse_signals(body::AbstractVector{UInt8}) =
    isempty(body) ? Dict{String, Any}() : parse_signals(String(body))
parse_signals(io::IO) = parse_signals(read(io))
function parse_signals(body::AbstractString)
    isempty(body) && return Dict{String, Any}()
    parsed = try
        JSON.parse(String(body))
    catch err
        # Truncated: a huge malformed body would flood logs.
        snippet = SubString(body, 1, min(lastindex(body), 80))
        throw(ArgumentError("parse_signals: invalid JSON body (first 80 chars: $(repr(snippet))) — $(err)"))
    end
    parsed isa AbstractDict ? Dict{String, Any}(parsed) :
        throw(ArgumentError("parse_signals: expected a JSON object at the top level, got $(typeof(parsed))"))
end
