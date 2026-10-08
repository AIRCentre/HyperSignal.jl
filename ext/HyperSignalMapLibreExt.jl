module HyperSignalMapLibreExt

# Nothing exported: reach in via `Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)`.

# Expressions are plain JSON arrays; the wrapper routes encoding through `JSON.lower`.
# https://maplibre.org/maplibre-style-spec/expressions/

import HyperSignal
import GeoInterface
using JSON

struct MapLibreExpr
    value::Vector{Any}
end

JSON.lower(e::MapLibreExpr) = e.value

# `prop_get`, `expr_step`, `expr_match`: `get`/`step`/`match` would shadow Base here
prop_get(name::Union{Symbol, AbstractString}) = MapLibreExpr(Any["get", String(name)])

# MapLibre reads a bare array as an expression; `literal` marks array constants as data.
literal(x) = MapLibreExpr(Any["literal", x])

linear() = MapLibreExpr(Any["linear"])

_push_stops!(out, stops) = (for (k, v) in stops; push!(out, k, v); end; out)

function interpolate(kind::MapLibreExpr, input::MapLibreExpr,
                     stops::Pair...)
    isempty(stops) &&
        throw(ArgumentError("interpolate requires at least one stop pair"))
    out = Any["interpolate", kind, input]
    MapLibreExpr(_push_stops!(out, stops))
end

function expr_step(input::MapLibreExpr, default, stops::Pair...)
    out = Any["step", input, default]
    MapLibreExpr(_push_stops!(out, stops))
end

# `default` is the trailing positional on the wire; omitted, unmatched features paint transparent.
function expr_match(input::MapLibreExpr, cases::Pair...; default=nothing)
    default === nothing &&
        throw(ArgumentError(
            "match requires a `default` kwarg — missing default silently paints features transparent"))
    out = Any["match", input]
    _push_stops!(out, cases)
    push!(out, default)
    MapLibreExpr(out)
end

struct Source
    spec::Dict{String, Any}
end

JSON.lower(s::Source) = s.spec

# `data`: inline GeoJSON (Dict) or a URL string MapLibre fetches.
function geojson_source(data; cluster::Bool=false, cluster_radius::Int=50)
    spec = Dict{String, Any}("type" => "geojson", "data" => data)
    if cluster
        spec["cluster"] = true
        spec["clusterRadius"] = cluster_radius
    end
    Source(spec)
end

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

const GI = GeoInterface

_coord(geom) = [GI.getcoord(geom, i) for i in 1:GI.ncoord(geom)]

geojson(geom) = _geojson(GI.geomtrait(geom), geom)

# Multi* forms reuse the singular nesting: a LineString is one element of
# MultiLineString coordinates, a Polygon's rings one element of MultiPolygon's.
_line(ls)  = [_coord(p) for p in GI.getgeom(ls)]
_rings(pg) = [_line(ring) for ring in GI.getgeom(pg)]

_geojson(::GI.PointTrait, geom) =
    Dict{String, Any}("type" => "Point", "coordinates" => _coord(geom))

_geojson(::GI.LineStringTrait, geom) =
    Dict{String, Any}("type" => "LineString", "coordinates" => _line(geom))

_geojson(::GI.PolygonTrait, geom) =
    Dict{String, Any}("type" => "Polygon", "coordinates" => _rings(geom))

_geojson(::GI.MultiPointTrait, geom) =
    Dict{String, Any}("type" => "MultiPoint",
                      "coordinates" => [_coord(p) for p in GI.getgeom(geom)])

_geojson(::GI.MultiLineStringTrait, geom) =
    Dict{String, Any}("type" => "MultiLineString",
                      "coordinates" => [_line(ls) for ls in GI.getgeom(geom)])

_geojson(::GI.MultiPolygonTrait, geom) =
    Dict{String, Any}("type" => "MultiPolygon",
                      "coordinates" => [_rings(pg) for pg in GI.getgeom(geom)])

