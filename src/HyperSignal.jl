"""
    HyperSignal

Datastar-flavored HTML for Julia. Compose pages from typed AST nodes,
render to streamed HTML, and bind Datastar actions without ever
hand-typing `data-on:click="@post('/x', {…})"` or escaping HTML by hand.

# Quickstart

```julia
using HyperSignal
HyperSignal.@using_tags                 # brings div / select / summary

# Build with tag constructors. Children go positional, attributes go kw.
page = Frag(
    DOCTYPE,
    html(lang="en",
        head(meta(charset="UTF-8"), title("My App")),
        body(
            h1("Hello"),
            form(on_submit(ds_post("/save"; form=true)),
                radio_field("size", "S", "Small"),
                radio_field("size", "L", "Large"; checked=true),
                button(type="submit", "Save")),
        )),
)

html_response(page)                   # full-page Response
fragment_response(page, "#card")      # Datastar morph with selector header
```

# What's exported

- AST primitives: [`Element`](@ref), [`Raw`](@ref), [`Frag`](@ref),
  [`Attribute`](@ref), [`DOCTYPE`](@ref).
- Tag constructors: every common HTML element (`div`, `h1`, `form`, …).
  Names that overlap with Base (`div`, `select`, `summary`) are
  brought into scope with the [`@using_tags`](@ref) macro.
- Datastar actions: [`ds_get`](@ref), [`ds_post`](@ref), [`ds_put`](@ref),
  [`ds_delete`](@ref), bound via [`on`](@ref) /
  [`on_click`](@ref) / [`on_submit`](@ref) /
  [`on_change_debounced`](@ref) / [`on_interval`](@ref). `on(...)` accepts
  raw JS expressions alongside `DSAction` and a `window=true` modifier
  for global listeners.
- Datastar attributes: [`ds_indicator`](@ref), [`ds_ignore_morph`](@ref),
  [`ds_bind`](@ref), [`ds_signal`](@ref), [`ds_signals`](@ref),
  [`ds_show`](@ref), [`ds_text`](@ref), [`ds_ref`](@ref),
  [`ds_attr`](@ref), [`ds_class`](@ref), [`ds_effect`](@ref),
  [`ds_init`](@ref).
- Datastar signal decoding: [`parse_signals`](@ref) (read the JSON body
  of a non-form Datastar action into a `Dict{String, Any}`).
- Form helpers: [`cls`](@ref), [`radio_field`](@ref),
  [`checkbox_field`](@ref), [`form_legend`](@ref), [`form_section`](@ref),
  [`help_tooltip`](@ref), [`preset_button`](@ref).
- Dialog helper: [`signal_dialog`](@ref) (native `<dialog>` driven by a
  Datastar expression).
- Rendering: [`render(io, x)`](@ref render) for streaming, [`render(x)`](@ref)
  for the String you usually want at the response boundary.
- Responses: [`html_response`](@ref), [`fragment_response`](@ref),
  [`redirect_via_fragment`](@ref), [`redirect_to`](@ref).

# Safety model

Strings and numbers in children / attribute values are auto-escaped at
render time. Use [`Raw`](@ref) at the boundary to inject pre-built HTML
(SVG snippets, audited generators) — never wrap user input in `Raw`.
JS-string interpolation inside Datastar actions is the renderer's job;
build a [`DSAction`](@ref) and let it through.
"""
module HyperSignal

using HTTP
using JSON

include("elements.jl")
include("datastar.jl")
include("render.jl")
include("response.jl")
include("sse.jl")
include("helpers.jl")
include("svg.jl")

# Element tree
export Element, Raw, Frag, Attribute, DOCTYPE

