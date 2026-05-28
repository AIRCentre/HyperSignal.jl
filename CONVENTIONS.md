# Conventions

How HyperSignal.jl code reads. Each convention: **Why** → **Convention** → ✅ Do
/ 🚫 Don't, tagged by severity:

- `[sec]` — break this and the library ships a vulnerability.
- `[corr]` — break this and code is wrong (alloc blow-up, regression, crash).
- `[style]` — break this and the codebase loses cohesion; reviewers will ask.
- `[taste]` — preference with a reason; deviate if you have a better one.

## Disagreement

- **Disagree? Open a GitHub issue, don't silently break the convention.**
  `[meta]`

  **Why:** silent violations + secret forks of style are how a doc dies — the
  convention rots, the violator resents the doc, reviewers play whack-a-mole.

  **Convention:** if you think a convention is wrong, costly, or stale, open an
  issue titled `Convention: <convention title> — proposal` with the case
  (concrete code, measured cost, alternative wording). PRs welcome that edit
  both the convention _and_ its enforcing test in the same commit.

  - ✅ "the `ds_` prefix collides with our new domain helper `ds_locale`;
    proposing rename to `signal_`" — concrete, names cost, suggests fix.
  - 🚫 land a PR that breaks a convention without raising it — review will bounce
    you and the next contributor cargo-cults your shortcut.

## Prose style

Applies to every `.md` in the repo (this file, `README.md`, `CHANGELOG.md`,
`docs/`) _and_ every code comment / docstring in `src/`, `ext/`, `test/`.

- **Telegraphic style. Sacrifice grammar for concision.** `[style]`

  **Why:** full sentences with articles + linking verbs add token weight without
  adding signal; readers scan, they don't read.

  **Convention:** drop articles ("the", "a") and linking verbs ("is", "are")
  where meaning survives. Fragments OK. `→` and `=` over "leads to" / "means".
  One idea per bullet. If a sentence reads fine with words removed, remove them.

  - ✅ "render once, at IO boundary".
  - ✅ "macros = parse-time dialect, fight tooling".
  - ✅ "`Raw` wraps trusted HTML you audited".
  - 🚫 "We should make sure that the render function is called only one time at
    the IO boundary of the system" — verbose padding.
  - 🚫 narrative paragraphs in code comments — break into fragments or delete.

## Staleness-proof

Applies to every `.md` + every code comment / docstring.

- **Describe behavior, not snapshots.** `[style]`

  **Why:** "currently 2 extensions" / "as of v0.3" rots on next commit.

  **Convention:** prose states invariants. Counts, dates, versions, file lists,
  "currently"/"as of" → generated output (`Project.toml`, `git log`), never
  prose.

  - ✅ "optional integrations live under `ext/`" — invariant.
  - 🚫 "the two extensions are Makie and MapLibre" — count rots.
  - 🚫 "since PR #29" / "as of 2026-Q2" — embed behavior; `git log` carries
    provenance.

- **Every convention names its failure mode.** `[taste]`

  **Why:** convention without a _why_ gets deleted next refactor; bug class
  resurfaces.

  **Convention:** **Why** names a concrete failure (XSS, alloc blow-up,
  SyntaxError, piracy regression). No nameable failure → not load-bearing →
  don't write it.

  - ✅ "unescaped user input = #1 XSS vector".
  - 🚫 "for consistency" / "cleaner" — unfalsifiable.

- **Examples use public API only.** `[corr]`

  **Why:** `Do:` calling `_init_js(...)` rots on rename; readers copy broken
  code.

  **Convention:** `Do:` / `Don't:` use exported names (or documented
  `Base.get_extension`). No underscore helpers, no struct internals, no private
  modules.

  - ✅ `render(card("x", "y"))`.
  - 🚫 `el.attrs[1]` — internals shift.

- **Convention change = test change, same commit.** `[corr]`

  **Why:** prose-only conventions are advisory; the `test/runtests.jl` grep is
  what survives contributors.

  **Convention:** tightening, loosening, removing → touch the enforcing test (or
  add one) in the same commit.

  - ✅ new `Don't:` + grep test that fails on the pattern.
  - 🚫 reword a convention, leave the test banning the old phrasing.

- **`CHANGELOG.md` = one entry per user-visible diff.** `[style]`

  **Why:** "refactor map_view" tells consumers nothing about upgrade safety.

  **Convention:** one entry = one observable change for a caller (new export,
  changed signature, dropped behavior, fixed bug). Zero-caller-effect refactors
  → no entry.

  - ✅ "`map_view` now accepts `click_post=nothing` to opt out of click POSTs".
  - 🚫 "cleaned up extension internals" — invisible.
  - 🚫 paste of a commit subject — rewrite from caller POV.

