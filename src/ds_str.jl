"""
    DSExpr <: AbstractString

A Datastar expression built by [`@ds_str`](@ref). As an `AbstractString`
it is accepted wherever an expression string is (`on`, `ds_show`, …).
Spliced into another `ds"…"`, it is inserted verbatim, not quoted.
"""
struct DSExpr <: AbstractString
    s::String
end
Base.String(e::DSExpr) = e.s
Base.ncodeunits(e::DSExpr) = ncodeunits(e.s)
Base.codeunit(e::DSExpr) = codeunit(e.s)
Base.codeunit(e::DSExpr, i::Integer) = codeunit(e.s, i)
Base.isvalid(e::DSExpr, i::Integer) = isvalid(e.s, i)
Base.iterate(e::DSExpr, i::Integer=1) = iterate(e.s, i)

# _ds_parse's quote tracking can be fooled (a quote inside a regex literal),
# so a splice must stay inert inside any JS string: `"`, backtick and `$`
# are escaped too. Those escapes are no-ops in a JS string, and in JSON these
# characters only occur inside strings. Other types go through JSON, not
# `_js_value`'s `string(v)`, so `nothing` or a Symbol can't land as a bare
# identifier.
_ds_splice(x::Union{Bool, Number}) = _js_value(x)
_ds_splice(x::AbstractString) =
    "'" * replace(_js_str_escape(x), "\"" => "\\\"", "`" => "\\`", "\$" => "\\\$") * "'"
_ds_splice(x) = replace(JSON.json(x), "'" => "\\'", "`" => "\\`", "\$" => "\\\$")
_ds_splice(x::DSExpr) = x.s
_ds_splice(a::DSAction) = action_js(a)

# Split a ds"…" body into literal Strings and Julia Exprs to splice. Only
# `$(` starts a splice: Datastar signal names never begin with `(`. Quotes
# are tracked so a splice can't land inside a JS string literal, where its
# own quotes would end the string early.
function _ds_parse(s::AbstractString)
    parts = Any[]
    buf = IOBuffer()
    quote_char = nothing
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '\\'
            i = _ds_copy_escape!(buf, s, i, quote_char)
        elseif c == '$'
            i = _ds_dollar!(parts, buf, s, i, quote_char)
        else
            quote_char = _ds_quote_state(quote_char, c)
            print(buf, c)
            i = nextind(s, i)
        end
    end
    quote_char === nothing ||
        throw(ArgumentError("ds\"…\": unterminated $(quote_char) string in $(repr(s))"))
    _ds_flush!(parts, buf)
end

_ds_flush!(parts, buf) = (position(buf) > 0 && push!(parts, String(take!(buf))); parts)

function _ds_quote_state(quote_char, c)
    c in ('\'', '"', '`') || return quote_char
    quote_char === nothing && return c
    quote_char == c ? nothing : quote_char
end

# Copy a JS escape pair whole so `\'` doesn't toggle the quote state.
function _ds_copy_escape!(buf, s, i, quote_char)
    nxt = nextind(s, i)
    print(buf, '\\')
    nxt > lastindex(s) && return nxt
    quote_char === nothing && s[nxt] == '$' &&
        throw(ArgumentError("ds\"…\": `\\\$` is not needed; write \$name " *
                            "for a signal or \$(expr) to splice a Julia value"))
    print(buf, s[nxt])
    nextind(s, nxt)
end

function _ds_dollar!(parts, buf, s, i, quote_char)
    nxt = nextind(s, i)
    rest = SubString(s, nxt)
    if startswith(rest, "\$(")
        print(buf, "\$(")
        return nextind(s, nxt, 2)
    end
    startswith(rest, '(') && return _ds_splice_expr!(parts, buf, s, nxt, quote_char)
    print(buf, '$')
    nxt
end

function _ds_splice_expr!(parts, buf, s, open, quote_char)
    quote_char === nothing || throw(ArgumentError(
        "ds\"…\": \$(…) inside a JS string literal would add a second " *
        "set of quotes; write 'Hi, ' + \$(name) instead"))
    ex, i = Meta.parseatom(s, open)
    ex isa Expr && ex.head in (:incomplete, :error) &&
        throw(ArgumentError("ds\"…\": unclosed or invalid \$(…) in $(repr(s))"))
    _ds_flush!(parts, buf)
    push!(parts, ex)
    i
end

"""
    ds"…" -> DSExpr

Write a Datastar expression without escaping `\$`. Unlike a Julia string,
`\$name` is **not** interpolated: it stays a Datastar signal reference.
`\$(expr)` evaluates the Julia `expr` and inserts it as a JS literal, the
same way [`DSAction`](@ref) options are written: strings single-quoted and
escaped (`"`, backtick and `\$` too), numbers and booleans as-is, `Dict`/`NamedTuple`/`Vector` as JSON,
anything else via `JSON.json`. A [`DSAction`](@ref)
or another `ds"…"` is inserted verbatim. Write `\$\$(` for a literal `\$(`.

A misplaced splice fails when the code loads: `\\\$` (not needed here) and
`\$(…)` inside a JS `'…'`/`"…"` string (it would add quotes; concatenate
with `+` instead).

# Examples
```jldoctest
julia> n = 3;

julia> ds"\$count = \$count + \$(n)"
"\\\$count = \\\$count + 3"

julia> s = "it's";

julia> render(button(on(:click, ds"\$label = \$(s)")))
"<button data-on:click=\\"\\\$label = &#39;it\\\\&#39;s&#39;\\"></button>"
```
"""
macro ds_str(s)
    parts = _ds_parse(s)
    all(p -> p isa String, parts) && return DSExpr(join(parts))
    args = [p isa String ? p : :(_ds_splice($(esc(p)))) for p in parts]
    :(DSExpr(string($(args...))))
end
