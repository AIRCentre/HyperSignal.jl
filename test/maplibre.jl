# Tests for HyperSignalMapLibreExt — gated on GeoInterface.
# The extension defines map_view + paint-DSL + source/layer constructors +
# server-returned JS helpers. Top-level HyperSignal exports nothing new
# (see issue #29), so tests reach into the extension module by name.

using Test
using GeoInterface
using JSON
using HyperSignal

const MapLibre = Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)

@testset "HyperSignalMapLibreExt" begin
    @testset "extension loads when GeoInterface is present" begin
        # Why: the whole MapLibre surface is gated on this; if the
        # extension doesn't activate, every later test is meaningless.
        @test MapLibre !== nothing
    end

    @testset "paint DSL" begin
        @testset "get(:prop) JSON-encodes as the MapLibre [\"get\", name] expression" begin
            # Why: every paint expression bottoms out in a property
            # lookup; getting the wire shape right is load-bearing for
            # every interpolate / step / match downstream.
            ex = MapLibre.prop_get(:mean_sst)
            @test JSON.json(ex) == "[\"get\",\"mean_sst\"]"
        end

        @testset "literal wraps a value in [\"literal\", value]" begin
            # Why: arrays/objects that should be paint constants (not
            # interpreted as nested expressions) need the literal escape.
            @test JSON.json(MapLibre.literal([1, 2, 3])) ==
                  "[\"literal\",[1,2,3]]"
            @test JSON.json(MapLibre.literal("x")) ==
                  "[\"literal\",\"x\"]"
        end

        @testset "linear() is a zero-arg interpolation kind marker" begin
            # Why: MapLibre encodes interpolation type as a nested
            # array [\"linear\"]; the marker keeps the call site
            # readable as `interpolate(linear(), input, …)`.
            @test JSON.json(MapLibre.linear()) == "[\"linear\"]"
        end

        @testset "interpolate flattens stop pairs into the MapLibre array form" begin
            # Why: `interpolate(linear(), get(:x), 15 => \"#00f\", 25 => \"#f00\")`
            # is the demo's color ramp. The wire form interleaves
            # stop-input/stop-output as flat positional args after the
            # input expression.
            ex = MapLibre.interpolate(MapLibre.linear(),
                                      MapLibre.prop_get(:mean_sst),
                                      15 => "#00f", 25 => "#f00")
            @test JSON.json(ex) == string(
                "[\"interpolate\",[\"linear\"],[\"get\",\"mean_sst\"],",
                "15,\"#00f\",25,\"#f00\"]",
            )
        end

        @testset "step flattens (default, threshold => value...) pairs" begin
            # Why: step expressions take a leading default before the
            # threshold pairs — the order is fixed by MapLibre and easy
            # to invert; pin it.
            ex = MapLibre.expr_step(MapLibre.prop_get(:value), "default",
                               10 => "low", 50 => "high")
            @test JSON.json(ex) == string(
                "[\"step\",[\"get\",\"value\"],\"default\",",
                "10,\"low\",50,\"high\"]",
            )
        end

        @testset "match flattens label=>value pairs with a trailing default" begin
            # Why: match takes the default as the LAST positional arg in
            # MapLibre's wire form, not as a keyword — easy to get wrong.
            ex = MapLibre.expr_match(MapLibre.prop_get(:kind),
                                "vessel" => "#222", "buoy" => "#08f";
                                default="#888")
            @test JSON.json(ex) == string(
                "[\"match\",[\"get\",\"kind\"],",
                "\"vessel\",\"#222\",\"buoy\",\"#08f\",\"#888\"]",
            )
        end

        @testset "get accepts a String property path, not just a Symbol" begin
            # Why: GeoJSON properties with dots or unicode names can't be
            # spelled as Symbols at the call site — strings are the
            # fallback. The wire form is identical.
            @test JSON.json(MapLibre.prop_get("nested.path")) ==
                  "[\"get\",\"nested.path\"]"
        end

        @testset "interpolate with one stop pair still emits a valid expression" begin
            # Why: a degenerate single-stop ramp is a useful default
            # before real data arrives; reject only the empty case (next
            # test). One pair must round-trip cleanly.
            ex = MapLibre.interpolate(MapLibre.linear(),
                                      MapLibre.prop_get(:x), 0 => "#fff")
            @test JSON.json(ex) ==
                  "[\"interpolate\",[\"linear\"],[\"get\",\"x\"],0,\"#fff\"]"
        end

        @testset "interpolate with zero stops fails loud" begin
            # Why: an empty ramp is meaningless in MapLibre and renders
            # nothing — fail at build time, not silently at draw time.
            @test_throws ArgumentError MapLibre.interpolate(
                MapLibre.linear(), MapLibre.prop_get(:x))
        end

        @testset "match requires a default — silent fallthroughs are a footgun" begin
            # Why: a match without a default silently returns null in
            # MapLibre, which paints the feature transparent — fail at
            # build time so the missing case is visible in the diff.
            @test_throws ArgumentError MapLibre.expr_match(MapLibre.prop_get(:k),
                                                      "a" => "#111")
        end

        @testset "paint expressions compose without losing the wire shape" begin
            # Why: real expressions nest — `interpolate(…, get(:x), …, match(get(:k), …))`
            # is one composed paint value. Re-encoding must not flatten
            # the inner expression.
            inner = MapLibre.expr_match(MapLibre.prop_get(:kind),
                                   "a" => "#111"; default="#222")
            outer = MapLibre.interpolate(MapLibre.linear(),
                                         MapLibre.prop_get(:x),
                                         0 => inner, 1 => "#fff")
            parsed = JSON.parse(JSON.json(outer))
            @test parsed[1] == "interpolate"
            @test parsed[3] == ["get", "x"]
            @test parsed[5] == ["match", ["get", "kind"],
                                 "a", "#111", "#222"]
        end
    end

    @testset "Source constructors" begin
        @testset "geojson_source defaults emit {type, data} only" begin
            # Why: callers that don't opt into clustering shouldn't pay
            # for extra keys in the wire form; MapLibre treats unset
            # keys as documented defaults.
            data = Dict("type" => "FeatureCollection", "features" => [])
            src = MapLibre.geojson_source(data)
            decoded = JSON.parse(JSON.json(src))
            @test decoded == Dict("type" => "geojson", "data" => data)
        end

        @testset "geojson_source cluster opts emit clusterRadius (camelCase)" begin
            # Why: MapLibre uses camelCase keys on the wire while the
            # Julia kwarg is snake_case — verify the translation.
            data = Dict("type" => "FeatureCollection", "features" => [])
            src = MapLibre.geojson_source(data; cluster=true,
                                          cluster_radius=80)
            decoded = JSON.parse(JSON.json(src))
            @test decoded["cluster"] == true
            @test decoded["clusterRadius"] == 80
            @test decoded["type"] == "geojson"
        end

        @testset "geojson_source accepts a URL String as data" begin
            # Why: MapLibre's geojson source spec lets `data` be either
            # an inline object or a URL to fetch — supporting both keeps
            # callers from reaching for a Dict literal just to wrap a URL.
            src = MapLibre.geojson_source("/api/cells.json")
            decoded = JSON.parse(JSON.json(src))
            @test decoded == Dict("type" => "geojson",
                                  "data" => "/api/cells.json")
        end

        @testset "raster_xyz_source emits {type, tiles, tileSize}" begin
            # Why: XYZ raster tiles are the bread-and-butter basemap;
            # the wire keys are camelCase and the tiles list must
            # survive as a JSON array.
            src = MapLibre.raster_xyz_source(
                ["https://example.com/{z}/{x}/{y}.png"];
                tile_size=512, attribution="© Example")
            decoded = JSON.parse(JSON.json(src))
            @test decoded["type"] == "raster"
            @test decoded["tiles"] == ["https://example.com/{z}/{x}/{y}.png"]
            @test decoded["tileSize"] == 512
            @test decoded["attribution"] == "© Example"
        end

        @testset "raster_xyz_source defaults: tileSize=256, no attribution key" begin
            # Why: omit empty attribution to keep the wire tidy and
            # match MapLibre's "absent = default" model.
            src = MapLibre.raster_xyz_source(
                ["https://e.com/{z}/{x}/{y}.png"])
            decoded = JSON.parse(JSON.json(src))
            @test decoded["tileSize"] == 256
            @test !haskey(decoded, "attribution")
        end

        @testset "raster_xyz_source rejects an empty tiles list" begin
            # Why: a raster source with no tile templates renders
            # nothing silently; fail loud.
            @test_throws ArgumentError MapLibre.raster_xyz_source(
                String[])
        end
    end

    @testset "Layer constructors" begin
        @testset "fill_layer emits {id, type, source, paint}" begin
            # Why: the polygon ramp in the SST demo bottoms out in this
            # exact wire shape — `paint` carries the MapLibre array
            # expression we built up in the paint DSL cycle.
            paint = Dict("fill-color" => MapLibre.prop_get(:mean_sst),
                         "fill-opacity" => 0.7)
            lyr = MapLibre.fill_layer("cells"; source="grid", paint=paint)
            decoded = JSON.parse(JSON.json(lyr))
            @test decoded["id"] == "cells"
            @test decoded["type"] == "fill"
            @test decoded["source"] == "grid"
            @test decoded["paint"]["fill-color"] == ["get", "mean_sst"]
            @test decoded["paint"]["fill-opacity"] == 0.7
        end

        @testset "line_layer, circle_layer, raster_layer set the type field" begin
            # Why: the only thing that varies across thin-paint layer
            # constructors is the MapLibre `type` discriminator — pin it.
            @test JSON.parse(JSON.json(MapLibre.line_layer("a"; source="s")))["type"] == "line"
            @test JSON.parse(JSON.json(MapLibre.circle_layer("b"; source="s")))["type"] == "circle"
            @test JSON.parse(JSON.json(MapLibre.raster_layer("c"; source="s")))["type"] == "raster"
        end

        @testset "fill_layer with filter/layout/source_layer emits the keys" begin
            # Why: vector-tile layers need `source-layer`; filtering
            # expressions are MapLibre arrays; layout opts (e.g.
            # `visibility`) are a separate dict on the wire.
            lyr = MapLibre.fill_layer("cells"; source="grid",
                                      layout=Dict("visibility" => "visible"),
                                      filter=Any["==", Any["get", "kind"], "land"],
                                      source_layer="features")
            decoded = JSON.parse(JSON.json(lyr))
            @test decoded["source-layer"] == "features"
            @test decoded["layout"]["visibility"] == "visible"
            @test decoded["filter"] == ["==", ["get", "kind"], "land"]
        end

        @testset "layer omits paint/layout/filter when not provided" begin
            # Why: keep the wire tidy and let MapLibre apply its defaults.
            lyr = MapLibre.line_layer("a"; source="s")
            decoded = JSON.parse(JSON.json(lyr))
            @test !haskey(decoded, "paint")
            @test !haskey(decoded, "layout")
            @test !haskey(decoded, "filter")
            @test !haskey(decoded, "source-layer")
        end
    end

    @testset "GeoInterface bridge" begin
        # We test through GeoInterface.Wrappers so the bridge stays
        # decoupled from any one concrete geometry package — anything
        # that implements the GeoInterface trait flows through.
        Pt = GeoInterface.Wrappers.Point
        LS = GeoInterface.Wrappers.LineString
        Poly = GeoInterface.Wrappers.Polygon

        @testset "geojson(Point) emits {type: Point, coordinates: [x, y]}" begin
            # Why: the smallest geometry — pin the wire shape so the
            # rest of the bridge can build on it.
            out = MapLibre.geojson(Pt((1.0, 2.0)))
            @test JSON.parse(JSON.json(out)) ==
                  Dict("type" => "Point",
                       "coordinates" => [1.0, 2.0])
        end

        @testset "geojson(LineString) emits a nested coordinate array" begin
            out = MapLibre.geojson(LS([(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)]))
            @test JSON.parse(JSON.json(out)) ==
                  Dict("type" => "LineString",
                       "coordinates" => [[0.0, 0.0], [1.0, 1.0], [2.0, 0.0]])
        end

        @testset "geojson(Polygon) wraps rings in an outer array" begin
            # Why: GeoJSON polygons are array-of-rings; the first ring is
            # exterior and any further are holes. Pin the wrap depth.
            ring = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (0.0, 0.0)]
            out = MapLibre.geojson(Poly([ring]))
            decoded = JSON.parse(JSON.json(out))
            @test decoded["type"] == "Polygon"
            @test length(decoded["coordinates"]) == 1
            @test decoded["coordinates"][1][1] == [0.0, 0.0]
            @test decoded["coordinates"][1][end] == [0.0, 0.0]
        end

        MPt = GeoInterface.Wrappers.MultiPoint
        MLS = GeoInterface.Wrappers.MultiLineString
        MPoly = GeoInterface.Wrappers.MultiPolygon
        GC = GeoInterface.Wrappers.GeometryCollection

        @testset "geojson(MultiPoint) emits an array of positions" begin
            # Why: scattered station/sensor sets arrive as MultiPoint; a
            # bare MethodError on the internal _geojson used to be the
            # only outcome.
            out = MapLibre.geojson(MPt([(0.0, 0.0), (1.0, 1.0)]))
            @test JSON.parse(JSON.json(out)) ==
                  Dict("type" => "MultiPoint",
                       "coordinates" => [[0.0, 0.0], [1.0, 1.0]])
        end

        @testset "geojson(MultiLineString) nests one level past LineString" begin
            out = MapLibre.geojson(MLS([[(0.0, 0.0), (1.0, 1.0)],
                                        [(2.0, 2.0), (3.0, 3.0)]]))
            @test JSON.parse(JSON.json(out)) ==
                  Dict("type" => "MultiLineString",
                       "coordinates" => [[[0.0, 0.0], [1.0, 1.0]],
                                         [[2.0, 2.0], [3.0, 3.0]]])
        end

        @testset "geojson(MultiPolygon) wraps each polygon's rings" begin
            # Why: this is the load-bearing one — coastlines / EEZ
            # boundaries / marine protected areas are MultiPolygons. The
            # wire form is array-of-polygons, each array-of-rings, each
            # array-of-positions: four levels deep, easy to under/over-nest.
            sq(o) = [[(o + 0.0, 0.0), (o + 1.0, 0.0), (o + 1.0, 1.0),
                      (o + 0.0, 1.0), (o + 0.0, 0.0)]]
            out = MapLibre.geojson(MPoly([sq(0.0), sq(2.0)]))
            decoded = JSON.parse(JSON.json(out))
            @test decoded["type"] == "MultiPolygon"
            @test length(decoded["coordinates"]) == 2        # two polygons
            @test length(decoded["coordinates"][1]) == 1      # one ring each
            @test length(decoded["coordinates"][1][1]) == 5   # closed ring
            @test decoded["coordinates"][2][1][1] == [2.0, 0.0]  # 2nd offset
        end

        @testset "geojson(GeometryCollection) recurses through its members" begin
            out = MapLibre.geojson(GC([Pt((1.0, 2.0)),
                                       LS([(0.0, 0.0), (1.0, 1.0)])]))
            decoded = JSON.parse(JSON.json(out))
            @test decoded["type"] == "GeometryCollection"
            @test decoded["geometries"][1] ==
                  Dict("type" => "Point", "coordinates" => [1.0, 2.0])
            @test decoded["geometries"][2]["type"] == "LineString"
        end

        @testset "feature_collection carries a MultiPolygon geometry column" begin
            # Why: the common real case — a table of regions whose geometry
            # is a MultiPolygon — must flow through feature_collection, not
            # just single Points.
            sq(o) = [[(o + 0.0, 0.0), (o + 1.0, 0.0), (o + 1.0, 1.0),
                      (o + 0.0, 1.0), (o + 0.0, 0.0)]]
            rows = [(geom=MPoly([sq(0.0), sq(2.0)]), name="region")]
            fc = MapLibre.feature_collection(rows; geometry_col=:geom,
                                             properties_cols=(:name,))
            decoded = JSON.parse(JSON.json(fc))
            @test decoded["features"][1]["geometry"]["type"] == "MultiPolygon"
            @test decoded["features"][1]["properties"]["name"] == "region"
        end

        @testset "feature_collection emits null geometry for missing/nothing rows" begin
            # Why: GeoJSON (RFC 7946 §3.2) allows a Feature's geometry to
            # be null, and real feature tables carry rows that failed
            # geocoding. One null-geometry row must not crash the whole
            # collection — it serializes to `"geometry":null` while the
            # valid rows still convert.
            rows = [(geom=Pt((1.0, 2.0)), name="a"),
                    (geom=missing, name="b"),
                    (geom=nothing, name="c")]
            fc = MapLibre.feature_collection(rows; geometry_col=:geom,
                                             properties_cols=(:name,))
            decoded = JSON.parse(JSON.json(fc))
            @test decoded["features"][1]["geometry"] ==
                  Dict("type" => "Point", "coordinates" => [1.0, 2.0])
            @test decoded["features"][2]["geometry"] === nothing
            @test decoded["features"][3]["geometry"] === nothing
            # Properties on a null-geometry feature still survive.
            @test decoded["features"][2]["properties"]["name"] == "b"
            # The wire form is literal JSON null, not the string "nothing".
            @test occursin("\"geometry\":null", JSON.json(fc))
        end

        @testset "feature_collection builds a {type, features} envelope" begin
            # Why: this is the input shape `geojson_source` expects when
            # given a Dict. Every row becomes a Feature with geometry +
            # selected properties.
            rows = [
                (geom=Pt((0.0, 0.0)), name="a", val=10),
                (geom=Pt((1.0, 1.0)), name="b", val=20),
            ]
            fc = MapLibre.feature_collection(rows;
                                             geometry_col=:geom,
                                             properties_cols=(:name, :val))
            decoded = JSON.parse(JSON.json(fc))
            @test decoded["type"] == "FeatureCollection"
            @test length(decoded["features"]) == 2
            f0 = decoded["features"][1]
            @test f0["type"] == "Feature"
            @test f0["geometry"]["type"] == "Point"
            @test f0["geometry"]["coordinates"] == [0.0, 0.0]
            @test f0["properties"] == Dict("name" => "a", "val" => 10)
        end

        # cycle 5 — JS helpers below

        @testset "feature_collection composes with geojson_source" begin
            # Why: load-bearing — the demo's polygon ramp wires up via
            # `geojson_source(feature_collection(rows; …))`.
            rows = [(geom=Pt((0.0, 0.0)), v=1)]
            fc = MapLibre.feature_collection(rows;
                                             geometry_col=:geom,
                                             properties_cols=(:v,))
            src = MapLibre.geojson_source(fc)
            decoded = JSON.parse(JSON.json(src))
            @test decoded["type"] == "geojson"
            @test decoded["data"]["type"] == "FeatureCollection"
            @test decoded["data"]["features"][1]["properties"]["v"] == 1
        end
    end

    @testset "Server JS helpers" begin
        # Each helper returns a HyperSignal.Raw carrying a JS snippet
        # that addresses the namespaced map instance under
        # window.__hs_maps[prefix]. Datastar's executeScript runs the
        # returned JS verbatim, so it must be a valid expression.
        Raw = HyperSignal.Raw

        @testset "fly_to emits the namespaced flyTo call" begin
            # Why: the instance handle MUST be `window.__hs_maps[prefix]`
            # so multiple maps on a page don't collide.
            js = HyperSignal.render(MapLibre.fly_to(;
                id_prefix="map_", center=(10.5, -20.0), zoom=4))
            @test occursin("window.__hs_maps['map_']", js)
            @test occursin(".flyTo(", js)
            @test occursin("\"center\":[10.5,-20.0]", js)
            @test occursin("\"zoom\":4", js)
        end

        @testset "fly_to omits zoom when not given, defaults duration to 600ms" begin
            js = HyperSignal.render(MapLibre.fly_to(;
                id_prefix="m_", center=(0.0, 0.0)))
            @test occursin("\"duration\":600", js)
            @test !occursin("\"zoom\"", js)
        end

        @testset "add_source emits map.addSource(id, spec) with the wire JSON" begin
            # Why: server-driven source addition must serialize the
            # Source struct through JSON, not stringify the Julia repr.
            src = MapLibre.geojson_source(Dict("type" => "FeatureCollection",
                                               "features" => []))
            js = HyperSignal.render(MapLibre.add_source(;
                id_prefix="m_", id="grid", spec=src))
            @test occursin("window.__hs_maps['m_']", js)
            @test occursin(".addSource(\"grid\",{", js)
            @test occursin("\"type\":\"geojson\"", js)
        end

        @testset "remove_source / remove_layer emit the named method call" begin
            @test occursin(".removeSource(\"x\")",
                HyperSignal.render(MapLibre.remove_source(; id_prefix="m_", id="x")))
            @test occursin(".removeLayer(\"y\")",
                HyperSignal.render(MapLibre.remove_layer(; id_prefix="m_", id="y")))
        end

        @testset "set_source_data emits guarded getSource(id).setData(data)" begin
            # Why: this is the runtime data-swap path — must NOT replace
            # the source (which would lose any layers wired to it), only
            # update its data payload.
            data = Dict("type" => "FeatureCollection", "features" => [])
            js = HyperSignal.render(MapLibre.set_source_data(;
                id_prefix="m_", source="grid", data=data))
            @test occursin("getSource(\"grid\").setData(d)", js)
            @test occursin("\"type\":\"FeatureCollection\"", js)
            # Guard: applies now if the source exists, else defers to the
            # one-shot `load` so a pre-load swap doesn't throw on undefined.
            @test occursin("m.getSource(\"grid\")?", js)
            @test occursin("m.once('load',f)", js)
            @test !occursin("removeSource", js)
        end

        @testset "add_layer emits addLayer(spec) with the wire JSON" begin
            lyr = MapLibre.fill_layer("cells"; source="grid")
            js = HyperSignal.render(MapLibre.add_layer(;
                id_prefix="m_", spec=lyr))
            @test occursin(".addLayer({", js)
            @test occursin("\"id\":\"cells\"", js)
            @test occursin("\"type\":\"fill\"", js)
        end

        @testset "set_paint_property emits setPaintProperty with JSON-encoded value" begin
            # Why: a paint value may be a MapLibre array expression; the
            # JSON encoding must flow through (not stringify).
            js = HyperSignal.render(MapLibre.set_paint_property(;
                id_prefix="m_", layer="cells", prop="fill-color",
                value=MapLibre.prop_get(:mean_sst)))
            @test occursin(".setPaintProperty(\"cells\",\"fill-color\",", js)
            @test occursin("[\"get\",\"mean_sst\"]", js)
        end

        @testset "map_call is the escape hatch: arbitrary method + args" begin
            # Why: anything beyond the curated helpers should still be
            # reachable. The instance dispatches the named method with
            # JSON-encoded args.
            js = HyperSignal.render(MapLibre.map_call(:resize; id_prefix="m_"))
            @test occursin(".resize()", js)
            js2 = HyperSignal.render(MapLibre.map_call(:setZoom, 5; id_prefix="m_"))
            @test occursin(".setZoom(5)", js2)
        end

        @testset "JS helpers return Raw so they inline into a script body" begin
            # Why: callers compose helpers into a `script()` body
            # returned from a route handler; the Raw wrapper bypasses
            # HTML-escaping at render time.
            @test MapLibre.fly_to(; id_prefix="m_", center=(0.0, 0.0)) isa Raw
        end

        @testset "id_prefix with a single quote is escaped at the JS layer" begin
            # Why: id_prefix lands inside a single-quoted JS string —
            # an unescaped ' would close the string and inject code.
            js = HyperSignal.render(MapLibre.fly_to(;
                id_prefix="a'b_", center=(0.0, 0.0)))
            @test occursin("window.__hs_maps['a\\'b_']", js)
        end
    end

    @testset "map_view + marker" begin
        Pt = GeoInterface.Wrappers.Point

        @testset "map_view renders a container div with the id_prefix-namespaced id" begin
            # Why: callers may put multiple maps on a page; the
            # container id must be unique per id_prefix so DOM lookups
            # and MapLibre's binding don't collide.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="map_",
                center=(0.0, 0.0), zoom=2,
                style="/static/style.json"))
            @test occursin("id=\"map_root\"", out)
        end

        @testset "map_view emits an init script that constructs the MapLibre Map" begin
            # Why: the init JS must `new maplibregl.Map({…})` with
            # container + style + center + zoom; without this the
            # container is just an empty div.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(10.0, 20.0), zoom=4,
                style="/static/style.json"))
            @test occursin("new maplibregl.Map(", out)
            @test occursin("\"container\":\"m_root\"", out)
            @test occursin("\"style\":\"/static/style.json\"", out)
            @test occursin("\"center\":[10.0,20.0]", out)
            @test occursin("\"zoom\":4", out)
        end

        @testset "map_view stores the instance under window.__hs_maps[prefix]" begin
            # Why: every server-returned JS helper addresses the map
            # via this handle — the init must publish it for them.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json"))
            @test occursin("window.__hs_maps['m_']", out)
        end

        @testset "map_view wires moveend → \$<prefix>center / zoom / bounds signals" begin
            # Why: the contract for viewport-driven UI is that the
            # idle moveend updates these signals; mousemove updates
            # the cursor signal separately.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="map_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json",
                center_signal="map_center",
                zoom_signal="map_zoom",
                bounds_signal="map_bounds",
                cursor_signal="map_cursor"))
            @test occursin("'moveend'", out)
            @test occursin("map_center", out)
            @test occursin("map_zoom", out)
            @test occursin("map_bounds", out)
            @test occursin("'mousemove'", out)
            @test occursin("map_cursor", out)
        end

        @testset "map_view click_post wires a Datastar @post with click payload" begin
            # Why: the click handler queries `click_layers` via
            # queryRenderedFeatures and posts {lat, lon, properties}
            # to the configured URL.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json",
                click_post="/api/click",
                click_layers=["cells"]))
            @test occursin("'click'", out)
            @test occursin("queryRenderedFeatures", out)
            @test occursin("\"cells\"", out)
            @test occursin("/api/click", out)
        end

        @testset "map_view bbox_post wires a shift+drag rectangle handler" begin
            # Why: this is the demo's main interaction — drag-rect picks
            # the bbox, server returns the timeseries view. The JS must
            # detect shiftKey and post {w, s, e, n}.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json",
                bbox_post="/api/bbox"))
            @test occursin("shiftKey", out)
            @test occursin("/api/bbox", out)
        end

        @testset "map_view defaults: no click/bbox handlers emitted" begin
            # Why: opting out should NOT inject dead handler stubs that
            # would post to undefined URLs.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json"))
            @test !occursin("queryRenderedFeatures", out)
            @test !occursin("shiftKey", out)
        end

        @testset "marker renders a div the init JS attaches via maplibregl.Marker" begin
            # Why: markers are HTML-content-bearing, and HyperSignal's
            # safety model auto-escapes user content. The marker helper
            # composes an Element tree, then the surrounding map's init
            # picks it up by id and binds it.
            out = HyperSignal.render(MapLibre.marker("Hi <b>there</b>";
                lat=10.0, lon=20.0, id_prefix="m_"))
            @test occursin("data-hs-marker", out)
            @test occursin("data-lat=\"10.0\"", out)
            @test occursin("data-lon=\"20.0\"", out)
            # auto-escaped, per HyperSignal safety model
            @test occursin("Hi &lt;b&gt;there&lt;/b&gt;", out)
        end

        @testset "init JS scans for [data-hs-marker] divs and creates real Markers" begin
            # Why: before this cycle, marker() was dead scaffolding — it
            # emitted data-attribute divs that no JS ever consumed.
            # Shipping API surface that silently does nothing is worse
            # than not shipping it. The init JS must now query the DOM
            # for the prefix-matching markers, parse lat/lon, and hand
            # them to `new maplibregl.Marker({element})`. Doing this
            # inside `_m.on('load')` guarantees the canvas is mounted
            # before MapLibre tries to attach the marker element.
            body = match(r"<script[^>]*>(.*?)</script>"s,
                         HyperSignal.render(MapLibre.map_view(;
                             id_prefix="m_", center=(0.0, 0.0),
                             zoom=2, style="/s.json"))).captures[1]
            # Selector wraps `[data-hs-marker="m_"]`; JSON-encoding emits
            # it as a double-quoted JS string with backslash-escaped
            # inner quotes, which is what `JSON.json` produces.
            @test occursin("document.querySelectorAll(\"[data-hs-marker=\\\"m_\\\"]\")",
                           body)
            @test occursin("new maplibregl.Marker", body)
            @test occursin("setLngLat", body)
            # parseFloat the data attributes; lat/lon as strings would
            # break MapLibre's LngLat constructor silently.
            @test occursin("parseFloat", body)
            # Marker uses the element itself so HyperSignal-rendered
            # children (auto-escaped) become the marker visual.
            @test occursin(r"\{element\s*:", body)
            # Loop over the NodeList — otherwise only the first marker
            # would attach (and a hardcoded-string impl would still pass
            # the syntactic checks above).
            @test occursin(r"forEach|for\s*\(", body)

            # Same shape, different id_prefix → the selector must
            # carry the new prefix (proves the prefix isn't hardcoded).
            body2 = match(r"<script[^>]*>(.*?)</script>"s,
                          HyperSignal.render(MapLibre.map_view(;
                              id_prefix="alt_", center=(0.0, 0.0),
                              zoom=2, style="/s.json"))).captures[1]
            @test occursin("[data-hs-marker=\\\"alt_\\\"]", body2)
            @test !occursin("[data-hs-marker=\\\"m_\\\"]", body2)
        end

        @testset "marker scan is deferred until _m.on('load')" begin
            # Why: an inline <script> runs synchronously while the
            # parser is mid-document — any <div data-hs-marker>
            # sibling appearing AFTER the script in source order is
            # not yet in the DOM. The idiomatic call site is
            # `div(map_view(...), marker(...), marker(...))`, so a
            # non-deferred querySelectorAll would silently match zero
            # markers in the common case. Wrap the scan in
            # `_m.on('load')` (which fires asynchronously after the
            # style fetch) so the parser has finished the document
            # body by the time we query. Regex pins the scan call
            # site to live inside a `_m.on('load',function(){...})`
            # block — a top-level scan would not match.
            body = match(r"<script[^>]*>(.*?)</script>"s,
                         HyperSignal.render(MapLibre.map_view(;
                             id_prefix="m_", center=(0.0, 0.0),
                             zoom=2, style="/s.json"))).captures[1]
            # Find the position of the marker selector and the
            # nearest preceding `_m.on('load',` opener — the latter
            # must come before the former with no intervening
            # closing of the on('load') callback.
            sel_idx = first(findfirst("document.querySelectorAll(\"[data-hs-marker=",
                                      body))
            prefix = body[1:sel_idx]
            # The most recent `_m.on('load',function(){` before the
            # selector must still be open (its matching `});` must
            # appear AFTER the selector, not in the prefix).
            on_load_count = length(collect(eachmatch(r"_m\.on\('load',function\(\)\{", prefix)))
            @test on_load_count >= 1
        end

        @testset "marker popup HTML is the rendered Element tree, auto-escaped" begin
            # Why: a popup is HTML — but the public arg may be a plain
            # string (user input, must be escaped) or a HyperSignal
            # Element (already escaped during render). Routing both
            # through HyperSignal.render preserves the safety model:
            # `<script>` in a string becomes `&lt;script&gt;`; a tag
            # built via the DSL stays a real tag.
            out = HyperSignal.render(MapLibre.marker("pin";
                lat=0.0, lon=0.0, id_prefix="m_",
                popup="<script>alert(1)</script>"))
            # The popup HTML lands in data-popup; HyperSignal renders
            # the string with escaping, then HTML-attribute-escapes the
            # whole thing — so the literal `<` never reaches the DOM.
            @test !occursin("<script>alert(1)</script>", out)
            @test occursin("data-popup", out)
            # Positively assert the escape happened (Yellow critique:
            # the negative assertion alone could pass if popup were
            # silently dropped). The double-escape is HTML-attribute
            # escaping over HyperSignal's content escaping — the
            # browser un-escapes once to read dataset.popup, then
            # setHTML treats the result as HTML, which is the safe
            # escaped form `&lt;script&gt;…&lt;/script&gt;`.
            @test occursin("&amp;lt;script&amp;gt;", out)

            # And the init JS must wire setPopup with setHTML using the
            # marker's data-popup payload — otherwise the attribute is
            # decorative noise.
            body = match(r"<script[^>]*>(.*?)</script>"s,
                         HyperSignal.render(MapLibre.map_view(;
                             id_prefix="m_", center=(0.0, 0.0),
                             zoom=2, style="/s.json"))).captures[1]
            @test occursin("setPopup", body)
            @test occursin("maplibregl.Popup", body)
            @test occursin("setHTML", body)
        end
    end

    # ----------------------------------------------------------------
    # Runtime-JS regression — the emitted <script> body must be plain
    # JavaScript. Datastar's `@post(...)` and `ctx.$signal` tokens are
    # only legal inside Datastar attribute-expression context; leaking
    # them into a <script> body produced a SyntaxError on `@` and a
    # ReferenceError on `ctx`. We assert by string inspection (no
    # external `node` dep) — sufficient to catch this regression class.
    # ----------------------------------------------------------------

    _script_body(out) = match(r"<script[^>]*>(.*?)</script>"s, out).captures[1]

    @testset "Datastar bridge (props down, events up)" begin
        out = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_",
            center=(0.0, 0.0), zoom=2,
            style="/s.json",
            center_signal="map_center",
            zoom_signal="map_zoom",
            bounds_signal="map_bounds",
            cursor_signal="map_cursor",
            click_post="/api/click",
            click_layers=["cells"],
            bbox_post="/api/bbox"))
        js = _script_body(out)

        @testset "no leaked Datastar attribute-expression tokens in the script body" begin
            # Why: `@post(...)` and `ctx.\$signal` are Datastar's
            # attribute-expression sugar; inside a <script> body they
            # raise SyntaxError / ReferenceError. The script must stay
            # plain JS and bridge to Datastar via CustomEvents.
            @test !occursin("@post(", js)
            @test !occursin("@get(", js)
            @test !occursin("ctx.\$", js)
        end

        @testset "script dispatches one CustomEvent per channel on document" begin
            # Why: per the canonical Datastar pattern ("props down,
            # events up"), external scripts dispatch CustomEvents that
            # data-on:* attribute expressions catch and translate into
            # signal writes / @post calls. Event names are namespaced
            # by id_prefix so multiple maps on a page don't collide.
            @test occursin("CustomEvent(\"hs-m_center\"", js)
            @test occursin("CustomEvent(\"hs-m_zoom\"", js)
            @test occursin("CustomEvent(\"hs-m_bounds\"", js)
            @test occursin("CustomEvent(\"hs-m_cursor\"", js)
            @test occursin("CustomEvent(\"hs-m_click\"", js)
            @test occursin("CustomEvent(\"hs-m_bbox\"", js)
            @test occursin("document.dispatchEvent", js)
        end

        @testset "dispatched CustomEvents bubble to the window listener" begin
            # Why: the data-on:*__window listeners Datastar installs live
            # on `window`. An event dispatched on `document` only reaches
            # `window` by bubbling, so every channel needs bubbles:true —
            # without it the cursor/viewport/click/bbox bridge silently
            # no-ops. (Caught by an in-browser run; regression-guarded here.)
            @test occursin("bubbles:true", js)
            @test !occursin("CustomEvent(\"hs-m_cursor\",{detail:[e.lngLat.lng,e.lngLat.lat]})", js)
        end

        @testset "container div carries matching data-on:*__window listeners" begin
            # Why: each script-side CustomEvent must have a Datastar
            # expression listening for it. moveend/mousemove channels
            # assign to \$signal; click/bbox set \$payload and @post.
            @test occursin("data-on:hs-m_center__window=\"\$map_center = evt.detail\"", out)
            @test occursin("data-on:hs-m_zoom__window=\"\$map_zoom = evt.detail\"", out)
            @test occursin("data-on:hs-m_bounds__window=\"\$map_bounds = evt.detail\"", out)
            @test occursin("data-on:hs-m_cursor__window=\"\$map_cursor = evt.detail\"", out)
            @test occursin("data-on:hs-m_click__window=", out)
            @test occursin("@post(&#39;/api/click&#39;)", out)
            @test occursin("data-on:hs-m_bbox__window=", out)
            @test occursin("@post(&#39;/api/bbox&#39;)", out)
        end

        @testset "click/bbox payload signal is not underscore-prefixed" begin
            # Why: Datastar's default request filter excludes any signal
            # matching /(^|\.)_/ from @post bodies (underscore signals are
            # client-local). A `$_payload` would be set locally but never
            # sent, so the server sees no payload and the click/bbox post
            # silently does nothing. Pin a plain `$payload` and forbid the
            # `_`-prefixed form. (Caught by an in-browser run: shift-drag
            # box posted but the timeseries never refreshed.)
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
                click_post="/api/click", bbox_post="/api/bbox"))
            @test occursin("\$payload = evt.detail", out)
            @test !occursin("\$_payload", out)
        end

        @testset "window.__hs_maps is lazily initialised before assignment" begin
            # Why: `window.__hs_maps['m_']=_m` on a fresh page would
            # throw TypeError if __hs_maps weren't created first.
            @test occursin("window.__hs_maps=window.__hs_maps||{}", js)
        end

        @testset "bbox handler disables MapLibre's built-in boxZoom and listens on document" begin
            # Why: shift-drag also fires MapLibre's default boxZoom; we
            # need to disable it. Mouseup on `document` (not canvas) so
            # an off-canvas release still completes the gesture.
            @test occursin("boxZoom", js)
            @test occursin(".disable()", js)
            @test occursin("document.addEventListener('mouseup'", js)
        end

        @testset "bbox handler suppresses dragPan so shift-drag selects, not pans" begin
            # Why: MapLibre's own boxZoom is what disables dragPan during a
            # shift-drag. Once we disable boxZoom (above) that suppression
            # is gone, so a shift-drag would pan the map — the grab point
            # tracks the cursor and start/end unproject to the same coord,
            # collapsing the posted bbox to a zero-area point. The handler
            # must disable dragPan on shift-mousedown and re-enable it on
            # mouseup, or the gesture never produces a real rectangle.
            @test occursin("dragPan", js)
            @test occursin("dragPan&&_m.dragPan.disable()", js) ||
                  occursin("dragPan.disable()", js)
            @test occursin("dragPan.enable()", js)
            # Re-enable must precede the threshold early-return so an
            # accidental shift-click can't leave dragPan permanently off.
            dis = findfirst("dragPan&&_m.dragPan.enable()", js)
            ret = findfirst("_bs=null;return;", js)
            @test dis !== nothing && ret !== nothing && first(dis) < first(ret)
        end

        @testset "bbox handler draws a live selection rectangle" begin
            # Why: MapLibre's boxZoom drew a visible rectangle while
            # dragging; disabling boxZoom removes it, leaving the user no
            # feedback that a box is being drawn (the gesture "doesn't
            # work" from their side). The handler must create an overlay
            # div in the canvas container and size it on mousemove.
            @test occursin("getCanvasContainer()", js)
            @test occursin("document.addEventListener('mousemove'", js)
            @test occursin("createElement('div')", js)
            # The rectangle must be torn down on release, not leaked.
            @test occursin(".remove()", js)
        end

        @testset "shift-click without drag does not fire bbox" begin
            # Why: a bare shift-mousedown immediately followed by a
            # shift-mouseup at the same screen point would otherwise
            # post a degenerate `w==e && s==n` bbox — almost certainly
            # an accidental modifier press, never a real user gesture.
            # We expect the handler to record the mousedown screen
            # coords and short-circuit on mouseup when the drag distance
            # is below a small pixel threshold.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
                bbox_post="/api/bbox"))
            body = _script_body(out)
            # The handler must remember the mousedown screen-space point
            # so it can measure the drag distance on mouseup.
            @test occursin(r"_bs_x\s*=\s*e\.(offset|client)X", body)
            @test occursin(r"_bs_y\s*=\s*e\.(offset|client)Y", body)
            # The dispatch must be guarded by a per-axis pixel-threshold
            # comparison against the recorded mousedown coords — a no-op
            # threshold (e.g. `Math.abs(0) < 3`) would pass a regex but
            # not protect anything, so the regex pins both abs() args to
            # actually reference _bs_x / _bs_y.
            @test occursin(
                r"Math\.abs\([^)]*-\s*_bs_x[^)]*\)\s*[<>]=?\s*\d", body)
            @test occursin(
                r"Math\.abs\([^)]*-\s*_bs_y[^)]*\)\s*[<>]=?\s*\d", body)
        end

        @testset "opting out of signals/posts emits no listeners" begin
            # Why: a bare map_view should not leak data-on:* attrs that
            # would post to undefined URLs or write phantom signals.
            bare = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json"))
            @test !occursin("data-on:hs-m_", bare)
            @test !occursin("CustomEvent(", _script_body(bare))
        end
    end

    @testset "click_post/bbox_post URLs survive a single-quote / backslash" begin
        # Why: the data-on:hs-*click__window attribute embeds the URL
        # inside a single-quoted JS string (`@post('<url>')`). A naive
        # interpolation breaks the JS as soon as the URL contains `'`
        # or `\` — turning a developer typo into a silent runtime
        # SyntaxError, or, with caller-controlled URLs, code injection.
        # We assert the JS-level escape happens *before* HTML escaping:
        # `'` must render as `\&#39;` (backslash + HTML-escaped quote),
        # so the browser un-escapes the attribute to `\'` — a valid
        # escaped quote inside the JS string literal.
        out = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/api/click'oops",
            bbox_post="/api/bbox\\here"))
        @test occursin("@post(&#39;/api/click\\&#39;oops&#39;)", out)
        @test occursin("@post(&#39;/api/bbox\\\\here&#39;)", out)

        # Mixed `\'` requires backslash-first ordering: a naive
        # quote-then-backslash pass would produce `\\\` + un-escaped `'`.
        mixed = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/x\\'y"))
        @test occursin("@post(&#39;/x\\\\\\&#39;y&#39;)", mixed)

        # Raw CR/LF inside a single-quoted JS string literal is a
        # SyntaxError — must be escaped to `\r`/`\n` before HTML escape.
        # U+2028/U+2029 escaped defensively for older JS engines.
        nl = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/a\nb",
            bbox_post="/c\rd"))
        @test occursin("@post(&#39;/a\\nb&#39;)", nl)
        @test occursin("@post(&#39;/c\\rd&#39;)", nl)
        @test !occursin("/a\nb", nl)  # raw LF must NOT survive into the attr
        @test !occursin("/c\rd", nl)

        para = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/a b c"))
        @test occursin("@post(&#39;/a\\u2028b\\u2029c&#39;)", para)
    end

    @testset "Identifier escaping in JS helpers" begin
        @testset "add_source JSON-escapes the id slot" begin
            # Why: id flows into a JS string literal. A naive `\"\$id\"`
            # interpolation breaks on any id containing `\"` or `\\`,
            # turning a benign caller mistake into a JS parse error
            # (or, with attacker-controlled ids, code injection).
            src = MapLibre.geojson_source(Dict("type"=>"FeatureCollection","features"=>[]))
            js = HyperSignal.render(MapLibre.add_source(;
                id_prefix="m_", id="a\"b", spec=src))
            @test occursin("\"a\\\"b\"", js)
        end

        @testset "set_paint_property JSON-escapes layer and prop" begin
            js = HyperSignal.render(MapLibre.set_paint_property(;
                id_prefix="m_", layer="a\"b", prop="c\\d", value=1))
            @test occursin("\"a\\\"b\"", js)
            @test occursin("\"c\\\\d\"", js)
        end
    end
end
