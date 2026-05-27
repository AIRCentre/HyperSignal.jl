# Response helpers — bundle the `datastar-selector` header so callers
# don't keep retyping it (and don't keep forgetting it).

"""
    html_response(body; status=200, headers=[]) -> HTTP.Response

Render `body` (anything renderable) and wrap it in an `HTTP.Response`
with `Content-Type: text/html; charset=utf-8`. Use this for full-page
GETs.

# Examples
```jldoctest
julia> r = html_response(p("ok"));

julia> r.status
200

julia> Dict(r.headers)["Content-Type"]
"text/html; charset=utf-8"

julia> String(r.body)
"<p>ok</p>"

julia> r2 = html_response(p("created"); status=201, headers=["X-Tag" => "v1"]);

julia> r2.status, Dict(r2.headers)["X-Tag"]
(201, "v1")
```
"""
function html_response(body; status::Int=200, headers=Pair{String,String}[])
    h = ["Content-Type" => "text/html; charset=utf-8", headers...]
    HTTP.Response(status, h, render(body))
end

const _FRAGMENT_MODES = (:outer, :inner, :replace, :prepend, :append,
                         :before, :after, :remove)

function _validate_mode(m::Symbol)
    m in _FRAGMENT_MODES || throw(ArgumentError(
        "fragment_response: unknown mode :$m; expected one of $(_FRAGMENT_MODES)"))
    m
end

"""
    fragment_response(body; selector=nothing, mode=nothing,
                      view_transition=false, status=200, headers=[]) -> HTTP.Response
    fragment_response(body, selector::AbstractString; kwargs...) -> HTTP.Response

Like [`html_response`](@ref) but also surfaces the Datastar fragment
control headers — `datastar-selector` (morph target), `datastar-mode`
(swap mode), and `datastar-use-view-transition` — so a single helper
covers any handler that swaps a fragment of an existing page.

- `selector` — CSS selector for the morph target. Omit for whole-body morph.
- `mode::Union{Nothing,Symbol}` — one of `:outer :inner :replace :prepend
  :append :before :after :remove`. `nothing` (the default) omits the
  header so the Datastar client uses its default (`outer`). An unknown
  symbol throws `ArgumentError`.
- `view_transition::Bool` — when `true`, adds
  `datastar-use-view-transition: true` so the client wraps the swap in a
  View Transition.

The positional `fragment_response(body, selector)` form is preserved.

# Examples
```jldoctest
julia> r = fragment_response(p("ok"), "#count");

julia> r.status, Dict(r.headers)["datastar-selector"]
(200, "#count")

julia> String(r.body)
"<p>ok</p>"

julia> r2 = fragment_response(p("ok"); selector="#count", mode=:inner,
                              view_transition=true);

julia> Dict(r2.headers)["datastar-mode"], Dict(r2.headers)["datastar-use-view-transition"]
("inner", "true")
```
"""
function fragment_response(body; selector::Union{Nothing,AbstractString}=nothing,
                           mode::Union{Nothing,Symbol}=nothing,
                           view_transition::Bool=false,
                           status::Int=200, headers=Pair{String,String}[])
    h = Pair{String,String}[]
    selector === nothing || push!(h, "datastar-selector" => String(selector))
    mode === nothing || push!(h, "datastar-mode" => String(_validate_mode(mode)))
    view_transition && push!(h, "datastar-use-view-transition" => "true")
    append!(h, headers)
    # Delegate to html_response so the Content-Type lives in one place.
    html_response(body; status, headers=h)
end

fragment_response(body, selector::AbstractString; kwargs...) =
    fragment_response(body; selector=selector, kwargs...)

