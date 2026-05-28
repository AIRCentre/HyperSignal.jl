### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 00000001-0000-0000-0000-000000000002
begin
    import Pkg
    Pkg.activate(mktempdir(); io=devnull)
    Pkg.develop(path=joinpath(@__DIR__, "..", "..", ".."); io=devnull)
    Pkg.add(["HTTP", "JSON", "CairoMakie", "NCDatasets", "GeoInterface"]; io=devnull)
    Pkg.instantiate(; io=devnull)
end

# ╔═╡ 00000001-0000-0000-0000-000000000003
using HyperSignal

# ╔═╡ 00000001-0000-0000-0000-000000000005
using HTTP, JSON

# ╔═╡ 00000001-0000-0000-0000-000000000006
using NCDatasets

# ╔═╡ 00000001-0000-0000-0000-000000000007
begin
    using CairoMakie
    CairoMakie.activate!(type="svg")
end

# ╔═╡ 00000001-0000-0000-0000-000000000008
# `using GeoInterface` is what loads HyperSignalMapLibreExt — the map API
# lives behind the weakdep and is unreachable until GeoInterface is in scope.
using GeoInterface

# ╔═╡ 00000001-0000-0000-0000-000000000009
using Dates, Printf

# ╔═╡ 00000001-0000-0000-0000-000000000001
md"""
# The North Atlantic is warming. Drag a box on the map.

This is the same vendored NOAA ERSSTv5 sea-surface-temperature slice as
before — but here **the map is the input**. MapLibre paints one polygon
per grid cell, colored by its mean SST over the year range you pick.
Shift-drag a rectangle and the timeseries on the right redraws for that
box; click a cell for its value; the arrows fly the camera.

Everything reactive flows through HyperSignal + Datastar:

- **Polygons** are a `fill_layer` over a `geojson_source`. The date
  sliders `@post` `{start, end}`; the server recomputes per-cell means
  and returns a `set_source_data` JS snippet that recolors in place — no
  morph, so your pan/zoom survives.
- **Shift-drag bbox** posts `{w, s, e, n}`; the server area-weights by
  `cos(lat)`, smooths, and morphs a fresh CairoMakie SVG into `#plot`.
- **Cursor lon/lat**, **camera nav**, and **click popups** are wired with
  `map_view`'s `cursor_signal`, `fly_to`, and `click_post`.

The basemap (country outlines) streams live from `demotiles.maplibre.org`;
only the pinned `maplibre-gl` library is vendored. First run installs the
plotting stack in a temp env — budget 60–120 s for the cold start.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000004
# Bring HyperSignal's tag constructors that shadow Base / Makie into scope.
import HyperSignal: div, on

# ╔═╡ 00000001-0000-0000-0000-000000000010
# The MapLibre surface is an extension module — reach it by name. Binding
# it to `M` keeps the page cells readable (`M.map_view`, `M.fill_layer`, …).
const M = Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)

# ╔═╡ 00000001-0000-0000-0000-000000000030
md"""
## Load the netCDF once

`NCDatasets` reads the vendored ERSSTv5 slice into memory: 541 monthly
timesteps (1980-01 → 2025-01), a 26 lon × 16 lat grid over the North
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

# ╔═╡ 00000001-0000-0000-0000-000000000032
# Region extent + a sensible camera, derived straight from the grid.
begin
    const W0, E0 = extrema(SST.lon)
    const S0, N0 = extrema(SST.lat)
    const CENTER = ((W0 + E0) / 2, (S0 + N0) / 2)
    const ZOOM0  = 3.0
    const YEARS  = Dates.year.(SST.time)
    const Y_LO, Y_HI = extrema(YEARS)
    (; W0, E0, S0, N0, CENTER, year_range=(Y_LO, Y_HI))
end

