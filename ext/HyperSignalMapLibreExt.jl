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

# Property lookup: `prop_get(:mean_sst)` → ["get", "mean_sst"]. Accepts
# a Symbol or a String so feature property paths with dots/spaces work.
# Named `prop_get` (not `get`) to avoid shadowing `Base.get` inside the
# extension module if it ever needs to dispatch on it.
prop_get(name::Symbol) = MapLibreExpr(Any["get", String(name)])
prop_get(name::AbstractString) = MapLibreExpr(Any["get", String(name)])

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
# Named `expr_step` to avoid shadowing `Base.step` inside the module.
function expr_step(input::MapLibreExpr, default, stops::Pair...)
    out = Any["step", input, default]
    for (k, v) in stops
        push!(out, k); push!(out, v)
    end
    MapLibreExpr(out)
end

# Match expression: required keyword `default` lands as the trailing
# positional in MapLibre's wire form. A missing default would silently
# paint the un-matched features transparent — fail loud instead.
# Named `expr_match` to avoid shadowing `Base.match` inside the module.
function expr_match(input::MapLibreExpr, cases::Pair...; default=nothing)
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

# Shared builders so the Multi* forms reuse the exact coordinate-nesting
# logic of their singular counterparts (a LineString IS one element of a
# MultiLineString's coordinates; a Polygon's rings ARE one element of a
# MultiPolygon's coordinates).
_line(ls)  = [_coord(p) for p in GI.getgeom(ls)]
_rings(pg) = [_line(ring) for ring in GI.getgeom(pg)]

_geojson(::GI.PointTrait, geom) =
    Dict{String, Any}("type" => "Point", "coordinates" => _coord(geom))

_geojson(::GI.LineStringTrait, geom) =
    Dict{String, Any}("type" => "LineString", "coordinates" => _line(geom))

_geojson(::GI.PolygonTrait, geom) =
    Dict{String, Any}("type" => "Polygon", "coordinates" => _rings(geom))

# Multi-geometries — ubiquitous in real basemaps (a coastline or EEZ
# boundary is a MultiPolygon, a scattered station set a MultiPoint). Each
# is one level of nesting deeper than its singular form.
_geojson(::GI.MultiPointTrait, geom) =
    Dict{String, Any}("type" => "MultiPoint",
                      "coordinates" => [_coord(p) for p in GI.getgeom(geom)])

_geojson(::GI.MultiLineStringTrait, geom) =
    Dict{String, Any}("type" => "MultiLineString",
                      "coordinates" => [_line(ls) for ls in GI.getgeom(geom)])

_geojson(::GI.MultiPolygonTrait, geom) =
    Dict{String, Any}("type" => "MultiPolygon",
                      "coordinates" => [_rings(pg) for pg in GI.getgeom(geom)])

# A GeometryCollection nests heterogeneous geometries; recurse so each
# member goes through the same dispatch.
_geojson(::GI.GeometryCollectionTrait, geom) =
    Dict{String, Any}("type" => "GeometryCollection",
                      "geometries" => [geojson(g) for g in GI.getgeom(geom)])

# Anything else: fail with a geometry-named message instead of an opaque
# MethodError on the internal `_geojson` so the call site sees what's
# unsupported.
_geojson(trait, geom) = throw(ArgumentError(
    "geojson: unsupported geometry trait $(typeof(trait)); supported: Point, " *
    "LineString, Polygon, MultiPoint, MultiLineString, MultiPolygon, GeometryCollection"))

# Per GeoJSON (RFC 7946 §3.2) a Feature's geometry member MAY be null.
# Real feature tables routinely carry rows that failed geocoding, so a
# missing/nothing geometry must emit JSON `null` (encoded from `nothing`)
# rather than crash the whole collection on the first null row.
_feature_geometry(g) = (g === nothing || g === missing) ? nothing : geojson(g)

# Feature collection from row-like records. `rows` is anything iterable
# of NamedTuples (or any object with `getproperty` on the named cols).
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

