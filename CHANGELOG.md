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
