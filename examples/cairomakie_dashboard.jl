# A CairoMakie dashboard — two figures inlined on the same page,
# auto-refreshed every second via a Datastar polling action.
#
# Run:
#   julia --project=examples examples/cairomakie_dashboard.jl
# then open http://127.0.0.1:8080 in a browser. Datastar polls
# /plots every second and morphs the two figures in place; the
# two id_prefixes keep the SVG clip-path / glyph IDs from colliding.
#
# This is the proof of the front-row CairoMakie claim: drop a Figure
# straight into a page tree, no fork-and-rewrite step.

using HTTP, HyperSignal, CairoMakie, Downloads
using HyperSignal: div

const DATASTAR_VERSION = "v$(HyperSignal.DATASTAR_SUPPORTED_VERSION)"
const DATASTAR_URL     = "https://cdn.jsdelivr.net/gh/starfederation/datastar@$(DATASTAR_VERSION)/bundles/datastar.js"
const DATASTAR_PATH    = joinpath(@__DIR__, "datastar-$(DATASTAR_VERSION).js")

function ensure_datastar()
    isfile(DATASTAR_PATH) && return DATASTAR_PATH
    @info "Downloading Datastar bundle" DATASTAR_URL DATASTAR_PATH
    Downloads.download(DATASTAR_URL, DATASTAR_PATH)
    DATASTAR_PATH
end

const DATASTAR_BODY = read(ensure_datastar())

function make_line_figure()
    fig = Figure(size=(640, 320))
    ax = Axis(fig[1, 1], title="Random walk", xlabel="step", ylabel="value",
              limits=(1, 50, -15, 15))
    lines!(ax, 1:50, cumsum(randn(50)))
    fig
end

function make_scatter_figure()
    fig = Figure(size=(640, 320))
    ax = Axis(fig[1, 1], title="Random scatter", xlabel="x", ylabel="y",
              limits=(-4, 4, -4, 4))
    scatter!(ax, randn(80), randn(80); markersize=8)
    fig
end

function plots_fragment()
    div(id="plots",
        on_interval(ds_get("/plots"); ms=1000),
        article(class="card",
            h2("Line"),
            div(class="plot",
                inline_svg(make_line_figure();
                           id_prefix="line_",
                           aria_label="Cumulative random walk over 50 steps"))),
        article(class="card",
            h2("Scatter"),
            div(class="plot",
                inline_svg(make_scatter_figure();
                           id_prefix="scatter_",
                           aria_label="80 random points on standard normal axes"))))
end

function home(_req)
    page = Frag(DOCTYPE,
        html(lang="en",
            head(meta(charset="UTF-8"),
                 title("HyperSignal × CairoMakie"),
                 script(type="module", src="/datastar.js"),
                 style(""".plot { max-width: 720px; margin: 1em 0; }
                          body { font-family: system-ui; max-width: 800px; margin: 2em auto; }""")),
            body(
                h1("CairoMakie dashboard"),
                p("Datastar polls every second. Two figures, one page, ",
                  "zero id collisions."),
                plots_fragment(),
            )))
    html_response(page)
end

plots(_req) = fragment_response(plots_fragment())

datastar_js(_req) = HTTP.Response(200,
    ["Content-Type" => "application/javascript; charset=utf-8",
     "Cache-Control" => "public, max-age=31536000, immutable"],
    DATASTAR_BODY)

const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "GET", "/",            home)
HTTP.register!(ROUTER, "GET", "/plots",       plots)
HTTP.register!(ROUTER, "GET", "/datastar.js", datastar_js)

if abspath(PROGRAM_FILE) == @__FILE__
    @info "Serving on http://127.0.0.1:8080 — Ctrl-C to stop"
    HTTP.serve(ROUTER, "127.0.0.1", 8080)
end
