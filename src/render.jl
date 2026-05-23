# Streaming renderer. render(io, x) is the only public dispatch — every
# child type lands here. Auto-escapes text, leaves Raw untouched, walks
# Element/Frag recursively, and emits a JS string for DSAction values that
# end up as attribute values via `on(...)`.

# Hot path. Branching on the five HTML metacharacters is meaningfully
# faster than a `Dict` lookup per character — and for plain `String`
# input we walk codeunits, write runs of safe bytes with a single
# `unsafe_write`, and only fall into the escape branches at the rare
# metacharacters. Continuation bytes of multi-byte UTF-8 are >=0x80 and
# skip the branches entirely.
@inline function escape_html(io::IO, c::Char)
    if c === '&'
        print(io, "&amp;")
    elseif c === '<'
        print(io, "&lt;")
    elseif c === '>'
        print(io, "&gt;")
    elseif c === '"'
        print(io, "&quot;")
    elseif c === '\''
        print(io, "&#39;")
    else
        print(io, c)
    end
    nothing
end

function escape_html(io::IO, s::AbstractString)
    if s isa String
        _escape_html_string(io, s)
    elseif s isa SubString{String}
        # SubString of a String can use the same codeunit fast path
        # by walking the parent buffer between the view's bounds.
        _escape_html_substring(io, s)
    else
        for c in s
            escape_html(io, c)
        end
    end
    nothing
end

function _escape_html_string(io::IO, s::String)
    data = codeunits(s)
    _escape_html_codeunits(io, data, 1, length(data))
end

function _escape_html_substring(io::IO, s::SubString{String})
    data = codeunits(s.string)
    offset = s.offset                  # 0-based byte offset into parent
    n = sizeof(s)                      # SubString length in bytes
    _escape_html_codeunits(io, data, offset + 1, offset + n)
end

# Walk codeunits in [first_idx, last_idx], writing safe runs via one
# `unsafe_write` and emitting the entity for each metacharacter.
@inline function _escape_html_codeunits(io::IO, data,
                                        first_idx::Int, last_idx::Int)
    i = first_idx
    run_start = first_idx
    @inbounds while i <= last_idx
        b = data[i]
        if b == 0x26 || b == 0x3c || b == 0x3e || b == 0x22 || b == 0x27
            i > run_start && unsafe_write(io, pointer(data, run_start), i - run_start)
            if b == 0x26
                print(io, "&amp;")
            elseif b == 0x3c
                print(io, "&lt;")
            elseif b == 0x3e
                print(io, "&gt;")
            elseif b == 0x22
                print(io, "&quot;")
            else
                print(io, "&#39;")
            end
            i += 1
            run_start = i
        else
            i += 1
        end
    end
    @inbounds if run_start <= last_idx
        unsafe_write(io, pointer(data, run_start), last_idx - run_start + 1)
    end
    nothing
end

"""
    render(x) -> String

Render `x` (any renderable: [`Element`](@ref), [`Frag`](@ref),
[`Raw`](@ref), strings, numbers, vectors, `nothing`/`missing`) into a
String. Sibling of the streaming [`render(io, x)`](@ref) — same dispatch,
just returns the bytes instead of writing them. Use this when you need a
String for an HTTP body or a test assertion; reach for `render(io, x)`
when you already hold an `IO`.

# Examples
```jldoctest
julia> using HyperSignal: div

julia> render(div(class="card", h2("Hi"), p("hello")))
"<div class=\\"card\\"><h2>Hi</h2><p>hello</p></div>"

julia> render("a < b & \\"c\\"")
"a &lt; b &amp; &quot;c&quot;"

julia> render(nothing)
""
```
"""
render(x) = (io = IOBuffer(); render(io, x); String(take!(io)))

"""
    render(io::IO, x)

Stream the HTML for `x` to `io`. The single dispatch surface for the
library — every renderable type lands here. Standard methods cover:

- [`Element`](@ref): writes `<tag …attrs…>children</tag>` (or `<tag …>`
  for void elements like `br`, `input`, `meta`).
- [`Frag`](@ref): walks children with no wrapper tag.
- [`Raw`](@ref): writes the wrapped string verbatim.
- `AbstractString`: writes auto-escaped (`&`, `<`, `>`, `"`, `'`).
- `Number`: writes as-is.
- `nothing` / `missing` / `Bool`: writes nothing — so
  `cond && extra` (which evaluates to bare `false` when `cond` is
  false) drops out of the children list cleanly.
- `AbstractVector`: walks elements in order.

To make a custom type renderable, add a method:

```julia
struct ImageCard; url::String; alt::String; end
HyperSignal.render(io::IO, c::ImageCard) =
    HyperSignal.render(io, img(src=c.url, alt=c.alt))
```

# Examples
```julia
io = IOBuffer()
render(io, h1("Hello, world"))
String(take!(io))   # "<h1>Hello, world</h1>"
```
"""
function render(io::IO, e::Element)
    _check_tag_name(e.tag)
    print(io, "<", e.tag)
    for (k, v) in e.attrs
        _render_attr(io, k, v)
    end
    if is_void(e.tag) && isempty(e.children)
        print(io, ">")
        return nothing
    end
    print(io, ">")
    for c in e.children
        render(io, c)
    end
    print(io, "</", e.tag, ">")
    nothing
