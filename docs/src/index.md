# HyperSignal.jl

Datastar-flavored HTML for Julia, with front-row support for inlining
CairoMakie figures and driving interactive MapLibre maps from your
pages.

Compatible with Datastar v1.0.1.

```julia
using HyperSignal
using HyperSignal.Helpers: radio_field
HyperSignal.@using_tags

page = Frag(DOCTYPE,
    html(lang="en",
        head(meta(charset="UTF-8"), title("My App")),
        body(
            h1("Hello"),
            form(on_submit(ds_post("/save"; form=true)),
                 radio_field("size", "S", "Small"),
                 radio_field("size", "L", "Large"; checked=true),
                 button("Save", type="submit")),
        )))

html_response(page)
```

## Install

```@eval
using Markdown
# On a tagged-version docs build the registered package is the right
# install. The `dev` docs track unreleased `main`, which can be ahead of
# the registry, so they point at the Git URL instead.
tagged = startswith(get(ENV, "GITHUB_REF", ""), "refs/tags/")
prose = tagged ?
    "HyperSignal is registered in Julia's General registry — install it with:" :
    "These are the development docs for the unreleased `main`. Install the latest commit with:"
cmd = tagged ? "] add HyperSignal" :
               "] add https://github.com/AIRCentre/HyperSignal.jl"
Markdown.MD(Markdown.parse(prose).content..., Markdown.Code("julia", cmd))
```

## Design in one paragraph

Element tree (data) + `render(io, x)` (streaming): components return
`Element` values you can compose, test, and inline; rendering streams
to IO with auto-escape — no intermediate strings. Datastar actions
are typed values; the element constructors lift `Attribute`-returning
helpers (`on(:click, ds_post(…))`, `ds_indicator()`, …) out of the
children list, so they drop in positionally without a splat ceremony.
Auto-escape by default; `Raw("…")` is the only opt-out — never wrap
user input.

## Where next

- [CairoMakie inlining](cairomakie.md) — drop figures into pages.
- [MapLibre maps](maplibre.md) — render a map and drive it from the
  server: viewport / cursor / click / drag-box as signals, recolor and
  fly back with JS snippets.
- [Datastar response shapes](datastar.md) — the HTML / JSON / JS / SSE
  responses a handler returns.
- [API reference](api.md) — every exported name, with examples.
- [`example.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/example.jl)
  — a runnable Pluto notebook: NOAA ERSSTv5 North Atlantic SST loaded
  from a vendored netCDF, rendered as a MapLibre map of per-cell mean
  SST. Date sliders `@post` a range and get a `set_source_data` recolor
  back; a shift-drag box posts `{w, s, e, n}` and gets a CairoMakie
  timeseries.
  [`smoke.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/smoke.jl)
  is the thin fixture the [`pluto-smoke`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/.github/workflows/pluto-smoke.yml)
  CI workflow asserts on.
- The [GitHub repo](https://github.com/AIRCentre/HyperSignal.jl)
  for issues, PRs, and the changelog.

## License

MIT. See the [`LICENSE`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/LICENSE)
file.