"""
    redirect_via_fragment(selector, location; cookies=String[], wrapper_tag=:div) -> HTTP.Response

Datastar can't issue an HTTP 303 from a form submit it owns — the morph
algorithm replaces the target instead. This helper wraps a tiny
`<script>window.location='…'</script>` in the morph target so a Datastar
form can navigate after success. Single quotes, backslashes, and `</`
sequences in `location` are escaped (the last to keep the HTML parser
from closing the surrounding `<script>` tag mid-string).

Pass `cookies` as a vector of complete `Set-Cookie` header values to
attach session cookies to the redirect — useful for the post-login flow
where you need to set the cookie AND navigate in the same response.
Use `wrapper_tag` when the morph target is something other than a `<div>`
(e.g. `:li` for a `<li>` morph target).

For non-Datastar redirects (login form POST, plain navigation), use
[`redirect_to`](@ref) instead.

# Examples
```julia
# Login flow: morph #login-form to a navigation script + set session cookie
return redirect_via_fragment("#login-form", "/dashboard";
    cookies=["sid=\$token; HttpOnly; Path=/; SameSite=Lax"])
```
"""
function redirect_via_fragment(selector::AbstractString, location::AbstractString;
                               cookies::AbstractVector=String[],
                               wrapper_tag::Symbol=:div)
    el = Element(wrapper_tag,
                 Pair{Symbol, Any}[:id => _strip_hash(selector)],
                 Any[Raw("<script>window.location='$(_js_escape(location))'</script>")])
    headers = Pair{String, String}["Set-Cookie" => String(c) for c in cookies]
    fragment_response(el, selector; headers=headers)
end

"""
    signals_response(signals; only_if_missing=false, status=200, headers=[]) -> HTTP.Response

Send a Datastar JSON-signals patch. Body is `JSON.json(signals)` — pass
anything `JSON.jl` knows how to encode (NamedTuple, Dict, struct).
`only_if_missing=true` adds the `datastar-only-if-missing: true` header,
which tells the client to skip the merge for any signal already on the
page.

# Examples
```jldoctest
julia> r = signals_response((; count=3));

julia> r.status, Dict(r.headers)["Content-Type"]
(200, "application/json; charset=utf-8")

julia> String(r.body)
"{\\"count\\":3}"
```
"""
function signals_response(signals; only_if_missing::Bool=false,
                          status::Int=200, headers=Pair{String,String}[])
    h = Pair{String,String}["Content-Type" => "application/json; charset=utf-8"]
    only_if_missing && push!(h, "datastar-only-if-missing" => "true")
    append!(h, headers)
    HTTP.Response(status, h, JSON.json(signals))
end

"""
    script_response(js::AbstractString; script_attributes=nothing,
                    status=200, headers=[]) -> HTTP.Response

Send a Datastar `text/javascript` response — the client appends a
`<script>` tag with `js` as its body and runs it. The body is written
verbatim; the caller owns the escape. **Never** interpolate unsanitized
user input.

`script_attributes` becomes the `datastar-script-attributes` header: an
`AbstractString` passes through; anything else is JSON-encoded with
`JSON.json`.

# Examples
```jldoctest
julia> r = script_response("alert('hi')");

julia> r.status, Dict(r.headers)["Content-Type"]
(200, "text/javascript; charset=utf-8")

julia> String(r.body)
"alert('hi')"
```
"""
function script_response(js::AbstractString; script_attributes=nothing,
                         status::Int=200, headers=Pair{String,String}[])
    h = Pair{String,String}["Content-Type" => "text/javascript; charset=utf-8"]
    if script_attributes !== nothing
        attr = script_attributes isa AbstractString ?
               String(script_attributes) : JSON.json(script_attributes)
        push!(h, "datastar-script-attributes" => attr)
    end
    append!(h, headers)
    HTTP.Response(status, h, String(js))
end

_strip_hash(s::AbstractString) = chopprefix(s, "#")
# Escape: backslashes (so the JS string parser doesn't eat the next char), single
# quotes (the JS string delimiter), and "</" (the HTML parser will close the
# enclosing <script> on </script> regardless of JS quoting — break the sequence
# at the HTML level by inserting a backslash, which the JS parser ignores).
_js_escape(s::AbstractString) =
    replace(s, "\\" => "\\\\", "'" => "\\'", "</" => "<\\/")
