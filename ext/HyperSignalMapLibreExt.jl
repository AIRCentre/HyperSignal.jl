module HyperSignalMapLibreExt

# Nothing exported: reach in via `Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)`.

# Expression spec: https://maplibre.org/maplibre-style-spec/expressions/

import HyperSignal
import HyperSignal: @ds_str
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

"""
    geojson_source(data; cluster=false, cluster_radius=50)

`data` is inline GeoJSON (a `Dict`) or a URL string MapLibre fetches.
"""
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

"""
    image_source(url; coordinates)

`coordinates` holds the image's 4 corners as `(lon, lat)`, in the order
top-left, top-right, bottom-right, bottom-left.
"""
function image_source(url::AbstractString; coordinates)
    length(coordinates) == 4 || throw(ArgumentError(
        "image_source needs 4 corners (TL, TR, BR, BL), got $(length(coordinates))"))
    Source(Dict{String, Any}(
        "type" => "image",
        "url" => String(url),
        "coordinates" => [collect(c) for c in coordinates],
    ))
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

"""
    feature_collection(rows; geometry_col, properties_cols)

`rows` is an iterable of NamedTuples, or of any objects with `getproperty` on
the named columns.
"""
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

const _MAPS_TABLE = "__hs_maps"
const _DRAW_TABLE = "__hs_draw"
const _DRAW_SIGNALS_TABLE = "__hs_draw_signals"
const _WATCH_SET = "__hs_watch"

# per-prefix handle keeps multiple maps on one page apart
_handle(prefix, table=_MAPS_TABLE) = "window.$table['$(HyperSignal._js_str_escape(prefix))']"
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

struct ByProperty
    key::String
    table::Dict{String, Any}
    default::Any
end

_by_key(k::Union{Integer, AbstractString, Symbol}) = string(k)
_by_key(k) = throw(ArgumentError(
    "by_property: keys must be integers, strings, symbols or booleans, got $(repr(k))"))

"""
    by_property(key, value => style, ...; default)

A Terra Draw style that depends on a property the drawing stamped on each
line (see `draw_options(; properties)`). Lines whose `key` matches no value
take `default`. Values match as strings, so `1` and `"1"` in one call throw
`ArgumentError`.
"""
function by_property(key::AbstractString, cases::Pair...; default)
    table = Dict{String, Any}()
    for (k, v) in cases
        sk = _by_key(k)
        # The page compares String(value), so 1 and "1" are the same case.
        haskey(table, sk) && throw(ArgumentError("by_property: two cases match the value $(repr(sk))"))
        table[sk] = v
    end
    ByProperty(String(key), table, default)
end

_style_js(v) = JSON.json(v)
_style_js(b::ByProperty) =
    "_dby($(JSON.json(b.key)),$(JSON.json(b.table)),$(JSON.json(b.default)))"

const _DRAW_MODES = (:select, :linestring)

struct DrawOptions
    modes::Vector{Symbol}
    signal::String
    properties::Union{Nothing, String}
    line_color::Any
    line_dash::Any
    selected_color::Any
    features::Vector{Any}
    change_post::Union{Nothing, String}
end

