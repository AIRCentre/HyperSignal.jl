# Changelog

All notable changes to this project are documented here. Format roughly
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added
- `ds_computed(name, expr)` — declare a read-only derived signal
  (`data-computed:<name>`); `ds_style(prop, expr)` — bind an inline CSS
  style property reactively (`data-style:<prop>`), the natural partner to
  `ds_class` / `ds_attr`; and `ds_json_signals()` (+ a filter overload) —
  the bare `data-json-signals` in-page signal-store debugger. All three are
  FREE-tier Datastar v1.0 attributes that previously had no first-class
  helper. (exported)

### Fixed
- **Thread-safe validator caches.** `_VALID_TAG_NAMES` / `_VALID_ATTR_NAMES`
  were plain `Set{Symbol}` mutated lock-free on every tag/attribute render.
  Under multithreaded `HTTP.serve`, concurrent `push!` into a cold cache
  races a `rehash!` that swaps the backing arrays non-atomically — which can
  **corrupt the cache (poisoning later validations) or segfault the
  process**, not merely "duplicate work" as the old comment claimed. Both
  caches are now a copy-on-write `_NameCache` (lock-free atomic-snapshot read
  on the hot path, copy-and-swap under a lock on a cold miss); the warm read
  path is unchanged (~1 ns).
- **`preset_button` now escapes `'` in a preset value.** The whole
  `querySelector('…')` selector is a single-quoted JS string, so a value like
  `it's` closed it early and made the generated `onclick` a `SyntaxError`
  (the preset silently did nothing). `_escape_preset_value` escaped only `"`
  and `\`; it now escapes `'` too. `preset_button` also rejects a non-CSS-
  identifier name (digit-leading, e.g. `name=123`) at build time rather than
  emitting an `input[name=123]` selector that throws in the browser.
- **`patch_svg` id-namespacing no longer rewrites `data-id` / `xml:id` /
  `aria-id`.** The `_ID_RE` matcher used a bare `\b` word boundary, so under
  `id_prefix` it mutated the values of any `*-id` / `xml:id` attribute, not
  just the SVG `id`. Anchored to a name-char boundary (`(?<![\w:-])`).
- **`ds_signal` now emits the keyed `data-signals:<name>` form** (colon,
  plural). It previously rendered the singular `data-signal-<name>`, which
  is not a Datastar v1.0 attribute — Datastar matched no plugin and ignored
  it, so the signal was **never created** (a silent client-side no-op, the
  exact failure class this library exists to prevent). Datastar's
  kebab→camel mapping still applies (`ds_signal("my-signal", …)` → `$mySignal`).
- **JS line terminators are now escaped in the single-quoted JS string**
  built by `action_js` (the URL and every string `extras` value) and by
  `redirect_via_fragment` (which shares `_js_str_escape`). A raw LF, CR,
  U+2028, or U+2029 — reachable via a reflected query param or a multi-line
  search box — is an ECMAScript `SyntaxError`, so the whole Datastar action
  (or inline-`<script>` redirect) silently failed to compile. The escapes
  round-trip to the same character after JS parsing, so the fetched
  URL / navigated location is unchanged. Mirrors the SSE path's existing
  CR/LF defenses.
- **`DSAction` extras with a structured value** (`headers=Dict(...)`,
  `filterSignals=(include=...)`, array-valued options) now serialize as a
  JSON object/array literal — valid JS — instead of Julia's `repr`, which
  is not (`Dict("a"=>"b")` had rendered as `Dict{String,…}(...)`).
- **`_js_value` renders non-finite floats as JS globals** `Infinity` /
  `-Infinity` / `NaN` instead of Julia's `Inf` / `-Inf` (a bare `Inf` is a
  JS `ReferenceError`). Relevant to numeric action options such as
  `retryMaxCount=Inf`.
- `_validate_preset_name` now anchors with `\z`, not `$`. PCRE `$` also
  matches just before a trailing `\n`, so a preset name like `"foo\n"` slipped
  past the CSS-identifier check and landed a raw newline in the
  `querySelector` selector (silently breaking the handler in the browser).

### Changed
- **An `Attribute` that reaches `render` as a child now raises an actionable
  `ArgumentError`** naming the fix (splat the collection) instead of an opaque
  internal `MethodError`. `_make_element` only lifts an `Attribute` into attrs
  when it is a *top-level* positional arg; nesting one inside a
  `Vector`/`Tuple`/`Generator` (e.g. collecting attrs into a vector as
  `signal_dialog` does, then forgetting to splat) previously failed deep in
  the renderer.
