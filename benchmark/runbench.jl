# Run with: julia --project=benchmark benchmark/runbench.jl
#
# Why this exists: the renderer is on the request-handler hot path in
# services that swap fragments dozens of times per page interaction. A
# regression that doubles allocation count won't be caught by the
# correctness tests but will show up as p99 latency. Run this before and
# after touching elements.jl / render.jl / svg.jl.

using BenchmarkTools, HyperSignal
using HyperSignal: div, select, summary

const SUITE = BenchmarkGroup()

# A representative small fragment — what fragment_response handlers emit.
small_fragment() = div(id="count-estimate", class="count-estimate",
    small(class="muted", "~12,345 images match"))

# A larger, more realistic page: 50-row table inside a card.
function large_table(n::Int=50)
    rows = [tr(td("row $i"), td("col2-$i"), td("col3-$i")) for i in 1:n]
    article(class="card",
        h2("Results"),
        table(thead(tr(th("A"), th("B"), th("C"))), tbody(rows...)))
end

# A wide form: 100 radio_field entries — exercises the helper layer too.
function wide_form(n::Int=100)
    fields = [radio_field("opt", "v$i", "Option $i"; checked=(i==1)) for i in 1:n]
    form(on_submit(ds_post("/save"; form=true)), fieldset(legend("Pick one"), fields...))
end

# Adversarial text — every char a metacharacter so the escape branches fire.
const ADVERSARIAL_TEXT = repeat("<&>\"'", 2000)  # 10k chars

# A CairoMakie-ish SVG: real CairoMakie output is ~80-300KB. Synthesise a
# representative one without pulling the plotting stack into the bench.
function synthetic_makie_svg(npaths::Int=200)
    io = IOBuffer()
    println(io, """<?xml version="1.0" encoding="UTF-8"?>""")
    println(io, """<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x.dtd">""")
    print(io, """<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="800px" height="600px" viewBox="0 0 800 600">""")
    print(io, "<defs>")
    for i in 0:npaths
        print(io, """<clipPath id="clip$i"><rect x="0" y="0" width="800" height="600"/></clipPath>""")
    end
    print(io, "</defs>")
    for i in 0:npaths
        print(io, """<g clip-path="url(#clip$i)"><use xlink:href="#glyph$i" x="$i" y="$i"/></g>""")
    end
    print(io, "</svg>")
    String(take!(io))
end

SUITE["render"] = BenchmarkGroup()
SUITE["render"]["small fragment"] = @benchmarkable render($(small_fragment()))
SUITE["render"]["table 50 rows"] = @benchmarkable render($(large_table(50)))
SUITE["render"]["wide form 100 fields"] = @benchmarkable render($(wide_form(100)))
SUITE["render"]["escape 10k adversarial chars"] = @benchmarkable render($(ADVERSARIAL_TEXT))

SUITE["svg"] = BenchmarkGroup()
SUITE["svg"]["patch 200-path makie-like"] =
    @benchmarkable patch_svg($(synthetic_makie_svg(200)); id_prefix="fig_", aria_label="Plot")
SUITE["svg"]["patch 1k-path makie-like"] =
    @benchmarkable patch_svg($(synthetic_makie_svg(1000)); id_prefix="fig_")

SUITE["response"] = BenchmarkGroup()
SUITE["response"]["html_response of a small fragment"] =
    @benchmarkable html_response($(small_fragment()))
SUITE["response"]["fragment_response with selector"] =
    @benchmarkable fragment_response($(small_fragment()), "#count-estimate")

const JSON_SMALL = "{\"a\":1,\"b\":\"two\",\"c\":true,\"d\":null}"
const JSON_LARGE = "{" * join(["\"k$i\":$i" for i in 1:50], ",") * "}"

SUITE["signals"] = BenchmarkGroup()
SUITE["signals"]["parse 4-key JSON body"]  = @benchmarkable parse_signals($JSON_SMALL)
SUITE["signals"]["parse 50-key JSON body"] = @benchmarkable parse_signals($JSON_LARGE)

if abspath(PROGRAM_FILE) == @__FILE__
    results = run(SUITE; verbose=true)
    show(stdout, MIME"text/plain"(), results)
    println()
end
