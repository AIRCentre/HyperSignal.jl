module HyperSignalMapLibreExt

# MapLibre integration for HyperSignal (issue #29).
# Top-level HyperSignal exports nothing new; consumers reach into this
# extension by name or import explicitly:
#   ext = Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)
#
# All MapLibre paint expressions are JSON arrays
# (https://maplibre.org/maplibre-style-spec/expressions/). We wrap them
# in a struct so JSON encoding goes through our `JSON.lower` method and
# the value flows opaquely through the rest of the pipeline.

import HyperSignal
import GeoInterface
using JSON

struct MapLibreExpr
    value::Vector{Any}
end

JSON.lower(e::MapLibreExpr) = e.value

# ----------------------------------------------------------------------
# Paint expression DSL
# ----------------------------------------------------------------------

# Property lookup: `get(:mean_sst)` → ["get", "mean_sst"]. Accepts a
# Symbol or a String so feature property paths with dots/spaces work.
get(name::Symbol) = MapLibreExpr(Any["get", String(name)])
get(name::AbstractString) = MapLibreExpr(Any["get", String(name)])

# Literal: forces a value to be interpreted as data, not as a nested
# expression — the escape hatch for paint constants that look like arrays.
literal(x) = MapLibreExpr(Any["literal", x])

# Interpolation kind markers (zero-arg).
linear() = MapLibreExpr(Any["linear"])

# Interpolate a numeric input across stop pairs.
function interpolate(kind::MapLibreExpr, input::MapLibreExpr,
                     stops::Pair...)
    isempty(stops) &&
        throw(ArgumentError("interpolate requires at least one stop pair"))
    out = Any["interpolate", kind, input]
    for (k, v) in stops
        push!(out, k); push!(out, v)
    end
    MapLibreExpr(out)
end

# Step function: leading default, then (threshold => value) pairs.
function step(input::MapLibreExpr, default, stops::Pair...)
    out = Any["step", input, default]
    for (k, v) in stops
        push!(out, k); push!(out, v)
    end
    MapLibreExpr(out)
end

# Match expression: required keyword `default` lands as the trailing
# positional in MapLibre's wire form. A missing default would silently
# paint the un-matched features transparent — fail loud instead.
function match(input::MapLibreExpr, cases::Pair...; default=nothing)
    default === nothing &&
        throw(ArgumentError(
            "match requires a `default` kwarg — missing default silently paints features transparent"))
    out = Any["match", input]
    for (k, v) in cases
        push!(out, k); push!(out, v)
    end
    push!(out, default)
    MapLibreExpr(out)
end

# ----------------------------------------------------------------------
# Source constructors
# ----------------------------------------------------------------------

# A Source is a wire-format struct: it carries an `OrderedDict`-ish
# payload that JSON-encodes to the MapLibre source spec. We use a plain
# Dict and lower it through `JSON.lower`.

struct Source
    spec::Dict{String, Any}
end

JSON.lower(s::Source) = s.spec

# GeoJSON source. `data` may be an inline GeoJSON object (a Dict) or a
# URL string MapLibre will fetch.
function geojson_source(data; cluster::Bool=false, cluster_radius::Int=50)
    spec = Dict{String, Any}("type" => "geojson", "data" => data)
    if cluster
        spec["cluster"] = true
        spec["clusterRadius"] = cluster_radius
    end
    Source(spec)
end

# XYZ raster source for basemap tiles.
function raster_xyz_source(tiles::Vector{String};
                           tile_size::Int=256,
                           attribution::AbstractString="")
    isempty(tiles) &&
        throw(ArgumentError("raster_xyz_source requires at least one tile URL template"))
    spec = Dict{String, Any}(
        "type" => "raster",
        "tiles" => tiles,
        "tileSize" => tile_size,
    )
    isempty(attribution) || (spec["attribution"] = String(attribution))
    Source(spec)
end

# ----------------------------------------------------------------------
# Layer constructors
# ----------------------------------------------------------------------

struct Layer
    spec::Dict{String, Any}
end

JSON.lower(l::Layer) = l.spec

function _layer(type_::String, id::AbstractString;
                source::AbstractString,
                paint=nothing, layout=nothing,
                filter=nothing, source_layer=nothing)
    spec = Dict{String, Any}(
        "id" => String(id),
        "type" => type_,
        "source" => String(source),
    )
    paint === nothing || (spec["paint"] = paint)
    layout === nothing || (spec["layout"] = layout)
    filter === nothing || (spec["filter"] = filter)
    source_layer === nothing || (spec["source-layer"] = String(source_layer))
    Layer(spec)
end

fill_layer(id; kwargs...)   = _layer("fill", id; kwargs...)
line_layer(id; kwargs...)   = _layer("line", id; kwargs...)
circle_layer(id; kwargs...) = _layer("circle", id; kwargs...)
raster_layer(id; kwargs...) = _layer("raster", id; kwargs...)

