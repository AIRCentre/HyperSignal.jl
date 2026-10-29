# Drives headless Chromium over the DevTools protocol, so tests can check what
# generated JS does in a real page. Without a browser the browser tests skip,
# unless HS_REQUIRE_CDP=1 (set in CI) turns a missing browser into a failure.
module CDP

using HTTP, JSON, Sockets

const CHROMIUM = let p = get(ENV, "HS_CHROMIUM", nothing)
    p === nothing ? something(Sys.which("chromium"), Sys.which("chromium-browser"),
                              Sys.which("google-chrome"), "/usr/bin/chromium") :
                    something(Sys.which(p), p)
end

available() = Sys.isexecutable(CHROMIUM)
required() = get(ENV, "HS_REQUIRE_CDP", "") == "1"

mutable struct Page
    ws::Any
    next_id::Int
    replies::Dict{Int, Channel{Any}}
    events::Vector{Any}
    lock::ReentrantLock
end

struct Browser
    proc::Base.Process
    port::Int
    dir::String
end

# A browser that is installed but can't start (sandbox, missing libs) is a
# missing browser, not a failing test.
struct LaunchError <: Exception
    msg::String
end
Base.showerror(io::IO, e::LaunchError) = print(io, "LaunchError: ", e.msg)

include("http_port.jl")

function _devtools_port(dir, proc; timeout=20)
    f = joinpath(dir, "DevToolsActivePort")
    t0 = time()
    while !(isfile(f) && countlines(f) >= 1)
        process_running(proc) || throw(LaunchError("chromium exited before opening its DevTools port"))
        time() - t0 > timeout && throw(LaunchError("chromium did not open its DevTools port in $(timeout)s"))
        sleep(0.05)
    end
    parse(Int, readline(f))
end

function with_browser(f)
    dir = mktempdir()
    # SwiftShader gives headless Chromium a WebGL context for MapLibre.
    cmd = `$CHROMIUM --headless=new --remote-debugging-port=0 --user-data-dir=$dir
           --no-first-run --no-default-browser-check --use-angle=swiftshader
           --enable-unsafe-swiftshader --window-size=1000,800 about:blank`
    proc = run(pipeline(cmd; stdout=devnull, stderr=devnull); wait=false)
    try
        port = _devtools_port(dir, proc)
        f(Browser(proc, port, dir))
    finally
        kill(proc)
        wait(proc)
        # Chromium's helper processes can outlive the main one by a moment.
        for _ in 1:50
            try
                rm(dir; recursive=true, force=true)
                break
            catch
                sleep(0.1)
            end
        end
    end
end

function _dispatch(page::Page, msg)
    id = get(msg, "id", nothing)
    if id === nothing
        lock(() -> push!(page.events, msg), page.lock)
    else
        ch = lock(() -> pop!(page.replies, id, nothing), page.lock)
        ch === nothing || !isopen(ch) || put!(ch, msg)
    end
end

function call(page::Page, method, params=Dict(); timeout=10)
    ch = Channel{Any}(1)
    id = lock(page.lock) do
        page.next_id += 1
        page.replies[page.next_id] = ch
        page.next_id
    end
    HTTP.WebSockets.send(page.ws, JSON.json(Dict("id" => id, "method" => method, "params" => params)))
    timer = Timer(_ -> isready(ch) || close(ch), timeout)
    msg = try
        take!(ch)
    catch
        lock(() -> delete!(page.replies, id), page.lock)
        error("CDP $method: no reply in $(timeout)s")
    finally
        close(timer)
    end
    haskey(msg, "error") && error("CDP $method: $(msg["error"])")
    msg["result"]
end

"""
    with_page(f, browser, routes)

Serves `routes` (path => HTML string, path => (content_type, body), or
path => req -> HTTP.Response) on a local port and opens a new tab. Calls `f(page, base_url)`.
"""
function with_page(f, browser::Browser, routes::AbstractDict)
    handler = function (req::HTTP.Request)
        path = String(first(split(req.target, '?')))
        r = get(routes, path, nothing)
        r === nothing && return HTTP.Response(404, "not found")
        r isa Function && return r(req)
        ctype, body = r isa Tuple ? r : ("text/html; charset=utf-8", r)
        HTTP.Response(200, ["Content-Type" => ctype], body)
    end
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    srv = quiet(() -> HTTP.serve!(handler, "127.0.0.1", 0))
    try
        port = bound_port(srv)
        # HTTP 1 pools this connection and the WebSocket reuses it; the pool's idle
        # monitor then closes it under the WebSocket's final flush.
        nopool = pkgversion(HTTP) < v"2" ? (; closeimmediately=true) : (;)
        tab = JSON.parse(String(HTTP.request("PUT",
            "http://127.0.0.1:$(browser.port)/json/new?about:blank"; nopool...).body))
        try
            opened = false
            function session(ws)
                opened = true
                page = Page(ws, 0, Dict{Int, Channel{Any}}(), Any[], ReentrantLock())
                reader = @async try
                    while true
                        _dispatch(page, JSON.parse(String(HTTP.WebSockets.receive(ws))))
                    end
                catch e
                    # A closed socket ends the loop; anything else would leave every
                    # later call to time out with no cause shown.
                    HTTP.WebSockets.isclosed(ws) || @error "CDP reader stopped" exception=e
                end
                call(page, "Page.enable")
                call(page, "Runtime.enable")
                f(page, "http://127.0.0.1:$port")
            end
            # The handshake can still meet a stale connection; retry it, never the page body.
            for attempt in 1:3
                try
                    return HTTP.WebSockets.open(session, tab["webSocketDebuggerUrl"])
                catch
                    (opened || attempt == 3) && rethrow()
                    sleep(0.2)
                end
            end
        finally
            HTTP.request("GET", "http://127.0.0.1:$(browser.port)/json/close/$(tab["id"])";
                         status_exception=false, nopool...)
        end
    finally
        quiet(() -> close(srv))
    end