end

render(io::IO, f::Frag) = (for c in f.children; render(io, c); end; nothing)
render(io::IO, r::Raw) = (print(io, r.html); nothing)

# Notebook / REPL display hooks. Pluto, IJulia, and VS Code's plot pane
# all pick up `text/html`, so this is the single line that turns an
# Element value into an interactive preview without the caller writing
# `render(...)` in every cell.
Base.show(io::IO, ::MIME"text/html", e::Element) = render(io, e)
Base.show(io::IO, ::MIME"text/html", f::Frag)    = render(io, f)
Base.show(io::IO, ::MIME"text/html", r::Raw)     = render(io, r)

# Plain-text REPL display: render the HTML but tag it as such so a user
# typing `div("hi")` at the prompt sees the markup instead of the struct
# dump. Element trees are data, but the markup is what people read.
function Base.show(io::IO, ::MIME"text/plain", e::Element)
    print(io, "HyperSignal.Element: ")
    render(io, e)
end
function Base.show(io::IO, ::MIME"text/plain", f::Frag)
    print(io, "HyperSignal.Frag: ")
    render(io, f)
end
function Base.show(io::IO, ::MIME"text/plain", r::Raw)
    print(io, "HyperSignal.Raw: ")
    print(io, r.html)
end

# 1-arg `show` is what `string(el)`, `print(io, el)`, and `"$(el)"`
# interpolation all dispatch to. Without this method, those paths fall
# back to a struct dump. Making `string(::Element)` mean the rendered
# HTML matches what every other side of the API already returns and
# makes a vector of elements print as readable markup instead of
# Element(:div, ..., ...).
Base.show(io::IO, e::Element) = render(io, e)
Base.show(io::IO, f::Frag)    = render(io, f)
Base.show(io::IO, r::Raw)     = render(io, r)
render(io::IO, s::AbstractString) = escape_html(io, s)
render(io::IO, c::Char) = escape_html(io, c)
render(io::IO, n::Number) = print(io, n)
# Bool children render as nothing — symmetric with the attr-vector
# fix and matches the natural Julia idiom `div(header, cond && extra,
# footer)`, where `cond && extra` evaluates to bare `false` when cond
# is false. Without this method Bool routed through the Number dispatch
# and emitted the literal text "false" / "true" — never what the user
# wants in a conditional-render context. Pass `string(b)` if you
# genuinely want to print the word.
render(io::IO, ::Bool) = nothing
render(io::IO, ::Nothing) = nothing
render(io::IO, ::Missing) = nothing
# Symbol children render as their text. The common case is a status
# enum (`span(:Pending)`) where the caller pulled the value straight
# from a model field without wanting to `string()` first. The escape
# walks the Symbol's bytes the same as a String.
render(io::IO, sym::Symbol) = escape_html(io, String(sym))
function render(io::IO, xs::AbstractVector)
    for x in xs
        render(io, x)
    end
    nothing
end

# A Generator can reach render time when nested inside a Vector or
# another container that doesn't get expanded at element construction
# (the construction-time generator-unpack only handles top-level
# positional args). Iterating here is a single pass — the same single
# pass `for c in e.children; render(io, c)` would do.
function render(io::IO, xs::Base.Generator)
    for x in xs
        render(io, x)
    end
    nothing
end

# A byte buffer is almost always a pre-rendered HTML response cached
# upstream — write it verbatim instead of falling through the generic
# AbstractVector path, which would emit each byte as a decimal Number.
# If a caller really wants the per-byte interpretation, they can wrap
# the bytes in `Any[b for b in v]` to opt back in.
render(io::IO, v::AbstractVector{UInt8}) = (write(io, v); nothing)

# Tag names are written verbatim into the open/close tags. A hostile
# Symbol("…") passed to the bare Element(...) constructor (the one
# documented for runtime-chosen tag names) could otherwise emit raw
# HTML. Tag-name grammar is stricter than attribute names — only
# letters, digits, and a few markers — but we only reject the
# parser-breaking subset for parity and to keep the rule learnable.
const _VALID_TAG_NAMES = Set{Symbol}()

