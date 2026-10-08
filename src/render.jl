# Hot path: branching on the five metacharacters beats a Dict lookup; String
# input writes safe runs with one `unsafe_write`. UTF-8 continuation bytes
# (>= 0x80) skip every branch.
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

# One method per concrete type: dispatch from the Vector{Any} children loop
# lands on the fast path with no per-child `isa` ladder.
escape_html(io::IO, s::String) = _escape_html_string(io, s)
escape_html(io::IO, s::SubString{String}) = _escape_html_substring(io, s)
function escape_html(io::IO, s::AbstractString)
    for c in s
        escape_html(io, c)
    end
    nothing
end

function _escape_html_string(io::IO, s::String)
    data = codeunits(s)
    _escape_html_codeunits(io, data, 1, length(data))
end

function _escape_html_substring(io::IO, s::SubString{String})
    data = codeunits(s.string)
    _escape_html_codeunits(io, data, s.offset + 1, s.offset + sizeof(s))
end

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

Render `x` to a String. Same dispatch as [`render(io, x)`](@ref render),
which streams to an `IO` you already hold.

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

# Bool/nothing/missing render nothing (`cond && extra` idiom), so they are
# not content in a void element.
_is_content_child(c) = !(c isa Bool || c === nothing || c === missing)

"""
    render(io::IO, x)

Stream the HTML for `x` to `io`. Every renderable type dispatches here:

- [`Element`](@ref): `<tag …attrs…>children</tag>`; void elements (`br`,
  `input`, …) write `<tag …>` and throw `ArgumentError` on content children.
- [`Frag`](@ref): children, no wrapper tag.
- [`Raw`](@ref): verbatim.
- `AbstractString`, `Char`, `Symbol`: escaped (`&`, `<`, `>`, `"`, `'`).
- `Number`: as-is.
- `nothing` / `missing` / `Bool`: nothing, so `cond && extra` drops out.
- `AbstractVector`, `Base.Generator`: each element in order.
- `AbstractVector{UInt8}`: verbatim bytes (pre-rendered HTML).
- [`Attribute`](@ref): throws `ArgumentError`; splat collections holding
  attributes so each is a top-level argument.

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
    # Browsers reparent void-element children as siblings, so server HTML
    # and client DOM diverge and Datastar's morph breaks. Throw before
    # writing bytes.
    void = is_void(e.tag)
    if void && any(_is_content_child, e.children)
        throw(ArgumentError(
            "HyperSignal: void element <$(e.tag)> cannot have content children; " *
            "void elements take attributes only"))
    end
    print(io, "<", e.tag)
    for (k, v) in e.attrs
        _render_attr(io, k, v)
    end
    print(io, ">")
    void && return nothing
    for c in e.children
        render(io, c)
    end
    print(io, "</", e.tag, ">")
    nothing
end

render(io::IO, f::Frag) = render(io, f.children)
render(io::IO, r::Raw) = (print(io, r.html); nothing)
render(io::IO, s::AbstractString) = escape_html(io, s)
render(io::IO, c::Char) = escape_html(io, c)
render(io::IO, n::Number) = print(io, n)
# Bool <: Number would print "false" for `cond && extra`.
render(io::IO, ::Bool) = nothing
render(io::IO, ::Nothing) = nothing
render(io::IO, ::Missing) = nothing
# Attributes nested in a collection arg become children; name the fix
# instead of an opaque MethodError.
render(io::IO, ::Attribute) = throw(ArgumentError(
    "HyperSignal: an Attribute (from on(...)/ds_*(...)) reached render as a child. " *
    "Attributes are only lifted into attrs when passed as a top-level positional arg, " *
    "not when nested inside a Vector/Tuple/Generator. " *
    "Splat the collection — tag(attrs..., children...) — so each Attribute is top-level."))
render(io::IO, sym::Symbol) = escape_html(io, String(sym))
# A Generator reaches render when nested inside a Vector: the
# construction-time unpack only handles top-level positional args.
function render(io::IO, xs::Union{AbstractVector, Base.Generator})
    for x in xs
        render(io, x)
    end
    nothing
end

# Bytes = pre-rendered HTML; the generic vector path would print each byte
# as a number.
render(io::IO, v::AbstractVector{UInt8}) = (write(io, v); nothing)

Base.show(io::IO, ::MIME"text/html", e::Element) = render(io, e)
Base.show(io::IO, ::MIME"text/html", f::Frag)    = render(io, f)
Base.show(io::IO, ::MIME"text/html", r::Raw)     = render(io, r)

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

# `string(el)` and `"$(el)"` go through 1-arg show: give markup, not a
# struct dump.
Base.show(io::IO, e::Element) = render(io, e)
Base.show(io::IO, f::Frag)    = render(io, f)
Base.show(io::IO, r::Raw)     = render(io, r)

# Tag and attr names are written verbatim, so a hostile Symbol would emit raw
# HTML. Both reject the same parser-breaking bytes: whitespace, quotes,
# `<`, `>`, `/`, `=`, NUL. Tag grammar is stricter, but one shared subset
# keeps the rule learnable.
@inline _is_invalid_name_byte(b::UInt8) =
    b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d ||
    b == 0x22 || b == 0x27 || b == 0x3e || b == 0x3c ||
    b == 0x2f || b == 0x3d || b == 0x00

# Name cache: valid names form a small vocabulary and Symbols are interned,
# so a Set hit skips the codeunit walk. `render` runs on many threads; an
# unguarded `push!` can rehash under a concurrent `in` and segfault.
# ReentrantLock, not an @atomic Set field: the latter segfaults on 1.10.
# Validation runs outside the lock so a rejected name throws without it.
struct _NameCache
    names::Set{Symbol}
    lk::ReentrantLock
end

const _VALID_TAG_NAMES = _NameCache(Set{Symbol}(), ReentrantLock())
const _VALID_ATTR_NAMES = _NameCache(Set{Symbol}(), ReentrantLock())

@inline function _cached_check(c::_NameCache, k::Symbol, check::F) where {F}
    (@lock c.lk k in c.names) && return nothing
    check(k)
    @lock c.lk push!(c.names, k)
    nothing
end

_check_tag_name(t::Symbol) = _cached_check(_VALID_TAG_NAMES, t, _check_tag_name_uncached)
_check_attr_name(k::Symbol) = _cached_check(_VALID_ATTR_NAMES, k, _check_attr_name_uncached)

@noinline function _check_tag_name_uncached(t::Symbol)
    s = String(t)
    isempty(s) && throw(ArgumentError("HyperSignal: empty tag name"))
    @inbounds for b in codeunits(s)
        _is_invalid_name_byte(b) &&
            throw(ArgumentError("HyperSignal: tag name $(repr(s)) contains a character that would break HTML parsing"))
    end
    nothing
end

# Rejected, not escaped: HTML defines no entity decoding inside attribute
# names, so `Symbol("x onerror=...")` would otherwise add a real attribute.
@noinline function _check_attr_name_uncached(k::Symbol)
    @inbounds for b in codeunits(String(k))
        _is_invalid_name_byte(b) &&
            throw(ArgumentError("HyperSignal: attribute name $(repr(String(k))) contains a character that would break HTML attribute parsing"))
    end
    nothing
end

function _render_attr(io::IO, k::Symbol, v)
    v === false && return nothing
    v === nothing && return nothing
    v === missing && return nothing
    _check_attr_name(k)
    print(io, " ", k)
    v === true && return nothing
    print(io, "=\"")
    if v isa DSAction
        _action_js(io, v, escape_html)
    elseif v isa AbstractString
        escape_html(io, v)
    elseif v isa Number
        print(io, v)
    elseif v isa AbstractVector || v isa Tuple
        # Space-joined, not the repr.
        _render_attr_vector(io, v)
    else
        escape_html(io, string(v))
    end
    print(io, "\"")
    nothing
end

# Skips nothing/missing/Bool/"" so `cond && "active"` drops out.
function _render_attr_vector(io::IO, v)
    first = true
    for x in v
        (x === nothing || x === missing || x === false || x === true) && continue
        x isa AbstractString && isempty(x) && continue
        first || print(io, ' ')
        escape_html(io, x isa AbstractString ? x : string(x))
        first = false
    end
end