"""
    draw_options(; modes=(:select, :linestring), signal="draw", properties=nothing,
                 line_color=nothing, line_dash=nothing, selected_color=nothing,
                 features=[], change_post=nothing)

Line drawing for `map_view(; draw=…)`, with Terra Draw state in Datastar
signals under `\$<signal>`. `modes` lists the Terra Draw modes the page may
switch to, from `:select` and `:linestring`; the first is the starting mode. `properties` is a Datastar expression whose value is stamped
on each line when it is finished. `features` are GeoJSON line Features
loaded at start. `change_post` is posted to after each finished edit.
"""
function draw_options(; modes=(:select, :linestring), signal::AbstractString="draw",
                      properties::Union{Nothing, AbstractString}=nothing,
                      line_color=nothing, line_dash=nothing, selected_color=nothing,
                      features=Any[],
                      change_post::Union{Nothing, AbstractString}=nothing)
    isempty(modes) && throw(ArgumentError("draw_options needs at least one mode"))
    for m in modes
        m in _DRAW_MODES || throw(ArgumentError(
            "draw_options: unknown mode $(repr(m)); expected one of $(_DRAW_MODES)"))
    end
    # A dotted name would be declared by data-signals as one literal key, and
    # Datastar leaves `_`-prefixed signals out of @post bodies.
    occursin(r"^[A-Za-z][A-Za-z0-9_]*\z", signal) || throw(ArgumentError(
        "draw_options: `signal` must be a plain name not starting with `_`, got $(repr(signal))"))
    # Terra Draw files a seed under the linestring mode; without it the seed is refused.
    isempty(features) || :linestring in modes || throw(ArgumentError(
        "draw_options: `features` needs :linestring in `modes`"))
    # A missing geometry would throw in the load handler and abort the drawing.
    # Symbol keys and NamedTuples serialise the same; check the JSON shape.
    features = [JSON.parse(JSON.json(f)) for f in features]
    all(f -> f isa AbstractDict && haskey(f, "geometry"), features) || throw(ArgumentError(
        "draw_options: each of `features` must be a GeoJSON Feature with a `geometry`"))
    # A seed's properties become its stamp, which by_property reads keys off.
    all(f -> get(f, "properties", nothing) isa Union{Nothing, AbstractDict}, features) || throw(ArgumentError(
        "draw_options: a feature's `properties` must be an object or null"))
    DrawOptions(collect(Symbol, modes), String(signal),
                properties === nothing ? nothing : String(properties),
                line_color, line_dash, selected_color, collect(Any, features),
                change_post === nothing ? nothing : String(change_post))
end

_draw_handle(prefix) = _handle(prefix, _DRAW_TABLE)

const _DRAW_ACTIONS = (:undo, :redo, :delete_selected)

"""
    draw_call(action; id_prefix)

A Datastar expression that runs `action` (`:undo`, `:redo` or
`:delete_selected`) on the map's drawing.
"""
function draw_call(action::Symbol; id_prefix::AbstractString)
    action in _DRAW_ACTIONS || throw(ArgumentError(
        "draw_call: unknown action $(repr(action)); expected one of $(_DRAW_ACTIONS)"))
    # Before the map loads, or after it is removed, there is no handle to call.
    HyperSignal.DSExpr("window.$_DRAW_TABLE?.['$(HyperSignal._js_str_escape(id_prefix))']?.$action()")
end

"""
    markers(children...; id, id_prefix="map_")

A hidden container of [`marker`](@ref)s. The map shows copies of its
children and rebuilds them whenever the container changes, so a Datastar
patch of `#id` updates the map's markers. The container must be in the page
when the map loads; render it empty if it starts with no markers.
"""
markers(children...; id::AbstractString, id_prefix::AbstractString="map_") =
    HyperSignal.div(children...; id, hidden=true, var"data-hs-markers"=id_prefix)

_padding(p::Real) = p
_padding(p::NamedTuple) = Dict(pairs(p))
_padding(p) = throw(ArgumentError(
    "map_view: `fit_padding` must be a number or (top=…, bottom=…, left=…, right=…), got $(repr(p))"))

# MapLibre fits a constructor `bounds` itself, with no animation.
function _view_opts(center, zoom, bounds, fit_padding)
    if bounds === nothing
        (center === nothing || zoom === nothing) && throw(ArgumentError(
            "map_view needs `center` and `zoom`, or `bounds`"))
        fit_padding === nothing || throw(ArgumentError(
            "map_view: `fit_padding` applies only with `bounds`"))
        return Dict{String, Any}("center" => collect(center), "zoom" => zoom)
    end
    (center === nothing && zoom === nothing) || throw(ArgumentError(
        "map_view takes `bounds` or `center` + `zoom`, not both"))
    (bounds isa NamedTuple && all(k -> haskey(bounds, k), (:w, :s, :e, :n))) || throw(ArgumentError(
        "map_view: `bounds` must be (w=…, s=…, e=…, n=…), got $(repr(bounds))"))
    # MapLibre's LngLat throws on these, and the map never starts.
    (all(isfinite, (bounds.w, bounds.e)) && all(v -> -90 <= v <= 90, (bounds.s, bounds.n))) || throw(ArgumentError(
        "map_view: `bounds` needs s and n in [-90, 90] and finite w and e, got $(repr(bounds))"))
    opts = Dict{String, Any}(
        "bounds" => [[bounds.w, bounds.s], [bounds.e, bounds.n]])
    fit_padding === nothing ||
        (opts["fitBoundsOptions"] = Dict("padding" => _padding(fit_padding)))
    opts