# ----------------------------------------------------------------------
# GeoInterface bridge
# ----------------------------------------------------------------------
#
# Convert any GeoInterface-conformant geometry into the GeoJSON shape
# MapLibre's geojson source consumes. Dispatch is on the geom trait so
# anything implementing the GeoInterface contract flows through.

const GI = GeoInterface

_coord(geom) = [GI.getcoord(geom, i) for i in 1:GI.ncoord(geom)]

geojson(geom) = _geojson(GI.geomtrait(geom), geom)

_geojson(::GI.PointTrait, geom) =
    Dict{String, Any}("type" => "Point", "coordinates" => _coord(geom))

_geojson(::GI.LineStringTrait, geom) =
    Dict{String, Any}(
        "type" => "LineString",
        "coordinates" => [_coord(p) for p in GI.getgeom(geom)],
    )

function _geojson(::GI.PolygonTrait, geom)
    rings = [[_coord(p) for p in GI.getgeom(ring)]
             for ring in GI.getgeom(geom)]
    Dict{String, Any}("type" => "Polygon", "coordinates" => rings)
end

# Feature collection from row-like records. `rows` is anything iterable
# of NamedTuples (or any object with `getproperty` on the named cols).
function feature_collection(rows; geometry_col::Symbol,
                            properties_cols)
    features = [Dict{String, Any}(
                    "type" => "Feature",
                    "geometry" => geojson(getproperty(row, geometry_col)),
                    "properties" => Dict{String, Any}(
                        String(c) => getproperty(row, c)
                        for c in properties_cols),
                ) for row in rows]
    Dict{String, Any}("type" => "FeatureCollection",
                      "features" => features)
end

# ----------------------------------------------------------------------
# Server-returned JS helpers
# ----------------------------------------------------------------------
#
# Each helper returns a HyperSignal.Raw carrying a JS snippet that the
# Datastar client runs via executeScript. The instance handle is
# `window.__hs_maps[prefix]` so multiple maps on one page don't collide.

# Escape a string for inside a single-quoted JS literal. We escape
# backslash first, then the single quote; nothing else is special
# inside a single-quoted JS string except line terminators (which
# id_prefix should never contain in practice).
_js_squote(s::AbstractString) =
    replace(replace(String(s), "\\" => "\\\\"), "'" => "\\'")

_handle(prefix) = "window.__hs_maps['$(_js_squote(prefix))']"

function fly_to(; id_prefix::AbstractString, center,
                zoom::Union{Nothing, Real}=nothing,
                duration_ms::Integer=600)
    args = Dict{String, Any}(
        "center" => collect(center),
        "duration" => duration_ms,
    )
    zoom === nothing || (args["zoom"] = zoom)
    HyperSignal.Raw("$(_handle(id_prefix)).flyTo($(JSON.json(args)))")
end

add_source(; id_prefix::AbstractString, id::AbstractString,
           spec::Source) =
    HyperSignal.Raw(
        "$(_handle(id_prefix)).addSource(\"$id\",$(JSON.json(spec)))")

remove_source(; id_prefix::AbstractString, id::AbstractString) =
    HyperSignal.Raw("$(_handle(id_prefix)).removeSource(\"$id\")")

remove_layer(; id_prefix::AbstractString, id::AbstractString) =
    HyperSignal.Raw("$(_handle(id_prefix)).removeLayer(\"$id\")")

set_source_data(; id_prefix::AbstractString,
                source::AbstractString, data) =
    HyperSignal.Raw(
        "$(_handle(id_prefix)).getSource(\"$source\").setData($(JSON.json(data)))")

add_layer(; id_prefix::AbstractString, spec::Layer) =
    HyperSignal.Raw(
        "$(_handle(id_prefix)).addLayer($(JSON.json(spec)))")

set_paint_property(; id_prefix::AbstractString,
                   layer::AbstractString,
                   prop::AbstractString, value) =
    HyperSignal.Raw(
        "$(_handle(id_prefix)).setPaintProperty(\"$layer\",\"$prop\",$(JSON.json(value)))")

function map_call(method::Symbol, args...; id_prefix::AbstractString)
    encoded = join((JSON.json(a) for a in args), ",")
    HyperSignal.Raw("$(_handle(id_prefix)).$method($encoded)")
end

# ----------------------------------------------------------------------
# map_view + marker
# ----------------------------------------------------------------------
#
# `map_view` returns an Element tree: a namespaced container div plus a
# <script> body that initializes a MapLibre Map at the container,
# publishes the instance to window.__hs_maps[prefix], and wires
# viewport / cursor / click / bbox handlers per the kwargs.

