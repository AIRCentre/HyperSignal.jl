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

"""
    fragment_response(body, selector::AbstractString; status=200, headers=[]) -> HTTP.Response

Like [`html_response`](@ref) but also pins the Datastar morph target via
the `datastar-selector` response header. Use this for any handler that
swaps a fragment of an existing page (the common case for Datastar
@get/@post actions).

# Examples
```jldoctest
julia> r = fragment_response(p("ok"), "#count");

julia> r.status, Dict(r.headers)["datastar-selector"]
(200, "#count")

julia> String(r.body)
"<p>ok</p>"
```
"""
function fragment_response(body, selector::AbstractString;
                           status::Int=200, headers=Pair{String,String}[])
    # Delegate to html_response so the Content-Type lives in one place;
    # only the datastar-selector header is fragment-specific.
    html_response(body; status,
                  headers=["datastar-selector" => String(selector),
                           headers...])
end

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

_strip_hash(s::AbstractString) = chopprefix(s, "#")
# Escape: backslashes (so the JS string parser doesn't eat the next char), single
# quotes (the JS string delimiter), and "</" (the HTML parser will close the
# enclosing <script> on </script> regardless of JS quoting — break the sequence
# at the HTML level by inserting a backslash, which the JS parser ignores).
_js_escape(s::AbstractString) =
    replace(s, "\\" => "\\\\", "'" => "\\'", "</" => "<\\/")
