# Conventions

Library-specific rules for HyperSignal.jl.

## Composition

- **Components are functions returning Elements.** Not macros, not classes.
  A "card" is `card(title, body) = article(class="card", h2(title), body)`.

  > Plain functions compose by call; multiple dispatch is available; tests
  > read like `@test render(card("x", "y")) == "..."` without setup.

- **Streaming over assembling.** Render at the IO boundary; compose at the
  Element-tree level. Don't `String(take!(...))` in the middle of a component
  — `render(x)` does that exactly once, at the service boundary, when you
  have to hand a String to an HTTP body.

  > Keeps allocation counts predictable on hot paths.

## Safety

- **All text is auto-escaped.** Pass strings, not pre-rendered HTML.
- **`Raw(...)` is the only escape hatch.** Use it for SVG snippets,
  icon libraries, or third-party HTML you've audited. Never wrap user
  input.
- **JS string interpolation is the renderer's job.** Build a `DSAction`
  and let `render` format it. Never concatenate user input into JS by
  hand.

## Naming

- Tag constructors mirror HTML names exactly: `div`, `h1`, `form`, …
- Datastar helpers use the `ds_*` prefix: `ds_post`, `ds_indicator`,
  `ds_bind`.
- Event binders use `on(:event, action)` — returns an `Attribute` value
  that drops in positionally; the element constructor lifts it into the
  attrs list, no splat.

## Packaging

- `Manifest.toml` is *not* checked in — this is a library, consumers
  resolve their own dep graph.
- Optional integrations live as package extensions under `ext/`.
  Currently: `HyperSignalMakieExt` for CairoMakie SVG inlining.

## Out of scope

- No template DSL macros. If `func(args; kwargs...)` doesn't read well,
  the component is too big — split it.
- No client-side state machine. State lives on the server; the page is
  a projection.
- **No type piracy.** A method on a `Base` (or third-party) type that
  HyperSignal does not own is forbidden. Owned types: `Element`,
  `Frag`, `Raw`, `Attribute`, `DSAction`. `Base.show` methods on these
  are fine; `Base.<anything>(::Vector{...})` or similar is not.
  Reason: Hyperscript broke on Julia 1.6 because of `Vector{Node}`
  piracy ([JuliaWeb/Hyperscript.jl#24](https://github.com/JuliaWeb/Hyperscript.jl/issues/24));
  the lesson is to keep dispatch boundaries inside our own type wall.
- **No `@generated` + `hasmethod`.** Both are individually risky, and
  the combination is what broke HypertextLiteral across Julia
  version bumps ([JuliaPluto/HypertextLiteral.jl#28](https://github.com/JuliaPluto/HypertextLiteral.jl/issues/28),
  [#33](https://github.com/JuliaPluto/HypertextLiteral.jl/issues/33)).
  Prefer plain methods with concrete signatures.

Both bans are enforced by a test in `test/runtests.jl` that greps
`src/` and `ext/`; any new occurrence fails CI.
