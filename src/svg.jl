# SVG patching — string-level rewrites that make an externally-produced
# SVG document safe to inline into an HTML page. The hot use case is
# CairoMakie figures: `save("plot.svg", fig)` ships a full XML document
# with a prolog, hard-coded `width`/`height`, and id values like
# `clip0`/`glyph0` that collide as soon as two figures share a page.
#
# Pure string ops live here so they work without pulling Makie. The
# Makie-typed entry points live in `ext/HyperSignalMakieExt.jl` and call
# down into `patch_svg`.

"""
    patch_svg(svg::AbstractString;
              id_prefix::AbstractString = "",
              strip_size::Bool = true,
              add_class::Union{AbstractString, Nothing} = nothing,
              aria_label::Union{AbstractString, Nothing} = nothing) -> String

Rewrite an SVG document string so it can be inlined into HTML without
breaking. Returns the patched SVG as a `String` — wrap with [`Raw`](@ref)
to drop straight into a HyperSignal tree, or use [`inline_svg`](@ref) to
do both in one call.

Transforms applied (each independently controlled):

- The XML prolog (`<?xml …?>`) and any `<!DOCTYPE …>` are removed; both
  are invalid inside HTML and would otherwise trip the parser. HTML
  comments (`<!-- … -->`) are stripped too — anywhere in the document,
  not just the prolog — since backends like CairoMakie emit generator
  notes that add bytes without affecting the rendered figure.
- When `strip_size=true`, the root `<svg>`'s `width` and `height`
  attributes are removed, leaving only `viewBox` so the figure scales to
  its CSS container. CairoMakie hard-codes px dimensions; strip them
  unless the page really wants the original size.
- When `id_prefix` is non-empty, every `id="…"`, `url(#…)`, and
  `xlink:href="#…"` / `href="#…"` is rewritten with the prefix. This is
  the only safe way to inline more than one CairoMakie figure on the
  same page — its `clip0` / `glyph0` ids collide otherwise.
- When `add_class` is set, the value is appended to the root `<svg>`'s
  `class` attribute (or a new `class="…"` is added).
- When `aria_label` is set, `role="img"` and `aria-label="…"` are added
  to the root `<svg>` so screen readers announce the figure.

For accessibility, prefer passing `aria_label` over relying on
surrounding text — the SVG is the figure, and screen readers traverse
it in isolation.

# Examples
```jldoctest
julia> patch_svg(""\"<?xml version="1.0"?><svg width="800" height="600" viewBox="0 0 8 6"><g/></svg>""\")
"<svg viewBox=\\"0 0 8 6\\"><g/></svg>"

julia> patch_svg(""\"<svg viewBox="0 0 1 1"><defs><clipPath id="c0"><rect/></clipPath></defs><g clip-path="url(#c0)"/></svg>""\";
                 id_prefix="fig_")
"<svg viewBox=\\"0 0 1 1\\"><defs><clipPath id=\\"fig_c0\\"><rect/></clipPath></defs><g clip-path=\\"url(#fig_c0)\\"/></svg>"
```
"""
function patch_svg(svg::AbstractString;
                   id_prefix::AbstractString = "",
                   strip_size::Bool = true,
                   add_class::Union{AbstractString, Nothing} = nothing,
                   aria_label::Union{AbstractString, Nothing} = nothing)
    s = String(svg)
    # One pass for all three prolog forms that can't appear inside HTML.
    # Folded into a single alternation so the input is walked once
    # instead of three times — meaningful on the larger figures.
    s = replace(s, r"<\?xml[^>]*\?>\s*|<!DOCTYPE[^>]*>\s*|<!--.*?-->"s => "")
    if !isempty(id_prefix)
        s = _namespace_ids(s, id_prefix)
    end
    s = _patch_root_svg(s; strip_size, add_class, aria_label)
    strip(s)
end

"""
    inline_svg(svg::AbstractString; kwargs...) -> Raw

Convenience: `Raw(patch_svg(svg; kwargs...))`. Use this directly inside
an element tree.

# Examples
```jldoctest
julia> r = inline_svg("<svg viewBox=\\"0 0 1 1\\"><g/></svg>"; aria_label="Plot");

julia> r isa Raw
true

julia> r.html
"<svg viewBox=\\"0 0 1 1\\" role=\\"img\\" aria-label=\\"Plot\\"><g/></svg>"
```
"""
inline_svg(svg::AbstractString; kwargs...) = Raw(patch_svg(svg; kwargs...))

"""
    inline_svg(figure; kwargs...) -> Raw

Render a Makie/CairoMakie `Figure` / `Scene` / `FigureAxisPlot` to SVG
and inline it. Requires `using CairoMakie` (or any backend that emits
`image/svg+xml`) in the caller's session — without it, the method body
isn't loaded and you get a `MethodError`.

Keyword arguments are forwarded to [`patch_svg`](@ref).

# Examples
```julia
using CairoMakie, HyperSignal
fig = Figure(); lines(fig[1, 1], 1:10, rand(10))
div(class="plot", inline_svg(fig; id_prefix="fig1_", aria_label="Random walk"))
```
"""
function inline_svg end

