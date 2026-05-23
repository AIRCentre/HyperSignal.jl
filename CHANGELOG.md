# Changelog

All notable changes to this project are documented here. Format roughly
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added
- `Base.show(::IO, ::MIME"text/html", ::Element|::Frag|::Raw)` so trees
  render directly in Pluto / IJulia / VS Code without per-cell
  `render(...)` calls.
- `Base.show(::IO, ::MIME"text/plain", ::Element|::Frag)` for
  REPL-friendly inspection.
- `benchmark/` subproject with `BenchmarkTools` covering render of
  small fragments, 50-row tables, 100-field forms, adversarial escape
  input, and `patch_svg` on synthetic 200- and 1000-path SVGs.
- Stress tests: 5000-deep nesting, 2000-attribute element,
  ~470KB synthetic SVG patching, 9KB metacharacter round-trip parity,
  and one canonical fixture pinned across `MIME"text/html"`,
  `MIME"text/plain"`, and `html_response(...).body`.
- `precompile()` block in the module top so the first `render(...)` in
  a user's session doesn't pay JIT cost for the common shapes.

### Changed
- `escape_html` walks codeunits and emits runs of safe bytes via a
  single `unsafe_write`, only branching at the five HTML
  metacharacters. ~30–50% faster on realistic markup.
- `BenchmarkTools` is no longer a runtime dep — moved to the
  `benchmark/` subproject.

### Fixed
- `patch_svg(...; id_prefix=p)` with a backslash in `p` would corrupt
  output because the prefix was spliced into a `SubstitutionString`
  template. The prefix is now escaped before splicing; pinned with a
  test exercising both `$` (literal in Julia `SubstitutionString`)
  and `\\` (needs escaping).
- `DSAction` string extras only escaped single quotes; a value with a
  backslash silently became a JS escape character, and a `</script>`
  substring could close an enclosing `<script>` tag. Now escapes
  backslash, single-quote, and `</` in that order — same hardening
  already applied to `redirect_via_fragment`.
- `radio_field`'s docstring was attached to the preceding internal
  helper instead of the public function. Moved so `@doc radio_field`
  resolves and the API page renders it.

### Docs
- Documenter-driven docs site (`docs/`) with index, CairoMakie guide,
  and a full API reference. Built and deployed in CI via
  `.github/workflows/Docs.yml`. Live at
  <https://aircentre.github.io/HyperSignal.jl/>.

### Added (later)
- `missing` is now treated like `nothing` in attribute values
  (omitted). Lets `value = optional_string()` flow into attr position
  without the caller juggling a coalesce.
- `parse_signals(::IO)` accepts a plain `IO` (e.g. an `IOBuffer`
  around a gzip-decoded body) alongside the existing
  `HTTP.Request` / `Vector{UInt8}` / `AbstractString` methods.
- `.JuliaFormatter.toml` so a `JuliaFormatter` pass is a no-op on
  `main` and contributor formatting stays stable.
- Doctests enabled in the Documenter build. Canonical examples for
  `render`, `cls`, `patch_svg`, `ds_get`, and `ds_post` are now
  `jldoctest` blocks, so any drift between the docs and behavior is
  caught on every doc build.
- `Base.show(::IO, ::Element|::Frag|::Raw)` 1-arg method, so
  `string(el)`, `print(io, el)`, and `"$(el)"` interpolation all
  return the rendered HTML instead of a struct dump. Vectors of
  elements print as readable markup too.
- `SubString{String}` arguments to `escape_html` now use the same
  codeunit fast path as `String`, so an interpolated text slice
  doesn't fall back to the per-`Char` loop.
- `parse_signals` raises a labeled `ArgumentError` on malformed JSON
  with a truncated body snippet, so a panicked handler log names the
  origin of the failure instead of just relaying JSON.jl's
  position-tagged message.
- `docs/make.jl` now uses `Remotes.GitHub(...)` for the `repo` arg,
  silencing the Documenter "Unable to determine the repository
  root URL" warning.
- `Vector{UInt8}` is now rendered as a verbatim byte buffer (one
  `write`), and `_make_element` keeps byte buffers as a single child
  instead of unpacking each `UInt8` into a per-byte Number. Lets a
  caller drop a pre-rendered HTML cache between ordinary children
  without going through `Raw(String(...))`.
- `examples/counter_app.jl` — a 50-line Datastar counter app that
  exercises `html_response`, `fragment_response`, `on_click` +
  `ds_post`, and the `datastar-selector` morph header in the smallest
  pasteable shape. Linked from the README.
- `examples/cairomakie_dashboard.jl` — two CairoMakie figures on one
  page through `inline_svg`, proving the id-prefix story.
  `examples/Project.toml` bundles HTTP + CairoMakie so the examples
  run with `julia --project=examples` without polluting the
  package's main dep tree.