@inline function _check_tag_name(t::Symbol)
    t in _VALID_TAG_NAMES && return nothing
    _check_tag_name_uncached(t)
    push!(_VALID_TAG_NAMES, t)
    nothing
end

@noinline function _check_tag_name_uncached(t::Symbol)
    s = String(t)
    isempty(s) && throw(ArgumentError("HyperSignal: empty tag name"))
    @inbounds for b in codeunits(s)
        if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d ||
           b == 0x22 || b == 0x27 || b == 0x3e || b == 0x3c ||
           b == 0x2f || b == 0x3d || b == 0x00
            throw(ArgumentError("HyperSignal: tag name $(repr(s)) contains a character that would break HTML parsing"))
        end
    end
    nothing
end

# HTML5's attribute-name grammar is permissive but bans the chars that
# would break the parser: whitespace (incl. tab/LF/FF/CR/space), '"',
# '\'', '<', '>', '/', '=', '\0'. We reject the parser-breaking subset
# loudly — escaping wouldn't help (the spec doesn't define entity
# decoding inside attribute names) and silent acceptance would mean a
# hostile Symbol key like `Symbol("x onerror=...")` introduces a real
# attribute. The lib's own Datastar helpers stay well within the
# allowed set (`data-on:click__prevent` etc.) so this only fires on
# adversarial input.
#
# Cache validated symbols: HTML attribute names form a small, bounded
# vocabulary, and Symbols are interned, so identity-keyed Set lookup
# is constant-time and skips the codeunit walk after the first check.
# A race on Set push only duplicates work — harmless beyond a brief
# extra walk — so we don't lock.
const _VALID_ATTR_NAMES = Set{Symbol}()

@inline function _check_attr_name(k::Symbol)
    k in _VALID_ATTR_NAMES && return nothing
    _check_attr_name_uncached(k)
    push!(_VALID_ATTR_NAMES, k)
    nothing
end

@noinline function _check_attr_name_uncached(k::Symbol)
    @inbounds for b in codeunits(String(k))
        if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d ||
           b == 0x22 || b == 0x27 || b == 0x3e || b == 0x3c ||
           b == 0x2f || b == 0x3d || b == 0x00
            throw(ArgumentError("HyperSignal: attribute name $(repr(String(k))) contains a character that would break HTML attribute parsing"))
        end
    end
    nothing
end

# Attribute writer. Boolean true → bare attr. false / nothing / missing
# → omit (symmetric with HyperSignal.render's nothing/missing handling
# for children, so `value = optional_string()` can return `missing`
# without changing the call site). DSAction → render its JS expression.
# Everything else → quoted, escaped.
function _render_attr(io::IO, k::Symbol, v)
    v === false && return nothing
    v === nothing && return nothing
    v === missing && return nothing
    _check_attr_name(k)
    print(io, " ", k)
    v === true && return nothing
    print(io, "=\"")
    if v isa DSAction
        escape_html(io, action_js(v))
    elseif v isa AbstractString
        escape_html(io, v)
    elseif v isa Number
        print(io, v)
    elseif v isa AbstractVector || v isa Tuple
        # Vector/Tuple attribute values almost always mean "join these"
        # — most commonly a class list (`class=["btn", "primary"]` or
        # `class=("btn", "primary")`), but the same intuition holds for
        # `aria-describedby` (multiple ids separated by space) and
        # Datastar's space-separated lists. The alternative (dumping
        # the container repr) emits hostile output like
        # `class="[&quot;btn&quot;, &quot;primary&quot;]"`.
        _render_attr_vector(io, v)
    else
        escape_html(io, string(v))
    end
    print(io, "\"")
    nothing
end

# Join a Vector value with spaces, skipping nothing/missing/false/
# empty entries so a conditional class list survives optional pieces.
# `false` is dropped (not stringified) so the natural Julia idiom
# `cond && "active"` works: when cond is false the entry evaluates
# to `false`, and we want that to mean "skip", not "include the
# literal text 'false'". `true` is dropped too for symmetry — a bare
# `true` in a class list never means anything useful.
function _render_attr_vector(io::IO, v)
    first = true
    for x in v
        (x === nothing || x === missing || x === false || x === true) && continue
        if x isa AbstractString
            isempty(x) && continue
            first || print(io, ' ')
            escape_html(io, x)
            first = false
        else
            first || print(io, ' ')
            escape_html(io, string(x))
            first = false
        end
    end
end