# ╔═╡ 00000001-0000-0000-0000-000000000040
md"""
## Per-cell means → GeoJSON

`cell_features(y0, y1)` builds one GeoJSON polygon per grid cell, tagging
each with its `mean_sst` over the chosen year window (land/NaN cells are
dropped so the basemap shows through). That `FeatureCollection` is what
the `geojson_source` ships — and what `set_source_data` replaces when the
date sliders move.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000041
begin
    const DLON = abs(SST.lon[2] - SST.lon[1])
    const DLAT = abs(SST.lat[2] - SST.lat[1])

    function cell_features(y0::Int, y1::Int)
        tmask = (YEARS .>= y0) .& (YEARS .<= y1)
        feats = Dict{String, Any}[]
        for (i, lon) in enumerate(SST.lon), (j, lat) in enumerate(SST.lat)
            col   = @view SST.sst[i, j, tmask]
            valid = .!isnan.(col)
            any(valid) || continue
            m  = sum(col[valid]) / count(valid)
            x0 = lon - DLON / 2; x1 = lon + DLON / 2
            yy0 = lat - DLAT / 2; yy1 = lat + DLAT / 2
            push!(feats, Dict{String, Any}(
                "type" => "Feature",
                "geometry" => Dict{String, Any}(
                    "type" => "Polygon",
                    "coordinates" => [[[x0, yy0], [x1, yy0],
                                       [x1, yy1], [x0, yy1], [x0, yy0]]]),
                "properties" => Dict{String, Any}(
                    "mean_sst" => round(m; digits=2))))
        end
        Dict{String, Any}("type" => "FeatureCollection", "features" => feats)
    end
end

# ╔═╡ 00000001-0000-0000-0000-000000000042
md"""
## Server-side timeseries

`area_mean` is the cosine-of-latitude weighted SST over a lon/lat box,
across the full time axis; `rolling_mean` smooths with a centered window.
`plot_fragment` wraps the figure in `<div id="plot">` — the morph target
the shift-drag handler refreshes.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000043
function area_mean(lat_min::Float64, lat_max::Float64,
                   lon_min::Float64, lon_max::Float64)
    lat_mask = (SST.lat .>= lat_min) .& (SST.lat .<= lat_max)
    lon_mask = (SST.lon .>= lon_min) .& (SST.lon .<= lon_max)
    (count(lat_mask) == 0 || count(lon_mask) == 0) &&
        return fill(NaN, length(SST.time))
    w     = reshape(cosd.(SST.lat[lat_mask]), 1, count(lat_mask))
    box   = SST.sst[lon_mask, lat_mask, :]                  # (lon, lat, time)
    valid = .!isnan.(box)
    wb    = w .* ifelse.(valid, box, 0.0)
    wv    = w .* valid
    num   = dropdims(sum(wb; dims=(1, 2)); dims=(1, 2))
    den   = dropdims(sum(wv; dims=(1, 2)); dims=(1, 2))
    num ./ den
end

# ╔═╡ 00000001-0000-0000-0000-000000000044
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

# ╔═╡ 00000001-0000-0000-0000-000000000045
function make_timeseries(w, s, e, n, smooth)
    raw    = area_mean(s, n, w, e)
    smooth = max(1, Int(round(smooth)))
    series = rolling_mean(raw, smooth)
    fig = Figure(size=(480, 360))
    ax = Axis(fig[1, 1];
              title  = @sprintf("SST  ·  %.0f°–%.0f°N  %.0f°–%.0f°E  ·  %d-mo mean",
                                s, n, w, e, smooth),
              xlabel = "year", ylabel = "°C")
    yrs = Dates.year.(SST.time) .+ (Dates.month.(SST.time) .- 1) ./ 12
    lines!(ax, yrs, raw;    color=(:steelblue, 0.25), linewidth=1,   label="monthly")
    lines!(ax, yrs, series; color=:firebrick,         linewidth=2.5, label="smoothed")
    axislegend(ax; position=:lt, framevisible=false)
    fig
end

# ╔═╡ 00000001-0000-0000-0000-000000000046
plot_fragment(w, s, e, n, smooth) =
    div(id="plot",
        inline_svg(make_timeseries(w, s, e, n, smooth); id_prefix="ts_"))