# Tag constructors (the common HTML5 set — extend as needed)
export html, head, body, title, meta, link, script, style, noscript
export span, p, a, h1, h2, h3, h4, h5, h6, hr, br, wbr
export ul, ol, li, dl, dt, dd
export form, input, button, label, fieldset, legend, option, optgroup, textarea, datalist
export table, thead, tbody, tfoot, tr, th, td, caption, colgroup, col
export article, section, nav, header, footer, main, aside, figure, figcaption, address
export img, svg, path, circle, polygon, rect, line, ellipse, polyline, g, defs, use
export small, strong, em, code, pre, b, i, s, u, kbd, samp, var, cite, q
export sub, sup, blockquote
export progress, details, dialog, meter, output, data
export audio, video, picture, source, track, iframe, embed, object, param, area

# Datastar
export DATASTAR_SUPPORTED_VERSION
export DSAction, ds_get, ds_post, ds_put, ds_delete
export ds_indicator, ds_ignore_morph, ds_bind, ds_signal, ds_signals, ds_show, ds_text
export ds_ref, ds_attr, ds_class, ds_effect, ds_init
export on, on_click, on_submit, on_change_debounced, on_interval
export parse_signals

# Component helpers (top-level)
export cls, redirect_to

# App-grade helpers live in HyperSignal.Helpers. No top-level shim:
# the package is pre-1.0 with no external users, so an outright move
# is cheaper than maintaining a deprecation cycle.

# Rendering + responses
export render
export fragment_response, html_response, redirect_via_fragment
export signals_response, script_response
export sse_response, sse_stream, patch_elements, patch_signals

# SVG inlining (CairoMakie etc.)
export patch_svg, inline_svg

# Macros
export @using_tags

# Drive precompilation of the render hot path so the first call in a
# user's session doesn't pay JIT cost for the most common shapes.
# `precompile` pins method specializations without executing them, so it
# stays runtime-cheap and adds no dep — for richer workload-driven
# precompilation, a downstream project can layer PrecompileTools on top.
let
    # Render hot path
    precompile(Tuple{typeof(render), IOBuffer, Element})
    precompile(Tuple{typeof(render), IOBuffer, Frag})
    precompile(Tuple{typeof(render), IOBuffer, Raw})
    precompile(Tuple{typeof(render), IOBuffer, String})
    precompile(Tuple{typeof(render), IOBuffer, SubString{String}})
    precompile(Tuple{typeof(render), IOBuffer, Char})
    precompile(Tuple{typeof(render), IOBuffer, Int})
    precompile(Tuple{typeof(render), IOBuffer, Nothing})
    precompile(Tuple{typeof(render), IOBuffer, Missing})
    precompile(Tuple{typeof(render), IOBuffer, Vector{Any}})
    precompile(Tuple{typeof(render), IOBuffer, Vector{UInt8}})
    precompile(Tuple{typeof(render), Element})
    precompile(Tuple{typeof(render), Frag})
    precompile(Tuple{typeof(render), Raw})
    precompile(Tuple{typeof(render), String})
    # Escape paths (String + SubString fast paths)
    precompile(Tuple{typeof(escape_html), IOBuffer, String})
    precompile(Tuple{typeof(escape_html), IOBuffer, SubString{String}})
    precompile(Tuple{typeof(escape_html), IOBuffer, Char})
    # Name validation cache hits
    precompile(Tuple{typeof(_check_attr_name), Symbol})
    precompile(Tuple{typeof(_check_tag_name), Symbol})
    # Datastar serialization
    precompile(Tuple{typeof(action_js), DSAction})
    # Response wrappers
    precompile(Tuple{typeof(html_response), Element})
    precompile(Tuple{typeof(html_response), Frag})
    precompile(Tuple{typeof(fragment_response), Element, String})
    # SVG patching for the CairoMakie story
    precompile(Tuple{typeof(patch_svg), String})
    precompile(Tuple{typeof(inline_svg), String})
    # Signal decoding
    precompile(Tuple{typeof(parse_signals), Vector{UInt8}})
    precompile(Tuple{typeof(parse_signals), String})
end

end
