"""
    patch_svg(svg::AbstractString;
              id_prefix::AbstractString = "",
              strip_size::Bool = true,
              add_class::Union{AbstractString, Nothing} = nothing,
              aria_label::Union{AbstractString, Nothing} = nothing) -> String

Rewrite an SVG document string for inlining into HTML. Returns a `String`;
wrap with [`Raw`](@ref) for a HyperSignal tree, or use
[`inline_svg`](@ref) to do both.

Transforms:

- Always: the XML prolog (`<?xml …?>`), any `<!DOCTYPE …>` and all HTML
  comments (`<!-- … -->`, anywhere in the document) are removed. Prolog and
  doctype are invalid inside HTML.
- `strip_size=true` (default): remove the root `<svg>`'s `width` and
  `height`, leaving `viewBox` so the figure scales to its CSS container.
  CairoMakie hard-codes px dimensions.
- non-empty `id_prefix`: prefix every `id="…"`, `url(#…)`, and
  `xlink:href="#…"` / `href="#…"`. Needed to inline several CairoMakie
  figures on one page: their `clip0` / `glyph0` ids collide otherwise.
- `add_class`: append the (escaped) value to the root `<svg>`'s `class`
  attribute, or add `class="…"`.
- `aria_label`: add `role="img"` and `aria-label="…"` (escaped) to the root
  `<svg>`. Prefer it to surrounding text: screen readers read the SVG in
  isolation.

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
    # One alternation, one pass over the input (large figures).
    s = replace(s, r"<\?xml[^>]*\?>\s*|<!DOCTYPE[^>]*>\s*|<!--.*?-->"s => "")
    if !isempty(id_prefix)
        s = _namespace_ids(s, id_prefix)
    end
    s = _patch_root_svg(s; strip_size, add_class, aria_label)
    strip(s)
end

"""
    inline_svg(svg::AbstractString; kwargs...) -> Raw

`Raw(patch_svg(svg; kwargs...))`, for use directly inside an element tree.

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
`image/svg+xml`); without it the method isn't loaded and you get a
`MethodError`.

Keyword arguments are forwarded to [`patch_svg`](@ref).

# Examples
```julia
using CairoMakie, HyperSignal
fig = Figure(); lines(fig[1, 1], 1:10, rand(10))
div(class="plot", inline_svg(fig; id_prefix="fig1_", aria_label="Random walk"))
```
"""
function inline_svg end

# One alternation = one pass (figures reach hundreds of KB). Matches
# `id="x"`, `url(#x)`, `xlink:href="#x"`, `href="#x"`; non-fragment hrefs are skipped.
# `_namespace_ids` splices the prefix as literal text, so `\` in a prefix needs
# no SubstitutionString escaping.
const _ID_RE = r"(?<![\w:-])id=\"([^\"]+)\"|url\(#([^)]+)\)|(?:xlink:)?href=\"#([^\"]+)\""

function _namespace_ids(s::AbstractString, prefix::AbstractString)
    io = IOBuffer(sizehint=sizeof(s))
    last = 1
    for m in eachmatch(_ID_RE, s)
        m.offset > last && write(io, SubString(s, last, prevind(s, m.offset)))
        if m.captures[1] !== nothing
            write(io, "id=\"", prefix, m.captures[1], "\"")
        elseif m.captures[2] !== nothing
            write(io, "url(#", prefix, m.captures[2], ")")
        else
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

# Regex on the root opening tag, no XML parser: enough for CairoMakie's output.
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
        # Unescaped, `x" onload="…` in add_class would inject attributes into the root <svg>.
        safe_class = _attr_escape(add_class)
        cm = match(r"\sclass=\"([^\"]*)\"", attrs)
        if cm === nothing
            attrs *= " class=\"$(safe_class)\""
        else
            # Existing class is already document text; only add_class needs escaping.
            merged = isempty(cm.captures[1]) ? safe_class :
                     "$(cm.captures[1]) $(safe_class)"
            attrs = replace(attrs, r"\sclass=\"[^\"]*\"" => " class=\"$(merged)\"")
        end
    end
    if aria_label !== nothing
        attrs *= " role=\"img\" aria-label=\"$(_attr_escape(aria_label))\""
    end
    # Byte count, not `length`: with multi-byte UTF-8 in the root tag, `length`
    # lands short of the match end and re-emits the trailing `>`.
    string(SubString(s, 1, m.offset - 1), "<svg", attrs, ">",
           SubString(s, m.offset + ncodeunits(m.match)))
end

# `add_class` and `aria_label` land inside "…" attrs.
_attr_escape(s::AbstractString) =
    replace(String(s), "&" => "&amp;", "\"" => "&quot;", "<" => "&lt;", ">" => "&gt;")