end

const _NAV_POSITIONS = Dict(:top_left => "top-left", :top_right => "top-right",
                           :bottom_left => "bottom-left", :bottom_right => "bottom-right")

_nav_position(p) = get(_NAV_POSITIONS, p) do
    throw(ArgumentError(
        "map_view: unknown nav_control $(repr(p)); expected one of $(Tuple(keys(_NAV_POSITIONS)))"))
end

function _init_js(; id_prefix, center, zoom, bounds, fit_padding, style,
                  rotate, double_click_zoom, nav_control, draw,
                  sources, layers,
                  center_signal, zoom_signal, bounds_signal, cursor_signal,
                  loading_signal, loading_delay,
                  click_post, bbox_post, click_layers)
    handle = _handle(id_prefix)
    container = "$(id_prefix)root"
    map_opts = merge(Dict{String, Any}("container" => container, "style" => style),
                     _view_opts(center, zoom, bounds, fit_padding))
    rotate || (map_opts["dragRotate"] = false; map_opts["touchPitch"] = false)
    double_click_zoom || (map_opts["doubleClickZoom"] = false)

    # Datastar parses `@post` / `$signal` only in attribute expressions, so the
    # script dispatches CustomEvents and map_view's `data-on:<event>__window`
    # attributes run the expressions.
    # `bubbles:true` required: the `__window` listener sits on `window`, and an event
    # dispatched on `document` reaches it only by bubbling; without it every event no-ops.
    _dispatch(io, name, value_js) =
        print(io, "document.dispatchEvent(new CustomEvent($(JSON.json(_event_name(id_prefix, name))),{detail:$value_js,bubbles:true}));")

    io = IOBuffer()
    print(io, "(function _hsinit(){")
    # Keyed by id_prefix, which may be "constructor" or "toString".
    print(io, "window.$_MAPS_TABLE=window.$_MAPS_TABLE||Object.create(null);")
    # Datastar runs a patched script, which the browser may also run: a live
    # map on this root means the script already ran. A map whose DOM a morph
    # stripped is replaced.
    print(io, "const _old=$handle;")
    # Read before `_old.remove()` stops it: a re-init keeps the lines, mode and
    # stamp, as the root's data-effect does not run again.
    draw === nothing || print(io, "const _dprev=window.$_DRAW_TABLE&&$(_draw_handle(id_prefix))&&",
                              "$(_draw_handle(id_prefix)).state();")
    print(io, "if(_old){if(_old.getContainer()===document.getElementById($(JSON.json(container)))&&",
          "_old.getCanvasContainer().isConnected)return;_old.remove();}")
    print(io, "const _m=new maplibregl.Map($(JSON.json(map_opts)));")
    print(io, "$handle=_m;")
    # A morph never fires 'remove'. A root that left the page takes its map
    # with it; a root a morph kept, minus the map's DOM, gets a fresh map from
    # the script's current text, which the morph may have changed without
    # running it. Removing runs every 'remove' cleanup and frees the WebGL
    # context. One page-wide observer runs every map's check.
    w = "window.$_WATCH_SET"
    print(io, "if(!$w){$w=new Set();const ws=$w;new MutationObserver(function(){ws.forEach(function(f){f();});})",
          ".observe(document.body,{childList:true,subtree:true});}")
    print(io, "const _orph=function(){if(!_m.getContainer().isConnected)_m.remove();",
          "else if(!_m.getCanvasContainer().isConnected){const s=document.getElementById($(JSON.json(id_prefix * "init")));",
          "if(!s)return _hsinit();const n=document.createElement('script');n.id=s.id;n.nonce=s.nonce;n.textContent=s.textContent;s.replaceWith(n);}};")
    print(io, "$w.add(_orph);")
    print(io, "_m.on('remove',function(){$w.delete(_orph);if($handle===_m)delete $handle;});")
    # dragRotate=false leaves touch and keyboard rotation on.
    rotate || print(io, "_m.touchZoomRotate.disableRotation();_m.keyboard.disableRotation();")
    nav_control === nothing || print(io,
        "_m.addControl(new maplibregl.NavigationControl({showCompass:$(JSON.json(rotate))}),",
        JSON.json(_nav_position(nav_control)), ");")

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
    # `load` waits on the style fetch, so the body is normally parsed by then.
    sel = JSON.json("[data-hs-marker=\"$(id_prefix)\"]")
    print(io, "const _mk=function(el){")
    print(io, "const mk=new maplibregl.Marker({element:el})")
    print(io, ".setLngLat([parseFloat(el.dataset.lon),parseFloat(el.dataset.lat)]);")
    print(io, "if(el.dataset.popup!==undefined){")
    # setHTML parses raw HTML: safe only because data-popup holds render() output (escaped)
    print(io, "mk.setPopup(new maplibregl.Popup().setHTML(el.dataset.popup));")
    print(io, "}")
    print(io, "return mk.addTo(_m);};")
    print(io, "_m.on('load',function(){")
    print(io, "document.querySelectorAll($sel).forEach(function(el){")
    print(io, "if(el.closest('[data-hs-markers]'))return;")
    print(io, "try{_mk(el);}catch(e){console.error(e);}")
    print(io, "});")
    print(io, "});")
    _markers_js(io, id_prefix)
    draw === nothing || _draw_js(io, id_prefix, draw, _dispatch)

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

    # `idle` waits for rendering to settle, not just the network. `_ld` starts
    # null, not false, so the first idle clears a signal the page initialised
    # to true.
    if loading_signal !== nothing
        print(io, "let _ld=null,_lt=null;")
        print(io, "const _lset=function(v){if(v===_ld)return;_ld=v;")
        _dispatch(io, "loading", "v")
        print(io, "};")
        print(io, "_m.on('dataloading',function(){")
        print(io, "if(_ld||_lt!==null)return;")
        print(io, "_lt=setTimeout(function(){_lt=null;_lset(true);},$(loading_delay));")
        print(io, "});")
        print(io, "_m.on('idle',function(){")
        print(io, "if(_lt!==null){clearTimeout(_lt);_lt=null;}_lset(false);")
        print(io, "});")
        print(io, "_m.on('remove',function(){if(_lt!==null){clearTimeout(_lt);_lt=null;}});")
        # MapLibre renders again on 'data' but not on 'error', so after a failed
        # source load nothing re-checks idle and the signal sticks at true.
        print(io, "_m.on('error',function(){_m.triggerRepaint();});")
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
        print(io, "const _bmv=function(e){")
        print(io, "if(!_bs)return;")
        print(io, "const r=_m.getCanvas().getBoundingClientRect();")
        print(io, "const cx=e.clientX-r.left,cy=e.clientY-r.top;")
        print(io, "if(!_bx){_bx=document.createElement('div');")
        print(io, "_bx.style.cssText='position:absolute;top:0;left:0;background:rgba(56,135,190,0.15);border:2px solid #3887be;pointer-events:none;z-index:5;';")
        print(io, "_bcc.appendChild(_bx);}")
        print(io, "_bx.style.transform='translate('+Math.min(_bs_x,cx)+'px,'+Math.min(_bs_y,cy)+'px)';")
        print(io, "_bx.style.width=Math.abs(cx-_bs_x)+'px';_bx.style.height=Math.abs(cy-_bs_y)+'px';")
        print(io, "};")
        print(io, "const _bmu=function(e){")
        print(io, "if(!_bs)return;_bclr();")
        print(io, "const r=_m.getCanvas().getBoundingClientRect();")
        print(io, "const ux=e.clientX-r.left,uy=e.clientY-r.top;")
        # 3px/axis: absorbs hand tremor on a shift-click
        print(io, "if(Math.abs(ux-_bs_x)<3&&Math.abs(uy-_bs_y)<3){_bs=null;return;}")
        print(io, "const be=_m.unproject([ux,uy]);")
        _dispatch(io, "bbox", "{w:Math.min(_bs.lng,be.lng),s:Math.min(_bs.lat,be.lat),e:Math.max(_bs.lng,be.lng),n:Math.max(_bs.lat,be.lat)}")
        print(io, "_bs=null;")
        print(io, "};")
        print(io, "document.addEventListener('mousemove',_bmv);document.addEventListener('mouseup',_bmu);")
        print(io, "_m.on('remove',function(){document.removeEventListener('mousemove',_bmv);",
              "document.removeEventListener('mouseup',_bmu);});")
    end

    print(io, "})();")
    String(take!(io))
