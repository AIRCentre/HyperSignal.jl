# Streaming renderer. render(io, x) is the only public dispatch — every
# child type lands here. Auto-escapes text, leaves Raw untouched, walks
# Element/Frag recursively, and emits a JS string for DSAction values that
# end up as attribute values via `on(...)`.

const _ESCAPE_MAP = Dict{Char, String}(
    '&' => "&amp;",
    '<' => "&lt;",
    '>' => "&gt;",
    '"' => "&quot;",
    '\'' => "&#39;",
)

function escape_html(io::IO, c::Char)
    repl = get(_ESCAPE_MAP, c, nothing)
    isnothing(repl) ? print(io, c) : print(io, repl)
    nothing
end

function escape_html(io::IO, s::AbstractString)
    for c in s
        escape_html(io, c)
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
```julia
render(div(class="card", h2("Hi"), p("hello")))
# => "<div class=\"card\"><h2>Hi</h2><p>hello</p></div>"
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
- `nothing` / `missing`: writes nothing — handy for conditional children.
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
render(io::IO, s::AbstractString) = escape_html(io, s)
render(io::IO, c::Char) = escape_html(io, c)
render(io::IO, n::Number) = print(io, n)
render(io::IO, ::Nothing) = nothing
render(io::IO, ::Missing) = nothing
function render(io::IO, xs::AbstractVector)
    for x in xs
        render(io, x)
    end
    nothing
end

# Attribute writer. Boolean true → bare attr. Boolean false / nothing → omit.
# DSAction → render its JS expression. Everything else → quoted, escaped.
function _render_attr(io::IO, k::Symbol, v)
    v === false && return nothing
    v === nothing && return nothing
    print(io, " ", k)
    v === true && return nothing
    print(io, "=\"")
    if v isa DSAction
        escape_html(io, action_js(v))
    elseif v isa AbstractString
        escape_html(io, v)
    elseif v isa Number
        print(io, v)
    else
        escape_html(io, string(v))
    end
    print(io, "\"")
    nothing
end
