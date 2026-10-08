# Why: top-level HyperSignal exports nothing new; tests reach extension module by name.

using Test
using GeoInterface
using JSON
using HyperSignal

const MapLibre = Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)

@testset "HyperSignalMapLibreExt" begin
    @testset "extension loads when GeoInterface is present" begin
        # Why: whole MapLibre surface gated on this; inactive extension makes later
        # tests meaningless.
        @test MapLibre !== nothing
    end

    @testset "paint DSL" begin
        @testset "get(:prop) JSON-encodes as the MapLibre [\"get\", name] expression" begin
            # Why: every paint expression bottoms out in property lookup; wire shape
            # load-bearing downstream.
            ex = MapLibre.prop_get(:mean_sst)
            @test JSON.json(ex) == "[\"get\",\"mean_sst\"]"
        end

        @testset "literal wraps a value in [\"literal\", value]" begin
            # Why: paint-constant arrays/objects need literal escape, else read as
            # nested expressions.
            @test JSON.json(MapLibre.literal([1, 2, 3])) ==
                  "[\"literal\",[1,2,3]]"
            @test JSON.json(MapLibre.literal("x")) ==
                  "[\"literal\",\"x\"]"
        end

        @testset "linear() is a zero-arg interpolation kind marker" begin
            # Why: MapLibre encodes interpolation type as nested array `["linear"]`;
            # marker keeps call site readable as `interpolate(linear(), input, …)`.
            @test JSON.json(MapLibre.linear()) == "[\"linear\"]"
        end

        @testset "interpolate flattens stop pairs into the MapLibre array form" begin
            # Why: wire form interleaves stop-input/stop-output as flat positional args
            # after input expression.
            ex = MapLibre.interpolate(MapLibre.linear(),
                                      MapLibre.prop_get(:mean_sst),
                                      15 => "#00f", 25 => "#f00")
            @test JSON.json(ex) == string(
                "[\"interpolate\",[\"linear\"],[\"get\",\"mean_sst\"],",
                "15,\"#00f\",25,\"#f00\"]",
            )
        end

        @testset "step flattens (default, threshold => value...) pairs" begin
            # Why: step takes leading default before threshold pairs; MapLibre fixes
            # order, easy to invert.
            ex = MapLibre.expr_step(MapLibre.prop_get(:value), "default",
                               10 => "low", 50 => "high")
            @test JSON.json(ex) == string(
                "[\"step\",[\"get\",\"value\"],\"default\",",
                "10,\"low\",50,\"high\"]",
            )
        end

        @testset "match flattens label=>value pairs with a trailing default" begin
            # Why: match default is LAST positional arg in wire form, not keyword.
            ex = MapLibre.expr_match(MapLibre.prop_get(:kind),
                                "vessel" => "#222", "buoy" => "#08f";
                                default="#888")
            @test JSON.json(ex) == string(
                "[\"match\",[\"get\",\"kind\"],",
                "\"vessel\",\"#222\",\"buoy\",\"#08f\",\"#888\"]",
            )
        end

        @testset "get accepts a String property path, not just a Symbol" begin
            # Why: GeoJSON properties with dots/unicode names can't be Symbols; strings
            # fall back, same wire form.
            @test JSON.json(MapLibre.prop_get("nested.path")) ==
                  "[\"get\",\"nested.path\"]"
        end

        @testset "interpolate with one stop pair still emits a valid expression" begin
            # Why: single-stop ramp valid before real data arrives; only empty rejected
            # (next test).
            ex = MapLibre.interpolate(MapLibre.linear(),
                                      MapLibre.prop_get(:x), 0 => "#fff")
            @test JSON.json(ex) ==
                  "[\"interpolate\",[\"linear\"],[\"get\",\"x\"],0,\"#fff\"]"
        end

        @testset "interpolate with zero stops fails loud" begin
            # Why: empty ramp renders nothing in MapLibre; fail at build time, not draw
            # time.
            @test_throws ArgumentError MapLibre.interpolate(
                MapLibre.linear(), MapLibre.prop_get(:x))
        end

        @testset "match requires a default — silent fallthroughs are a footgun" begin
            # Why: match without default returns null → feature paints transparent; fail
            # at build time.
            @test_throws ArgumentError MapLibre.expr_match(MapLibre.prop_get(:k),
                                                      "a" => "#111")
        end

        @testset "paint expressions compose without losing the wire shape" begin
            # Why: real expressions nest; re-encoding must not flatten inner expression.
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
            # Why: unset keys stay off wire; MapLibre applies documented defaults.
            data = Dict("type" => "FeatureCollection", "features" => [])
            src = MapLibre.geojson_source(data)
            decoded = JSON.parse(JSON.json(src))
            @test decoded == Dict("type" => "geojson", "data" => data)
        end

        @testset "geojson_source cluster opts emit clusterRadius (camelCase)" begin
            # Why: MapLibre wire keys camelCase, Julia kwargs snake_case.
            data = Dict("type" => "FeatureCollection", "features" => [])
            src = MapLibre.geojson_source(data; cluster=true,
                                          cluster_radius=80)
            decoded = JSON.parse(JSON.json(src))
            @test decoded["cluster"] == true
            @test decoded["clusterRadius"] == 80
            @test decoded["type"] == "geojson"
        end

        @testset "geojson_source accepts a URL String as data" begin
            # Why: geojson `data` is inline object or URL; supporting both avoids
            # wrapping URL in Dict.
            src = MapLibre.geojson_source("/api/cells.json")
            decoded = JSON.parse(JSON.json(src))
            @test decoded == Dict("type" => "geojson",
                                  "data" => "/api/cells.json")
        end

        @testset "raster_xyz_source emits {type, tiles, tileSize}" begin
            # Why: wire keys camelCase; tiles list must survive as JSON array.
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
            # Why: absent = MapLibre default; omit empty attribution.
            src = MapLibre.raster_xyz_source(
                ["https://e.com/{z}/{x}/{y}.png"])
            decoded = JSON.parse(JSON.json(src))
            @test decoded["tileSize"] == 256
            @test !haskey(decoded, "attribution")
        end

        @testset "raster_xyz_source rejects an empty tiles list" begin
            # Why: raster source with no tile templates renders nothing silently; fail
            # loud.
            @test_throws ArgumentError MapLibre.raster_xyz_source(
                String[])
        end
    end

    @testset "Layer constructors" begin
        @testset "fill_layer emits {id, type, source, paint}" begin
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
            # Why: only MapLibre `type` discriminator varies across thin-paint layer
            # constructors.
            @test JSON.parse(JSON.json(MapLibre.line_layer("a"; source="s")))["type"] == "line"
            @test JSON.parse(JSON.json(MapLibre.circle_layer("b"; source="s")))["type"] == "circle"
            @test JSON.parse(JSON.json(MapLibre.raster_layer("c"; source="s")))["type"] == "raster"
        end

        @testset "fill_layer with filter/layout/source_layer emits the keys" begin
            # Why: vector-tile layers need `source-layer`; filters are MapLibre arrays;
            # layout opts (e.g. `visibility`) are separate dict on wire.
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
            # Why: omit empty keys; MapLibre applies defaults.
            lyr = MapLibre.line_layer("a"; source="s")
            decoded = JSON.parse(JSON.json(lyr))
            @test !haskey(decoded, "paint")
            @test !haskey(decoded, "layout")
            @test !haskey(decoded, "filter")
            @test !haskey(decoded, "source-layer")
        end
    end

    @testset "GeoInterface bridge" begin
        # Why: GeoInterface.Wrappers keeps bridge decoupled from any one concrete
        # geometry package.
        Pt = GeoInterface.Wrappers.Point
        LS = GeoInterface.Wrappers.LineString
        Poly = GeoInterface.Wrappers.Polygon

        @testset "geojson(Point) emits {type: Point, coordinates: [x, y]}" begin
            # Why: smallest geometry; rest of bridge builds on this wire shape.
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
            # Why: polygons = array-of-rings; first exterior, rest holes. Pin wrap
            # depth.
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
            # Why: scattered station/sensor sets arrive as MultiPoint.
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
            # Why: coastlines/EEZ/MPAs are MultiPolygons; wire form nests four levels
            # deep, easy to under/over-nest.
            sq(o) = [[(o + 0.0, 0.0), (o + 1.0, 0.0), (o + 1.0, 1.0),
                      (o + 0.0, 1.0), (o + 0.0, 0.0)]]
            out = MapLibre.geojson(MPoly([sq(0.0), sq(2.0)]))
            decoded = JSON.parse(JSON.json(out))
            @test decoded["type"] == "MultiPolygon"
            @test length(decoded["coordinates"]) == 2
            @test length(decoded["coordinates"][1]) == 1
            @test length(decoded["coordinates"][1][1]) == 5
            @test decoded["coordinates"][2][1][1] == [2.0, 0.0]
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
            # Why: regions table with MultiPolygon geometry must flow through
            # feature_collection, not just Points.
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
            # Why: RFC 7946 §3.2 allows null geometry; rows failing geocoding must not
            # crash the collection.
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
            @test decoded["features"][2]["properties"]["name"] == "b"
            # Why: literal JSON null, not string "nothing".
            @test occursin("\"geometry\":null", JSON.json(fc))
        end

        @testset "feature_collection builds a {type, features} envelope" begin
            # Why: input shape `geojson_source` expects for a Dict.
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


        @testset "feature_collection composes with geojson_source" begin
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
        # Why: Datastar executeScript runs returned JS verbatim; must be valid
        # expression.
        Raw = HyperSignal.Raw

        @testset "fly_to emits the namespaced flyTo call" begin
            # Why: handle MUST be `window.__hs_maps[prefix]` so multiple maps on a page
            # do not collide.
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
            # Why: Source struct must serialize through JSON, not Julia repr.
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
            # Why: runtime data swap must NOT replace source (loses wired layers);
            # update data only.
            data = Dict("type" => "FeatureCollection", "features" => [])
            js = HyperSignal.render(MapLibre.set_source_data(;
                id_prefix="m_", source="grid", data=data))
            @test occursin("getSource(\"grid\").setData(d)", js)
            @test occursin("\"type\":\"FeatureCollection\"", js)
            # Why: pre-load swap defers to one-shot `load` instead of throwing on
            # undefined.
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
            # Why: paint value may be MapLibre array expression; JSON must flow through,
            # not stringify.
            js = HyperSignal.render(MapLibre.set_paint_property(;
                id_prefix="m_", layer="cells", prop="fill-color",
                value=MapLibre.prop_get(:mean_sst)))
            @test occursin(".setPaintProperty(\"cells\",\"fill-color\",", js)
            @test occursin("[\"get\",\"mean_sst\"]", js)
        end

        @testset "map_call is the escape hatch: arbitrary method + args" begin
            # Why: methods beyond curated helpers stay reachable via named dispatch with
            # JSON-encoded args.
            js = HyperSignal.render(MapLibre.map_call(:resize; id_prefix="m_"))
            @test occursin(".resize()", js)
            js2 = HyperSignal.render(MapLibre.map_call(:setZoom, 5; id_prefix="m_"))
            @test occursin(".setZoom(5)", js2)
        end

        @testset "JS helpers return Raw so they inline into a script body" begin
            # Why: callers compose helpers into `script()` body from route handler; Raw
            # bypasses HTML-escaping at render.
            @test MapLibre.fly_to(; id_prefix="m_", center=(0.0, 0.0)) isa Raw
        end

        @testset "id_prefix with a single quote is escaped at the JS layer" begin
            # Why: id_prefix lands in single-quoted JS string; unescaped ' closes it and
            # injects code.
            js = HyperSignal.render(MapLibre.fly_to(;
                id_prefix="a'b_", center=(0.0, 0.0)))
            @test occursin("window.__hs_maps['a\\'b_']", js)
        end
    end

    @testset "map_view + marker" begin
        Pt = GeoInterface.Wrappers.Point

        @testset "map_view renders a container div with the id_prefix-namespaced id" begin
            # Why: container id must be unique per id_prefix, else DOM lookups and
            # MapLibre binding collide.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="map_",
                center=(0.0, 0.0), zoom=2,
                style="/static/style.json"))
            @test occursin("id=\"map_root\"", out)
        end

        @testset "map_view emits an init script that constructs the MapLibre Map" begin
            # Why: init JS must `new maplibregl.Map({…})` with container + style +
            # center + zoom; else empty div.
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
            # Why: every server-returned JS helper addresses map via this handle; init
            # must publish it.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json"))
            @test occursin("window.__hs_maps['m_']", out)
        end

        @testset "map_view wires moveend → \$<prefix>center / zoom / bounds signals" begin
            # Why: idle moveend updates viewport signals; mousemove updates cursor
            # signal separately.
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
            # Why: click handler queries `click_layers` via queryRenderedFeatures, posts
            # {lat, lon, properties} to URL.
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
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json",
                bbox_post="/api/bbox"))
            @test occursin("shiftKey", out)
            @test occursin("/api/bbox", out)
        end

        @testset "map_view defaults: no click/bbox handlers emitted" begin
            # Why: opting out must NOT inject dead handler stubs posting to undefined
            # URLs.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_",
                center=(0.0, 0.0), zoom=2,
                style="/s.json"))
            @test !occursin("queryRenderedFeatures", out)
            @test !occursin("shiftKey", out)
        end

        @testset "marker renders a div the init JS attaches via maplibregl.Marker" begin
            # Why: markers carry HTML content; safety model auto-escapes user content.
            # Marker helper composes Element tree; map init picks it up by id and binds
            # it.
            out = HyperSignal.render(MapLibre.marker("Hi <b>there</b>";
                lat=10.0, lon=20.0, id_prefix="m_"))
            @test occursin("data-hs-marker", out)
            @test occursin("data-lat=\"10.0\"", out)
            @test occursin("data-lon=\"20.0\"", out)
            @test occursin("Hi &lt;b&gt;there&lt;/b&gt;", out)
        end

        @testset "init JS scans for [data-hs-marker] divs and creates real Markers" begin
            # Why: without this scan, marker() divs are a silent no-op. `_m.on('load')`
            # guarantees the canvas is mounted before markers attach.
            body = match(r"<script[^>]*>(.*?)</script>"s,
                         HyperSignal.render(MapLibre.map_view(;
                             id_prefix="m_", center=(0.0, 0.0),
                             zoom=2, style="/s.json"))).captures[1]
            # Why: selector `[data-hs-marker="m_"]` JSON-encodes to double-quoted JS
            # string with backslash-escaped inner quotes.
            @test occursin("document.querySelectorAll(\"[data-hs-marker=\\\"m_\\\"]\")",
                           body)
            @test occursin("new maplibregl.Marker", body)
            @test occursin("setLngLat", body)
            # Why: parseFloat data attributes; string lat/lon silently break MapLibre's
            # LngLat constructor.
            @test occursin("parseFloat", body)
            @test occursin(r"\{element\s*:", body)
            # Why: loop over NodeList; otherwise only first marker attaches.
            @test occursin(r"forEach|for\s*\(", body)

            # Why: other id_prefix must change selector; proves prefix not hardcoded.
            body2 = match(r"<script[^>]*>(.*?)</script>"s,
                          HyperSignal.render(MapLibre.map_view(;
                              id_prefix="alt_", center=(0.0, 0.0),
                              zoom=2, style="/s.json"))).captures[1]
            @test occursin("[data-hs-marker=\\\"alt_\\\"]", body2)
            @test !occursin("[data-hs-marker=\\\"m_\\\"]", body2)
        end

        @testset "marker scan is deferred until _m.on('load')" begin
            # Why: inline <script> runs mid-parse; sibling markers after it are not in
            # DOM yet, so non-deferred querySelectorAll matches zero in common
            # `div(map_view(...), marker(...))` case. Scan must sit inside
            # `_m.on('load',function(){...})`; regex pins that.
            body = match(r"<script[^>]*>(.*?)</script>"s,
                         HyperSignal.render(MapLibre.map_view(;
                             id_prefix="m_", center=(0.0, 0.0),
                             zoom=2, style="/s.json"))).captures[1]
            sel_idx = first(findfirst("document.querySelectorAll(\"[data-hs-marker=",
                                      body))
            prefix = body[1:sel_idx]
            on_load_count = length(collect(eachmatch(r"_m\.on\('load',function\(\)\{", prefix)))
            @test on_load_count >= 1
        end

        @testset "marker popup HTML is the rendered Element tree, auto-escaped" begin
            # Why: popup arg may be plain string (user input, must be escaped) or
            # Element (already escaped in render). Routing both through
            # HyperSignal.render keeps safety model: `<script>` in string becomes
            # `&lt;script&gt;`; DSL-built tag stays real.
            out = HyperSignal.render(MapLibre.marker("pin";
                lat=0.0, lon=0.0, id_prefix="m_",
                popup="<script>alert(1)</script>"))
            # Why: HTML-attribute-escaping rendered popup keeps literal `<` out of DOM.
            @test !occursin("<script>alert(1)</script>", out)
            @test occursin("data-popup", out)
            # Why: negative assertion alone passes if popup silently dropped. Double
            # escape = attribute-escape over content-escape; browser un-escapes once for
            # dataset.popup, setHTML then sees safe `&lt;script&gt;…&lt;/script&gt;`.
            @test occursin("&amp;lt;script&amp;gt;", out)

            # Why: init JS must wire setPopup with setHTML from marker's data-popup;
            # else attribute is decorative.
            body = match(r"<script[^>]*>(.*?)</script>"s,
                         HyperSignal.render(MapLibre.map_view(;
                             id_prefix="m_", center=(0.0, 0.0),
                             zoom=2, style="/s.json"))).captures[1]
            @test occursin("setPopup", body)
            @test occursin("maplibregl.Popup", body)
            @test occursin("setHTML", body)
        end
    end


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
            # Why: `@post(...)` and `ctx.$signal` are Datastar attribute-expression
            # sugar; in <script> they raise SyntaxError / ReferenceError. Script stays
            # plain JS, bridges to Datastar via CustomEvents.
            @test !occursin("@post(", js)
            @test !occursin("@get(", js)
            @test !occursin("ctx.\$", js)
        end

        @testset "script dispatches one CustomEvent per channel on document" begin
            # Why: "props down, events up": scripts dispatch CustomEvents; data-on:*
            # expressions turn them into signal writes / @post. Event names namespaced
            # by id_prefix so maps do not collide.
            @test occursin("CustomEvent(\"hs-m_center\"", js)
            @test occursin("CustomEvent(\"hs-m_zoom\"", js)
            @test occursin("CustomEvent(\"hs-m_bounds\"", js)
            @test occursin("CustomEvent(\"hs-m_cursor\"", js)
            @test occursin("CustomEvent(\"hs-m_click\"", js)
            @test occursin("CustomEvent(\"hs-m_bbox\"", js)
            @test occursin("document.dispatchEvent", js)
        end

        @testset "dispatched CustomEvents bubble to the window listener" begin
            # Why: Datastar data-on:*__window listeners live on `window`; event on
            # `document` reaches it only by bubbling → every channel needs bubbles:true,
            # else cursor/viewport/click/bbox bridge silently no-ops.
            @test occursin("bubbles:true", js)
            @test !occursin("CustomEvent(\"hs-m_cursor\",{detail:[e.lngLat.lng,e.lngLat.lat]})", js)
        end

        @testset "container div carries matching data-on:*__window listeners" begin
            # Why: each script-side CustomEvent needs listening Datastar expression;
            # moveend/mousemove assign to $signal, click/bbox set $payload and @post.
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
            # Why: Datastar's default request filter drops signals matching /(^|\.)_/
            # from @post bodies (client-local). `$_payload` sets locally, never sent →
            # click/bbox post does nothing. Pin plain `$payload`, forbid `_`-prefixed
            # form.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
                click_post="/api/click", bbox_post="/api/bbox"))
            @test occursin("\$payload = evt.detail", out)
            @test !occursin("\$_payload", out)
        end

        @testset "window.__hs_maps is lazily initialised before assignment" begin
            # Why: `window.__hs_maps['m_']=_m` throws TypeError unless __hs_maps created
            # first.
            @test occursin("window.__hs_maps=window.__hs_maps||{}", js)
        end

        @testset "bbox handler disables MapLibre's built-in boxZoom and listens on document" begin
            # Why: shift-drag also fires MapLibre default boxZoom; disable it. Mouseup
            # on `document`, not canvas, so off-canvas release still completes gesture.
            @test occursin("boxZoom", js)
            @test occursin(".disable()", js)
            @test occursin("document.addEventListener('mouseup'", js)
        end

        @testset "bbox handler suppresses dragPan so shift-drag selects, not pans" begin
            # Why: MapLibre's boxZoom suppresses dragPan during shift-drag. Once boxZoom
            # is disabled, shift-drag pans: grab point tracks cursor, start/end
            # unproject to same coord, posted bbox collapses to zero area. Handler must
            # disable dragPan on shift-mousedown, re-enable on mouseup.
            @test occursin("dragPan", js)
            @test occursin("dragPan&&_m.dragPan.disable()", js) ||
                  occursin("dragPan.disable()", js)
            @test occursin("dragPan.enable()", js)
            # Why: re-enable must precede threshold early-return, else accidental
            # shift-click leaves dragPan off.
            dis = findfirst("dragPan&&_m.dragPan.enable()", js)
            ret = findfirst("_bs=null;return;", js)
            @test dis !== nothing && ret !== nothing && first(dis) < first(ret)
        end

        @testset "bbox handler draws a live selection rectangle" begin
            # Why: boxZoom drew the visible rectangle; disabling it leaves no drag
            # feedback. Handler must create overlay div in canvas container and size it
            # on mousemove.
            @test occursin("getCanvasContainer()", js)
            @test occursin("document.addEventListener('mousemove'", js)
            @test occursin("createElement('div')", js)
            # Why: overlay must be torn down on release, not leaked.
            @test occursin(".remove()", js)
        end

        @testset "shift-click without drag does not fire bbox" begin
            # Why: shift-mousedown + shift-mouseup at same point would post degenerate
            # `w==e && s==n` bbox (accidental modifier press). Handler records mousedown
            # coords, short-circuits on mouseup below small pixel threshold.
            out = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
                bbox_post="/api/bbox"))
            body = _script_body(out)
            @test occursin(r"_bs_x\s*=\s*e\.(offset|client)X", body)
            @test occursin(r"_bs_y\s*=\s*e\.(offset|client)Y", body)
            # Why: no-op threshold (e.g. `Math.abs(0) < 3`) would pass a regex but
            # protect nothing; regex pins both abs() args to reference _bs_x / _bs_y.
            @test occursin(
                r"Math\.abs\([^)]*-\s*_bs_x[^)]*\)\s*[<>]=?\s*\d", body)
            @test occursin(
                r"Math\.abs\([^)]*-\s*_bs_y[^)]*\)\s*[<>]=?\s*\d", body)
        end

        @testset "opting out of signals/posts emits no listeners" begin
            # Why: bare map_view must not leak data-on:* attrs posting to undefined URLs
            # or writing phantom signals.
            bare = HyperSignal.render(MapLibre.map_view(;
                id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json"))
            @test !occursin("data-on:hs-m_", bare)
            @test !occursin("CustomEvent(", _script_body(bare))
        end
    end

    @testset "click_post/bbox_post URLs survive a single-quote / backslash" begin
        # Why: URL sits in single-quoted JS string (`@post('<url>')`); naive
        # interpolation breaks on `'` or `\` → silent SyntaxError, or code injection
        # with caller-controlled URLs. JS escape must precede HTML escape: `'` renders
        # `\&#39;`, browser un-escapes to `\'`.
        out = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/api/click'oops",
            bbox_post="/api/bbox\\here"))
        @test occursin("@post(&#39;/api/click\\&#39;oops&#39;)", out)
        @test occursin("@post(&#39;/api/bbox\\\\here&#39;)", out)

        # Why: mixed `\'` needs backslash-first ordering; quote-then-backslash yields
        # `\\\` + unescaped `'`.
        mixed = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/x\\'y"))
        @test occursin("@post(&#39;/x\\\\\\&#39;y&#39;)", mixed)

        # Why: raw CR/LF in single-quoted JS string is SyntaxError; escape to `\r`/`\n`
        # before HTML escape. U+2028/U+2029 escaped for older JS engines.
        nl = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/a\nb",
            bbox_post="/c\rd"))
        @test occursin("@post(&#39;/a\\nb&#39;)", nl)
        @test occursin("@post(&#39;/c\\rd&#39;)", nl)
        @test !occursin("/a\nb", nl)
        @test !occursin("/c\rd", nl)

        para = HyperSignal.render(MapLibre.map_view(;
            id_prefix="m_", center=(0.0, 0.0), zoom=2, style="/s.json",
            click_post="/a b c"))
        @test occursin("@post(&#39;/a\\u2028b\\u2029c&#39;)", para)
    end

    @testset "Identifier escaping in JS helpers" begin
        @testset "add_source JSON-escapes the id slot" begin
            # Why: id flows into JS string literal; naive `"$id"` interpolation breaks
            # on `"` or `\` → JS parse error, or code injection with attacker-controlled
            # ids.
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