- **`README.md` code blocks run on `main` as-is.** `[corr]`

  **Why:** aspirational examples referencing unreleased APIs = README lies =
  burned first-time users.

  **Convention:** every fenced block runs end-to-end on `main` with only obvious
  placeholders (`/your/path`, `YOUR_TOKEN`) filled in. Else → `docs/` under
  "Planned", or delete.

  - ✅ imports only symbols exported on `main`.
  - 🚫 showcase a branch-only helper — link from CHANGELOG once merged.

## Composition

- **Components = plain functions returning `Element` / `Frag`.** `[style]`

  **Why:** plain functions compose by call + dispatch; tests read `@test
  render(card("x","y")) == "..."` with no setup.

  **Convention:** reusable UI = `f(args; kwargs...) -> Element`. Never macro,
  struct, or callable object.

  - ✅ `card(title, body) = article(class="card", h2(title), body)`.
  - 🚫 `Card` struct + `Base.show(::IO, ::MIME, ::Card)` — piracy on `Base.show`
    shapes.

- **Render once, at the IO boundary.** `[corr]`

  **Why:** internal `String(take!(io))` explodes allocations on hot paths and
  breaks streaming SSE.

  **Convention:** compose at Element-tree level. `render(x)` runs exactly once,
  where a `String` must leave the system (HTTP body, file write, SSE frame).

  - ✅ handlers return `Element`; response layer renders.
  - 🚫 `render(inner)` then splice the string into an outer Element.

## Safety

- **All text auto-escapes on render.** `[sec]`

  **Why:** unescaped interpolation of user input = #1 XSS vector in hypermedia
  stacks.

  **Convention:** pass `String`s as children/attrs; renderer escapes. Your code
  never does.

  - ✅ `p(user.name)` — renderer handles `<`, `&`, quotes.
  - 🚫 pre-`replace` / pre-`escape_html` before passing in.

- **`Raw(...)` is the only escape hatch.** `[sec]`

  **Why:** every bypass = potential XSS hole. Surface must be small, named,
  grep-able.

  **Convention:** `Raw` wraps trusted HTML you audited (SVG, vendored icons,
  generator output). Never anything user-derived.

  - ✅ `Raw(read("logo.svg", String))` — vendored asset.
  - 🚫 `Raw(user_html)` / `Raw("<div>$untrusted</div>")`.

- **JS interpolation → renderer or `JSON.json`, never raw `$`.** `[sec]`

  **Why:** hand-built JS strings drop auto-escape; `"alert('$name')"` becomes
  code-exec the moment `name` contains `'`, `\`, or newline.

  **Convention:** a Julia value reaches JS via (a) `DSAction` / `Attribute`
  helper rendered by `render`, or (b) `JSON.json(value)` into a `Raw`/script
  string. Julia `$x` into JS literal = forbidden, "safe-looking" or not.

  - ✅ `on(:click, ds_post("/api/x", (id=user.id,)))`.
  - ✅ `Raw("$(handle).setZoom($(JSON.json(zoom)))")` — value via JSON.json.
  - ✅ `Raw("$(handle).addSource($(JSON.json(id)), $(JSON.json(spec)))")` — id
    _and_ payload JSON-encoded.
  - 🚫 `Raw("<button onclick=\"submit($(user.id))\">")`.
  - 🚫 `Raw("$(handle).setZoom($zoom)")` even when `zoom::Int` — later
    type-loosening silently reopens the hole.
  - 🚫 `Raw("$(handle).setLayer(\"$id\")")` — `id` with `"` or `\` breaks the
    literal; use `JSON.json(id)`.
  - 🚫 pre-stringify via `string(x)` / `repr(x)` and splice — only JSON survives
    every nesting level.

## Naming

- **HTML tag constructors mirror HTML exactly.** `[style]`

  **Why:** HTML-fluent readers read Julia source without a glossary.

  **Convention:** one tag = one lowercase function: `div`, `h1`, `form`, `svg`,
  …

  - ✅ `div(class="card", h1("Title"))`.
  - 🚫 `Div`, `make_div`, `tag(:div, ...)`.

- **Datastar helpers carry `ds_` prefix.** `[style]`

  **Why:** prefix marks "Datastar action/attribute/signal binding" without
  scanning the implementation.

  **Convention:** every Datastar helper exported from `src/datastar.jl` starts
  `ds_`: `ds_post`, `ds_signal`, `ds_indicator`, `ds_bind`, …

  - ✅ `ds_signal("count", 0)`.
  - 🚫 `signal("count", 0)` — collides with Base + domain code.

