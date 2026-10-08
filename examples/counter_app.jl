# Minimal Datastar counter app.
#
# Run:
#   julia --project=examples examples/counter_app.jl
# then open http://127.0.0.1:8080 in a browser. The button increments a
# server-side counter and Datastar morphs the new value into the page.
#
# This file is intentionally short — its job is to be a complete,
# pasteable shape of a HyperSignal + Datastar server. For a richer
# walkthrough see the docs site.

using HTTP, HyperSignal
using HyperSignal: div

const COUNTER = Ref(0)
const DATASTAR_BODY = read(joinpath(pkgdir(HyperSignal),
                                    "docs", "src", "notebooks", "assets", "datastar.js"))

function home(_req)
    page = Frag(DOCTYPE,
        html(lang="en",
            head(meta(charset="UTF-8"),
                 title("HyperSignal counter"),
                 script(type="module", src="/datastar.js")),
            body(
                h1("Counter"),
                div(id="counter", COUNTER[]),
                button("Increment",
                       on_click(ds_post("/increment"))),
                button("Reset",
                       on_click(ds_post("/reset"))),
            )))
    html_response(page)
end

function increment(_req)
    COUNTER[] += 1
    fragment_response(div(id="counter", COUNTER[]))
end

function reset(_req)
    COUNTER[] = 0
    fragment_response(div(id="counter", COUNTER[]))
end

datastar_js(_req) = HTTP.Response(200,
    ["Content-Type" => "application/javascript; charset=utf-8",
     "Cache-Control" => "public, max-age=31536000, immutable"],
    DATASTAR_BODY)

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET",  "/",            home)
HTTP.register!(ROUTER, "GET",  "/datastar.js", datastar_js)
HTTP.register!(ROUTER, "POST", "/increment",   increment)
HTTP.register!(ROUTER, "POST", "/reset",       reset)

if abspath(PROGRAM_FILE) == @__FILE__
    @info "Serving on http://127.0.0.1:8080 — Ctrl-C to stop"
    HTTP.serve(ROUTER, "127.0.0.1", 8080)
end