# ╔═╡ 00000001-0000-0000-0000-000000000050
md"""
## The map layers

A `fill_layer` colors each cell by `mean_sst` through an `interpolate`
expression — the paint DSL renders straight to a MapLibre array. A faint
`line_layer` draws cell edges. The `geojson_source` is seeded with the
default decade; the date sliders swap its data at runtime.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000051
begin
    const START0, END0 = 2015, 2024
    # SST color ramp (°C). interpolate() lowers to a MapLibre paint array.
    sst_paint = M.interpolate(M.linear(), M.prop_get(:mean_sst),
                              0  => "#2c7bb6", 8  => "#abd9e9",
                              16 => "#ffffbf", 22 => "#fdae61",
                              28 => "#d7191c")
    cells_source = M.geojson_source(cell_features(START0, END0))
    fill_lyr = M.fill_layer("cells-fill"; source="cells",
                            paint=Dict("fill-color" => sst_paint,
                                       "fill-opacity" => 0.78))
    edge_lyr = M.line_layer("cells-edge"; source="cells",
                            paint=Dict("line-color" => "#33333333",
                                       "line-width" => 0.4))
end

# ╔═╡ 00000001-0000-0000-0000-000000000060
md"""
## Local HTTP server

`GET /maplibre-gl.{js,css}` and `GET /datastar.js` ship the vendored
runtimes. `POST /cells` recolors the polygons (`set_source_data`).
`POST /series` redraws the timeseries for the dragged bbox and echoes the
box back into `$bbox` so the smoothing slider can reuse it. `POST /click`
returns a `maplibregl.Popup` for the clicked cell. The `OPTIONS` routes
answer the CORS preflight Datastar's cross-origin `fetch` triggers inside
Pluto.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000061
begin
    const ASSET_DIR = joinpath(@__DIR__, "assets")
    const DATASTAR_JS = read(joinpath(ASSET_DIR, "datastar.js"), String)
    const MAPLIBRE_JS = read(joinpath(ASSET_DIR, "maplibre", "maplibre-gl.js"), String)
    const MAPLIBRE_CSS = read(joinpath(ASSET_DIR, "maplibre", "maplibre-gl.css"), String)
end

# ╔═╡ 00000001-0000-0000-0000-000000000062
const CORS_HEADERS = [
    "Access-Control-Allow-Origin"  => "*",
    "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers" => "content-type, datastar-request",
]

# ╔═╡ 00000001-0000-0000-0000-000000000063
_num(v, fallback) = v isa Number ? Float64(v) :
                    v isa AbstractString ? something(tryparse(Float64, v), fallback) :
                    fallback

# ╔═╡ 00000001-0000-0000-0000-000000000064
# Resolve the active bbox from a request: a fresh shift-drag arrives in
# `_payload`; a smoothing-only re-post carries the persisted `$bbox`.
# Falls back to the full region.
function _bbox(sig)
    src = get(sig, "_payload", nothing)
    src isa AbstractDict && haskey(src, "w") || (src = get(sig, "bbox", nothing))
    src isa AbstractDict || return (W0, S0, E0, N0)
    (_num(get(src, "w", W0), W0), _num(get(src, "s", S0), S0),
     _num(get(src, "e", E0), E0), _num(get(src, "n", N0), N0))
end

# ╔═╡ 00000001-0000-0000-0000-000000000065
function handle_cells(req::HTTP.Request)
    sig = parse_signals(req)
    y0  = clamp(round(Int, _num(get(sig, "yr0", START0), START0)), Y_LO, Y_HI)
    y1  = clamp(round(Int, _num(get(sig, "yr1", END0),   END0)),   y0,   Y_HI)
    js  = M.set_source_data(; id_prefix="map_", source="cells",
                            data=cell_features(y0, y1))
    script_response(js.html; headers=CORS_HEADERS)
end