# Build the init JS as a single string. We assemble per-feature pieces
# so opting out doesn't leave dead handler stubs (per Datastar contract).
function _init_js(; id_prefix, center, zoom, style,
                  sources, layers,
                  center_signal, zoom_signal, bounds_signal, cursor_signal,
                  click_post, bbox_post, click_layers)
    handle = _handle(id_prefix)
    container = "$(id_prefix)root"
    map_opts = Dict{String, Any}(
        "container" => container,
        "style" => style,
        "center" => collect(center),
        "zoom" => zoom,
    )

    io = IOBuffer()
    print(io, "(function(){")
    print(io, "const _m=new maplibregl.Map($(JSON.json(map_opts)));")
    print(io, "$handle=_m;")

    # Sources + layers — load once the map's style is ready.
    if !isempty(sources) || !isempty(layers)
        print(io, "_m.on('load',function(){")
        for (id, spec) in pairs(sources)
            print(io, "_m.addSource(\"$(String(id))\",$(JSON.json(spec)));")
        end
        for lyr in layers
            print(io, "_m.addLayer($(JSON.json(lyr)));")
        end
        print(io, "});")
    end

    # Viewport signals on moveend (idle update).
    if center_signal !== nothing || zoom_signal !== nothing ||
       bounds_signal !== nothing
        print(io, "_m.on('moveend',function(){")
        if center_signal !== nothing
            print(io, "const c=_m.getCenter();")
            print(io, "ctx.\$$center_signal=[c.lng,c.lat];")
        end
        if zoom_signal !== nothing
            print(io, "ctx.\$$zoom_signal=_m.getZoom();")
        end
        if bounds_signal !== nothing
            print(io, "const b=_m.getBounds();")
            print(io, "ctx.\$$bounds_signal={w:b.getWest(),s:b.getSouth(),e:b.getEast(),n:b.getNorth()};")
        end
        print(io, "});")
    end

    # Cursor signal on mousemove (live readout).
    if cursor_signal !== nothing
        print(io, "_m.on('mousemove',function(e){")
        print(io, "ctx.\$$cursor_signal=[e.lngLat.lng,e.lngLat.lat];")
        print(io, "});")
    end

    # Click handler → ds_post {lat, lon, properties} from
    # queryRenderedFeatures restricted to click_layers.
    if click_post !== nothing
        layers_js = JSON.json(click_layers)
        print(io, "_m.on('click',function(e){")
        print(io, "const f=_m.queryRenderedFeatures(e.point,{layers:$layers_js});")
        print(io, "const p=f.length?f[0].properties:{};")
        print(io, "ctx.\$_payload={lat:e.lngLat.lat,lon:e.lngLat.lng,properties:p};")
        print(io, "@post('$(_js_squote(click_post))');")
        print(io, "});")
    end

    # Shift+drag rectangle → ds_post {w, s, e, n}.
    if bbox_post !== nothing
        print(io, "let _bs=null;")
        print(io, "_m.getCanvas().addEventListener('mousedown',function(e){")
        print(io, "if(!e.shiftKey)return;e.preventDefault();_bs=_m.unproject([e.offsetX,e.offsetY]);")
        print(io, "});")
        print(io, "_m.getCanvas().addEventListener('mouseup',function(e){")
        print(io, "if(!_bs)return;const be=_m.unproject([e.offsetX,e.offsetY]);")
        print(io, "ctx.\$_payload={w:Math.min(_bs.lng,be.lng),s:Math.min(_bs.lat,be.lat),e:Math.max(_bs.lng,be.lng),n:Math.max(_bs.lat,be.lat)};")
        print(io, "@post('$(_js_squote(bbox_post))');_bs=null;")
        print(io, "});")
    end

    print(io, "})();")
    String(take!(io))
end

function map_view(; id_prefix::AbstractString="map_",
                  style::AbstractString,
                  center, zoom,
                  sources=NamedTuple(), layers=(),
                  center_signal=nothing,
                  zoom_signal=nothing,
                  bounds_signal=nothing,
                  cursor_signal=nothing,
                  click_post=nothing,
                  bbox_post=nothing,
                  click_layers::Vector{String}=String[])
    init_js = _init_js(; id_prefix, center, zoom, style,
                       sources, layers,
                       center_signal, zoom_signal, bounds_signal, cursor_signal,
                       click_post, bbox_post, click_layers)
    HyperSignal.Frag(
        HyperSignal.div(id="$(id_prefix)root"),
        HyperSignal.script(HyperSignal.Raw(init_js)),
    )
end

function marker(content; lat::Real, lon::Real,
                popup=nothing, id_prefix::AbstractString="map_")
    HyperSignal.div(content,
        Symbol("data-hs-marker") => id_prefix,
        Symbol("data-lat") => string(lat),
        Symbol("data-lon") => string(lon),
    )
end

end # module
