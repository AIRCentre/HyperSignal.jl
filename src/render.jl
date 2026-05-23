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
    else
        for c in s
            escape_html(io, c)
        end
    end
    nothing
end

function _escape_html_string(io::IO, s::String)
    data = codeunits(s)
    n = length(data)
    i = 1
    run_start = 1
    @inbounds while i <= n
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
    @inbounds if run_start <= n
        unsafe_write(io, pointer(data, run_start), n - run_start + 1)
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

# Attribute writer. Boolean true → bare attr. false / nothing / missing
# → omit (symmetric with HyperSignal.render's nothing/missing handling
# for children, so `value = optional_string()` can return `missing`
# without changing the call site). DSAction → render its JS expression.
# Everything else → quoted, escaped.
function _render_attr(io::IO, k::Symbol, v)
    v === false && return nothing
    v === nothing && return nothing
    v === missing && return nothing
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
