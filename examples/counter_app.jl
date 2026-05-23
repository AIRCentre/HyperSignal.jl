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

function home(_req)
    page = Frag(DOCTYPE,
        html(lang="en",
            head(meta(charset="UTF-8"),
                 title("HyperSignal counter"),
                 script(type="module",
                        src="https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0-beta.11/bundles/datastar.js")),
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
    fragment_response(div(id="counter", COUNTER[]), "#counter")
end

function reset(_req)
    COUNTER[] = 0
    fragment_response(div(id="counter", COUNTER[]), "#counter")
end

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET",  "/",          home)
HTTP.register!(ROUTER, "POST", "/increment", increment)
HTTP.register!(ROUTER, "POST", "/reset",     reset)

if abspath(PROGRAM_FILE) == @__FILE__
    @info "Serving on http://127.0.0.1:8080 — Ctrl-C to stop"
    HTTP.serve(ROUTER, "127.0.0.1", 8080)
end