- **Event binders = `on(:event, action)` returning `Attribute`.** `[style]`

  **Why:** attribute helpers must drop in positionally without kwarg-splat
  dance, so generators / conditional bindings stay one-liners.

  **Convention:** event-binding helpers return `Attribute`; element constructor
  lifts into attrs list.

  - ✅ `button(on(:click, ds_post("/x")), "Go")`.
  - 🚫 `button("Go"; "data-on:click" => "@post('/x')")`.

## Packaging

- **`Manifest.toml` is not checked in.** `[corr]`

  **Why:** library → consumers resolve their own deps; committed manifest pins
  their world to ours.

  **Convention:** `.gitignore` excludes `/Manifest.toml` and every nested
  `*/Manifest.toml` (`docs/`, `benchmark/`, `examples/`).

  - ✅ commit `Project.toml` only.
  - 🚫 `git add -f Manifest.toml` to "make CI reproducible".

- **Optional integrations = package extensions under `ext/`.** `[corr]`

  **Why:** extensions gate heavy deps (Makie, GeoInterface) on `using`.
  Importing HyperSignal stays light for consumers that don't need them.

  **Convention:** integration requiring a third-party package lives in
  `ext/HyperSignal<Name>Ext.jl` with trigger package in `[weakdeps]` +
  `[extensions]`.

  - ✅ `HyperSignalMakieExt` (gated on `Makie`), `HyperSignalMapLibreExt` (gated
    on `GeoInterface`).
  - 🚫 hard-import optional deps from `src/`.

## JS-emitting code (extensions, server-returned scripts)

- **Script bodies = plain JS; Datastar tokens stay in attribute
  expressions.** `[corr]`

  **Why:** browser parses `<script>` as JS — `@post(...)` = SyntaxError on `@`;
  `ctx.$signal` = ReferenceError. Datastar parses those tokens only inside
  `data-on:* / data-effect / data-text` attribute values. Applies to
  initial-render scripts _and_ SSE-returned `text/javascript` run via
  `executeScript`.

  **Convention:** anything between `<script>...</script>`, or returned with
  `Content-Type: text/javascript`, must parse as standard JS. Datastar-only
  tokens (`@post`, `@get`, `@put`, `@delete`, `ctx`, `evt`, `$<name>`) forbidden
  in that string; they belong in `data-*` attribute values.

  - ✅ container: `data-on:click__window="$x = evt.detail; @post('/url')"`.
  - ✅ script: `document.dispatchEvent(new CustomEvent('hs-x', {detail: v}))`.
  - ✅ script: `window.__hs_maps[prefix].flyTo({...})` — map by published handle,
    no Datastar tokens.
  - 🚫 `script(Raw("@post('/url')"))` — `@` = JS syntax error.
  - 🚫 `script(Raw("ctx.\$x = 1"))` — `ctx` undefined in script body.
  - 🚫 `script(Raw("\$count = 0"))` — `$count` = JS identifier referring to
    nothing; signal init belongs in `data-signals`.
  - 🚫 emit `@post(...)` from `text/javascript` SSE and expect Datastar to
    interpret it — `executeScript` `eval`s as JS.

- **Bridge external scripts to Datastar via CustomEvent (props down, events
  up).** `[corr]`

  **Why:** Datastar v1 exposes no global signal-write API; per [the JS
  guide][ds-js], the only bridge = dispatch CustomEvents that
  `data-on:<event>__window` catches.

  **Convention:** one CustomEvent per logical channel, dispatched on `document`,
  name `hs-<id_prefix><channel>`, payload on `detail`. Component server-renders
  matching `data-on:hs-…__window` on its container; that expression does the
  signal write and/or `@post`.

  - ✅ script: `document.dispatchEvent(new CustomEvent("hs-m_center", {detail:
    [lng, lat]}))`.
  - ✅ container: `data-on:hs-m_center__window="$map_center = evt.detail"`.
  - ✅ action channels = signal + post: `data-on:hs-m_click__window="$_payload =
    evt.detail; @post('/api/click')"`.
  - ✅ omit the listener attr entirely when the kwarg is `nothing` — opt-out path
    doesn't leak a `@post` to an undefined URL.
  - 🚫 single shared `hs-signal` event with `detail.name` — expressions can't
    switch on `evt.detail.name` cleanly; one-event-per-channel = grep-able
    wiring.
  - 🚫 dispatch on container when listener uses `__window` (or vice versa) —
    event + modifier must agree.
  - 🚫 hand the user a `window.__hs_signals` cache to read — out-of-band,
    Datastar can't react.
  - 🚫 hard-code event name `hs-center` without `id_prefix` — two maps on one
    page race on every moveend.

