### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 00000001-0000-0000-0000-000000000002
begin
    import Pkg
    Pkg.activate(mktempdir(); io=devnull)
    Pkg.develop(path=joinpath(@__DIR__, "..", "..", ".."); io=devnull)
    Pkg.add(["HTTP", "CairoMakie", "NCDatasets"]; io=devnull)
    Pkg.instantiate(; io=devnull)
end

# ╔═╡ 00000001-0000-0000-0000-000000000003
using HyperSignal

# ╔═╡ 00000001-0000-0000-0000-000000000005
using HTTP

# ╔═╡ 00000001-0000-0000-0000-000000000006
using NCDatasets

# ╔═╡ 00000001-0000-0000-0000-000000000007
begin
    using CairoMakie
    CairoMakie.activate!(type="svg")
end

# ╔═╡ 00000001-0000-0000-0000-000000000009
using Dates

# ╔═╡ 00000001-0000-0000-0000-000000000001
md"""
# The North Atlantic is warming. Drag a slider.

A vendored netCDF holds NOAA ERSSTv5 monthly sea-surface temperature
for the North Atlantic, 1980 → present. Sliders pick a latitude band
and a rolling-mean window. Every drag debounces 300 ms, then a Julia
HTTP route slices the netCDF, area-weights by `cos(lat)`, smooths, and
re-renders the figure with CairoMakie. Datastar morphs the new SVG
into the page.

No CDN — Datastar is served from `assets/datastar.js`. No client-side
plotting — every pixel comes from a `fragment_response` on the server.

> First run installs CairoMakie + NCDatasets in a temp env. Budget
> 60–120 s for the cold start.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000004
# Bring HyperSignal's tag constructors that shadow Base / Makie into scope.
import HyperSignal: div, select, summary, on

# ╔═╡ 00000001-0000-0000-0000-000000000020
md"""
## Auto-escape, by default

Strings in children are escaped at render time. The `<script>` below
renders as text, not as a script tag — try the same thing in your
hand-rolled templating layer.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000021
p("user said: ", "<script>alert('xss')</script>")

# ╔═╡ 00000001-0000-0000-0000-000000000030
md"""
## Load the netCDF once

`NCDatasets` reads the vendored ERSSTv5 slice into memory. 541 monthly
timesteps (1980-01 → 2025-01), 16 latitudes × 26 longitudes, North
Atlantic. ~900 KB on disk.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000031
const SST = let
    ds = NCDataset(joinpath(@__DIR__, "assets", "sst.nc"))
    data = (lat   = Float64.(ds["latitude"][:]),
            lon   = Float64.(ds["longitude"][:]),
            time  = ds["time"][:],
            sst   = Float64.(coalesce.(ds["sst"][:, :, 1, :], NaN)))
    close(ds)
    data
end

# ╔═╡ 00000001-0000-0000-0000-000000000040
md"""
## Server-side plot

`area_mean` returns a single timeseries: cosine-of-latitude weighted
mean over the selected lat band and the full longitude box.
`rolling_mean` smooths with a centered window. `plot_fragment` builds
the figure and wraps it in `<div id="plot">` — that's the morph target
the page declares.

Look at `plot_fragment`: ~10 lines of Julia produce a fully
auto-escaped, server-rendered SVG that arrives over the wire as a
Datastar fragment. The same code path would normally be a Vite
project, a JSX file, and a fetch hook.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000041
function area_mean(lat_min::Float64, lat_max::Float64,
                   lon_min::Float64, lon_max::Float64)
    lat_mask = (SST.lat .>= lat_min) .& (SST.lat .<= lat_max)
    lon_mask = (SST.lon .>= lon_min) .& (SST.lon .<= lon_max)
    w        = reshape(cosd.(SST.lat[lat_mask]), 1, count(lat_mask))
    box      = SST.sst[lon_mask, lat_mask, :]                # (lon, lat, time)
    valid    = .!isnan.(box)
    wb       = w .* ifelse.(valid, box, 0.0)
    wv       = w .* valid
    num      = dropdims(sum(wb; dims=(1, 2)); dims=(1, 2))
    den      = dropdims(sum(wv; dims=(1, 2)); dims=(1, 2))
    num ./ den
end

# ╔═╡ 00000001-0000-0000-0000-000000000042
function rolling_mean(x::Vector{Float64}, w::Int)
    w <= 1 && return x
    n = length(x)
    out = similar(x)
    @inbounds for i in 1:n
        lo, hi = max(1, i - w÷2), min(n, i + w÷2)
        out[i] = sum(@view x[lo:hi]) / (hi - lo + 1)
    end
    out
end