_geojson(::GI.GeometryCollectionTrait, geom) =
    Dict{String, Any}("type" => "GeometryCollection",
                      "geometries" => [geojson(g) for g in GI.getgeom(geom)])

# named error instead of an opaque MethodError on internal `_geojson`
_geojson(trait, geom) = throw(ArgumentError(
    "geojson: unsupported geometry trait $(typeof(trait)); supported: Point, " *
    "LineString, Polygon, MultiPoint, MultiLineString, MultiPolygon, GeometryCollection"))

# RFC 7946 §3.2: Feature geometry MAY be null; one null row (e.g. failed geocode)
# must not crash the whole collection.
_feature_geometry(g) = (g === nothing || g === missing) ? nothing : geojson(g)

# `rows`: iterable of NamedTuples, or any objects with `getproperty` on the named cols.
function feature_collection(rows; geometry_col::Symbol,
                            properties_cols)
    features = [Dict{String, Any}(
                    "type" => "Feature",
                    "geometry" => _feature_geometry(getproperty(row, geometry_col)),
                    "properties" => Dict{String, Any}(
                        String(c) => getproperty(row, c)
                        for c in properties_cols),
                ) for row in rows]
    Dict{String, Any}("type" => "FeatureCollection",
                      "features" => features)
end

# Single-quoted JS literal. Backslash first, else later escapes get doubled.
# Raw LF/CR = SyntaxError; U+2028/9 escaped for pre-ES2019 engines.
function _js_squote(s::AbstractString)
    t = replace(String(s), "\\" => "\\\\")
    t = replace(t, "'"  => "\\'")
    t = replace(t, "\r" => "\\r")
    t = replace(t, "\n" => "\\n")
    t = replace(t, "\u2028" => "\\u2028")
    t = replace(t, "\u2029" => "\\u2029")
    t
end

# per-prefix handle keeps multiple maps on one page apart
_handle(prefix) = "window.__hs_maps['$(_js_squote(prefix))']"
_event_name(id_prefix, name) = "hs-$(id_prefix)$name"

function map_call(method::Symbol, args...; id_prefix::AbstractString)
    encoded = join((JSON.json(a) for a in args), ",")
    HyperSignal.Raw("$(_handle(id_prefix)).$method($encoded)")
end

function fly_to(; id_prefix::AbstractString, center,
                zoom::Union{Nothing, Real}=nothing,
                duration_ms::Integer=600)
    args = Dict{String, Any}(
        "center" => collect(center),
        "duration" => duration_ms,
    )
    zoom === nothing || (args["zoom"] = zoom)
    map_call(:flyTo, args; id_prefix)
end

add_source(; id_prefix::AbstractString, id::AbstractString, spec::Source) =
    map_call(:addSource, id, spec; id_prefix)

remove_source(; id_prefix::AbstractString, id::AbstractString) =
    map_call(:removeSource, id; id_prefix)

remove_layer(; id_prefix::AbstractString, id::AbstractString) =
    map_call(:removeLayer, id; id_prefix)

# Before `load` (e.g. slider dragged while first tiles load) `getSource()` is
# undefined and a bare `.setData()` throws: defer to one-shot `load` when absent.
# `setData`, never re-add: layers keep their source binding.
set_source_data(; id_prefix::AbstractString,
                source::AbstractString, data) =
    HyperSignal.Raw(
        "(function(){var m=$(_handle(id_prefix)),d=$(JSON.json(data))," *
        "f=function(){m.getSource($(JSON.json(source))).setData(d)};" *
        "m.getSource($(JSON.json(source)))?f():m.once('load',f)})()")

add_layer(; id_prefix::AbstractString, spec::Layer) =
    map_call(:addLayer, spec; id_prefix)