end

events(page::Page, method) =
    lock(() -> [e["params"] for e in page.events if e["method"] == method], page.lock)

function goto(page::Page, url; timeout=10)
    n = length(events(page, "Page.loadEventFired"))
    call(page, "Page.navigate", Dict("url" => url))
    wait_for(() -> length(events(page, "Page.loadEventFired")) > n; timeout,
             what="load of $url")
end

"""
    js(page, expr)

Evaluates `expr` in the page, awaits a returned Promise and returns the
JSON value. A thrown exception becomes an `ErrorException`.
"""
function js(page::Page, expr; timeout=10)
    r = call(page, "Runtime.evaluate",
             Dict("expression" => expr, "returnByValue" => true,
                  "awaitPromise" => true, "userGesture" => true); timeout)
    haskey(r, "exceptionDetails") &&
        error("page JS threw: $(get(get(r["exceptionDetails"], "exception", Dict()), "description", r["exceptionDetails"]))")
    get(r["result"], "value", nothing)
end

function wait_for(cond; timeout=10, what="condition")
    t0 = time()
    while !cond()
        time() - t0 > timeout && error("timed out after $(timeout)s waiting for $what")
        sleep(0.05)
    end
    true
end

wait_js(page::Page, expr; timeout=10) =
    wait_for(() -> js(page, expr) === true; timeout, what=expr)

function mouse(page::Page, type, x, y; button="left", click_count=1,
               buttons=type == "mouseReleased" || button == "none" ? 0 : button == "right" ? 2 : 1)
    call(page, "Input.dispatchMouseEvent",
         Dict("type" => type, "x" => x, "y" => y, "button" => button,
              "buttons" => buttons, "clickCount" => click_count, "pointerType" => "mouse"))
end

function drag(page::Page, from, to; button="left", steps=10)
    mouse(page, "mouseMoved", from...; button="none")
    mouse(page, "mousePressed", from...; button)
    for i in 1:steps
        t = i / steps
        mouse(page, "mouseMoved", from[1] + t * (to[1] - from[1]), from[2] + t * (to[2] - from[2]);
              button, buttons=button == "right" ? 2 : 1)
        sleep(0.02)
    end
    mouse(page, "mouseReleased", to...; button)
end

touch(page::Page, type, points) =
    call(page, "Input.dispatchTouchEvent", Dict("type" => type,
         "touchPoints" => [Dict("x" => x, "y" => y, "id" => i) for (i, (x, y)) in enumerate(points)]))

function click(page::Page, x, y)
    mouse(page, "mouseMoved", x, y; button="none")
    mouse(page, "mousePressed", x, y)
    mouse(page, "mouseReleased", x, y)
end

# The second press carries click_count=2, which makes the browser fire dblclick.
function dblclick(page::Page, x, y)
    for n in 1:2
        mouse(page, "mousePressed", x, y; click_count=n)
        mouse(page, "mouseReleased", x, y; click_count=n)
    end
end

# `key_code` sets evt.keyCode, which some handlers (MapLibre's keyboard) read instead of evt.key.
function key(page::Page, key; code=key, modifiers=0, text=nothing, key_code=0)
    down = Dict{String, Any}("type" => text === nothing ? "rawKeyDown" : "keyDown",
                             "key" => key, "code" => code, "modifiers" => modifiers,
                             "windowsVirtualKeyCode" => key_code)
    text === nothing || (down["text"] = text)
    call(page, "Input.dispatchKeyEvent", down)
    call(page, "Input.dispatchKeyEvent",
         Dict("type" => "keyUp", "key" => key, "code" => code, "modifiers" => modifiers,
              "windowsVirtualKeyCode" => key_code))
end

end
