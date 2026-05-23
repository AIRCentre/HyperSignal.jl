# Security model

HyperSignal is an HTML-output library. The single most important
question for one is: *what happens to user input that ends up in the
page?* This page documents every escape boundary the lib draws, in
the order they get crossed.

## Element text content

```julia
div("user said: $(user_input)")
```

The string interpolates a `String` (or `SubString`) into the element's
children. At [`render`](@ref) time, `escape_html` walks the bytes and
replaces `<`, `>`, `&`, `"`, `'` with HTML entities. **Auto-escape is
on by default for every child of every Element.** There is no way to
disable it short of explicitly wrapping in [`Raw`](@ref) — which is the
one and only way to opt out.

## Attribute values

```julia
input(type="text", value=user_input)
```

Attribute values go through the same escape walker. Boolean attributes
(`true`, `false`, `nothing`, `missing`) follow HTML semantics: `true`
emits the bare attribute name, anything falsy omits the attribute
entirely. `Number`s are written as their decimal representation
(no escape needed). A [`DSAction`](@ref) value (Datastar action) is
formatted by the renderer; the JS string inside is escaped against
single quote, backslash, and `</script>`.

## Attribute and tag *names*

```julia
# This injection vector is closed:
key = Symbol("x onerror=alert(1)")
div(key => "v")                    # → ArgumentError
Element(Symbol("<script>"), …)     # → ArgumentError
```

`Symbol`-keyed attributes and the `Element(::Symbol, …)` constructor
both let a caller pass an arbitrary name. The renderer would write
those names verbatim — including a literal `<`, `=`, `"`, or a space
— so a hostile name could inject markup. HyperSignal rejects names
containing whitespace, `<`, `>`, `"`, `'`, `/`, `=`, or `\0`. Names
that pass are cached by Symbol identity, so the validation cost is
amortized to zero on the bounded vocabulary the library actually
uses (`data-on:click__prevent`, `aria-label`, `xlink:href`, etc.).

## `Raw(...)` — the only opt-out

```julia
const SPINNER = Raw("""<svg viewBox="0 0 24 24">…</svg>""")
div(class="loading", SPINNER, " Working…")
```

`Raw` writes its payload byte-for-byte with no escape. Use it for SVG
icons, audited HTML generators, and the output of [`patch_svg`](@ref)
or [`inline_svg`](@ref). **Never wrap user input in `Raw`.**

## `Vector{UInt8}` cached HTML

A `Vector{UInt8}` child renders as a verbatim byte buffer — the same
trust model as `Raw`. The common case is a pre-rendered, cached HTML
fragment. The lib doesn't autodetect malicious bytes; if the buffer
comes from user input, scrub it first.

## CairoMakie SVG inlining

`inline_svg(::Figure)` calls Makie's SVG backend, then runs
the output through [`patch_svg`](@ref). The patch removes:

- The XML prolog and DOCTYPE (would break HTML parsing).
- The hard-coded `width`/`height` (responsive embed).
- Internal id collisions (`clip0`, `glyph0`) via the `id_prefix`
  argument — and the prefix is splice-escaped so a user-supplied
  prefix containing `\` won't get interpreted as a regex
  back-reference.

The patched SVG is wrapped in `Raw` because by then it's been
re-emitted by the lib, not the caller. If you ever pass an SVG from
an untrusted source through `patch_svg`, treat it the same as any
other third-party HTML and audit it first.

## Datastar JS expressions

```julia
button(on_click(ds_post("/api/save")),       # safe — typed action
       on(:click, "raw JS expression"))      # caller's responsibility
```

A [`DSAction`](@ref) value is formatted by the renderer with
`single-quote → \'`, `\ → \\`, `</ → <\/` (the same triple-escape
used by [`redirect_via_fragment`](@ref) and `DSAction` extras). A raw
JS-string action — the second form above — is passed through
verbatim into the attribute value; the HTML-attribute escape still
fires (so `"` becomes `&quot;`), but the JS-string quoting inside is
your job.

## Reporting a security issue

Don't open a public issue. Email <joao.goncalves@aircentre.org>.