# ╔═╡ 00000001-0000-0000-0000-000000000043
function make_timeseries(lat_min, lat_max, lon_min, lon_max, smooth)
    raw    = area_mean(lat_min, lat_max, lon_min, lon_max)
    smooth = max(1, Int(round(smooth)))
    series = rolling_mean(raw, smooth)
    fig = Figure(size=(480, 360))
    ax = Axis(fig[1, 1];
              title  = "SST  ·  $(Int(lat_min))°–$(Int(lat_max))°N  ·  $(Int(lon_min))°–$(Int(lon_max))°E  ·  $(smooth)-mo mean",
              xlabel = "year", ylabel = "°C")
    yrs = Dates.year.(SST.time) .+ (Dates.month.(SST.time) .- 1) ./ 12
    lines!(ax, yrs, raw;    color=(:steelblue, 0.25), linewidth=1, label="monthly")
    lines!(ax, yrs, series; color=:firebrick,         linewidth=2.5, label="smoothed")
    axislegend(ax; position=:lt, framevisible=false)
    fig
end

# ╔═╡ 00000001-0000-0000-0000-000000000050
md"""
## Local HTTP server

Three handlers. `GET /datastar.js` ships the vendored runtime.
`POST /plot` reads the posted signals (`parse_signals`), rebuilds the
figure, and returns a `fragment_response` with `datastar-selector:
#plot`. `OPTIONS /plot` handles the CORS preflight that Datastar's
cross-origin `fetch` triggers when the page is rendered inside Pluto.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000051
const DATASTAR_JS = read(joinpath(@__DIR__, "assets", "datastar.js"), String)

# ╔═╡ 00000001-0000-0000-0000-000000000052
const CORS_HEADERS = [
    "Access-Control-Allow-Origin"  => "*",
    "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers" => "content-type, datastar-request",
]

# ╔═╡ 00000001-0000-0000-0000-000000000053
_num(v, fallback) = v isa Number ? Float64(v) :
                    v isa AbstractString ? parse(Float64, v) : fallback

# ╔═╡ 00000001-0000-0000-0000-000000000060
md"""
## The page

`ds_signals` seeds the three signals. Each `<input type=range>` uses
`ds_bind` for two-way binding and `on(:input, ds_post("/plot");
debounce=300)` to drive the server.

Read the `slider` helper below — six lines, no string-typed
`data-on:input__debounce.300ms=\"@post(...)\"` anywhere. The same
attribute name the renderer emits is what you'd otherwise type by hand
in the HTML.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000044
function make_map(lat_min, lat_max, lon_min, lon_max)
    snap = SST.sst[:, :, end]                                # (lon, lat) latest month
    fig = Figure(size=(480, 360))
    ax = Axis(fig[1, 1];
              title  = "latest month  ·  selected box outlined",
              xlabel = "lon", ylabel = "lat",
              aspect = DataAspect())
    hm = heatmap!(ax, SST.lon, SST.lat, snap;
                  colormap=:thermal, nan_color=:gray90)
    poly!(ax, Point2f[(lon_min, lat_min), (lon_max, lat_min),
                      (lon_max, lat_max), (lon_min, lat_max)];
          color=(:white, 0.0), strokecolor=:black, strokewidth=2)
    scatter!(ax, [Point2f(-28.0, 38.5)];
             marker=:star5, markersize=18, color=:white, strokecolor=:black, strokewidth=1)
    text!(ax, -27.0, 38.5; text="Azores", align=(:left, :center), fontsize=11)
    Colorbar(fig[1, 2], hm; label="°C")
    fig
end

# ╔═╡ 00000001-0000-0000-0000-000000000045
plot_fragment(lat_min, lat_max, lon_min, lon_max, smooth) =
    div(id="figs",
        div(id="plot", inline_svg(make_timeseries(lat_min, lat_max,
                                                   lon_min, lon_max, smooth);
                                  id_prefix="ts_")),
        div(id="map",  inline_svg(make_map(lat_min, lat_max, lon_min, lon_max);
                                  id_prefix="map_")))

# ╔═╡ 00000001-0000-0000-0000-000000000054
function handle_plot(req::HTTP.Request)
    sig = parse_signals(req)
    lat_min = clamp(_num(get(sig, "lat_min", 30.0), 30.0),   30.0, 58.0)
    lat_max = clamp(_num(get(sig, "lat_max", 60.0), 60.0),   lat_min + 2, 60.0)
    lon_min = clamp(_num(get(sig, "lon_min", -50.0), -50.0), -50.0, -4.0)
    lon_max = clamp(_num(get(sig, "lon_max",   0.0),  0.0),  lon_min + 2, 0.0)
    smooth  = _num(get(sig, "smooth",  12.0), 12.0)
    fragment_response(
        plot_fragment(lat_min, lat_max, lon_min, lon_max, smooth),
        "#figs"; headers=CORS_HEADERS)
end