- **A caller-supplied header no longer double-emits.** Every response helper
  (`html_response`, `fragment_response`, `signals_response`,
  `script_response`, `redirect_*`, `sse_response`, `sse_stream`) prepended
  its library-owned `Content-Type` (and the SSE trio) then appended the
  caller's `headers`, so a caller passing their own `Content-Type` (custom
  charset, `application/problem+json`, …) put **two** `Content-Type` lines on
  the wire — a malformed message whose interpretation diverges across
  consumers. A new `_with_default` skips the library default when the caller
  already supplied that field (matched case-insensitively); the caller wins,
  with exactly one header. The default path is byte-identical.
- `parse_signals` now throws `ArgumentError` (not the bare `ErrorException`
  from `error()`) for a top-level non-object JSON body, matching the
  malformed-JSON path — both bad-request-body cases now raise one
  consistent type. `cls` (bad `Pair` value / unhandled type) and
  `preset_button` (invalid input name) likewise now throw `ArgumentError`
  rather than a bare `error()`, so every caller-input mistake in the library
  raises one consistent exception type. The SSE `selector` CR/LF rejection
  message is now prefixed (`patch_elements:`) and echoes the offending value,
  matching the rest of the library's error messages.
- Internal, no behavior change: the render hot path streams `DSAction`
  attributes straight into the response `IO` (dropping a throwaway
  intermediate `String` that `escape_html` then re-walked); `escape_html`
  is split into concrete `String` / `SubString{String}` methods so the
  per-child dispatch lands directly (no runtime `isa` ladder); `is_void` is
  hoisted to one lookup per element; and the tag/attribute name validators
  share one `_is_invalid_name_byte` predicate.

