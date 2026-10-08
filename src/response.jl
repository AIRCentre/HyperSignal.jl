# Default header, skipped when caller supplied it (case-insensitive, RFC 9110 §5.1).
# Two Content-Type lines on the wire parse differently per consumer:
# HTTP.header reads the first, Dict()/browser fetch the last.
function _with_default(extra, name::String, val::String)
    lname = lowercase(name)
    any(lowercase(String(k)) == lname for (k, _) in extra) && return extra
    h = Pair{String,String}[name => val]
    append!(h, extra)
    h
end

"""
    html_response(body; status=200, headers=[]) -> HTTP.Response

Render `body` (anything renderable) into an `HTTP.Response` with
`Content-Type: text/html; charset=utf-8`. For full-page GETs.

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
    h = _with_default(headers, "Content-Type", "text/html; charset=utf-8")
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

Like [`html_response`](@ref) plus the Datastar fragment control headers
`datastar-selector` (morph target), `datastar-mode` (swap mode) and
`datastar-use-view-transition`, for handlers that swap a fragment of an
existing page.

- `selector` — CSS selector for the morph target. Omit for whole-body morph.
- `mode::Union{Nothing,Symbol}` — one of `:outer :inner :replace :prepend
  :append :before :after :remove`. `nothing` (default) omits the header, so
  the Datastar client uses its default (`outer`). Unknown symbol throws
  `ArgumentError`.
- `view_transition::Bool` — `true` adds `datastar-use-view-transition: true`;
  the client wraps the swap in a View Transition.

# Examples
```jldoctest
julia> r = fragment_response(p("ok"), "#count");

julia> r.status, HTTP.header(r, "datastar-selector")
(200, "#count")

julia> String(r.body)
"<p>ok</p>"

julia> r2 = fragment_response(p("ok"); selector="#count", mode=:inner,
                              view_transition=true);

julia> HTTP.header(r2, "datastar-mode"), HTTP.header(r2, "datastar-use-view-transition")
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
    html_response(body; status, headers=h)
end

fragment_response(body, selector::AbstractString; kwargs...) =
    fragment_response(body; selector=selector, kwargs...)

"""
    redirect_via_fragment(selector, location; cookies=String[], wrapper_tag=:div) -> HTTP.Response

Datastar can't follow an HTTP 303 from a form submit it owns: the morph
replaces the target instead. This helper puts a
`<script>window.location='…'</script>` in the morph target so a Datastar
form can navigate after success. Single quotes, backslashes and `</`
sequences in `location` are escaped (`</` so the HTML parser doesn't close
the surrounding `<script>` mid-string).

`selector` must be a single `#id`; anything else throws `ArgumentError`.
`cookies` is a vector of complete `Set-Cookie` header values, e.g. to set a
session cookie and navigate in one response. `wrapper_tag` sets the morph
target's tag when it isn't a `<div>` (e.g. `:li`).

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
    # target's `id` = selector minus `#`: `.card` / `#a #b` would never match (silent no-op),
    # CR/LF would land raw in the `datastar-selector` header
    (startswith(selector, "#") && !occursin(r"\s", selector) && length(selector) > 1) ||
        throw(ArgumentError("redirect_via_fragment: selector must be a single \"#id\" " *
              "(the morph target is rendered with that id), got $(repr(selector))"))
    el = Element(wrapper_tag,
                 Pair{Symbol, Any}[:id => chopprefix(selector, "#")],
                 Any[Raw("<script>window.location='$(_js_str_escape(location))'</script>")])
    headers = Pair{String, String}["Set-Cookie" => String(c) for c in cookies]
    fragment_response(el, selector; headers=headers)
end

"""
    signals_response(signals; only_if_missing=false, status=200, headers=[]) -> HTTP.Response

Send a Datastar JSON-signals patch. Body is `JSON.json(signals)`: any value
`JSON.jl` encodes (NamedTuple, Dict, struct). `only_if_missing=true` adds the
`datastar-only-if-missing: true` header; the client skips signals already on
the page.

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
    h = Pair{String,String}[]
    only_if_missing && push!(h, "datastar-only-if-missing" => "true")
    append!(h, headers)
    h = _with_default(h, "Content-Type", "application/json; charset=utf-8")
    HTTP.Response(status, h, JSON.json(signals))
end

"""
    script_response(js::AbstractString; script_attributes=nothing,
                    status=200, headers=[]) -> HTTP.Response

Send a Datastar `text/javascript` response; the client appends a `<script>`
tag with `js` as its body and runs it. Body is written verbatim, caller owns
escaping. **Never** interpolate unsanitized user input.

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
    h = Pair{String,String}[]
    if script_attributes !== nothing
        attr = script_attributes isa AbstractString ?
               String(script_attributes) : JSON.json(script_attributes)
        push!(h, "datastar-script-attributes" => attr)
    end
    append!(h, headers)
    h = _with_default(h, "Content-Type", "text/javascript; charset=utf-8")
    HTTP.Response(status, h, String(js))
end
