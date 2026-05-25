# HyperSignal.jl

[![CI](https://github.com/AIRCentre/HyperSignal.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/AIRCentre/HyperSignal.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://AIRCentre.github.io/HyperSignal.jl/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Datastar-flavored HTML for Julia, with front-row support for inlining
CairoMakie figures into your pages. Build hypermedia UIs that read
top-to-bottom and stay out of the way.

```julia
using HyperSignal
using HyperSignal.Helpers: radio_field      # app-grade helpers live here
HyperSignal.@using_tags                       # brings div, select, summary

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

html_response(page)                           # HTTP.Response, text/html
fragment_response(page, "#card")              # Datastar morph w/ selector header
```

## Install

```julia
] add https://github.com/AIRCentre/HyperSignal.jl
```

A General-registry release is planned; once published you'll be able to
`] add HyperSignal`.

## Why

A common pattern in Julia web services is hand-built HTML through long
`print(io, "...")` chains. That works, but every page accumulates
papercuts:

- Hand-typed `data-on:submit="@post('/path', {contentType: 'form'})"` strings —
  one typo and the form silently does nothing.
- Manual `html_escape` on every interpolated value, easy to forget.
- Every fragment route repeats the `"datastar-selector" => "#foo"` header.
- The "redirect from a Datastar submit" pattern is copy-pasted as a `<script>` tag.
- Per-file ad-hoc helpers (`print_radio`, `print_checkbox`, …) drift apart.

HyperSignal keeps the IO-streaming model (no big tree allocations on hot paths),
adds auto-escape, and turns Datastar attributes into typed values that you
build with named functions instead of strings.

## API at a glance

```julia
using HyperSignal
HyperSignal.@using_tags

page = html(lang="en",
    head(title("Validation Studio")),
    body(
        article(class="card",
            h2("Start a session"),
            form(on(:submit, ds_post("/session/new"; form=true)),
                 on_change_debounced(ds_get("/api/session/count"; form=true)),
                 fieldset(
                     legend("Confidence"),
                     label(input(type="radio", name="confidence", value="all", checked=true), " All"),
                     label(input(type="radio", name="confidence", value="medium"), " Medium"),
                 ),
                 button("Start", type="submit"),
            ),
        ),
    ),
)

html_response(page)
```

`on(:submit, …)`, `on_change_debounced(…)`, and `ds_indicator()` drop in
as positional arguments — they return `Attribute` values, and the
element constructors lift them out of the children list automatically.

Same idea for a fragment response that targets a morph point:

```julia
fragment_response(div(id="count-estimate", small("~$(format_number(n)) images")),
                  "#count-estimate")
```

## CairoMakie inlining

Inlining a Makie SVG into an HTML page sounds trivial — until two
figures share a page and CairoMakie's `clip0` / `glyph0` ids collide,
the embedded XML prolog trips the HTML parser, and the hard-coded px
sizes refuse to scale. `inline_svg` solves all three:

```julia
using HyperSignal, CairoMakie

fig = Figure()
lines(fig[1, 1], 1:10, rand(10))

div(class="card",
    h2("Random walk"),
    inline_svg(fig; id_prefix="fig1_", aria_label="Random walk over 10 steps"))
```

What you get:

- **No XML prolog / DOCTYPE** — both are invalid inside HTML and will
  trip the parser.
- **No `width` / `height`** by default — `viewBox` survives, so the
  figure scales to its CSS container. Pass `strip_size=false` to keep them.
- **Prefixed ids** — every `id="…"`, `url(#…)`, and `href="#…"` is
  rewritten with `id_prefix`, so you can drop two figures on one page
  without `clip0`s clashing.
- **Accessibility** — `aria_label` adds `role="img"` and the label
  attribute so screen readers announce the figure as one image.

Makie support is loaded as a [package extension][ext] — `HyperSignal`
itself stays a small HTML lib and does not pull a plotting stack. The
typed entry point activates automatically as soon as the caller has
`Makie` (or a backend like `CairoMakie`) in their session.

[ext]: https://pkgdocs.julialang.org/v1/creating-packages/#Conditional-loading-of-code-in-packages-(Extensions)

You can also patch an SVG string directly without going through Makie:

```julia
svg = read("plot.svg", String)
patched = patch_svg(svg; id_prefix="fig1_", aria_label="Sales by quarter")
article(h2("Q4"), Raw(patched))
```

## Design

- **Element tree (data) + `render(io, x)` (streaming).** Components return
  `Element` values you can compose, test, and inline; rendering streams to IO
  with auto-escape — no intermediate strings.
- **Datastar actions are values.** `ds_post("/x"; form=true)` builds a
  `DSAction` struct. `on(:submit, action)` returns an `Attribute` you drop in
  positionally — the element constructor lifts it out of children into attrs,
  no splat. The renderer formats the JS expression once, in one place.
- **Auto-escape by default; `Raw("…")` to opt out.** No more sprinkling
  `html_escape` calls and hoping you got them all.
- **Boolean attribute semantics that match HTML.** `checked=true` → bare
  attribute; `checked=false` or `nothing` → omitted. Lets you write
  `checked = is_selected(opt)` directly.
- **`Frag(…)` for grouping without a wrapper.** Useful when a component
  needs to return multiple siblings.

## Safety model

Every escape boundary in one paragraph:

- **Element text content** and **attribute values** are auto-escaped
  at render time. The five HTML metacharacters (`<`, `>`, `&`, `"`,
  `'`) get entity-encoded; the codeunit-fast-path walker keeps this
  branch-free on the safe-byte runs.
- **Attribute and tag *names*** that contain parser-breaking chars
  (whitespace, `<`, `>`, `"`, `'`, `/`, `=`, NUL) raise
  `ArgumentError`. There is no escape syntax for names; rejecting
  them is the only correct option. The check is cached by `Symbol`
  identity, so the amortized cost is zero.
- **`Raw(...)` is the only opt-out.** SVG icons, audited HTML
  generators, the output of `patch_svg` / `inline_svg`. Never wrap
  user input.
- **`Vector{UInt8}`** renders as a verbatim byte buffer — same trust
  model as `Raw`. The common case is a pre-rendered, cached HTML
  fragment.
- **Datastar JS extras** (string values inside `ds_post("/x"; foo=...)`)
  are escaped against `\`, `'`, and `</script>` before going into the
  attribute, so a user-supplied option value can't break out of the
  JS string or the wrapping `<script>` tag.

Full write-up: [Security page of the docs site][docs-security].

[docs-security]: https://aircentre.github.io/HyperSignal.jl/

## What it deliberately doesn't do

- No client-side templating, hydration, or virtual DOM. The whole point of
  Datastar is that the server owns state and ships HTML. This lib stays in
  that lane.
- No CSS-in-Julia. Use a stylesheet.
- No macro DSL. Function calls compose better and play nicely with multiple
  dispatch and IDE tooling.

## Component helpers

App-grade form/dialog helpers live in `HyperSignal.Helpers`. `cls` and
`redirect_to` stay at the top level (they're primitives, not app
idioms).

```julia
using HyperSignal.Helpers: radio_field, checkbox_field, form_section,
                            form_legend, preset_button

# Conditional classes — replaces `class="card $(active ? "active" : "")"`.
button("Save", class=cls("btn", "primary", "active" => is_active))

# Form fields with label-around-input wrapping.
fieldset(
    legend("Color"),
    radio_field("color", "red", "Red"; checked=picked == "red"),
    radio_field("color", "blue", "Blue"; checked=picked == "blue"),
)

checkbox_field("agree", "I agree to the terms"; checked=true)

# Single-event Datastar bindings read better as on_click / on_submit.
button("Dismiss", on_click(ds_post("/api/dismiss")))

# Plain HTTP redirects for non-Datastar flows (login, logout).
redirect_to("/dashboard"; cookies=["sid=$(token); HttpOnly; Path=/"])

# Form scaffolding — section header + card grid in one call.
form_section("Image Batch",
    article(fieldset(
        form_legend("Size"; tooltip="Number of images to review."),
        radio_field("target_count", "10", "10"),
        radio_field("target_count", "25", "25"; checked=true),
        radio_field("target_count", "50", "50"),
    )))

# Preset buttons that flip a set of radios and fire a change event.
preset_button("Easy", ["confidence" => "all", "label_filter" => "both"])
```

## Layout — built from primitives, not a `page_layout` helper

Real-world page layouts are heavily project-specific (which CDN, which
fonts, which footer copy, which favicons). A one-size-fits-all
`page_layout` helper would either be too rigid or balloon into a
configuration object that's worse than just composing primitives.

The lib exposes one tiny `DOCTYPE` constant — the only truly invariant
prelude — and lets consumers build their layout from the AST tags
directly.

## Prior art

Two existing Julia packages cover adjacent ground. Both were considered
as bases for this work; the Datastar use case ruled them out.

### [Hyperscript.jl](https://github.com/JuliaWeb/Hyperscript.jl) (JuliaWeb)

Mature `m("div", ...)` / `@tags` DSL with HTML, SVG, scoped CSS, and
unit arithmetic. The natural answer to "build HTML in Julia" — and a
strong default for most projects.

**Why it isn't the base here:** Hyperscript transforms attribute names
(camelCase → kebab-case, with hyphens inserted at special-char
transitions) before emit. That's helpful for ordinary HTML but
**actively breaks Datastar's wire-format attribute names**:

```julia
# Hyperscript:
button("Click"; Symbol("data-on:click") => "@post('/x')")
# → <button data-on-:click="...">                    ⚠ extra hyphen
button("Click"; Symbol("data-on:change__debounce.300ms") => "@get('/c')")
# → <button data-on-:change-_-_debounce-.300ms="..."> ⚠ multiple injections
```

Datastar's client binds on the exact attribute names — mangled names
are silently ignored. HyperSignal emits attribute names verbatim,
which is the property Datastar requires.

### [HypertextLiteral.jl](https://github.com/JuliaPluto/HypertextLiteral.jl) (JuliaPluto)

`@htl("<tr><td>$(book.name)…")` macro-template style with
context-sensitive auto-escape. Strong fit for Pluto notebooks.

**Why it isn't the base here:** the value-add here is *typed Datastar
actions* (`on(:click, ds_post(...))`, `ds_indicator()`) that compose
with element constructors and enforce escaping at the attribute
boundary. That doesn't translate well to a string-template macro —
you'd be shipping JS strings inside `$(...)` interpolations again,
which is what the `DSAction` type exists to avoid.

### Relationship to Datastar

At the time of writing no other Julia binding for
[Datastar](https://data-star.dev) exists — the official SDK list covers
13 languages but Julia is absent. The Datastar layer in this package
(`DSAction`, `ds_get` / `ds_post` / `ds_put` / `ds_delete`, `on` /
`on_click` / `on_submit` / `on_change_debounced` / `on_interval`,
`ds_indicator` / `ds_bind` / `ds_signal` / `ds_signals` / `ds_show` /
`ds_text` / `ds_ignore_morph`, `ds_ref` / `ds_attr` / `ds_effect` /
`ds_init`, `parse_signals`, `fragment_response` /
`redirect_via_fragment`) is the actual novel surface — the AST, render,
and form helpers exist to serve it.

## Signals: encoding and decoding

Datastar signals round-trip between server-rendered HTML and the
browser through two surfaces: an attribute on the seed element
(`data-signals='{...}'`) and a request body when an action fires
without `contentType: 'form'` (a JSON object the server reads).

```julia
# Encode: seed several signals from a NamedTuple — the lib JSON-encodes it
# once and lets the renderer's attribute escape handle the `"` round-trip.
div(ds_signals((showDetails=false, count=0)),
    span(ds_show("\$showDetails"), "Details…"))
# → <div data-signals='{"showDetails":false,"count":0}'>…</div>

# Decode: parse the JSON body of a non-form action, get a Dict back.
function handle_increment(req::HTTP.Request)
    sig = parse_signals(req)        # Dict{String, Any}
    n = Int(get(sig, "count", 0)) + 1
    fragment_response(div(id="counter", n), "#counter")
end
```

For form-mode submits (`@post('/x', {contentType: 'form'})`), parse the
body with your service's form parser — that wire format and the
JSON-mode signals payload are distinct.

## Runnable example

A 50-line Datastar counter app lives in
[`examples/counter_app.jl`](examples/counter_app.jl):

```bash
julia --project=examples examples/counter_app.jl
# → serving on http://127.0.0.1:8080
```

It uses every part of the public surface — `html_response`,
`fragment_response`, `on_click(ds_post(...))`, fragment morph via the
`datastar-selector` header — in the smallest pasteable shape.

A CairoMakie dashboard with two figures on one page lives in
[`examples/cairomakie_dashboard.jl`](examples/cairomakie_dashboard.jl) —
the proof that `inline_svg(::Figure)` lets two plots share a page
without `clip0` / `glyph0` collisions.

## Notebook display

`Element`, `Frag`, and `Raw` define `Base.show(::IO, ::MIME"text/html", …)`,
so they render directly in Pluto, IJulia, and any editor pane that
picks up the `text/html` MIME. No `render(...)` boilerplate per cell.

## Running the tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Benchmarks

The renderer is on the request-handler hot path; a self-contained
benchmark suite lives in `benchmark/` so regressions are catchable.

```bash
julia --project=benchmark benchmark/runbench.jl
```

Indicative numbers on a typical workstation (`v0.1.0`):

| benchmark                           | time      |
|-------------------------------------|-----------|
| render small fragment               | ~290 ns   |
| render 50-row table                 | ~14 µs    |
| render 100-field form               | ~24 µs    |
| escape 10k adversarial chars        | ~48 µs    |
| `html_response` of a small fragment | ~460 ns   |
| `fragment_response` with selector   | ~670 ns   |
| `patch_svg` on a 200-path SVG       | ~130 µs   |
| `patch_svg` on a 1000-path SVG      | ~630 µs   |
| `parse_signals` of a 4-key body     | ~640 ns   |
| `parse_signals` of a 50-key body    | ~5 µs     |

## Contributing

Issues and PRs welcome. Conventions live in [CONVENTIONS.md](CONVENTIONS.md).

## License

[MIT](LICENSE)
