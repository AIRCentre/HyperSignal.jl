# Datastar SSE event constructors + buffered sse_response. The streaming
# variant (long-lived connections) lives elsewhere; this file ships the
# events you can fit in one Response.

struct PatchElementsEvent
    html::String
    selector::Union{Nothing,String}
    mode::Union{Nothing,Symbol}
    view_transition::Bool
end

struct PatchSignalsEvent
    json::String
    only_if_missing::Bool
end

"""
    patch_elements(body; selector=nothing, mode=nothing, view_transition=false)

Build a `datastar-patch-elements` SSE event for [`sse_response`](@ref).
`body` is rendered with [`render`](@ref); multi-line HTML is split into
one `data: elements …` line per source line. `mode` is one of the
fragment modes accepted by [`fragment_response`](@ref); unknown symbols
throw `ArgumentError`.
"""
function patch_elements(body; selector::Union{Nothing,AbstractString}=nothing,
                        mode::Union{Nothing,Symbol}=nothing,
                        view_transition::Bool=false)
    mode === nothing || _validate_mode(mode)
    PatchElementsEvent(render(body),
                       selector === nothing ? nothing : String(selector),
                       mode, view_transition)
end

"""
    patch_signals(signals; only_if_missing=false)

Build a `datastar-patch-signals` SSE event. `signals` is JSON-encoded
with `JSON.json`. `only_if_missing=true` adds the `onlyIfMissing true`
data line so the client skips signals already present.
"""
patch_signals(signals; only_if_missing::Bool=false) =
    PatchSignalsEvent(JSON.json(signals), only_if_missing)

function _encode_event(io::IO, ev::PatchElementsEvent)
    print(io, "event: datastar-patch-elements\n")
    if ev.selector !== nothing
        '\n' in ev.selector && throw(ArgumentError("selector must not contain a newline"))
        print(io, "data: selector ", ev.selector, "\n")
    end
    ev.mode === nothing || print(io, "data: mode ", ev.mode, "\n")
    ev.view_transition && print(io, "data: useViewTransition true\n")
    # Drop a single trailing empty line so render() output that ends in '\n'
    # doesn't emit a stray `data: elements ` line (which a client would
    # reassemble as an extra newline in the payload).
    html = endswith(ev.html, '\n') ? chop(ev.html) : ev.html
    for line in split(html, '\n')
        print(io, "data: elements ", line, "\n")
    end
    print(io, "\n")
end

function _encode_event(io::IO, ev::PatchSignalsEvent)
    print(io, "event: datastar-patch-signals\n")
    ev.only_if_missing && print(io, "data: onlyIfMissing true\n")
    print(io, "data: signals ", ev.json, "\n\n")
end

"""
    sse_response(events; status=200, headers=[]) -> HTTP.Response

Buffer one or more Datastar SSE events (built by [`patch_elements`](@ref) /
[`patch_signals`](@ref)) into a single `text/event-stream` response. Use
this when a handler must emit an HTML patch and a signal patch in one
shot.

# Examples
```jldoctest
julia> r = sse_response([
           patch_elements(HyperSignal.div(id="card", "Saved"); selector="#card"),
           patch_signals((; saved=true)),
       ]);

julia> r.status, Dict(r.headers)["Content-Type"]
(200, "text/event-stream; charset=utf-8")

julia> print(String(r.body))
event: datastar-patch-elements
data: selector #card
data: elements <div id="card">Saved</div>

event: datastar-patch-signals
data: signals {"saved":true}

```
"""
function sse_response(events; status::Int=200, headers=Pair{String,String}[])
    io = IOBuffer()
    for ev in events
        _encode_event(io, ev)
    end
    h = Pair{String,String}[
        "Content-Type" => "text/event-stream; charset=utf-8",
        "Cache-Control" => "no-cache",
        "Connection" => "keep-alive",
    ]
    append!(h, headers)
    HTTP.Response(status, h, take!(io))
end