end

# A container's markers are rebuilt from copies of its children: Marker moves
# its element into the map, which would leave a later morph nothing to update.
# MapLibre rewrites each copy's style on every frame of a pan; the copies sit
# outside any container, so the closest() check below skips those writes.
# Printed by _init_js after it defines `_m` and `_mk`, which this code uses.
function _markers_js(io, id_prefix)
    sel = JSON.json("[data-hs-markers=\"$(id_prefix)\"]")
    # Keyed by container id, which may be "constructor" or "toString".
    print(io, "const _mks=Object.create(null),_mkh=Object.create(null);let _mkq=false;")
    print(io, "const _mkb=function(){_mkq=false;const seen=Object.create(null);")
    print(io, "document.querySelectorAll($sel).forEach(function(c){")
    print(io, "seen[c.id]=true;if(_mkh[c.id]===c.innerHTML)return;")
    print(io, "(_mks[c.id]||[]).forEach(function(m){m.remove();});const ms=[];")
    print(io, "c.querySelectorAll('[data-hs-marker]').forEach(function(el){try{ms.push(_mk(el.cloneNode(true)));}catch(e){console.error(e);}});")
    print(io, "_mks[c.id]=ms;_mkh[c.id]=c.innerHTML;")
    print(io, "});")
    print(io, "Object.keys(_mks).forEach(function(id){if(!seen[id]){_mks[id].forEach(function(m){m.remove();});delete _mks[id];delete _mkh[id];}});")
    print(io, "};")
    # Containers must be in the page when the map loads; a page without one
    # gets no document-wide observer.
    print(io, "_m.on('load',function(){if(!document.querySelector($sel))return;_mkb();")
    # A change counts only inside a container, or when the nodes a childList
    # change adds or removes are or hold one.
    print(io, "const _mkin=function(n){return n.nodeType===1&&(n.matches($sel)||!!n.closest($sel)||!!n.querySelector($sel));};")
    print(io, "const ob=new MutationObserver(function(rs){if(_mkq)return;")
    print(io, "if(rs.some(function(r){return (r.type==='childList'&&(Array.prototype.some.call(r.addedNodes,_mkin)||",
          "Array.prototype.some.call(r.removedNodes,_mkin)))||(r.target.closest&&r.target.closest($sel))||")
    print(io, "(r.target.parentElement&&r.target.parentElement.closest($sel));})){_mkq=true;queueMicrotask(_mkb);}});")
    print(io, "ob.observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true});")
    print(io, "_m.on('remove',function(){ob.disconnect();});")
    print(io, "});")