# ╔═╡ 00000001-0000-0000-0000-000000000066
function handle_series(req::HTTP.Request)
    sig = parse_signals(req)
    w, s, e, n = _bbox(sig)
    smooth = _num(get(sig, "smooth", 12.0), 12.0)
    sse_response([
        patch_elements(plot_fragment(w, s, e, n, smooth); selector="#plot"),
        patch_signals((; bbox=(; w, s, e, n))),
    ]; headers=CORS_HEADERS)
end

# ╔═╡ 00000001-0000-0000-0000-000000000067
function handle_click(req::HTTP.Request)
    sig  = parse_signals(req)
    pl   = get(sig, "_payload", Dict{String, Any}())
    lat  = _num(get(pl, "lat", 0.0), 0.0)
    lon  = _num(get(pl, "lon", 0.0), 0.0)
    prop = get(pl, "properties", Dict{String, Any}())
    v    = get(prop, "mean_sst", nothing)
    # HyperSignal element → auto-escaped HTML for the popup body.
    body = div(strong("Cell SST"), br(),
               span(v === nothing ? "no data" :
                    @sprintf("%.2f °C", _num(v, NaN))), br(),
               span(style="color:#666;font-size:11px",
                    @sprintf("%.2f°, %.2f°", lat, lon)))
    js = "new maplibregl.Popup().setLngLat([$lon,$lat])" *
         ".setHTML($(JSON.json(render(body))))" *
         ".addTo(window.__hs_maps['map_'])"
    script_response(js; headers=CORS_HEADERS)
end

# ╔═╡ 00000001-0000-0000-0000-000000000068
function build_router()
    r = HTTP.Router()
    HTTP.register!(r, "GET", "/datastar.js", _ ->
        HTTP.Response(200, ["Content-Type" => "application/javascript; charset=utf-8",
                            CORS_HEADERS...], DATASTAR_JS))
    HTTP.register!(r, "GET", "/maplibre-gl.js", _ ->
        HTTP.Response(200, ["Content-Type" => "application/javascript; charset=utf-8",
                            CORS_HEADERS...], MAPLIBRE_JS))
    HTTP.register!(r, "GET", "/maplibre-gl.css", _ ->
        HTTP.Response(200, ["Content-Type" => "text/css; charset=utf-8",
                            CORS_HEADERS...], MAPLIBRE_CSS))
    for path in ("/cells", "/series", "/click")
        HTTP.register!(r, "OPTIONS", path, _ -> HTTP.Response(204, CORS_HEADERS))
    end
    HTTP.register!(r, "POST", "/cells",  handle_cells)
    HTTP.register!(r, "POST", "/series", handle_series)
    HTTP.register!(r, "POST", "/click",  handle_click)
    r
end

# ╔═╡ 00000001-0000-0000-0000-000000000069
begin
    # Close any prior server when the cell re-runs so we don't leak listeners.
    if @isdefined(SERVER) && SERVER isa HTTP.Server
        try close(SERVER) catch end
    end
    # Pin the port across reactive re-runs so BASE_URL — and the asset
    # <script>/<link> tags below — keep a stable identity.
    PORT   = @isdefined(PORT) ? PORT : rand(10_000:60_000)
    SERVER = HTTP.serve!(build_router(), "127.0.0.1", PORT)
    "listening on http://127.0.0.1:$(PORT)"
end

# ╔═╡ 00000001-0000-0000-0000-000000000070
BASE_URL = "http://127.0.0.1:$(PORT)"