- **JS identifier slots → `JSON.json`, not raw `$interp`.** `[sec]`

  **Why:** `"$id"` breaks the JS string on any `"` or `\` in `id` — script
  corruption at best, code injection at worst.

  **Convention:** every value inside a JS string literal serialized via
  `JSON.json(value)` — ids, layer names, prop names, URLs.

  - ✅ `"$(handle).addSource($(JSON.json(id)), $(JSON.json(spec)))"`.
  - 🚫 `"$(handle).addSource(\"$id\", ...)"`.

- **Lazy-init shared `window.*` namespaces before first write.** `[corr]`

  **Why:** `window.__hs_maps[prefix] = _m` on a fresh page = TypeError because
  `__hs_maps` undefined; script aborts before publishing the handle; every
  downstream helper fails.

  **Convention:** first emit into any shared `window.*` slot guards with
  `window.X = window.X || {}` (or equivalent).

  - ✅ `window.__hs_maps = window.__hs_maps || {}; window.__hs_maps[$prefix] =
    _m;`.
  - 🚫 assume the slot exists at load time.

## Testing

- **Testset names describe observable behavior, not the function
  tested.** `[taste]`

  **Why:** failing-test report reads as broken guarantees, not implementation
  details — easier triage, survives internal renames, forces naming the behavior
  before writing the assertion.

  **Convention:** `@testset` strings = full sentences, present tense, stating
  what the code _does_ from the caller's view. Name the input shape and output
  guarantee. If guarding a specific footgun, say so.

  - ✅ `"auto-escapes text content so user input can never break out"`.
  - ✅ `"<form> auto-injects data-on:submit__prevent when no submit binding is
    given"`.
  - ✅ `"match requires a default — silent fallthroughs are a footgun"`.
  - ✅ `"interpolate with zero stops fails loud"` — names the failure mode.
  - ✅ `"opting out of click_post emits no queryRenderedFeatures call"` —
    explicit negative guarantee.
  - 🚫 `"test_escape"` / `"escape works"` / `"basic test"` — says nothing about
    _what_ is true.
  - 🚫 `"match() function"` / `"_init_js helper"` — names implementation; rename
    = stale.
  - 🚫 `"#29 regression"` / `"PR #42"` — issue numbers rot; embed the _behavior_
    the regression broke.
  - 🚫 two unrelated behaviors in one testset; sentence needs an "and" → split.

