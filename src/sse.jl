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

# A `data: selector <sel>` SSE line is terminated by CR/LF/CRLF (EventSource
# treats all three as line ends), so a CR or LF in the selector would end the
# line early and corrupt the rest of the event. Validate at build time (in
# patch_elements, alongside the mode check) so the mistake surfaces at the
# call site; _encode_event re-checks as defense-in-depth for a directly
# constructed PatchElementsEvent. (Defined ABOVE patch_elements' docstring so
# the docstring stays attached to patch_elements, not this helper.)
function _validate_sse_selector(sel::AbstractString)
    ('\n' in sel || '\r' in sel) &&
        throw(ArgumentError("patch_elements: selector must not contain a CR or LF, got $(repr(sel))"))
    nothing
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
    selector === nothing || _validate_sse_selector(selector)
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
        # Defense-in-depth: patch_elements already validated this for the
        # public path; re-check here so a directly-built PatchElementsEvent
        # can't emit a CR/LF that splits the SSE line.
        _validate_sse_selector(ev.selector)
        print(io, "data: selector ", ev.selector, "\n")
    end
    ev.mode === nothing || print(io, "data: mode ", ev.mode, "\n")
    ev.view_transition && print(io, "data: useViewTransition true\n")
    # Split the payload on the full SSE line-terminator set (CR, LF, CRLF):
    # splitting on '\n' alone would leave a lone '\r' embedded in a data
    # line, which the client reads as an early line end and silently drops
    # the remainder. Strip one trailing terminator first so render() output
    # ending in a newline doesn't emit a stray `data: elements ` line.
    html = replace(ev.html, r"(?:\r\n|\r|\n)$" => "")
    for line in split(html, r"\r\n|\r|\n")
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
    h = _with_default(headers, "Connection", "keep-alive")
    h = _with_default(h, "Cache-Control", "no-cache")
    h = _with_default(h, "Content-Type", "text/event-stream; charset=utf-8")
    HTTP.Response(status, h, take!(io))
end

"""
    sse_stream(f; status=200, headers=[]) -> stream handler

Build an HTTP.jl stream handler that streams Datastar SSE events over a
chunked `text/event-stream` response. `f` receives a `writer` callable:
each call with a [`patch_elements`](@ref) / [`patch_signals`](@ref)
event encodes the event and flushes it as its own chunk so the client
sees progress in real time. Register the returned handler with
`HTTP.serve(handler, host, port; stream=true)` on **HTTP.jl 1.x**. On
**HTTP.jl 2.x**, drop the `stream=true` keyword — a `::HTTP.Stream` handler
is auto-detected as streaming — and pass the host as a `String`:
`HTTP.serve(handler, "127.0.0.1", port)`.

`writer` is **not** concurrency-safe — concurrent calls from multiple
tasks will interleave chunks. Serialize calls (or guard `writer` with
a `ReentrantLock`) if `f` fans out work.

# Example
```julia
HTTP.serve(sse_stream() do writer
    for i in 1:5
        writer(patch_elements(div(id="progress", "step \$i"); selector="#progress", mode=:inner))
        sleep(0.5)
    end
end, "127.0.0.1", 8080; stream=true)
```
"""
function sse_stream(f; status::Int=200, headers=Pair{String,String}[])
    base_headers = _with_default(headers, "Connection", "keep-alive")
    base_headers = _with_default(base_headers, "Cache-Control", "no-cache")
    base_headers = _with_default(base_headers, "Content-Type", "text/event-stream; charset=utf-8")
    function handler(stream::HTTP.Stream)
        HTTP.setstatus(stream, status)
        for (k, v) in base_headers
            HTTP.setheader(stream, k => v)
        end
        HTTP.startwrite(stream)
        writer = function (ev)
            _encode_event(stream, ev)
            flush(stream)
        end
        try
            f(writer)
        catch
            # End the chunked response cleanly so the client sees EOF and
            # keeps the bytes already flushed, rather than tearing the
            # connection down mid-chunk (which raises HTTP.RequestError).
            try; HTTP.closewrite(stream); catch; end
            rethrow()
        end
    end
    return handler
end