# ╔═╡ 00000001-0000-0000-0000-000000000080
md"""
## UI components

`navbtn` mutates the camera signals on click; the map's `data-effect`
(below) flies to them. `yearslider` / `smoothslider` bind a signal and
`@post` the matching route, debounced 300 ms.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000081
# A camera-nav button: clicking runs a JS expression that reassigns the
# `$nav_*` signals. The map's data-effect watches those and flies there.
navbtn(glyph, expr) =
    button(glyph, on(:click, expr); type="button",
           style="min-width:34px;padding:5px 9px;font-size:15px;cursor:pointer")

# ╔═╡ 00000001-0000-0000-0000-000000000082
function yearslider(text, sig, init)
    label(span(text), " ",
        span(ds_text("\$$sig.toFixed(0)");
             style="font-variant-numeric:tabular-nums"),
        input(:type => "range",
              :min => string(Y_LO), :max => string(Y_HI), :step => "1",
              :value => string(init),
              ds_bind(sig),
              on(:input, ds_post("$(BASE_URL)/cells"); debounce=300),
              :style => "width:100%"))
end

# ╔═╡ 00000001-0000-0000-0000-000000000083
smoothslider() =
    label(span("smooth"), " ",
        span(ds_text("\$smooth.toFixed(0) + ' mo'");
             style="font-variant-numeric:tabular-nums"),
        input(:type => "range", :min => "1", :max => "36", :step => "1",
              :value => "12",
              ds_bind("smooth"),
              on(:input, ds_post("$(BASE_URL)/series"); debounce=300),
              :style => "width:100%"))

# ╔═╡ 00000001-0000-0000-0000-000000000090
md"""
## The page

`map_view` emits the container plus the init `<script>`. Viewport, cursor,
click, and shift-drag bbox are wired through its kwargs. The camera nav
buttons write `$nav_center` / `$nav_zoom`; a single `data-effect` flies
the map to them — kept separate from the map's own `$map_*` readout
signals so the moveend echo can't feed back into a flyTo loop.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000091
Frag(
    # Vendored MapLibre, served by our own HTTP route. Classic script so
    # `maplibregl` is a global by the time map_view's init script runs.
    script(src="$(BASE_URL)/maplibre-gl.js"),
    link(rel="stylesheet", href="$(BASE_URL)/maplibre-gl.css"),
    script(src="$(BASE_URL)/datastar.js", type="module"),
    style("""
        .demo { font-family: system-ui, sans-serif; max-width: 1100px;
                padding:18px 22px; border-radius:10px;
                box-shadow: 0 2px 14px rgba(0,0,0,.08); }
        .demo h3 { margin:0 0 6px; font-weight:600; }
        .demo .nav { display:flex; gap:6px; align-items:center;
                     margin:6px 0 12px; flex-wrap:wrap; }
        .demo .grid { display:grid; grid-template-columns: 1fr 1fr;
                      gap:14px; align-items:start; }
        .demo .mapwrap { position:relative; }
        .demo #map_root { height:360px; border-radius:8px; overflow:hidden; }
        .demo .readout { position:absolute; left:8px; bottom:8px; z-index:5;
                         background:rgba(0,0,0,.6); color:#fff; padding:3px 8px;
                         border-radius:5px; font:12px/1.4 monospace;
                         pointer-events:none; }
        .demo #plot svg { max-width:100%; height:auto; }
        .demo .sliders { display:grid; grid-template-columns:1fr 1fr 1fr;
                         gap:8px 18px; margin-top:14px; }
        .demo label { display:grid; grid-template-columns:64px 56px 1fr;
                      align-items:center; gap:8px; }
        .demo .hint { color:#666; font-size:12px; margin-top:6px; }
    """),
    div(class="demo",
        ds_signals((; map_center=collect(CENTER), map_zoom=ZOOM0,
                      map_cursor=nothing,
                      nav_center=collect(CENTER), nav_zoom=ZOOM0,
                      bbox=(; w=W0, s=S0, e=E0, n=N0),
                      yr0=START0, yr1=END0, smooth=12)),
        # Fly the camera whenever a nav button writes $nav_center/$nav_zoom.
        ds_effect("let m=window.__hs_maps['map_'];" *
                  "m&&m.flyTo({center:\$nav_center,zoom:\$nav_zoom,duration:400})"),
        h3("North Atlantic SST — the map is the input"),
        div(class="nav",
            navbtn("⟲", "\$nav_center=$(collect(CENTER)); \$nav_zoom=$(ZOOM0)"),
            navbtn("←", "\$nav_center=[\$nav_center[0]-6,\$nav_center[1]]"),
            navbtn("→", "\$nav_center=[\$nav_center[0]+6,\$nav_center[1]]"),
            navbtn("↑", "\$nav_center=[\$nav_center[0],\$nav_center[1]+5]"),
            navbtn("↓", "\$nav_center=[\$nav_center[0],\$nav_center[1]-5]"),
            navbtn("＋", "\$nav_zoom=Math.min(10,\$nav_zoom+1)"),
            navbtn("－", "\$nav_zoom=Math.max(1,\$nav_zoom-1)"),
            span(class="hint", "shift-drag a box to pick the timeseries region")),
        div(class="grid",
            div(class="mapwrap",
                M.map_view(; id_prefix="map_",
                           style="https://demotiles.maplibre.org/style.json",
                           center=CENTER, zoom=ZOOM0,
                           sources=(; cells=cells_source),
                           layers=(fill_lyr, edge_lyr),
                           center_signal="map_center",
                           zoom_signal="map_zoom",
                           cursor_signal="map_cursor",
                           click_post="$(BASE_URL)/click",
                           click_layers=["cells-fill"],
                           bbox_post="$(BASE_URL)/series"),
                div(class="readout",
                    ds_text("\$map_cursor ? " *
                            "(\$map_cursor[1]).toFixed(2)+'°, '+(\$map_cursor[0]).toFixed(2)+'°'" *
                            " : 'move over the map'"))),
            plot_fragment(W0, S0, E0, N0, 12)),
        div(class="sliders",
            yearslider("start", "yr0", START0),
            yearslider("end", "yr1", END0),
            smoothslider()),
        p(class="hint",
          "Polygons: mean SST over the year window. Drag the sliders to ",
          "recolor (set_source_data); shift-drag the map to refresh the plot.")),
)

