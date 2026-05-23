# CairoMakie inlining

Inlining a Makie SVG into an HTML page sounds trivial — until two
figures share a page and CairoMakie's `clip0` / `glyph0` ids collide,
the embedded XML prolog trips the HTML parser, and the hard-coded px
sizes refuse to scale. [`inline_svg`](@ref) solves all three.

## Quick start

```julia
using HyperSignal, CairoMakie

fig = Figure()
lines(fig[1, 1], 1:10, rand(10))

div(class="card",
    h2("Random walk"),
    inline_svg(fig; id_prefix="fig1_", aria_label="Random walk over 10 steps"))
```

## What `inline_svg` does

| Concern                          | Default behavior                                         |
|----------------------------------|----------------------------------------------------------|
| XML prolog / DOCTYPE             | stripped — both are invalid inside HTML                  |
| Comments                         | stripped (combined into the same pass)                   |
| `width` / `height` on root `<svg>` | stripped (so the figure scales to its CSS container) — pass `strip_size=false` to keep them |
| Internal ids                     | rewritten with `id_prefix` so two figures on one page don't collide on `clip0` / `glyph0` |
| `url(#…)`, `xlink:href="#…"`, `href="#…"` | rewritten with the same prefix                     |
| Accessibility                    | `aria_label=` adds `role="img"` and the label so screen readers announce the figure |

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