# ----------------------------------------------------------------------
# Server-returned JS helpers
# ----------------------------------------------------------------------
#
# Each helper returns a HyperSignal.Raw carrying a JS snippet that the
# Datastar client runs via executeScript. The instance handle is
# `window.__hs_maps[prefix]` so multiple maps on one page don't collide.

# Escape a string for inside a single-quoted JS literal. Backslash
# must go first (so the later escapes' own backslashes aren't doubled).
# Then `'` (would close the literal) and LF/CR (raw line terminators
# are a SyntaxError inside a JS string literal). U+2028/U+2029 are no
# longer line terminators in string literals per ES2019, but we escape
# them too for older engines and to keep the emitted JS valid JSON-ish.
function _js_squote(s::AbstractString)
    t = replace(String(s), "\\" => "\\\\")
    t = replace(t, "'"  => "\\'")
    t = replace(t, "\r" => "\\r")
    t = replace(t, "\n" => "\\n")
    t = replace(t, " " => "\\u2028")
    t = replace(t, " " => "\\u2029")
    t
end

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
        "$(_handle(id_prefix)).addSource($(JSON.json(id)),$(JSON.json(spec)))")

remove_source(; id_prefix::AbstractString, id::AbstractString) =
    HyperSignal.Raw("$(_handle(id_prefix)).removeSource($(JSON.json(id)))")

remove_layer(; id_prefix::AbstractString, id::AbstractString) =
    HyperSignal.Raw("$(_handle(id_prefix)).removeLayer($(JSON.json(id)))")

# Guard: a runtime data swap can fire before the map's `load` event —
# e.g. a slider dragged while the first tiles are still in flight — and
# at that point `getSource()` returns undefined, so a bare `.setData()`
# throws. Apply immediately when the source is present, otherwise defer to
# the one-shot `load`. Always `setData` (never re-add the source) so layers
# wired to it keep their binding.
set_source_data(; id_prefix::AbstractString,
                source::AbstractString, data) =
    HyperSignal.Raw(
        "(function(){var m=$(_handle(id_prefix)),d=$(JSON.json(data))," *
        "f=function(){m.getSource($(JSON.json(source))).setData(d)};" *
        "m.getSource($(JSON.json(source)))?f():m.once('load',f)})()")

add_layer(; id_prefix::AbstractString, spec::Layer) =
    HyperSignal.Raw(
        "$(_handle(id_prefix)).addLayer($(JSON.json(spec)))")