- Aqua-style sanity tests using stdlib `Test.detect_ambiguities` /
  `Test.detect_unbound_args` and a walk over `names(HyperSignal)` to
  confirm every exported name resolves to a defined binding. No new
  dep; same guarantee an Aqua test would catch.
- `Base.show(::IO, ::MIME"text/plain", ::Raw)` so `DOCTYPE` and other
  `Raw` values inspect at the REPL as `HyperSignal.Raw: <…>` instead
  of a struct dump.
- Stress tests for `SubString` escape: slice landing on
  metacharacters at both ends, and a slice past a multi-byte UTF-8
  codepoint, both render byte-stable.

### Perf
- `patch_svg`'s id-namespacing now walks the SVG once with a single
  alternation regex instead of four sequential `replace` passes.
  Measured: `patch_svg` on a 200-path SVG drops from ~180µs to
  ~130µs (-27%), and on a 1000-path SVG from ~880µs to ~630µs (-28%).
  Same output; pinned by the existing tests including the prefix
  backslash / dollar reliability cases.

### Security
- Reject attribute-name `Symbol`s that contain parser-breaking
  characters (whitespace, `<`, `>`, `"`, `'`, `/`, `=`, NUL). Without
  this, a hostile `Symbol` key from user input (rare but possible via
  the Pair-attrs path) could introduce a real attribute mid-tag.
  The check is cached per Symbol so the amortized cost is zero on
  the bounded attribute-name vocabulary the lib actually uses.
- Same validation applied to tag names. `Element(Symbol(...), ...)`
  is the documented escape hatch for runtime-chosen tags; without
  validation `Symbol("<script>")` would smuggle markup into the
  open tag. Empty tag names also rejected. Cached the same way.