# --- internals ---------------------------------------------------------

# Rewrite IDs in a root-namespaced way in a single walk:
#   id="foo"            -> id="<prefix>foo"
#   url(#foo)           -> url(#<prefix>foo)
#   xlink:href="#foo"   -> xlink:href="#<prefix>foo"
#   href="#foo"         -> href="#<prefix>foo"   (svg2 form)
# Skips href values that aren't pure fragments (anything not "#...").
#
# Combining the four shapes into one alternation lets us walk the
# input once instead of four times — a measurable win on large
# CairoMakie figures (which can run into the hundreds of KB). The
# function-form replacement also lets us splice the prefix as
# literal text without any SubstitutionString escape juggling for
# `\` in a user-supplied prefix.
const _ID_RE = r"\bid=\"([^\"]+)\"|url\(#([^)]+)\)|(?:xlink:)?href=\"#([^\"]+)\""

function _namespace_ids(s::AbstractString, prefix::AbstractString)
    io = IOBuffer(sizehint=sizeof(s))
    last = 1
    for m in eachmatch(_ID_RE, s)
        # Emit the run before this match unchanged.
        m.offset > last && write(io, SubString(s, last, prevind(s, m.offset)))
        if m.captures[1] !== nothing
            write(io, "id=\"", prefix, m.captures[1], "\"")
        elseif m.captures[2] !== nothing
            write(io, "url(#", prefix, m.captures[2], ")")
        else
            # href and xlink:href differ only in the matched prefix
            # text; recover that text from the matched substring's
            # leading bytes so we don't lose the xlink: distinction.
            token = m.match
            ref = m.captures[3]
            if startswith(token, "xlink:")
                write(io, "xlink:href=\"#", prefix, ref, "\"")
            else
                write(io, "href=\"#", prefix, ref, "\"")
            end
        end
        last = m.offset + ncodeunits(m.match)
    end
    last <= ncodeunits(s) && write(io, SubString(s, last))
    String(take!(io))
end

# Mutate the root <svg ...> opening tag: optionally strip width/height,
# append a class, and add ARIA attrs. We do this with a single regex
# match on the opening tag and rebuild the attribute string — character-
# level enough for CairoMakie's stable output without needing a full XML
# parser.
function _patch_root_svg(s::AbstractString;
                         strip_size::Bool,
                         add_class::Union{AbstractString, Nothing},
                         aria_label::Union{AbstractString, Nothing})
    m = match(r"<svg\b([^>]*)>"s, s)
    m === nothing && return s
    attrs = m.captures[1]
    if strip_size
        attrs = replace(attrs, r"\s+width=\"[^\"]*\""  => "")
        attrs = replace(attrs, r"\s+height=\"[^\"]*\"" => "")
    end
    if add_class !== nothing
        # Escape the caller's class value before it lands in the quoted
        # attribute — symmetric with aria_label below. Without this a
        # stray `"` (or `<`) closes the class attribute and injects new
        # attributes into the root <svg> (e.g. add_class=`x" onload="…`).
        safe_class = _attr_escape(add_class)
        cm = match(r"\sclass=\"([^\"]*)\"", attrs)
        if cm === nothing
            attrs *= " class=\"$(safe_class)\""
        else
            # The existing class came from the source SVG and is already
            # in the document as-is; only the caller's add_class needs
            # escaping. (replace() with a plain-String replacement does
            # not interpret `$`/`\`, so no SubstitutionString surprise.)
            merged = isempty(cm.captures[1]) ? safe_class :
                     "$(cm.captures[1]) $(safe_class)"
            attrs = replace(attrs, r"\sclass=\"[^\"]*\"" => " class=\"$(merged)\"")
        end
    end
    if aria_label !== nothing
        attrs *= " role=\"img\" aria-label=\"$(_attr_escape(aria_label))\""
    end
    # Resume past the matched opening tag by BYTE count: `m.offset` is a
    # codeunit index and SubString is byte-indexed, so `length` (character
    # count) would land short of the match end whenever the root tag holds
    # any multi-byte UTF-8 (e.g. a pre-existing non-ASCII attribute value),
    # re-emitting the trailing `>`. Mirror _namespace_ids' ncodeunits use.
    string(SubString(s, 1, m.offset - 1), "<svg", attrs, ">",
           SubString(s, m.offset + ncodeunits(m.match)))
end

# Minimal attribute-value escape — `aria_label` lands inside a "…" attr.
_attr_escape(s::AbstractString) =
    replace(String(s), "&" => "&amp;", "\"" => "&quot;", "<" => "&lt;", ">" => "&gt;")
