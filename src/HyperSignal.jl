"""
    HyperSignal

Datastar-flavored HTML for Julia. Compose pages from typed AST nodes,
render to streamed HTML, and bind Datastar actions without ever
hand-typing `data-on:click="@post('/x', {…})"` or escaping HTML by hand.

# Quickstart

```julia
using HyperSignal
using HyperSignal.Helpers: radio_field
HyperSignal.@using_tags                 # unexported tags: div, select, …

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

# Exports

- AST: [`Element`](@ref), [`Raw`](@ref), [`Frag`](@ref),
  [`Attribute`](@ref), [`DOCTYPE`](@ref).
- Tag constructors: common HTML elements (`h1`, [`form`](@ref), …).
  `div`, `select`, `summary`, `mark`, `time` are not exported; bring them in
  with [`@using_tags`](@ref).
- Datastar actions: [`ds_get`](@ref), [`ds_post`](@ref), [`ds_put`](@ref),
  [`ds_delete`](@ref), bound via [`on`](@ref) / [`on_click`](@ref) /
  [`on_submit`](@ref) / [`on_change_debounced`](@ref) /
  [`on_interval`](@ref). `on(...)` also takes raw JS expressions and
  `window=true` for global listeners.
- Datastar attributes: [`ds_indicator`](@ref), [`ds_ignore_morph`](@ref),
  [`ds_bind`](@ref), [`ds_signal`](@ref), [`ds_signals`](@ref),
  [`ds_show`](@ref), [`ds_text`](@ref), [`ds_json_signals`](@ref),
  [`ds_ref`](@ref), [`ds_attr`](@ref), [`ds_class`](@ref),
  [`ds_computed`](@ref), [`ds_style`](@ref), [`ds_effect`](@ref),
  [`ds_init`](@ref). `ds_show`, `ds_text`, `ds_attr`, `ds_class`,
  `ds_style` and `ds_computed` take a `Symbol` for one signal
  (`ds_show(:open)`); `ds_bind` and `ds_indicator` take one for the bare
  name.
- Datastar expressions: [`@ds_str`](@ref) (`ds"\$count = \$(n)"`) writes
  `\$signal` without escaping and splices Julia values as escaped JS literals;
  it returns a [`DSExpr`](@ref).
- Request decoding: [`parse_signals`](@ref).
- Rendering: [`render(io, x)`](@ref render) streams; [`render(x)`](@ref)
  returns a String.
- Responses: [`html_response`](@ref), [`fragment_response`](@ref),
  [`signals_response`](@ref), [`script_response`](@ref),
  [`redirect_via_fragment`](@ref), [`redirect_to`](@ref).
- SSE: [`sse_response`](@ref), [`sse_stream`](@ref),
  [`patch_elements`](@ref), [`patch_signals`](@ref).
- SVG: [`patch_svg`](@ref), [`inline_svg`](@ref).
- [`cls`](@ref) class-list builder; [`DATASTAR_SUPPORTED_VERSION`](@ref).

`HyperSignal.Helpers` (not re-exported) holds form and dialog helpers:
[`radio_field`](@ref HyperSignal.Helpers.radio_field),
[`checkbox_field`](@ref HyperSignal.Helpers.checkbox_field),
[`text_field`](@ref HyperSignal.Helpers.text_field),
[`form_legend`](@ref HyperSignal.Helpers.form_legend),
[`form_section`](@ref HyperSignal.Helpers.form_section),
[`help_tooltip`](@ref HyperSignal.Helpers.help_tooltip),
[`preset_button`](@ref HyperSignal.Helpers.preset_button),
[`signal_dialog`](@ref HyperSignal.Helpers.signal_dialog).

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
include("ds_str.jl")
include("render.jl")
include("response.jl")
include("sse.jl")
include("helpers.jl")
include("svg.jl")

export Element, Raw, Frag, Attribute, DOCTYPE

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

export DATASTAR_SUPPORTED_VERSION
export DSAction, DSExpr, ds_get, ds_post, ds_put, ds_delete
export ds_indicator, ds_ignore_morph, ds_bind, ds_signal, ds_signals, ds_show, ds_text, ds_json_signals
export ds_ref, ds_attr, ds_class, ds_computed, ds_style, ds_effect, ds_init
export on, on_click, on_submit, on_change_debounced, on_interval
export parse_signals

export cls, redirect_to

export render
export fragment_response, html_response, redirect_via_fragment
export signals_response, script_response
export sse_response, sse_stream, patch_elements, patch_signals

export patch_svg, inline_svg

export @using_tags, @ds_str

# Plain `precompile`, not PrecompileTools: no extra dep, nothing executed.
let
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
    precompile(Tuple{typeof(escape_html), IOBuffer, String})
    precompile(Tuple{typeof(escape_html), IOBuffer, SubString{String}})
    precompile(Tuple{typeof(escape_html), IOBuffer, Char})
    precompile(Tuple{typeof(_check_attr_name), Symbol})
    precompile(Tuple{typeof(_check_tag_name), Symbol})
    precompile(Tuple{typeof(action_js), DSAction})
    precompile(Tuple{typeof(html_response), Element})
    precompile(Tuple{typeof(html_response), Frag})
    precompile(Tuple{typeof(fragment_response), Element, String})
    precompile(Tuple{typeof(patch_svg), String})
    precompile(Tuple{typeof(inline_svg), String})
    precompile(Tuple{typeof(parse_signals), Vector{UInt8}})
    precompile(Tuple{typeof(parse_signals), String})
end

end
