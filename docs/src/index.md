# HyperSignal.jl

Datastar-flavored HTML for Julia, with front-row support for inlining
CairoMakie figures into your pages.

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

```julia
] add https://github.com/AIRCentre/HyperSignal.jl
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
- [API reference](api.md) — every exported name, with examples.
- [`example.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/example.jl)
  — a runnable Pluto notebook: NOAA ERSSTv5 North Atlantic SST loaded
  from a vendored netCDF, five Datastar-bound sliders, and a local Julia
  HTTP route that slices, smooths, and re-renders the figures with
  CairoMakie on every drag.
  [`smoke.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/smoke.jl)
  is the thin fixture the [`pluto-smoke`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/.github/workflows/pluto-smoke.yml)
  CI workflow asserts on.
- The [GitHub repo](https://github.com/AIRCentre/HyperSignal.jl)
  for issues, PRs, and the changelog.

## License

MIT. See the [`LICENSE`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/LICENSE)
file.
