"""
    Raw(html::String)

Trusted HTML that bypasses auto-escape. Wrap at the boundary (SVG icon
strings, audited HTML generators, third-party widget markup). Never wrap
user input.

# Examples
```julia
const SPINNER = Raw("<svg viewBox=\"0 0 24 24\">…</svg>")

div(class="loading", SPINNER, " Working…")  # SVG kept verbatim, " Working…" escaped
```

# Adversarial round-trip

`Raw` is written out verbatim: no escaping, no sanitizing. A regression
that rewrites it breaks SVG icons and fails this doctest.

```jldoctest
julia> render(p(Raw("<img src=x onerror=alert(1)>")))
"<p><img src=x onerror=alert(1)></p>"
```
"""
struct Raw
    html::String
end

"""
    DOCTYPE

The `<!DOCTYPE html>` prelude as a [`Raw`](@ref) constant. Put it first in a
[`Frag`](@ref) wrapping `html(...)`.

# Examples
```julia
page = Frag(
    DOCTYPE,
    html(lang="en",
        head(meta(charset="UTF-8"), title("My App")),
        body(h1("Hello"))),
)
html_response(page)
```
"""
const DOCTYPE = Raw("<!DOCTYPE html>")

"""
    Frag(children...)

A group of children with no wrapper tag. Use it to return sibling
elements from one function, or to prepend [`DOCTYPE`](@ref) to an
`html(...)` tree.

# Examples
```julia
# Two siblings, no wrapper div:
section_with_grid(label, cards...) = Frag(
    small(class="muted form-section-label", label),
    div(class="form-card-grid", cards...),
)
```
"""
struct Frag
    children::Vector{Any}
    # Explicit inner constructor suppresses the generic `Frag(children)`:
    # it would match `Frag(some_element)` and fail in `convert` before the
    # varargs outer method is reached.
    Frag(children::Vector{Any}) = new(children)
end
Frag(xs...) = Frag(collect(Any, xs))

"""
    Attribute(key::Symbol, value)

Attribute returned by helpers like [`on`](@ref) and
[`ds_indicator`](@ref). Tag constructors lift these out of positional args
into the attrs list, so they sit next to children without a splat.

Rarely constructed directly; exported so user code can match or filter on it.

# Examples
```julia
button("Submit",
    ds_indicator(),                          # Attribute
    on(:click, ds_post("/api/submit")),      # Attribute
    "  ", strong("now"))                     # children
```
"""
struct Attribute
    key::Symbol
    value::Any
end

"""
    Element(tag::Symbol, attrs::Vector{Pair{Symbol,Any}}, children::Vector{Any})

The HTML AST node. Normally built by a tag constructor (`div`, `h1`,
`form`, …), which splits positional args, kwargs and [`Attribute`](@ref)
values. Construct directly only for a tag name chosen at runtime.

# Examples
```julia
# Tag chosen at runtime:
heading(level::Int, text) = Element(Symbol("h", level), Pair{Symbol,Any}[], Any[text])
heading(2, "Hello")                                          # ≡ h2("Hello")
```

# Boolean-attribute policy

`true` renders the attribute bare; `false`, `nothing` and `missing` omit
it; any other value renders as a quoted, escaped string.

```jldoctest
julia> render(input(type="checkbox", checked=true))
"<input type=\\"checkbox\\" checked>"

julia> render(input(type="checkbox", checked=false))
"<input type=\\"checkbox\\">"

julia> render(input(type="checkbox", checked=nothing))
"<input type=\\"checkbox\\">"

julia> render(input(type="checkbox", checked=missing))
"<input type=\\"checkbox\\">"

julia> render(input(type="checkbox", checked="yes"))
"<input type=\\"checkbox\\" checked=\\"yes\\">"
```
"""
struct Element
    tag::Symbol
    attrs::Vector{Pair{Symbol, Any}}
    children::Vector{Any}
end

# Last duplicate wins, at first-seen position. HTML5 parsers keep the FIRST
# duplicate attribute (§13.2.5.33), so `class="a" class="b"` would apply "a",
# not the override `button(on_click(a), on_click(b))` intends.
function _dedup_attrs(attrs::Vector{Pair{Symbol, Any}})
    length(attrs) < 2 && return attrs
    slot = Dict{Symbol, Int}()
    out = Pair{Symbol, Any}[]
    for (k, v) in attrs
        i = get(slot, k, 0)
        if i == 0
            push!(out, k => v)
            slot[k] = lastindex(out)
        else
            out[i] = k => v
        end
    end
    length(out) == length(attrs) ? attrs : out
