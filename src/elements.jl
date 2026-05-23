# Element tree — plain data, render() walks and emits to IO. Children are
# anything renderable: another Element, a String (auto-escaped), a Number,
# nothing (skipped), a Vector of children, or a Raw wrapper for trusted HTML.

"""
    Raw(html::String)

Trusted HTML that bypasses auto-escape. Wrap the value at the boundary —
SVG icon strings, output of an audited HTML generator, third-party widget
markup — never wrap user input.

# Examples
```julia
const SPINNER = Raw("<svg viewBox=\"0 0 24 24\">…</svg>")

div(class="loading", SPINNER, " Working…")  # SVG kept verbatim, " Working…" escaped
```
"""
struct Raw
    html::String
end

"""
    DOCTYPE

The `<!DOCTYPE html>` prelude as a [`Raw`](@ref) constant. Drop it as the
first child of a [`Frag`](@ref) wrapping `html(...)` so page builders don't
hand-type the doctype string at every call site.

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

A "group of children with no wrapper tag". Use it to return multiple
sibling elements from a single function, or to prepend [`DOCTYPE`](@ref)
to an `html(...)` tree.

# Examples
```julia
# A component that renders to two siblings — without an extra wrapper div:
section_with_grid(label, cards...) = Frag(
    small(class="muted form-section-label", label),
    div(class="form-card-grid", cards...),
)
```
"""
struct Frag
    children::Vector{Any}
    # Pin the typed inner constructor explicitly so Julia DOESN'T also
    # auto-generate the generic single-arg form `Frag(children)` — that one
    # matches `Frag(some_element)` and fails inside `convert(Vector{Any}, …)`
    # before dispatch can fall through to the varargs outer.
    Frag(children::Vector{Any}) = new(children)
end
Frag(xs...) = Frag(collect(Any, xs))

"""
    Attribute(key::Symbol, value)

Attribute value returned by helpers like [`on`](@ref) and
[`ds_indicator`](@ref). Tag constructors filter these out of positional
args and merge them into the attrs list, so an `Attribute`-returning
helper drops in next to children without a splat ceremony.

You rarely construct `Attribute` directly — use the helpers. It's exported
mostly so user code can pattern-match or filter on it.

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

The HTML AST node. You almost never build one directly — call a tag
constructor (`div`, `h1`, `form`, …) and let it split positional args /
kwargs / [`Attribute`](@ref) values for you. Construct manually only if
you're building a custom element with a non-static tag name.

# Examples
```julia
# Direct construction — for a component with a tag chosen at runtime:
heading(level::Int, text) = Element(Symbol("h", level), Pair{Symbol,Any}[], Any[text])
heading(2, "Hello")                                          # ≡ h2("Hello")
```
"""
struct Element
    tag::Symbol
    attrs::Vector{Pair{Symbol, Any}}
    children::Vector{Any}
end

# Internal builder. Positional args are children unless they're Attributes
# (which become attrs); keyword args are always attrs. Order: kwarg attrs
# first, then any positional Attributes — later wins on collision (HTML's
# default behaviour anyway, but we keep the order stable).
function _make_element(tag::Symbol, args::Tuple, kwargs)
    children = Any[]
    attrs = Pair{Symbol, Any}[Symbol(k) => v for (k, v) in pairs(kwargs)]
    for a in args
        a === nothing && continue
        if a isa Attribute
            push!(attrs, a.key => a.value)
        elseif a isa Pair && a.first isa Symbol
            # Accept Symbol-keyed Pairs as ad-hoc attributes — covers
            # attribute names that aren't valid Julia kwarg identifiers
            # (e.g. `:for => "x"`, `Symbol("aria-label") => "..."`).
            push!(attrs, a.first => a.second)
        elseif a isa Pair && a.first isa AbstractString
            # String-keyed Pairs are the ergonomic shortcut for the
            # same thing: `"data-foo" => "v"` reads better than
            # `Symbol("data-foo") => "v"`. The render-time attribute
            # name validation still fires, so the relaxation is purely
            # syntactic.
            push!(attrs, Symbol(a.first) => a.second)
        elseif a isa Vector{UInt8}
            # Keep byte buffers as a single child — render handles them
            # as a verbatim write. Without this branch a buffer would
            # get unpacked into individual UInt8 Number children, each
            # emitting its decimal value.
            push!(children, a)
        elseif a isa Vector
            append!(children, a)
        elseif a isa Tuple
            # Tuple-of-children mirrors the Vector unpacking: a caller
            # who has children in a tuple (destructure, comprehension
            # result via collect-to-tuple, splat receiver) gets the
            # same flatten behavior as if they'd passed a vector.
            for c in a
                push!(children, c)
            end
        else
            push!(children, a)
        end
    end
    Element(tag, attrs, children)