set_paint_property(; id_prefix::AbstractString,
                   layer::AbstractString,
                   prop::AbstractString, value) =
    HyperSignal.Raw(
        "$(_handle(id_prefix)).setPaintProperty($(JSON.json(layer)),$(JSON.json(prop)),$(JSON.json(value)))")

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

    # Bridge to Datastar via the canonical "props down, events up"
    # pattern (per data-star.dev/guide/datastar_expressions_javascript).
    # Each channel dispatches a CustomEvent on `document`; the matching
    # `data-on:<event>__window` attribute that `map_view` renders on
    # the container then runs the real Datastar expression — signal
    # assignment for moveend/mousemove, `@post(...)` for click/bbox.
    # That keeps `@post` and `$signal` inside attribute-expression
    # context (the only place Datastar parses them) while the script
    # body remains plain JS.
    #
    # `bubbles:true` is load-bearing: the listener Datastar installs for
    # `__window` lives on `window`, and an event dispatched on `document`
    # only reaches `window` by bubbling up the propagation chain. Without
    # it every channel (cursor/viewport/click/bbox) silently no-ops.
    ev(name) = "hs-$(id_prefix)$name"
    _dispatch(io, name, value_js) =
        print(io, "document.dispatchEvent(new CustomEvent($(JSON.json(ev(name))),{detail:$value_js,bubbles:true}));")

    io = IOBuffer()
    print(io, "(function(){")
    print(io, "window.__hs_maps=window.__hs_maps||{};")
    print(io, "const _m=new maplibregl.Map($(JSON.json(map_opts)));")
    print(io, "$handle=_m;")

    # Sources + layers — load once the map's style is ready.
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

    # Marker scan — pick up every <div data-hs-marker="<prefix>"> on
    # the page and attach it as a real maplibregl.Marker. The div
    # itself becomes the marker `element`, so HyperSignal's auto-escaped
    # content renders inside the marker. data-popup, if present, wires
    # a Popup whose setHTML reads the (already-escaped) attribute.
    #
    # Deferred to `_m.on('load')` for two reasons:
    #  1. Inline <script> tags execute synchronously when the parser
    #     reaches them — any <div data-hs-marker> sibling that appears
    #     AFTER the script in source order has not been parsed yet, so
    #     a synchronous querySelectorAll would silently miss it. The
    #     idiomatic `div(map_view(...), marker(...), marker(...))` puts
    #     markers after the script, so a non-deferred scan would attach
    #     zero markers in the common case.
    #  2. `_m.on('load')` fires once the style has loaded (after at
    #     least one network round-trip), which guarantees the rest of
    #     the document body has been parsed by then.
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

    # Viewport signals on moveend (idle update). One event per channel
    # so the listening data-on:* attribute can target the right $signal.
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

    # Cursor signal on mousemove (live readout).
    if cursor_signal !== nothing
        print(io, "_m.on('mousemove',function(e){")
        _dispatch(io, "cursor", "[e.lngLat.lng,e.lngLat.lat]")
        print(io, "});")
    end

    # Click handler → dispatch event with {lat, lon, properties} from
    # queryRenderedFeatures restricted to click_layers. The container
    # div's data-on:hs-<prefix>click handler runs `\$_payload = evt.detail; @post(...)`.
    if click_post !== nothing
        layers_js = JSON.json(click_layers)
        print(io, "_m.on('click',function(e){")
        print(io, "const f=_m.queryRenderedFeatures(e.point,{layers:$layers_js});")
        print(io, "const p=f.length?f[0].properties:{};")
        _dispatch(io, "click", "{lat:e.lngLat.lat,lon:e.lngLat.lng,properties:p}")
        print(io, "});")
    end

    # Shift+drag rectangle → dispatch {w, s, e, n}. The mouseup listener
    # is on `document` so off-canvas releases still fire; MapLibre's
    # built-in shift-drag boxZoom is disabled to avoid double-firing.
    if bbox_post !== nothing
        print(io, "_m.boxZoom&&_m.boxZoom.disable();")
        print(io, "let _bs=null,_bs_x=0,_bs_y=0;")
        print(io, "_m.getCanvas().addEventListener('mousedown',function(e){")
        print(io, "if(!e.shiftKey)return;e.preventDefault();")
        print(io, "_bs=_m.unproject([e.offsetX,e.offsetY]);")
        print(io, "_bs_x=e.offsetX;_bs_y=e.offsetY;")
        print(io, "});")
        print(io, "document.addEventListener('mouseup',function(e){")
        print(io, "if(!_bs)return;const r=_m.getCanvas().getBoundingClientRect();")
        print(io, "const ux=e.clientX-r.left,uy=e.clientY-r.top;")
        # 3px threshold per axis: smaller than a deliberate drag, large
        # enough to absorb hand tremor on a shift-click.
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

    # data-on:* attributes that bridge the script's CustomEvents into
    # Datastar expressions. `__window` listens on document, matching
    # where the script dispatches. Each maps one channel → one signal
    # write (or signal-write + @post for the action channels).
    ev(name) = "hs-$(id_prefix)$name"
    attrs = Pair[:id => "$(id_prefix)root"]
    _on(name, expr) = push!(attrs,
        Symbol("data-on:$(ev(name))__window") => expr)
    center_signal === nothing || _on("center", "\$$center_signal = evt.detail")
    zoom_signal   === nothing || _on("zoom",   "\$$zoom_signal = evt.detail")
    bounds_signal === nothing || _on("bounds", "\$$bounds_signal = evt.detail")
    cursor_signal === nothing || _on("cursor", "\$$cursor_signal = evt.detail")
    click_post === nothing    || _on("click",  "\$_payload = evt.detail; @post('$(_js_squote(click_post))')")
    bbox_post  === nothing    || _on("bbox",   "\$_payload = evt.detail; @post('$(_js_squote(bbox_post))')")

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