# ╔═╡ Cell order:
# ╟─00000001-0000-0000-0000-000000000001
# ╠═00000001-0000-0000-0000-000000000002
# ╠═00000001-0000-0000-0000-000000000003
# ╠═00000001-0000-0000-0000-000000000005
# ╠═00000001-0000-0000-0000-000000000006
# ╠═00000001-0000-0000-0000-000000000007
# ╠═00000001-0000-0000-0000-000000000008
# ╠═00000001-0000-0000-0000-000000000009
# ╠═00000001-0000-0000-0000-000000000004
# ╠═00000001-0000-0000-0000-000000000010
# ╟─00000001-0000-0000-0000-000000000030
# ╠═00000001-0000-0000-0000-000000000031
# ╠═00000001-0000-0000-0000-000000000032
# ╟─00000001-0000-0000-0000-000000000040
# ╠═00000001-0000-0000-0000-000000000041
# ╟─00000001-0000-0000-0000-000000000042
# ╠═00000001-0000-0000-0000-000000000043
# ╠═00000001-0000-0000-0000-000000000044
# ╠═00000001-0000-0000-0000-000000000045
# ╠═00000001-0000-0000-0000-000000000046
# ╟─00000001-0000-0000-0000-000000000050
# ╠═00000001-0000-0000-0000-000000000051
# ╟─00000001-0000-0000-0000-000000000060
# ╠═00000001-0000-0000-0000-000000000061
# ╠═00000001-0000-0000-0000-000000000062
# ╠═00000001-0000-0000-0000-000000000063
# ╠═00000001-0000-0000-0000-000000000064
# ╠═00000001-0000-0000-0000-000000000065
# ╠═00000001-0000-0000-0000-000000000066
# ╠═00000001-0000-0000-0000-000000000067
# ╠═00000001-0000-0000-0000-000000000068
# ╠═00000001-0000-0000-0000-000000000069
# ╠═00000001-0000-0000-0000-000000000070
# ╟─00000001-0000-0000-0000-000000000080
# ╠═00000001-0000-0000-0000-000000000081
# ╠═00000001-0000-0000-0000-000000000082
# ╠═00000001-0000-0000-0000-000000000083
# ╟─00000001-0000-0000-0000-000000000090
# ╠═00000001-0000-0000-0000-000000000091