end

# The cheap `\$draw` fields: name, JS read from Terra Draw, initial value.
# `mode` comes back so a fallback from an unknown mode reaches the signal; it
# is the mode asked for, not getMode(), which passes through `static`.
_draw_state(d) = (
    ("mode", "_dmode", String(first(d.modes))),
    ("drawing", "_td.getModeState()==='drawing'", false),
    ("selected", "_dsel()", Any[]),
    ("can_undo", "_td.canUndo()", false),
    ("can_redo", "_td.canRedo()", false))

# Terra Draw state reaches Datastar as CustomEvents (see _init_js), split so
# $draw.features changes only when a finished line does: `draw` carries the
# cheap state, `draw_features` the lines, `draw_change` asks for change_post.
# Lines are stamped in a side table, not on the feature: a property write
# after `finish` is its own undo entry, so undo would strip the stamp first.
# Signals are Proxies that structuredClone rejects; values from them are JSON
# round-tripped before Terra Draw keeps them.
function _draw_js(io, id_prefix, d::DrawOptions, dispatch)
    h = _draw_handle(id_prefix)
    hit = "matchMedia('(any-pointer: coarse)').matches?22:10"
    print(io, "window.$_DRAW_TABLE=window.$_DRAW_TABLE||Object.create(null);")
    # Two maps on one signal overwrite each other's state; only the page can see that.
    sig = JSON.json(d.signal)
    t = "window.$_DRAW_SIGNALS_TABLE"
    print(io, "$t=$t||Object.create(null);")
    # A map patched over another starts while the old one is still in the
    # page; the observer removes it before the next task.
    print(io, "const _dother=$t[$sig];setTimeout(function(){",
          "if(_dother&&_dother!==_m&&_dother.getContainer().isConnected)",
          "console.error('HyperSignal: two drawing maps share the signal '+$sig+'; give each its own draw_options(; signal)');});")
    print(io, "$t[$sig]=_m;")
    print(io, "const _dhit=$hit;")
    print(io, "let _td=null,_dprops=_dprev?_dprev.props:{},",
          "_dmode=_dprev?_dprev.mode:$(JSON.json(String(first(d.modes)))),_dlf=null,_dls=null,_ddown=false;")
    print(io, "const _dst={},_drej=_dprev&&_dprev.lines?_dprev.rejected:[];")
    print(io, "const _dseed=_dprev&&_dprev.lines||$(JSON.json(d.features));")
    print(io, "const _dclone=function(v){return JSON.parse(JSON.stringify(v));};")
    print(io, "const _dby=function(k,t,dv){return function(f){const v=(_dst[f.id]||_dprops)[k];")
    print(io, "return Object.prototype.hasOwnProperty.call(t,String(v))?t[String(v)]:dv;};};")
    print(io, "const _dsel=function(){return _td.getSnapshot().filter(function(f){return f.properties.selected;}).map(function(f){return f.id;});};")
    print(io, "const _dlines=function(){return _td.getSnapshot().filter(function(f){")
    print(io, "return f.geometry.type==='LineString'&&!f.properties.currentlyDrawing&&f.geometry.coordinates.length>=2;")
    print(io, "}).map(function(f){if(!_dst[f.id])_dst[f.id]=_dclone(_dprops);")
    print(io, "return {type:'Feature',id:f.id,geometry:{type:'LineString',coordinates:f.geometry.coordinates},properties:_dclone(_dst[f.id])};});};")
    print(io, "const _dstate=function(force){if(!_td)return;")
    print(io, "const s={", join(("$k:$js" for (k, js, _) in _draw_state(d)), ","), "};")
    print(io, "const k=JSON.stringify(s);if(!force&&k===_dls)return;_dls=k;")
    dispatch(io, "draw", "s")
    print(io, "};")
    print(io, "const _dfeat=function(post,force){if(!_td)return;const f=_dlines();const k=JSON.stringify(f);")
    print(io, "if(!force&&k===_dlf)return;_dlf=k;")
    # Datastar writes into the objects it is handed; a copy keeps the stored stamps intact.
    dispatch(io, "draw_features", "{features:f,rejected:_dclone(_drej)}")
    print(io, "if(post){")
    dispatch(io, "draw_change", "null")
    print(io, "}};")
    # Pointer moves while drawing or dragging change the snapshot on every
    # frame; the lines are re-read once the pointer is up and the line done.
    print(io, "const _dall=function(){_dstate(false);if(!_ddown&&_td.getModeState()!=='drawing')_dfeat(true,false);};")
    print(io, "const _dtry=function(f){try{if(_td)f();}catch(e){console.error(e);}};")
    print(io, "$h={")
    # Before load `mode` only records the mode. After it, a mode the drawing
    # lacks throws; the state event then writes the mode in use back.
    print(io, "mode:function(m){if(!_td){_dmode=m;return;}")
    print(io, "try{if(_td.getMode()!==m)_td.setMode(m);_dmode=m;_dstate(false);}catch(e){console.error(e);_dstate(true);}},")
    # A stamp must be an object: by_property reads keys off it, and GeoJSON
    # properties are an object or null.
    print(io, "props:function(p){const v=p==null?{}:_dclone(p);_dprops=v&&typeof v==='object'&&!Array.isArray(v)?v:{};},")
    print(io, "undo:function(){_dtry(function(){_td.undo();_dall();});},")
    print(io, "redo:function(){_dtry(function(){_td.redo();_dall();});},")
    print(io, "delete_selected:function(){_dtry(function(){const ids=_dsel();if(ids.length){_td.removeFeatures(ids);_dall();}});},")
    print(io, "sync:function(){_dtry(function(){_dstate(true);_dfeat(false,true);});},")
    print(io, "state:function(){let l=null;try{if(_td)l=_dlines();}catch(e){console.error(e);}",
          "return {props:_dprops,mode:_dmode,lines:l,rejected:_drej};}")
    print(io, "};")
    print(io, "const _dh=$h;")
    print(io, "_m.on('remove',function(){if($h===_dh)delete $h;if($t[$sig]===_m)delete $t[$sig];});")

    print(io, "_m.on('load',function(){")
    print(io, "const TD=window.terraDraw;")
    print(io, "const _dmodes=[];")
    if :select in d.modes
        print(io, "_dmodes.push(new TD.TerraDrawSelectMode({pointerDistance:_dhit,")
        print(io, "flags:{linestring:{feature:{draggable:false,coordinates:{midpoints:true,draggable:true,deletable:true}}}},")
        print(io, "styles:{selectedLineStringWidth:4")
        d.selected_color === nothing || print(io, ",selectedLineStringColor:", _style_js(d.selected_color))
        print(io, "}}));")
    end
    if :linestring in d.modes
        print(io, "_dmodes.push(new TD.TerraDrawLineStringMode({pointerDistance:_dhit,")
        print(io, "styles:{lineStringWidth:3.5")
        d.line_color === nothing || print(io, ",lineStringColor:", _style_js(d.line_color))
        d.line_dash === nothing || print(io, ",lineStringDash:", _style_js(d.line_dash))
        print(io, "}}));")
    end
    print(io, "_td=new TD.TerraDraw({adapter:new window.terraDrawMaplibreGlAdapter.TerraDrawMapLibreGLAdapter({map:_m}),")
    print(io, "modes:_dmodes,undoRedo:{modeLevel:new TD.TerraDrawModeUndoRedo(),sessionLevel:new TD.TerraDrawSessionUndoRedo()}});")
    print(io, "_td.start();")
    # Terra Draw refuses invalid features; they are reported, not dropped.
    print(io, "if(_dseed.length){")
    print(io, "_td.addFeatures(_dseed.map(function(f){return {type:'Feature',geometry:_dclone(f.geometry),properties:{mode:'linestring'}};}))")
    print(io, ".forEach(function(r,i){if(r.valid)_dst[r.id]=_dclone(_dseed[i].properties||{});else _drej.push(_dseed[i]);});")
    print(io, "_td.clearUndoRedoHistory();}")
    # $draw.mode may already name a mode this map lacks; a throw here would
    # leave the listeners below unregistered.
    print(io, "try{_td.setMode(_dmode);}catch(e){console.error(e);_dmode=$(JSON.json(String(first(d.modes))));_td.setMode(_dmode);}")
    print(io, "_td.on('change',function(ids,type){if(type!=='styling')_dall();});")
    print(io, "_td.on('finish',_dall);")
    print(io, "_td.on('select',function(){_dstate(false);});")
    print(io, "_td.on('deselect',function(){_dstate(false);});")
    print(io, "_m.getCanvasContainer().addEventListener('pointerdown',function(){_ddown=true;},true);")
    # A browser that takes over a touch gesture sends pointercancel, not pointerup.
    print(io, "const _dup=function(){_ddown=false;setTimeout(function(){_dtry(_dall);});};")
    print(io, "window.addEventListener('pointerup',_dup,true);window.addEventListener('pointercancel',_dup,true);")
    print(io, "_m.on('remove',function(){window.removeEventListener('pointerup',_dup,true);")
    print(io, "window.removeEventListener('pointercancel',_dup,true);});")
    if :linestring in d.modes
        # Terra Draw has no double-click: after a line, the first click finishes it
        # and the second starts a stray one-point line. Leaving the mode cancels
        # it; Terra Draw always has a `static` mode to step through.
        print(io, "_m.getCanvasContainer().addEventListener('dblclick',function(){_dtry(function(){")
        print(io, "const st=_td.getSnapshot().filter(function(f){return f.properties.currentlyDrawing;})[0];if(!st)return;")
        print(io, "const pl=st.geometry.coordinates.slice(0,-1);const p0=_m.project(pl[0]);")
        print(io, "if(pl.every(function(p){const q=_m.project(p);return Math.hypot(q.x-p0.x,q.y-p0.y)<=_dhit;})){")
        print(io, "_td.setMode('static');_td.setMode('linestring');_dstate(false);}")
        print(io, "});});")
    end
    print(io, "$h.sync();")
    print(io, "});")
