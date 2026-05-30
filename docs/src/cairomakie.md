# CairoMakie inlining

Inlining a Makie SVG into an HTML page sounds trivial — until two
figures share a page and CairoMakie's `clip0` / `glyph0` ids collide,
the embedded XML prolog trips the HTML parser, and the hard-coded px
sizes refuse to scale. [`inline_svg`](@ref) solves all three.

## Quick start

```julia
using HyperSignal, CairoMakie
HyperSignal.@using_tags  # brings the Base-shadowed `div`, `select`, ... into scope

fig = Figure()
lines(fig[1, 1], 1:10, rand(10))

div(class="card",
    h2("Random walk"),
    inline_svg(fig; id_prefix="fig1_", add_class="plot", aria_label="Random walk over 10 steps"))
```

With `strip_size` on by default, `add_class="plot"` lets the figure fill
its container via plain CSS, e.g. `.plot { width: 100%; }`.

## Signature

```julia
patch_svg(svg; id_prefix="", strip_size=true, add_class=nothing, aria_label=nothing) -> String
inline_svg(svg::AbstractString; kwargs...)   # = Raw(patch_svg(svg; kwargs...))
inline_svg(figure; kwargs...)                # Makie Figure / Scene / FigureAxisPlot (extension)
```

Defaults: ids are **not** namespaced unless you pass `id_prefix`; size
**is** stripped unless you pass `strip_size=false`; `add_class` and
`aria_label` are off unless set.

## What `inline_svg` does

| Concern                          | Default behavior                                         |
|----------------------------------|----------------------------------------------------------|
| XML prolog / DOCTYPE             | stripped — both are invalid inside HTML                  |
| Comments                         | stripped (combined into the same pass)                   |
| `width` / `height` on root `<svg>` | stripped (so the figure scales to its CSS container) — pass `strip_size=false` to keep them |
| `add_class=`                     | appended to the root `<svg>`'s `class` (merged with any existing class); the value is escaped so it can't break out of the attribute |
| Internal ids                     | rewritten with `id_prefix` so two figures on one page don't collide on `clip0` / `glyph0` |
| `url(#…)`, `xlink:href="#…"`, `href="#…"` | rewritten with the same prefix                     |
| Accessibility                    | `aria_label=` adds `role="img"` and the label so screen readers announce the figure |

The id rewrite is narrow: it touches only bare `id="…"` attributes and
`#`-fragment references (`url(#…)`, `href="#…"`, `xlink:href="#…"`).
Namespaced or compound attributes such as `xml:id`, `data-id`, and other
`*-id` forms are left untouched, so hand-authored SVGs keep their
semantic ids.

## Without Makie

You can also patch an SVG string directly:

```julia
svg = read("plot.svg", String)
patched = patch_svg(svg; id_prefix="fig1_", aria_label="Sales by quarter")
article(h2("Q4"), Raw(patched))
```

## How it's wired

Makie support lives in a [package extension][ext]
(`HyperSignalMakieExt`) — `HyperSignal` itself stays a small HTML lib
and does not pull a plotting stack. The typed entry point activates
automatically as soon as the caller has `Makie` (or a backend like
`CairoMakie`) in their session. No extra import needed.

[ext]: https://pkgdocs.julialang.org/v1/creating-packages/#Conditional-loading-of-code-in-packages-(Extensions)