### Docs
- `security.md` now lists the full `DSAction` JS-string escape set — the four
  JS line terminators (`LF`, `CR`, `U+2028`, `U+2029`) alongside the original
  `'` / `\` / `</` — and drops the now-incorrect "triple-escape" wording.

## 0.3.1 — 2026-05-29

Documentation-only release; no code changes since 0.3.0.

### Docs
- New **MapLibre** guide (`docs/src/maplibre.md`, added to the nav)
  covering the 0.3.0 extension end to end: loading the weakdep-gated
  extension, `map_view` / `marker`, sources, layers, the
  paint-expression DSL, the GeoInterface bridge, and the
  server-returned JS helpers. The extension shipped in 0.3.0 with no
  docs page.
- `api.md` now indexes `sse_stream` and `DATASTAR_SUPPORTED_VERSION`
  (both exported in 0.3.0 but previously only `@ref`'d, leaving the
  cross-references dangling); `security.md` documents that
  `patch_svg`'s `add_class` / `aria_label` are attribute-escaped onto
  the root `<svg>`.
- Fixed stale copy: the home page described CairoMakie-only support and
  the pre-0.3.0 slider demo; the Datastar page's response table called
  SSE a "future" shape though `sse_response` / `sse_stream` are already
  documented there.
- The Install snippet is now build-context-aware — tagged-version docs
  show `] add HyperSignal` (registered in General), while the `dev`
  docs keep the Git-URL install for unreleased `main`.

## 0.3.0 — 2026-05-29

### Changed
- `fragment_response` now accepts `mode` and `view_transition` kwargs,
  surfacing the Datastar v1.0.1 `datastar-mode` and
  `datastar-use-view-transition` response headers. `selector` is now a
  keyword too; the positional `fragment_response(body, selector)` form
  is preserved. Unknown `mode` symbols throw `ArgumentError`. The
  `docs/src/datastar.md` page gains an HTML section covering every
  mode value and a `view_transition` example. (#17)

### Added
- `HyperSignalMapLibreExt` — a reactive MapLibre map surface, gated on
  the `GeoInterface` weakdep (top-level `HyperSignal` exports nothing
  new; reach the API via `Base.get_extension`). Ships `map_view` and
  `marker`; `geojson_source` / `raster_xyz_source`; `fill_layer` /
  `line_layer` / `circle_layer` / `raster_layer`; the paint-expression
  DSL (`prop_get`, `interpolate`/`linear`, `expr_step`, `expr_match`,
  `literal`); a GeoInterface bridge (`geojson`, `feature_collection`);
  and server-returned-JS helpers (`fly_to`, `add_source`,
  `remove_source`, `set_source_data`, `add_layer`, `remove_layer`,
  `set_paint_property`, `map_call`). Viewport/cursor channels bridge to
  Datastar via `CustomEvent` + `data-on:*__window` attributes;
  shift-drag posts a bbox, clicks post `queryRenderedFeatures`. Pinned
  `maplibre-gl@5.24.0` (JS/CSS/LICENSE) is vendored under
  `docs/src/notebooks/assets/maplibre/`; the basemap streams live from
  `demotiles.maplibre.org`. `docs/src/notebooks/example.jl` is rewritten
  as the SST map-as-input demo (fill polygons recolored via
  `set_source_data`, drag-rect timeseries, camera nav via `fly_to`) and
  `map_smoke.jl` is the CI smoke fixture. (#29)
- `sse_stream(f; status, headers)` — streaming SSE handler for
  long-running tasks. Returns an HTTP.jl stream handler (use with
  `HTTP.serve(...; stream=true)`); `f` receives a `writer` that
  encodes a `patch_elements` / `patch_signals` event and flushes it
  as one chunk so progress reaches the client in real time. Shares
  the SSE encoder and headers with `sse_response`. Recipe in
  `docs/src/datastar.md`. (#20)
- `sse_response(events; status, headers)` plus the two event
  constructors `patch_elements(body; selector, mode, view_transition)`
  and `patch_signals(signals; only_if_missing)` — the buffered
  `text/event-stream` shape that lets a handler emit an HTML patch and
  a signal patch in one response. Lives in new `src/sse.jl`; covered
  in `docs/src/datastar.md` and `docs/src/security.md`. Streaming
  (long-lived connections) is out of scope. (#19)
- `signals_response(signals; only_if_missing, status, headers)` and
  `script_response(js; script_attributes, status, headers)` — the two
  non-streaming Datastar v1.0.1 response shapes (JSON signals patch,
  `text/javascript` script). New `docs/src/datastar.md` page covers
  both. (#18)
- `DATASTAR_SUPPORTED_VERSION = v"1.0.1"` constant (exported) pinning
  the Datastar protocol/client version HyperSignal targets. Examples
  reference the constant instead of hard-coding the literal so future
  bumps land as a single visible diff.
- GeoJSON support for `MultiPoint` / `MultiLineString` / `MultiPolygon` /
  `GeometryCollection` in the MapLibre `GeoInterface` bridge — previously
  only Point/Line/Polygon were handled and everything else hit a bare
  `MethodError` (MultiPolygon is coastline / EEZ-boundary data, core to an
  ocean org). Unsupported traits now raise a named `ArgumentError`.
  `feature_collection` emits `"geometry": null` (GeoJSON RFC 7946 §3.2) for
  rows whose geometry is missing/`nothing` instead of crashing the whole
  collection. (#39)

### Fixed
- **Void elements given children now throw** (`br`, `img`, `input`, …)
  instead of emitting invalid `<br>x</br>`. Browsers reparent such
  "children" as siblings, diverging the server HTML from the client DOM and
  breaking Datastar's morph idempotency; the error fires before any bytes are
  written, matching the existing tag/attr-name validation. (#39)
- **Duplicate attribute names now collapse last-wins** via `_dedup_attrs`
  (stable first position, last value). HTML5 §13.2.5.33 keeps the *first*
  duplicate, so the previous double-emit silently used the earlier value,
  defeating the library's documented "later wins" intent. (#39)
- `patch_svg`'s root-tag rewrite resumes past the matched `<svg>` by
  `ncodeunits` (bytes) rather than `length` (chars); a multi-byte UTF-8
  character inside the tag had been re-emitting a stray `>`. (#39)
- The SSE encoder now treats CR and CRLF as line terminators alongside LF
  (per the EventSource spec) — a lone CR previously truncated a data line
  silently. (#39)

### Security
- `patch_svg`'s `add_class` is now attribute-escaped in `_patch_root_svg`.
  An unescaped `"` closed the `class="…"` attribute and injected attributes
  onto the root `<svg>` (e.g. `add_class='x" onload="alert(1)'`) — now
  symmetric with the already-escaped `aria_label`. (#39)
- `action_js` now JS-string-escapes the URL, not just `extras` values; a raw
  `'` from an unencoded query param closed the JS string and broke the
  action. The escape is factored into `_js_str_escape`, reused by `_js_value`
  and `response.jl`'s `_js_escape` (one source of truth). (#39)

## 0.2.0 — 2026-05-26

### Removed
- **Breaking:** `div`, `select`, `summary`, `mark`, `time` are no longer
  in HyperSignal's `export` list. `using HyperSignal` no longer brings
  them into scope. Pull them in with `HyperSignal.@using_tags` (the
  documented idiom) or `using HyperSignal: div, …` explicitly. Rationale:
  these names shadow Base / Makie; a plain `using HyperSignal` was
  already ambiguous, so making the user opt in via `@using_tags` removes
  the foot-gun.

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
  MIME show round-trip parity.
- `precompile()` block in the module top so the first `render(...)` in
  a user's session doesn't pay JIT cost for the common shapes.
- `jldoctest` in `Element`'s docstring pinning the boolean-attribute
  policy (`true` → bare, `false`/`nothing`/`missing` → omitted, other →
  quoted+escaped) so a regression fails doc-build.
- Adversarial `jldoctest` on `Raw`'s docstring (`<img src=x
  onerror=alert(1)>`) proving the lib does NOT re-escape `Raw` —
  any "auto-escape Raw" regression fails CI.
- `docs/src/performance.md`: regeneratable benchmark page with
  workload definitions, indicative numbers from v0.1.0, and the
  `julia --project=benchmark benchmark/runbench.jl` regen command.
  Linked in `docs/make.jl` between Security and API reference.
- Pluto demo notebook `docs/src/notebooks/example.jl`: end-to-end
  SST/CairoMakie/Datastar demo. Vendored NOAA ERSSTv5 North Atlantic
  netCDF + vendored Datastar runtime under
  `docs/src/notebooks/assets/`. Five Datastar-bound sliders drive a
  local Julia HTTP route that area-weights `cos(lat)`, smooths, and
  re-renders a timeseries + heatmap server-side via CairoMakie's
  `inline_svg` (with `id_prefix` to disambiguate the two SVGs). A
  `fragment_response("#figs")` morphs both figures atomically. Map
  shows the selected box outlined plus an Azores marker.
- Thin CI smoke fixture `docs/src/notebooks/smoke.jl`: just Pkg setup,
  `@using_tags`, and `div(class="card", "hello")`. The
  `pluto-smoke` workflow now evaluates this notebook (instead of the
  full demo) and asserts the `text/html` MIME body, so CI catches
  regressions in `Base.show(::IO, ::MIME"text/html", ::Element)` in
  seconds rather than minutes. Eval script at
  `.github/scripts/pluto_smoke.jl`.
- Type-piracy + `@generated`/`hasmethod` audit pinned as a test in
  `runtests.jl`. Greps `src/` and `ext/`; any future occurrence
  fails CI. Owned types (`Element`, `Frag`, `Raw`, `Attribute`,
  `DSAction`) whitelist the `Base.show` methods we legitimately
  define. Both bans also documented under `CONVENTIONS.md` → "Out
  of scope" with the prior-art references that motivated them
  (Hyperscript#24, HypertextLiteral#28/#33).
- `test/escape_conformance.jl`: adversarial HTML5 escape suite
  covering the five metacharacters in both text and attribute
  positions, NUL in attribute name (rejected) / value / text (passed
  through), CR/LF in attributes, mixed UTF-8 + metacharacters, and a
  10 KiB safe-run-with-embedded-escapes stress. Every case
  cross-checks against `EzXML.parsehtml` so the assertions match
  what a real HTML5 parser sees, not a regex. EzXML is `[extras]`-
  only — not a runtime dep.

### Changed
- **Breaking:** app-grade helpers moved to a new `HyperSignal.Helpers`
  submodule — `radio_field`, `checkbox_field`, `text_field`,
  `help_tooltip`, `form_legend`, `form_section`, `preset_button`,
  `signal_dialog`. `cls` and `redirect_to` stay at the top level
  (primitives, not app idioms). Update sites with
  `using HyperSignal.Helpers: …`. No deprecation shim — the package
  is pre-1.0 with no registered users, so an outright move was
  cheaper than a deprecation cycle. Rationale: keep the v1.0 surface
  small; prior-art lesson — Hyperscript / HypertextLiteral calcified
  app idioms into their public surface and could not evolve.
- `escape_html` walks codeunits and emits runs of safe bytes via a
  single `unsafe_write`, only branching at the five HTML
  metacharacters. ~30–50% faster on realistic markup.
- `BenchmarkTools` is no longer a runtime dep — moved to the
  `benchmark/` subproject.
- Security docs: `Raw`-is-the-only-escape-hatch callout promoted to
  the top of *Element text content* so the contract is the first
  thing a reader sees.

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