end

# Attrs: kwargs first, then positional Attributes / Symbol- or String-keyed Pairs.
function _make_element(tag::Symbol, args::Tuple, kwargs)
    children = Any[]
    attrs = Pair{Symbol, Any}[k => v for (k, v) in pairs(kwargs)]
    for a in args
        a === nothing && continue
        if a isa Attribute
            push!(attrs, a.key => a.value)
        elseif a isa Pair && a.first isa Symbol
            # Covers names that aren't valid kwarg identifiers (`:for`, `Symbol("aria-label")`).
            push!(attrs, a.first => a.second)
        elseif a isa Pair && a.first isa AbstractString
            push!(attrs, Symbol(a.first) => a.second)
        elseif a isa Vector{UInt8}
            # Single child (verbatim write); unpacking would emit each byte as a decimal Number.
            push!(children, a)
        elseif a isa Vector
            append!(children, a)
        elseif a isa Tuple || a isa Base.Generator
            # Generators are consumed here so the element renders more than
            # once. A loop, not append!: append! trusts the iterator's length.
            for c in a
                push!(children, c)
            end
        else
            push!(children, a)
        end
    end
    Element(tag, _dedup_attrs(attrs), children)
end

const _TAGS = (
    :html, :head, :body, :title, :meta, :link, :script, :style, :noscript,
    :div, :span, :p, :a, :h1, :h2, :h3, :h4, :h5, :h6, :hr, :br, :wbr,
    :ul, :ol, :li, :dl, :dt, :dd,
    :input, :button, :label, :fieldset, :legend, :select, :option, :optgroup, :textarea, :datalist,
    :table, :thead, :tbody, :tfoot, :tr, :th, :td, :caption, :colgroup, :col,
    :article, :section, :nav, :header, :footer, :main, :aside, :figure, :figcaption, :address,
    :img, :svg, :path, :circle, :polygon, :rect, :line, :ellipse, :polyline, :g, :defs, :use,
    :small, :strong, :em, :code, :pre, :b, :i, :s, :u, :mark, :kbd, :samp, :var, :cite, :q,
    :sub, :sup, :blockquote,
    :progress, :details, :summary, :dialog, :meter, :output, :data, :time,
    :audio, :video, :picture, :source, :track, :iframe, :embed, :object, :param,
    :area,
    # <map>, <base> omitted: `map` would clash with Base.map. Build via `Element(:map, …)`.
)

for tag in _TAGS
    @eval $(tag)(args...; kwargs...) = _make_element($(QuoteNode(tag)), args, kwargs)
end

"""
    form(args...; kwargs...) -> Element

Like the other tag constructors, plus a default
`data-on:submit__prevent="void 0"` unless any `data-on:submit*` attribute is
present. Without it, Enter in an input submits natively, reloading the page
and dropping client signals. For native submission pass
`on_submit(...; prevent=false)`.

# Examples
```jldoctest
julia> render(form())
"<form data-on:submit__prevent=\\"void 0\\"></form>"
```
"""
function form(args...; kwargs...)
    el = _make_element(:form, args, kwargs)
    has_submit = any(p -> startswith(String(p.first), "data-on:submit"), el.attrs)
    # `void 0`, not a bare attribute: Datastar requires a value on data-on:*.
    has_submit || pushfirst!(el.attrs, Symbol("data-on:submit__prevent") => "void 0")
    el
end

# Defined but not exported: `div`, `summary`, `mark`, `time` clash with Base
# exports. `select` has no Base clash but is withheld with them.
const _BASE_SHADOWED = (:div, :select, :summary, :mark, :time)

"""
    @using_tags

Bring the Base-shadowed tag constructors (`div`, `select`, `summary`,
`mark`, `time`) into the current module. Equivalent to
`using HyperSignal: div, select, summary, mark, time`.

`using HyperSignal` exports every other tag (`h1`, `form`, `button`, …);
only these five need this.

# Examples
```julia
using HyperSignal
HyperSignal.@using_tags

div(class="card", select(name="kind", option("a"), option("b")))
```
"""
macro using_tags()
    items = [Expr(:., name) for name in _BASE_SHADOWED]
    esc(Expr(:using, Expr(:(:), Expr(:., :HyperSignal), items...)))
end

const _VOID_TAGS = Set{Symbol}((
    :area, :base, :br, :col, :embed, :hr, :img, :input, :link,
    :meta, :param, :source, :track, :wbr,
))

is_void(tag::Symbol) = tag in _VOID_TAGS