# ╔═╡ 00000001-0000-0000-0000-000000000055
function build_router()
    r = HTTP.Router()
    HTTP.register!(r, "GET", "/datastar.js", _ ->
        HTTP.Response(200,
            ["Content-Type" => "application/javascript; charset=utf-8",
             CORS_HEADERS...],
            DATASTAR_JS))
    HTTP.register!(r, "OPTIONS", "/plot", _ -> HTTP.Response(204, CORS_HEADERS))
    HTTP.register!(r, "POST",    "/plot", handle_plot)
    r
end

# ╔═╡ 00000001-0000-0000-0000-000000000056
begin
    # Close any prior server when the cell re-runs so we don't leak listeners.
    if @isdefined(SERVER) && SERVER isa HTTP.Server
        try close(SERVER) catch end
    end
    const PORT   = rand(10_000:60_000)
    const SERVER = HTTP.serve!(build_router(), "127.0.0.1", PORT)
    "listening on http://127.0.0.1:$(PORT)"
end

# ╔═╡ 00000001-0000-0000-0000-000000000061
const BASE_URL = "http://127.0.0.1:$(PORT)"

# ╔═╡ 00000001-0000-0000-0000-000000000062
slider(name, lo, hi, step, init, suffix="") =
    label(span(name), " ",
        span(ds_text("\$$name.toFixed(1) + '$(suffix)'");
             style="font-variant-numeric: tabular-nums"),
        input(type="range", min=string(lo), max=string(hi),
              step=string(step), value=string(init),
              ds_bind(name),
              on(:input, ds_post("$(BASE_URL)/plot"); debounce=300);
              style="width:100%"))

# ╔═╡ 00000001-0000-0000-0000-000000000063
Frag(
    script(src="$(BASE_URL)/datastar.js", type="module"),
    style("""
        .demo { font-family: system-ui, sans-serif; max-width: 1140px;
                padding:18px 22px; border-radius:10px;
                box-shadow: 0 2px 14px rgba(0,0,0,.08); }
        .demo label { display:grid; grid-template-columns: 90px 70px 1fr;
                      align-items:center; gap:10px; margin:8px 0; }
        .demo h3 { margin:0 0 6px; font-weight:600; }
        .demo #figs { display:grid; grid-template-columns: 1fr 1fr;
                      gap:14px; margin-top:14px; align-items:start; }
        .demo #plot svg, .demo #map svg { max-width:100%; height:auto; }
    """),
    div(class="demo",
        ds_signals((lat_min=30.0, lat_max=60.0,
                    lon_min=-50.0, lon_max=0.0,
                    smooth=12.0)),
        h3("North Atlantic SST — drag a slider"),
        slider("lat_min", 30, 58, 2, 30, "°N"),
        slider("lat_max", 32, 60, 2, 60, "°N"),
        slider("lon_min", -50, -4, 2, -50, "°E"),
        slider("lon_max", -48, 0, 2, 0,   "°E"),
        slider("smooth",   1, 36, 1, 12,  " mo"),
        plot_fragment(30.0, 60.0, -50.0, 0.0, 12),
    ),
)

# ╔═╡ Cell order:
# ╟─00000001-0000-0000-0000-000000000001
# ╠═00000001-0000-0000-0000-000000000002
# ╠═00000001-0000-0000-0000-000000000003
# ╠═00000001-0000-0000-0000-000000000004
# ╠═00000001-0000-0000-0000-000000000005
# ╠═00000001-0000-0000-0000-000000000006
# ╠═00000001-0000-0000-0000-000000000007
# ╟─00000001-0000-0000-0000-000000000020
# ╠═00000001-0000-0000-0000-000000000021
# ╟─00000001-0000-0000-0000-000000000030
# ╠═00000001-0000-0000-0000-000000000031
# ╟─00000001-0000-0000-0000-000000000040
# ╠═00000001-0000-0000-0000-000000000041
# ╠═00000001-0000-0000-0000-000000000042
# ╠═00000001-0000-0000-0000-000000000043
# ╟─00000001-0000-0000-0000-000000000050
# ╠═00000001-0000-0000-0000-000000000051
# ╠═00000001-0000-0000-0000-000000000052
# ╠═00000001-0000-0000-0000-000000000053
# ╠═00000001-0000-0000-0000-000000000054
# ╠═00000001-0000-0000-0000-000000000055
# ╠═00000001-0000-0000-0000-000000000056
# ╟─00000001-0000-0000-0000-000000000060
# ╠═00000001-0000-0000-0000-000000000061
# ╠═00000001-0000-0000-0000-000000000062
# ╠═00000001-0000-0000-0000-000000000063
# ╠═00000001-0000-0000-0000-000000000009
# ╠═00000001-0000-0000-0000-000000000044
# ╠═00000001-0000-0000-0000-000000000045