set_paint_property(; id_prefix::AbstractString,
                   layer::AbstractString,
                   prop::AbstractString, value) =
    map_call(:setPaintProperty, layer, prop, value; id_prefix)

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

    # Datastar parses `@post` / `$signal` only in attribute expressions, so the
    # script dispatches CustomEvents and map_view's `data-on:<event>__window`
    # attributes run the expressions.
    # `bubbles:true` required: the `__window` listener sits on `window`, and an event
    # dispatched on `document` reaches it only by bubbling; without it every channel no-ops.
    _dispatch(io, name, value_js) =
        print(io, "document.dispatchEvent(new CustomEvent($(JSON.json(_event_name(id_prefix, name))),{detail:$value_js,bubbles:true}));")

    io = IOBuffer()
    print(io, "(function(){")
    print(io, "window.__hs_maps=window.__hs_maps||{};")
    print(io, "const _m=new maplibregl.Map($(JSON.json(map_opts)));")
    print(io, "$handle=_m;")

    if !isempty(sources) || !isempty(layers)
        print(io, "_m.on('load',function(){")
        for (id, spec) in pairs(sources)
            print(io, "_m.addSource($(JSON.json(String(id))),$(JSON.json(spec)));")
        end
        for lyr in layers
            print(io, "_m.addLayer($(JSON.json(lyr)));")
        end
        print(io, "});")
    end

    # Marker scan deferred to `load`: the inline script runs before markers placed
    # after it in source order are parsed, so a synchronous scan attaches none.
    sel = JSON.json("[data-hs-marker=\"$(id_prefix)\"]")
    print(io, "_m.on('load',function(){")
    print(io, "document.querySelectorAll($sel).forEach(function(el){")
    print(io, "const mk=new maplibregl.Marker({element:el})")
    print(io, ".setLngLat([parseFloat(el.dataset.lon),parseFloat(el.dataset.lat)]);")
    print(io, "if(el.dataset.popup!==undefined){")
    print(io, "mk.setPopup(new maplibregl.Popup().setHTML(el.dataset.popup));")
    print(io, "}")
    print(io, "mk.addTo(_m);")
    print(io, "});")
    print(io, "});")

    if center_signal !== nothing || zoom_signal !== nothing ||
       bounds_signal !== nothing
        print(io, "_m.on('moveend',function(){")
        if center_signal !== nothing
            print(io, "const c=_m.getCenter();")
            _dispatch(io, "center", "[c.lng,c.lat]")
        end
        if zoom_signal !== nothing
            _dispatch(io, "zoom", "_m.getZoom()")
        end
        if bounds_signal !== nothing
            print(io, "const b=_m.getBounds();")
            _dispatch(io, "bounds", "{w:b.getWest(),s:b.getSouth(),e:b.getEast(),n:b.getNorth()}")
        end
        print(io, "});")
    end

    if cursor_signal !== nothing
        print(io, "_m.on('mousemove',function(e){")
        _dispatch(io, "cursor", "[e.lngLat.lng,e.lngLat.lat]")
        print(io, "});")
    end

    if click_post !== nothing
        layers_js = JSON.json(click_layers)
        print(io, "_m.on('click',function(e){")
        print(io, "const f=_m.queryRenderedFeatures(e.point,{layers:$layers_js});")
        print(io, "const p=f.length?f[0].properties:{};")
        _dispatch(io, "click", "{lat:e.lngLat.lat,lon:e.lngLat.lng,properties:p}")
        print(io, "});")
    end

    # boxZoom off: built-in shift-drag zooms to the rectangle and double-fires.
    # boxZoom also disables dragPan during shift-drag; without it the map pans,
    # start/end unproject to the same point and the bbox collapses to zero area.
    # So dragPan is disabled on shift-mousedown, re-enabled on mouseup in every branch.
    # Selection rectangle redrawn by hand: boxZoom's own visual goes with it.
    # Appended to the canvas container (positioned ancestor) so offsets match canvas pixels.
    # mouseup on `document`: off-canvas releases still fire.
    if bbox_post !== nothing
        print(io, "_m.boxZoom&&_m.boxZoom.disable();")
        print(io, "let _bs=null,_bs_x=0,_bs_y=0,_bx=null;")
        print(io, "const _bcc=_m.getCanvasContainer();")
        print(io, "const _bclr=function(){if(_bx){_bx.remove();_bx=null;}");
        print(io, "_m.dragPan&&_m.dragPan.enable();};")
        print(io, "_m.getCanvas().addEventListener('mousedown',function(e){")
        print(io, "if(!e.shiftKey)return;e.preventDefault();")
        print(io, "_m.dragPan&&_m.dragPan.disable();")
        print(io, "_bs=_m.unproject([e.offsetX,e.offsetY]);")
        print(io, "_bs_x=e.offsetX;_bs_y=e.offsetY;")
        print(io, "});")
        print(io, "document.addEventListener('mousemove',function(e){")
        print(io, "if(!_bs)return;")
        print(io, "const r=_m.getCanvas().getBoundingClientRect();")
        print(io, "const cx=e.clientX-r.left,cy=e.clientY-r.top;")
        print(io, "if(!_bx){_bx=document.createElement('div');")
        print(io, "_bx.style.cssText='position:absolute;top:0;left:0;background:rgba(56,135,190,0.15);border:2px solid #3887be;pointer-events:none;z-index:5;';")
        print(io, "_bcc.appendChild(_bx);}")
        print(io, "_bx.style.transform='translate('+Math.min(_bs_x,cx)+'px,'+Math.min(_bs_y,cy)+'px)';")
        print(io, "_bx.style.width=Math.abs(cx-_bs_x)+'px';_bx.style.height=Math.abs(cy-_bs_y)+'px';")
        print(io, "});")
        print(io, "document.addEventListener('mouseup',function(e){")
        print(io, "if(!_bs)return;_bclr();")
        print(io, "const r=_m.getCanvas().getBoundingClientRect();")
        print(io, "const ux=e.clientX-r.left,uy=e.clientY-r.top;")
        # 3px/axis: absorbs hand tremor on a shift-click
        print(io, "if(Math.abs(ux-_bs_x)<3&&Math.abs(uy-_bs_y)<3){_bs=null;return;}")
        print(io, "const be=_m.unproject([ux,uy]);")
        _dispatch(io, "bbox", "{w:Math.min(_bs.lng,be.lng),s:Math.min(_bs.lat,be.lat),e:Math.max(_bs.lng,be.lng),n:Math.max(_bs.lat,be.lat)}")
        print(io, "_bs=null;")
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

    attrs = Pair[:id => "$(id_prefix)root"]
    _on(name, expr) = push!(attrs,
        Symbol("data-on:$(_event_name(id_prefix, name))__window") => expr)
    center_signal === nothing || _on("center", "\$$center_signal = evt.detail")
    zoom_signal   === nothing || _on("zoom",   "\$$zoom_signal = evt.detail")
    bounds_signal === nothing || _on("bounds", "\$$bounds_signal = evt.detail")
    cursor_signal === nothing || _on("cursor", "\$$cursor_signal = evt.detail")
    # payload signal must not be `_`-prefixed: Datastar's request filter drops
    # /(^|\.)_/ signals from @post bodies, so the handler would never see it
    click_post === nothing    || _on("click",  "\$payload = evt.detail; @post('$(_js_squote(click_post))')")
    bbox_post  === nothing    || _on("bbox",   "\$payload = evt.detail; @post('$(_js_squote(bbox_post))')")

    HyperSignal.Frag(
        HyperSignal.div(attrs...),
        HyperSignal.script(HyperSignal.Raw(init_js)),
    )
end

function marker(content; lat::Real, lon::Real,
                popup=nothing, id_prefix::AbstractString="map_")
    attrs = Pair[
        Symbol("data-hs-marker") => id_prefix,
        Symbol("data-lat") => string(lat),
        Symbol("data-lon") => string(lon),
    ]
    popup === nothing || push!(attrs,
        Symbol("data-popup") => HyperSignal.render(popup))
    HyperSignal.div(content, attrs...)
end

end # module