- New [Security](https://aircentre.github.io/HyperSignal.jl/security)
  docs page documenting every escape boundary the lib draws: child
  text, attribute values, attribute and tag *names*, the `Raw` /
  `Vector{UInt8}` opt-outs, CairoMakie inlining, Datastar JS, and
  the security-disclosure address.
- `redirect_to` example converted to `jldoctest`, pinning the 303
  status, Location header, and Set-Cookie attachment shape.
- Precompile statements expanded to cover the methods added across
  recent iterations: `SubString` escape fast-path, `Vector{UInt8}`
  render, `Missing` render, name validation, `html_response` /
  `fragment_response`, `patch_svg` / `inline_svg`, and
  `parse_signals` of bytes / string.
- Benchmark suite extended with `response` and `signals` groups:
  `html_response` of a small fragment lands at ~460 ns,
  `fragment_response` at ~670 ns, `parse_signals` at ~640 ns for a
  4-key body and ~5 µs for 50 keys. README perf table updated.
- `cls("a", 1)` previously stack-overflowed: the iterator fallback
  walked any non-collection input, and `Number` is a 1-iterable in
  Julia (yields itself) — instant infinite recursion. The walk is
  now restricted to `AbstractVector` / `Tuple` / `NamedTuple` /
  `AbstractSet`, and other types hit a clear `cls: don't know how
  to handle …` error.
- `on(:event, action; …)` docstring converted to `jldoctest` for
  the four canonical modifier shapes: bare, `:submit` auto-prevent,
  `prevent=false` opt-out, and the `__window` modifier. Pins the
  attribute-name format so a regression in the modifier-stack
  ordering breaks the doc build immediately.
- String-keyed `Pair` positional args are now accepted as attributes
  alongside Symbol-keyed ones, so `div("data-foo" => "v")` works
  symmetric with `div(Symbol("data-foo") => "v")`. Previously the
  String-keyed form silently became a child and MethodError'd at
  render time. The render-time attribute-name validation still
  fires, so this is a syntactic relaxation only.
- `Base.show(::IO, ::DSAction)` returns the JS expression, so
  `string(ds_post("/x"))` is `"@post('/x')"` instead of a struct
  dump. Symmetric with the Element/Frag/Raw show methods — every
  HyperSignal value `string`s to what the lib would put in the page.
- Vector attribute values are now space-joined: `class=["btn",
  "primary"]` emits `class="btn primary"` instead of dumping the
  Vector repr. `nothing` / `missing` / `false` / `true` / empty
  entries drop, so the natural Julia idiom
  `class=["btn", is_active && "active"]` works without coalesce
  gymnastics — `cond && "x"` returns `false` when `cond` is false,
  and the renderer treats that as "skip" instead of emitting the
  literal text "false". Works for any space-separated attribute
  (`aria-describedby`, Datastar lists).
- `inline_svg(::AbstractString)` docstring example converted to
  `jldoctest`, pinning the wrap-in-Raw + aria_label shape.
- Bool children now render as nothing, symmetric with the attr-
  vector treatment from the previous entry. Means `div(header,
  cond && extra, footer)` works for conditional rendering without
  having to write `cond ? extra : nothing` at every call site.
  Passing `string(b)` still emits the literal text if needed.
- Symbol children render as their text — status enums like
  `span(:Pending)` now Just Work, where they used to raise a
  MethodError. Same auto-escape pass as String children.
- `Tuple` attribute values space-join the same as `AbstractVector`,
  so `class=("btn", "primary")` is symmetric with the bracket form.
  Same `nothing` / `missing` / `false` / `true` / empty filtering.
- `Tuple`-of-children unpacks at element construction the same as a
  `Vector` does, so `div((span("a"), span("b")))` works alongside
  `div([span("a"), span("b")])`. Both shapes show up in real code
  (destructure targets, splat receivers, heterogeneous
  comprehensions) and the previous behavior was a MethodError at
  render time.
- `Base.Generator` children also unpack — `div(p(i) for i in 1:n)`
  now Just Works. Consumed eagerly so the element survives multiple
  renders (generators are single-pass).
- A `Base.Generator` that reaches render time (e.g. nested inside
  a Vector — `div([gen1, gen2])`) is now iterated by the render
  walker. Closes the last MethodError path on the generator surface.
- `html_response` and `fragment_response` docstrings converted to
  `jldoctest`. Pins the status code, `Content-Type: text/html; …`
  header, body rendering, custom-headers passthrough, and the
  `datastar-selector` header on `fragment_response` — five
  invariants any consumer relies on, now checked on every doc build.
- `radio_field` and `checkbox_field` docstring examples converted
  to `jldoctest`. Pins the exact `<label><input …> text</label>`
  shape, including the leading space before the visible text and
  the bare `checked` attribute on truthy values.
- Tag constructor set extended to cover the rest of HTML5 in
  common use: `noscript`, `wbr`, `tfoot`, `caption`, `colgroup`,
  `col`, `address`, `optgroup`, `datalist`, `blockquote`,
  `mark`, `kbd`, `samp`, `var`, `cite`, `q`, `b`, `i`, `s`,
  `sub`, `sup`, `meter`, `output`, `data`, `time`, `audio`,
  `video`, `picture`, `source`, `track`, `iframe`, `embed`,
  `object`, `param`, `area`, and the common SVG primitives
  (`rect`, `line`, `ellipse`, `polyline`, `g`, `defs`, `use`).
  `mark` and `time` clash with `Base.mark` and `Base.time`, so
  they join `div`/`select`/`summary` in the `_BASE_SHADOWED`
  set — pull them in with `@using_tags`. `<map>` and `<base>`
  are deliberately omitted (`Base.map`, `Base.base` are too
  load-bearing to shadow); use `Element(:map, …)` / `Element(:base, …)`
  at the call site that needs them. Behavioral test set pins the
  rendered shape for the most user-facing additions (`blockquote`,
  `audio`+`controls`, `iframe`, `kbd`, `b`, `i`, `sub`, `sup`,
  `wbr` as void, `caption`, `meter`, qualified `mark`/`time`, and
  SVG primitives composed inside `svg(...)`).
- `examples/Manifest.toml` added to `.gitignore` so a contributor
  running `julia --project=examples examples/counter_app.jl` doesn't
  end up staging the generated manifest.
- `docs/src/api.md` now includes the module-level docstring under
  "Module overview", removing the Documenter "1 docstring not
  included in the manual" warning.

## 0.1.0 — 2026-05-23

Initial public release.

- Streaming Element tree (`Element`, `Frag`, `Raw`, `DOCTYPE`) with
  auto-escape, void-tag handling, boolean-attribute semantics, and
  `Frag` for wrapper-less grouping.
- Typed Datastar actions: `ds_get` / `ds_post` / `ds_put` /
  `ds_delete`, bound via `on` / `on_click` / `on_submit` /
  `on_change_debounced` / `on_interval`. Modifiers: `debounce`,
  `window`, `prevent`, `stop`, `outside`.
- Full Datastar attribute helpers: `ds_indicator`, `ds_ignore_morph`,
  `ds_bind`, `ds_signal`, `ds_signals`, `ds_show`, `ds_text`, `ds_ref`,
  `ds_attr`, `ds_class`, `ds_effect`, `ds_init`.
- `parse_signals(req | bytes | string)` to decode JSON-mode signal
  payloads into a `Dict{String, Any}`.
- Response wrappers: `html_response`, `fragment_response`,
  `redirect_via_fragment`, `redirect_to`.
- Component helpers: `cls`, `radio_field`, `checkbox_field`,
  `text_field`, `help_tooltip`, `form_legend`, `form_section`,
  `preset_button`, `signal_dialog`, `@using_tags` macro.
- `patch_svg` / `inline_svg` for CairoMakie-style SVG inlining: strips
  XML prologs and DOCTYPE, namespaces ids and `url(#…)` / `href="#…"`
  references, drops hard-coded `width`/`height`, adds `role="img"` +
  `aria-label`.
- `HyperSignalMakieExt` package extension: `inline_svg(::Figure |
  ::Scene | ::FigureAxisPlot)` renders to SVG via the active Makie
  backend and patches in one call.
