# Security model

HyperSignal is an HTML-output library. The single most important
question for one is: *what happens to user input that ends up in the
page?* This page documents every escape boundary the lib draws, in
the order they get crossed.

## Element text content

!!! warning "Raw is the ONLY documented escape-hatch"
    Use it for SVG icons, audited HTML generators, and the output of
    [`patch_svg`](@ref) / [`inline_svg`](@ref). **Never wrap user
    input.** There is no `SafeHTML`, no `unsafe=true` kwarg, no
    sanitizer — one hatch, one trust boundary.

```julia
div("user said: $(user_input)")
```

The string interpolates a `String` (or `SubString`) into the element's
children. At [`render`](@ref) time, `escape_html` walks the bytes and
replaces `<`, `>`, `&`, `"`, `'` with HTML entities. **Auto-escape is
on by default for every child of every Element.** The only way to opt
out is to explicitly wrap the value in [`Raw`](@ref).

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
single quote, backslash, `</` (which an HTML parser treats as the start
of an end-tag, closing an enclosing `<script>` regardless of JS
quoting), and the four JS line terminators (LF, CR, U+2028, U+2029).

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

## SVG inlining (Makie / `patch_svg`)

`inline_svg(fig)` (provided by the Makie extension) renders a
`Figure` / `Scene` / `FigureAxisPlot` to SVG via whatever Makie
backend is loaded — CairoMakie in practice — then runs the output
through [`patch_svg`](@ref). The patch removes:

- The XML prolog and DOCTYPE (would break HTML parsing).
- The hard-coded `width`/`height` (responsive embed).
- Internal id collisions (`clip0`, `glyph0`) via the `id_prefix`
  argument — and the prefix is splice-escaped so a user-supplied
  prefix containing `\` won't get interpreted as a regex
  back-reference.

The `add_class` and `aria_label` arguments patched onto the root
`<svg>` are both attribute-escaped before splicing, so a value
containing `"` cannot break out of the attribute and inject markup
onto the root element.

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
`single-quote → \'`, `\ → \\`, `</ → <\/`, and the four JS line
terminators (`LF → \n`, `CR → \r`, `U+2028 → \u2028`, `U+2029 → \u2029`)
(the same JS-string escape used by [`redirect_via_fragment`](@ref) and
`DSAction` extras). A raw
JS-string action — the second form above — is passed through
verbatim into the attribute value; the HTML-attribute escape still
fires (so `"` becomes `&quot;`), but the JS-string quoting inside is
your job.

## `script_response` — verbatim JS

```julia
script_response("doStuff($(user_input))")    # DANGER
```

[`script_response`](@ref) writes its `js` argument byte-for-byte into
the response body — the Datastar client appends it to a `<script>` tag
and runs it. Same trust model as [`Raw`](@ref): the caller owns the
escape. Never interpolate unsanitized input. If you need a value
inside the script body, JSON-encode it (`JSON.json(value)`) and rely on
the fact that JSON's quoting is a valid JS literal.

The `script_attributes` keyword goes into the
`datastar-script-attributes` header verbatim when passed as a string,
or JSON-encoded otherwise — sanitize before passing.

## SSE responses

[`sse_response`](@ref) and its event constructors
([`patch_elements`](@ref), [`patch_signals`](@ref)) follow the same
trust model as the other helpers, with two boundaries worth naming:

- `elements` HTML is rendered through [`render`](@ref), so text and
  attribute values are escape-walked — same guarantees as
  [`html_response`](@ref).
- `selector` and `script_attributes` are written into the wire format
  verbatim. Sanitize before passing if they can carry user input. A
  `selector` containing a CR or LF would split the SSE line and corrupt
  the rest of the event; [`patch_elements`](@ref) rejects this with an
  `ArgumentError` at event-build time (so the mistake surfaces at the
  call site), and [`sse_response`](@ref) re-checks as defense-in-depth
  for a directly-constructed event.

`patch_signals` JSON-encodes its argument; `JSON.json` escapes
embedded newlines, so signals are safe to round-trip.

## `redirect_via_fragment` selector

[`redirect_via_fragment`](@ref) renders the morph target itself, with
`id` set to the selector minus its leading `#`, so it accepts only a
single `"#id"` selector. It rejects anything that isn't `#` followed by
non-whitespace (length > 1, no whitespace) with an `ArgumentError` at
build time. This closes two failure modes at once: a class/compound/
whitespace selector (`.card`, `#a #b`) would produce an `id` the
selector can't match (the redirect silently no-ops), and a CR/LF in the
selector would be injected raw into the `datastar-selector` header. The
`location` argument is escaped for its single-quoted inline-`<script>`
JS literal via the same `_js_str_escape` set used by [`DSAction`](@ref)
(backslash, single quote, `</`, and the four line terminators
LF/CR/U+2028/U+2029).

## Reporting a security issue

Don't open a public issue. Email <joao.goncalves@aircentre.org>.