- **Tests reach only through the public interface.** `[corr]`

  **Why:** black-box tests survive refactors; private-helper tests turn every
  cleanup into a test-rewrite and lock in implementation choices the public API
  never promised.

  **Convention:** construct via exported names (or
  `Base.get_extension(HyperSignal, :…)` for an extension's public surface).
  Observe via `render(...)` or returned values; assert on rendered string /
  returned value. Never struct fields, leading-underscore helpers, unexported
  modules. Exception: a helper explicitly named `_internal` _and_ covered by its
  own unit testset its public callers can rely on; even then, no public-API test
  reaches it directly.

  - ✅ `render(MapLibre.map_view(...))` then `@test occursin("data-on:hs-…",
    out)`.
  - ✅ `render(card("x", "y"))` and assert on the HTML string.
  - ✅ pull extension publics via `Base.get_extension(HyperSignal,
    :HyperSignalMapLibreExt).map_view`.
  - ✅ assert on `JSON.json(value)` round-tripping a `DSAction` — `JSON.lower` is
    a documented contract.
  - 🚫 `MapLibre._init_js(...)` — internal.
  - 🚫 `el.attrs`, `el.children`, `frag.children` — struct internals.
  - 🚫 `using HyperSignal: _make_element` — underscore name.
  - 🚫 monkeypatch `Base.show` for a fixture type to test rendering — render the
    real component.
  - 🚫 re-implement the renderer in tests to compare ASTs; compare the rendered
    string.

- **JS-emitting tests assert via string inspection; `node` =
  local-debug only.** `[corr]`

  **Why:** baking `node --check` into the suite = undeclared toolchain dep +
  silent-skip path with zero CI coverage when node is absent.

  **Convention:** suite runs with Julia + declared `Project.toml` deps only.
  Verify emitted JS at the shell with `node` during dev, then translate findings
  into `@test occursin(...)` / `@test !occursin(...)`.

  - ✅ `@test !occursin("@post(", js)` and `@test
    occursin("data-on:hs-click__window=", out)`.
  - 🚫 `success(pipeline(\`node --check $path\`))`inside`@test`.

- **Every comment in a test body answers "why this test exists".** `[taste]`

  **Why:** the assertion already says _what_; only the rationale survives the
  next refactor and tells the next reader whether the test is still
  load-bearing.

  **Convention:** if you comment in a test, start with `Why:` and name the
  failure mode guarded.

  - ✅ `# Why: an empty ramp is meaningless and silently renders nothing.`
  - 🚫 `# Test that interpolate works.`

## Out of scope

- **No template DSL macros.** `[taste]`

  **Why:** macros add a parse-time dialect diverging from plain Julia, fight IDE
  tooling, resist refactor.

  **Convention:** if `func(args; kwargs...)` doesn't read well, the component is
  too big — split.

  - 🚫 `@html"<div>$x</div>"` or any string-macro DSL.

- **No client-side state machine.** `[corr]`

  **Why:** HyperSignal is hypermedia-first: state on the server, page =
  projection, divergent client state = the bug class the whole stack exists to
  avoid.

  **Convention:** signals carry UI-local _view_ state — things the server
  doesn't need, that vanish on refresh. Anything persistable, queryable, or
  auditable round-trips through the server.

  - ✅ `ds_signal("drawer_open", false)` — pure UI affordance.
  - ✅ `ds_signal("active_tab", "overview")` — view selection.
  - ✅ `ds_signal("map_center", [0, 0])` — derived from a live UI event.
  - ✅ `ds_signal("_payload", nothing)` — short-lived buffer for the next
    `@post`.
  - 🚫 `ds_signal("cart", [...])` — business state; POST adds, server sends back
    the rendered cart.
  - 🚫 `ds_signal("user", {...})` — identity belongs in the session.
  - 🚫 model multi-step form progress as a client-side enum branching
    rendering — each step = a server response.
  - 🚫 cache server data in a signal "so we don't re-fetch" — re-fetch via
    `@get`; server decides what's fresh.

- **No type piracy.** `[corr]`

  **Why:** Hyperscript broke on Julia 1.6 due to `Vector{Node}` piracy
  ([Hyperscript#24][hs24]);
  lesson = keep dispatch inside our type wall so a Base / third-party update
  can't silently rewrite our semantics.

  **Convention:** a method defined under `HyperSignal` (or any extension)
  dispatches on at least one HyperSignal-owned type. Owned = `Element`, `Frag`,
  `Raw`, `Attribute`, `DSAction` (extensions own structs they define:
  `MapLibreExpr`, `Source`, `Layer`).

  - ✅ `Base.show(io::IO, ::MIME"text/html", el::Element) = …` — owned type in
    signature.
  - ✅ `JSON.lower(e::MapLibreExpr) = e.value` — owned by extension.
  - ✅ `render(io, x::Raw)` — owned type.
  - 🚫 `Base.length(::Vector{Pair{Symbol,Any}}) = …` — no owned type.
  - 🚫 `JSON.lower(d::Dict{String, Any}) = …` — `Dict` isn't ours; even innocuous
    body, convention = "no method without an owned type".
  - 🚫 `Base.string(::AbstractString) = …` — strings aren't ours.
  - 🚫 method on `Base.show` for `MIME"text/html"` of a third-party struct to
    "make it render" — wrap in `Raw` or `Element` instead.

- **No `@generated` + `hasmethod`.** `[corr]`

  **Why:** both individually risky; combo broke HypertextLiteral across Julia
  bumps ([HTL#28][htl28], [HTL#33][htl33]).

  **Convention:** plain methods, concrete signatures. Dispatch needs branching →
  write the branches by hand.

  - 🚫 `@generated f(x) = hasmethod(g, Tuple{typeof(x)}) ? :(g(x)) : :(h(x))`.

Both bans are CI-enforced (grep over `src/` + `ext/` in `test/runtests.jl`)
because each came from a real broken-on-upgrade incident ([hs24], [htl28],
[htl33]) and we don't want a third. Disagree? See [Disagreement](#disagreement).

[hs24]: https://github.com/JuliaWeb/Hyperscript.jl/issues/24
[htl28]: https://github.com/JuliaPluto/HypertextLiteral.jl/issues/28
[htl33]: https://github.com/JuliaPluto/HypertextLiteral.jl/issues/33
[ds-js]: https://data-star.dev/guide/datastar_expressions_javascript