end

function _draw_attrs!(attrs, on, id_prefix, d::DrawOptions)
    ref = "\$" * d.signal
    sig = HyperSignal.ds_signals(Dict(d.signal => Dict{String, Any}(
        "features" => [], "rejected" => [], (k => v for (k, _, v) in _draw_state(d))...)))
    push!(attrs, sig.key => sig.value)
    on("draw", join(("$ref.$k = evt.detail.$k" for (k, _, _) in _draw_state(d)), "; "))
    on("draw_features", "$ref.features = evt.detail.features; $ref.rejected = evt.detail.rejected")
    d.change_post === nothing ||
        on("draw_change", ds"$(HyperSignal.ds_post(d.change_post))")
    h = _draw_handle(id_prefix)
    # Signals are read before the handle: an effect that throws first
    # subscribes to nothing and never runs again.
    body = ["const m = $ref.mode", "const d = $h", "if (d) d.mode(m)"]
    d.properties === nothing || push!(body, "const p = $(d.properties)", "if (d) d.props(p)")
    eff = HyperSignal.ds_effect("try { $(join(body, "; ")) } catch (e) { console.error(e) }")
    init = HyperSignal.ds_init("$h.sync()")
    push!(attrs, eff.key => eff.value, init.key => init.value)
end

function map_view(; id_prefix::AbstractString="map_",
                  style::AbstractString,
                  center=nothing, zoom=nothing,
                  bounds=nothing, fit_padding=nothing,
                  rotate::Bool=true, double_click_zoom::Bool=true,
                  nav_control::Union{Nothing, Symbol}=nothing,
                  draw::Union{Nothing, DrawOptions}=nothing,
                  sources=NamedTuple(), layers=(),
                  center_signal=nothing,
                  zoom_signal=nothing,
                  bounds_signal=nothing,
                  cursor_signal=nothing,
                  loading_signal=nothing,
                  loading_delay::Integer=200,
                  click_post=nothing,
                  bbox_post=nothing,
                  click_layers::Vector{String}=String[])
    init_js = _init_js(; id_prefix, center, zoom, bounds, fit_padding, style,
                       rotate, double_click_zoom, nav_control, draw,
                       sources, layers,
                       center_signal, zoom_signal, bounds_signal, cursor_signal,
                       loading_signal, loading_delay,
                       click_post, bbox_post, click_layers)

    attrs = Pair[:id => "$(id_prefix)root"]
    _on(name, expr) = push!(attrs,
        Symbol("data-on:$(_event_name(id_prefix, name))__window") => expr)
    center_signal === nothing || _on("center", "\$$center_signal = evt.detail")
    zoom_signal   === nothing || _on("zoom",   "\$$zoom_signal = evt.detail")
    bounds_signal === nothing || _on("bounds", "\$$bounds_signal = evt.detail")
    cursor_signal === nothing || _on("cursor", "\$$cursor_signal = evt.detail")
    loading_signal === nothing || _on("loading", "\$$loading_signal = evt.detail")
    # payload signal must not be `_`-prefixed: Datastar's request filter drops
    # /(^|\.)_/ signals from @post bodies, so the handler would never see it
    click_post === nothing    || _on("click",  ds"$payload = evt.detail; $(HyperSignal.ds_post(click_post))")
    bbox_post  === nothing    || _on("bbox",   ds"$payload = evt.detail; $(HyperSignal.ds_post(bbox_post))")
    draw === nothing || _draw_attrs!(attrs, _on, id_prefix, draw)

    # `</` and `<!--` occur only inside JS string literals here.
    HyperSignal.Frag(
        HyperSignal.div(attrs...),
        HyperSignal.script(id="$(id_prefix)init", HyperSignal.Raw(
            HyperSignal._script_safe(init_js))),
    )
end

function marker(content; lat::Real, lon::Real,
                popup=nothing, id_prefix::AbstractString="map_")
    # MapLibre's LngLat throws on these; the page would drop the marker.
    isfinite(lon) && -90 <= lat <= 90 ||
        throw(ArgumentError("marker: lat must be in [-90, 90] and lon finite, got lat=$lat, lon=$lon"))
    attrs = Pair[
        Symbol("data-hs-marker") => id_prefix,
        Symbol("data-lat") => string(lat),
        Symbol("data-lon") => string(lon),
    ]
    popup === nothing || push!(attrs,
        Symbol("data-popup") => HyperSignal.render(popup))
    HyperSignal.div(content, attrs...)
end

end
