# A CairoMakie dashboard — two figures inlined on the same page.
#
# Run:
#   julia --project=examples examples/cairomakie_dashboard.jl
# then open http://127.0.0.1:8080 in a browser. Refresh and the figures
# regenerate with new random data; the two id_prefixes keep the SVG
# clip-path / glyph IDs from colliding.
#
# This is the proof of the front-row CairoMakie claim: drop a Figure
# straight into a page tree, no fork-and-rewrite step.

using HTTP, HyperSignal, CairoMakie
using HyperSignal: div

function make_line_figure()
    fig = Figure(size=(640, 320))
    ax = Axis(fig[1, 1], title="Random walk", xlabel="step", ylabel="value")
    lines!(ax, 1:50, cumsum(randn(50)))
    fig
end

function make_scatter_figure()
    fig = Figure(size=(640, 320))
    ax = Axis(fig[1, 1], title="Random scatter", xlabel="x", ylabel="y")
    scatter!(ax, randn(80), randn(80); markersize=8)
    fig
end

function dashboard(_req)
    page = Frag(DOCTYPE,
        html(lang="en",
            head(meta(charset="UTF-8"),
                 title("HyperSignal × CairoMakie"),
                 style(""".plot { max-width: 720px; margin: 1em 0; }
                          body { font-family: system-ui; max-width: 800px; margin: 2em auto; }""")),
            body(
                h1("CairoMakie dashboard"),
                p("Refresh for new random data. Two figures, one page, ",
                  "zero id collisions."),
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
                                   aria_label="80 random points on standard normal axes"))),
            )))
    html_response(page)
end

if abspath(PROGRAM_FILE) == @__FILE__
    @info "Serving on http://127.0.0.1:8080 — Ctrl-C to stop"
    HTTP.serve(dashboard, "127.0.0.1", 8080)
end