end

# Generate a constructor for each common HTML tag.
#
# Each constructor accepts arbitrary positional children (Element, String,
# Number, Frag, Raw, Vector of any of those, nothing) plus arbitrary
# kwargs which become attributes. Attribute-returning helpers (`on(...)`,
# `ds_indicator()`, etc.) can be passed positionally — they're lifted out
# of children and merged into attrs.
#
# Names that overlap with Base (`div`, `select`, `summary`) are
# exported but `using` skips them by design; pull them in with the
# [`@using_tags`](@ref) macro or an explicit `using HyperSignal: div, …`.
#
# # Examples
# ```julia
# h1("Hello, world")
# div(class="card", id="welcome",
#     h2("Title"),
#     p("body text"),
#     button(type="submit", on(:click, ds_post("/api/x")), "Go"))
# ```
const _TAGS = (
    :html, :head, :body, :title, :meta, :link, :script, :style,
    :div, :span, :p, :a, :h1, :h2, :h3, :h4, :h5, :h6, :hr, :br,
    :ul, :ol, :li, :dl, :dt, :dd,
    :input, :button, :label, :fieldset, :legend, :select, :option, :textarea,
    :table, :thead, :tbody, :tr, :th, :td,
    :article, :section, :nav, :header, :footer, :main, :aside, :figure, :figcaption,
    :img, :svg, :path, :circle, :polygon,
    :small, :strong, :em, :code, :pre,
    :progress, :details, :summary, :dialog, :u,
)

for tag in _TAGS
    @eval $(tag)(args...; kwargs...) = _make_element($(QuoteNode(tag)), args, kwargs)
end

# `<form>` overrides the generic constructor to inject a default
# `data-on:submit__prevent` when the caller didn't bind a submit handler.
# Why: a bare <form> (one used only for change-driven Datastar fetches, or
# for layout) still receives a native submit when the user presses Enter
# in any input, which reloads the page and drops client signals. Forcing
# preventDefault unless the caller wired their own submit handler removes
# that footgun. Callers that *do* want native submission can pass
# `on_submit(..., prevent=false)` or any other `data-on:submit*` binding —
# the override only fires when no submit binding is present at all.
function form(args...; kwargs...)
    el = _make_element(:form, args, kwargs)
    has_submit = any(p -> startswith(String(p.first), "data-on:submit"), el.attrs)
    has_submit || pushfirst!(el.attrs, Symbol("data-on:submit__prevent") => true)
    el
end

# Tags whose names overlap with Base names (Base.div, Base.select,
# Base.summary) — `using HyperSignal` skips them by design, so the
# @using_tags macro emits the explicit `using HyperSignal: …` line for
# them. Note: `<time>` is NOT listed here; Base.time is the wall-clock
# function the codebase uses, and the HTML <time> element is built
# directly via `HyperSignal.Element(:time, …)` on the rare site that
# needs it. `<map>` is similarly absent: no HyperSignal-defined `map`
# constructor exists (it's not in `_TAGS`), so importing it would just
# re-bind Base.map for no gain.
const _BASE_SHADOWED = (:div, :select, :summary)

"""
    @using_tags

Bring the Base-shadowed tag constructors (`div`, `select`, `summary`)
into the current module's scope. Equivalent to the explicit `using
HyperSignal: div, select, summary` line — saves callers from memorizing
which names conflict.

Plain `using HyperSignal` already imports every other tag (`h1`, `form`,
`button`, …) automatically; only the Base-shadowed set needs this.

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

# Self-closing tags that must not emit `</tag>`.
const _VOID_TAGS = Set{Symbol}((
    :area, :base, :br, :col, :embed, :hr, :img, :input, :link,
    :meta, :param, :source, :track, :wbr,
))

is_void(tag::Symbol) = tag in _VOID_TAGS
