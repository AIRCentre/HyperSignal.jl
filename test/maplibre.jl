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
            ex = MapLibre.get(:mean_sst)
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
                                      MapLibre.get(:mean_sst),
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
            ex = MapLibre.step(MapLibre.get(:value), "default",
                               10 => "low", 50 => "high")
            @test JSON.json(ex) == string(
                "[\"step\",[\"get\",\"value\"],\"default\",",
                "10,\"low\",50,\"high\"]",
            )
        end

        @testset "match flattens label=>value pairs with a trailing default" begin
            # Why: match takes the default as the LAST positional arg in
            # MapLibre's wire form, not as a keyword — easy to get wrong.
            ex = MapLibre.match(MapLibre.get(:kind),
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
            @test JSON.json(MapLibre.get("nested.path")) ==
                  "[\"get\",\"nested.path\"]"
        end

        @testset "interpolate with one stop pair still emits a valid expression" begin
            # Why: a degenerate single-stop ramp is a useful default
            # before real data arrives; reject only the empty case (next
            # test). One pair must round-trip cleanly.
            ex = MapLibre.interpolate(MapLibre.linear(),
                                      MapLibre.get(:x), 0 => "#fff")
            @test JSON.json(ex) ==
                  "[\"interpolate\",[\"linear\"],[\"get\",\"x\"],0,\"#fff\"]"
        end

        @testset "interpolate with zero stops fails loud" begin
            # Why: an empty ramp is meaningless in MapLibre and renders
            # nothing — fail at build time, not silently at draw time.
            @test_throws ArgumentError MapLibre.interpolate(
                MapLibre.linear(), MapLibre.get(:x))
        end

        @testset "match requires a default — silent fallthroughs are a footgun" begin
            # Why: a match without a default silently returns null in
            # MapLibre, which paints the feature transparent — fail at
            # build time so the missing case is visible in the diff.
            @test_throws ArgumentError MapLibre.match(MapLibre.get(:k),
                                                      "a" => "#111")
        end

        @testset "paint expressions compose without losing the wire shape" begin
            # Why: real expressions nest — `interpolate(…, get(:x), …, match(get(:k), …))`
            # is one composed paint value. Re-encoding must not flatten
            # the inner expression.
            inner = MapLibre.match(MapLibre.get(:kind),
                                   "a" => "#111"; default="#222")
            outer = MapLibre.interpolate(MapLibre.linear(),
                                         MapLibre.get(:x),
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
            paint = Dict("fill-color" => MapLibre.get(:mean_sst),
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

        @testset "set_source_data emits getSource(id).setData(data)" begin
            # Why: this is the runtime data-swap path — must NOT replace
            # the source (which would lose any layers wired to it), only
            # update its data payload.
            data = Dict("type" => "FeatureCollection", "features" => [])
            js = HyperSignal.render(MapLibre.set_source_data(;
                id_prefix="m_", source="grid", data=data))
            @test occursin("getSource(\"grid\").setData({", js)
            @test occursin("\"type\":\"FeatureCollection\"", js)
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
                value=MapLibre.get(:mean_sst)))
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
    end
end
