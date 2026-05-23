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
  MIME show round-trip parity.
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
