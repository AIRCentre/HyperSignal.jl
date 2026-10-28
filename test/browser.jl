# Generated JS checked in headless Chromium against the vendored MapLibre,
# Terra Draw and Datastar bundles. Run from runtests.jl through CDP.with_browser.

const _ASSETS = joinpath(@__DIR__, "..", "docs", "src", "notebooks", "assets")
_js_asset(path...) = ("text/javascript", read(joinpath(path...), String))

const _BROWSER_ROUTES = Dict{String, Any}(
    "/maplibre.js" => _js_asset(_ASSETS, "maplibre", "maplibre-gl.js"),
    "/maplibre.css" => ("text/css", read(joinpath(_ASSETS, "maplibre", "maplibre-gl.css"), String)),
    "/datastar.js" => _js_asset(_ASSETS, "datastar.js"),
    "/terra-draw.js" => _js_asset(@__DIR__, "assets", "terra-draw", "terra-draw.js"),
    "/terra-draw-adapter.js" => _js_asset(@__DIR__, "assets", "terra-draw", "terra-draw-maplibre-gl-adapter.js"),
    "/style.json" => ("application/json",
        """{"version":8,"sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"#234"}}]}"""),
)

function _browser_page(content; signals=(;))
    HyperSignal.render(Frag(DOCTYPE, html(
        head(meta(charset="utf-8"),
             link(rel="stylesheet", href="/maplibre.css"),
             script(src="/maplibre.js"), script(src="/terra-draw.js"),
             script(src="/terra-draw-adapter.js"),
             script(type="module", src="/datastar.js"),
             style("body{margin:0}#map_root{width:800px;height:600px}")),
        body(ds_signals(signals), content,
             HyperSignal.pre(id="signals", ds_json_signals())))))
end

_routes(pairs...) = merge(_BROWSER_ROUTES, Dict{String, Any}(pairs...))
_signals(page) = JSON.parse(CDP.js(page, "document.getElementById('signals').textContent"))
# The page-global handles map_view and draw_options publish, written out so a
# renamed table fails here.
_h(prefix="map_") = "window.__hs_maps['$prefix']"
_dh(prefix="map_") = "window.__hs_draw['$prefix']"
# True once every expression is truthy; a missing table reads as not yet.
_ready_js(exprs...) = "(function(){try{return !!(" * join(exprs, " && ") * ")}catch(e){return false}})()"
_wait_maps(page, prefixes...) = CDP.wait_js(page, _ready_js(("$(_h(p)).loaded()" for p in prefixes)...); timeout=20)
_map(page, expr) = CDP.js(page, "$(_h()).$expr")
_wait_map(page) = _wait_maps(page, "map_")
_wait_signals(page, f; what="signals") = CDP.wait_for(() -> f(_signals(page)); what)
_wait_signal_text(page, text; timeout=10) =
    CDP.wait_js(page, "document.getElementById('signals').textContent.includes($(JSON.json(text)))"; timeout)
_wait_draw(page) = _wait_signal_text(page, "\"draw\""; timeout=20)

function _draw_line(page, pts)
    for (x, y) in pts
        CDP.click(page, x, y)
        sleep(0.1)
    end
    CDP.click(page, pts[end]...)
    sleep(0.3)
end

_draw_view(; kw...) = MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8,
                                         draw=MapLibre.draw_options(; kw...))

@testset "browser: map_view drawing" begin
    page_html = _browser_page(Frag(
        _draw_view(; properties=ds"{set: $active}", change_post="/preview"),
        button(id="line", on_click(ds"$draw.mode = 'linestring'"), "line"),
        button(id="set1", on_click(ds"$active = 1"), "set 1"),
        button(id="select", on_click(ds"$draw.mode = 'select'"), "select"),
        button(id="undo", on_click(MapLibre.draw_call(:undo; id_prefix="map_")), "undo"),
        button(id="redo", on_click(MapLibre.draw_call(:redo; id_prefix="map_")), "redo"),
        button(id="delete", on_click(MapLibre.draw_call(:delete_selected; id_prefix="map_")), "delete"));
        signals=(active=0,))
    posts = Dict{String, Any}[]
    routes = _routes("/" => page_html,
                     "/preview" => req -> (push!(posts, parse_signals(req)); HTTP.Response(204)))

    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/")
        _wait_map(page); _wait_draw(page)

        @testset "setting \$draw.mode switches the Terra Draw mode" begin
            # Why: the generated data-effect is the only path from the signal to setMode.
            CDP.click(page, 100, 100); sleep(0.2)
            @test _signals(page)["draw"]["drawing"] == false
            CDP.js(page, "document.getElementById('line').click()"); sleep(0.2)
            CDP.click(page, 100, 100); sleep(0.2)
            @test _signals(page)["draw"]["drawing"] == true
            CDP.key(page, "Escape")
            sleep(0.2)
        end

        CDP.js(page, "window.__nf = 0; window.addEventListener('hs-map_draw_features', function () { window.__nf++ })")

        @testset "pointer moves while drawing write no \$draw.features" begin
            # Why: a write per move would re-run every effect on the features each frame.
            CDP.click(page, 200, 200); sleep(0.1)
            CDP.click(page, 300, 260); sleep(0.1)
            for x in 300:10:400
                CDP.mouse(page, "mouseMoved", x, 300; button="none")
                sleep(0.02)
            end
            @test _signals(page)["draw"]["drawing"] == true
            @test CDP.js(page, "window.__nf") == 0
        end

        @testset "finishing a line writes \$draw.features with its stamp" begin
            # Why: the stamp is how the server learns which set a line belongs to.
            CDP.click(page, 400, 220); sleep(0.1)
            CDP.click(page, 400, 220); sleep(0.4)
            d = _signals(page)["draw"]
            @test length(d["features"]) == 1
            @test d["features"][1]["properties"] == Dict("set" => 0)
            @test d["features"][1]["geometry"]["type"] == "LineString"
            @test d["can_undo"] == true
            @test length(posts) == 1
            @test posts[end]["draw"]["features"] == d["features"]
        end

        @testset "undo after two lines keeps the first line's stamp" begin
            # Why: Terra Draw records a property write as its own undo step, which
            # would strip the stamp instead of removing the line.
            CDP.js(page, "document.getElementById('set1').click()"); sleep(0.2)
            _draw_line(page, [(200, 400), (300, 450), (400, 420)])
            @test [f["properties"] for f in _signals(page)["draw"]["features"]] ==
                  [Dict("set" => 0), Dict("set" => 1)]
            np = length(posts)
            CDP.js(page, "document.getElementById('undo').click()"); sleep(0.4)
            @test length(posts) == np + 1
            d = _signals(page)["draw"]
            @test [f["properties"] for f in d["features"]] == [Dict("set" => 0)]
            @test d["can_redo"] == true
        end

        @testset "redo and delete_selected reach Terra Draw and post" begin
            np = length(posts)
            CDP.js(page, "document.getElementById('redo').click()"); sleep(0.4)
            @test length(_signals(page)["draw"]["features"]) == 2
            @test length(posts) == np + 1
            CDP.js(page, "document.getElementById('select').click()"); sleep(0.2)
            CDP.click(page, 250, 230); sleep(0.3)
            @test length(_signals(page)["draw"]["selected"]) == 1
            np = length(posts)
            CDP.js(page, "document.getElementById('delete').click()"); sleep(0.4)
            @test [f["properties"] for f in _signals(page)["draw"]["features"]] == [Dict("set" => 1)]
            @test length(posts) == np + 1
        end

        @testset "dragging a vertex writes \$draw.features once, on release" begin
            # Why: select mode fires a change per move; a write per move would post each frame.
            CDP.click(page, 225, 412); sleep(0.3)
            @test length(_signals(page)["draw"]["selected"]) == 1
            n, np = CDP.js(page, "window.__nf"), length(posts)
            CDP.mouse(page, "mouseMoved", 300, 450; button="none")
            CDP.mouse(page, "mousePressed", 300, 450)
            for y in 452:4:490
                CDP.mouse(page, "mouseMoved", 300, y; buttons=1)
                sleep(0.02)
            end
            @test CDP.js(page, "window.__nf") == n
            CDP.mouse(page, "mouseReleased", 300, 490); sleep(0.4)
            @test CDP.js(page, "window.__nf") == n + 1
            @test length(posts) == np + 1
        end

        @testset "a drag the browser cancels still writes \$draw.features" begin
            # Why: a browser that takes over a touch gesture sends pointercancel, not
            # pointerup; the lines would wait for the next press.
            n = CDP.js(page, "window.__nf")
            CDP.mouse(page, "mousePressed", 300, 490)
            for y in 494:4:520
                CDP.mouse(page, "mouseMoved", 300, y; buttons=1)
                sleep(0.02)
            end
            CDP.js(page, "window.dispatchEvent(new PointerEvent('pointercancel'))"); sleep(0.4)
            @test CDP.js(page, "window.__nf") == n + 1
            CDP.mouse(page, "mouseReleased", 300, 520); sleep(0.4)
        end

        @testset "a double-click after a line cancels the stray line it starts" begin
            # Why: Terra Draw has no double-click; the second click would start a line.
            CDP.js(page, "document.getElementById('line').click()"); sleep(0.2)
            CDP.click(page, 600, 100); sleep(0.1)
            CDP.click(page, 650, 150); sleep(0.1)
            CDP.dblclick(page, 650, 150)
            sleep(0.4)
            d = _signals(page)["draw"]
            @test length(d["features"]) == 2
            @test d["drawing"] == false
        end
    end
end

@testset "browser: a line-only drawing survives a mode it lacks and a stamp that is not an object" begin
    page_html = _browser_page(Frag(_draw_view(; modes=(:linestring,), properties=ds"7"),
                                   div(ds_init(ds"$draw.mode = 'select'")),
                                   button(id="select", on_click(ds"$draw.mode = 'select'"), "select")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/")
        _wait_map(page); _wait_draw(page)

        @testset "a mode set before load falls back to the first mode" begin
            # Why: setMode throws on an unknown mode, and a throw at load would
            # leave the change listeners unregistered.
            @test _signals(page)["draw"]["mode"] == "linestring"
            _draw_line(page, [(200, 200), (300, 260)])
            @test length(_signals(page)["draw"]["features"]) == 1
        end

        @testset "a stamp that is not an object is stored as {}" begin
            # Why: by_property reads keys off the stamp, and GeoJSON properties are an object.
            @test _signals(page)["draw"]["features"][1]["properties"] == Dict()
        end

        @testset "a mode set after load reverts to the mode in use" begin
            # Why: a signal left on the unknown mode would disagree with the map for good.
            CDP.js(page, "document.getElementById('select').click()")
            _wait_signals(page, s -> s["draw"]["mode"] == "linestring")
            _draw_line(page, [(200, 400), (300, 460)])
            @test length(_signals(page)["draw"]["features"]) == 2
        end
    end
end

@testset "browser: a coarse pointer widens the hit radius" begin
    # Why: a finger lands farther from a line than a mouse. Select mode hits
    # within about half its pointerDistance, so 8 px off misses at the mouse
    # radius (10) and hits at the touch one (22).
    seed = Dict("type" => "Feature", "properties" => Dict(),
                "geometry" => Dict("type" => "LineString", "coordinates" => [[-9.2, 38.0], [-8.8, 38.0]]))
    view = _draw_view(; modes=(:select, :linestring), features=[seed])
    for (touch, want) in ((false, 0), (true, 1))
        CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
            touch && CDP.call(page, "Emulation.setTouchEmulationEnabled",
                              Dict("enabled" => true, "maxTouchPoints" => 1))
            CDP.goto(page, base * "/")
            _wait_map(page); _wait_draw(page)
            _wait_signals(page, s -> length(s["draw"]["features"]) == 1)
            @test CDP.js(page, "matchMedia('(any-pointer: coarse)').matches") == touch
            p = _map(page, "project([-9.0, 38.0])")
            CDP.click(page, round(Int, p["x"]), round(Int, p["y"]) + 8); sleep(0.4)
            @test length(_signals(page)["draw"]["selected"]) == want
        end
    end
end

@testset "browser: selected_color and line_dash reach the drawn lines" begin
    # Why: only Terra Draw's own style callbacks apply these; a wrong option name is silently ignored.
    seed = Dict("type" => "Feature", "properties" => Dict(),
                "geometry" => Dict("type" => "LineString", "coordinates" => [[-9.2, 38.0], [-8.8, 38.0]]))
    view = _draw_view(; features=[seed], selected_color="#ff00ff", line_dash=[4, 2])
    CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
        CDP.goto(page, base * "/")
        _wait_map(page); _wait_draw(page)
        _wait_signals(page, s -> length(s["draw"]["features"]) == 1)
        prop(k) = _map(page, "querySourceFeatures('td-linestring').map(function(f){return f.properties.$k;})")
        CDP.wait_for(() -> !isempty(prop("lineStringDash")); what="the seed line on the map")
        # The adapter stores the dash in line widths (3.5 px), as a JSON string.
        @test all(d -> JSON.parse(d) ≈ [4, 2] ./ 3.5, prop("lineStringDash"))
        p = _map(page, "project([-9.0, 38.0])")
        CDP.click(page, round(Int, p["x"]), round(Int, p["y"])); sleep(0.4)
        @test length(_signals(page)["draw"]["selected"]) == 1
        @test "#ff00ff" in prop("lineStringColor")
    end
end

@testset "browser: two drawing maps on one page keep their own \$draw state" begin
    # Why: the Terra Draw handle and the draw events are keyed by id_prefix; a
    # shared key would send one map's lines to the other's signal.
    dview(prefix, sig) = MapLibre.map_view(; id_prefix=prefix, style="/style.json", center=(-9.0, 38.0), zoom=8,
                                           draw=MapLibre.draw_options(; signal=sig, modes=(:linestring,)))
    page_html = _browser_page(Frag(
        HyperSignal.style("#a_root,#b_root{width:400px;height:300px}"),
        dview("a_", "da"), dview("b_", "db"),
        button(id="undo_a", on_click(MapLibre.draw_call(:undo; id_prefix="a_")), "undo a"),
        button(id="undo_b", on_click(MapLibre.draw_call(:undo; id_prefix="b_")), "undo b")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/")
        _wait_maps(page, "a_", "b_")
        CDP.wait_js(page, _ready_js(_dh("a_"), _dh("b_")))
        sleep(0.3)
        _draw_line(page, [(100, 100), (200, 150)])
        s = _signals(page)
        @test length(s["da"]["features"]) == 1
        @test isempty(s["db"]["features"])
        CDP.js(page, "document.getElementById('undo_b').click()"); sleep(0.3)
        @test length(_signals(page)["da"]["features"]) == 1
        CDP.js(page, "document.getElementById('undo_a').click()"); sleep(0.3)
        @test isempty(_signals(page)["da"]["features"])
    end
end

@testset "browser: an invalid seed feature lands in \$draw.rejected" begin
    # Why: Terra Draw drops features it finds invalid; a later save would lose them.
    line(coords, set) = Dict("type" => "Feature", "properties" => Dict("set" => set),
                             "geometry" => Dict("type" => "LineString", "coordinates" => coords))
    seed = [line([[-9.2, 38.1], [-9.0, 38.2]], 1), line([[-9.2, 38.1]], 0)]
    routes = _routes("/" => _browser_page(_draw_view(; features=seed)))
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/")
        _wait_map(page); _wait_draw(page)
        _wait_signals(page, s -> !isempty(s["draw"]["features"]))
        d = _signals(page)["draw"]
        @test [f["properties"] for f in d["features"]] == [Dict("set" => 1)]
        @test d["rejected"] == [seed[2]]
        @test d["can_undo"] == false
    end
end

@testset "browser: a line-only drawing colours lines by stamp and cancels a stray double-click line" begin
    line(coords, set) = Dict("type" => "Feature", "properties" => Dict("set" => set),
                             "geometry" => Dict("type" => "LineString", "coordinates" => coords))
    seed = [line([[-9.3, 38.1], [-9.2, 38.15]], 0), line([[-9.3, 37.9], [-9.2, 37.95]], 1)]
    view = _draw_view(; modes=(:linestring,), features=seed,
                      line_color=MapLibre.by_property("set", 0 => "#ff0000", 1 => "#0000ff"; default="#00ff00"))
    CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
        CDP.goto(page, base * "/")
        _wait_map(page); _wait_draw(page)
        _wait_signals(page, s -> length(s["draw"]["features"]) == 2)

        @testset "by_property reads each line's stamp" begin
            # Why: a lookup that misses the stamp paints every line the default colour.
            colours = _map(page, "querySourceFeatures('td-linestring').map(function(f)" *
                                 "{return [f.geometry.coordinates[0][1], f.properties.lineStringColor];})" *
                                 ".sort(function(a,b){return b[0]-a[0];}).map(function(p){return p[1];})")
            # querySourceFeatures returns a line once per tile it crosses.
            @test unique(colours) == ["#ff0000", "#0000ff"]
        end

        @testset "a double-click cancels the stray line with no select mode to step through" begin
            # Why: stepping through a mode the drawing lacks throws, and the stray line stays.
            CDP.click(page, 600, 100); sleep(0.1)
            CDP.click(page, 650, 150); sleep(0.1)
            CDP.dblclick(page, 650, 150)
            sleep(0.4)
            d = _signals(page)["draw"]
            @test length(d["features"]) == 3
            @test d["drawing"] == false
        end

        @testset "a double-click away from the first point leaves a longer line drawing" begin
            # Why: cancelling on any double-click would drop a line the user is still drawing.
            for (x, y) in ((300, 400), (400, 450), (500, 400))
                CDP.click(page, x, y); sleep(0.1)
            end
            CDP.js(page, "$(_h()).getCanvasContainer()" *
                         ".dispatchEvent(new MouseEvent('dblclick', {bubbles: true})), 0")
            sleep(0.3)
            @test _signals(page)["draw"]["drawing"] == true
        end
    end
end

@testset "browser: double_click_zoom and nav_control" begin
    function zoom_after_dblclick(view)
        out = Ref{Any}()
        CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
            CDP.goto(page, base * "/")
            _wait_map(page)
            CDP.dblclick(page, 400, 300)
            sleep(1.0)
            out[] = (_map(page, "getZoom()"),
                     CDP.js(page, "!!document.querySelector('.maplibregl-ctrl-zoom-in')"))
        end
        out[]
    end
    plain(; kw...) = MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8, kw...)

    @testset "a double-click zooms the default map" begin
        z, _ = zoom_after_dblclick(plain())
        @test z > 8.5
    end

    @testset "double_click_zoom=false keeps the zoom and nav_control mounts the buttons" begin
        # Why: a drawing page finishes lines with a double-click, which must not zoom.
        z, ctrl = zoom_after_dblclick(plain(; double_click_zoom=false, nav_control=:top_right))
        @test z == 8
        @test ctrl
    end
end

@testset "browser: with rotate=false, dragRotate is off, a pinch keeps bearing 0 and pitch 0 and still zooms" begin
    # Why: dragRotate=false alone leaves two-finger rotation on, and turning
    # touch handling off altogether would lose pinch-zoom.
    view(rotate) = _browser_page(MapLibre.map_view(; style="/style.json",
                                                   center=(-9.0, 38.0), zoom=8, rotate))
    function bearings(page)
        CDP.drag(page, (400, 300), (550, 300); button="right")
        sleep(0.3)
        by_drag = _map(page, "getBearing()")
        CDP.touch(page, "touchStart", [(300, 300), (500, 300)])
        for a in 0.1:0.1:0.8
            CDP.touch(page, "touchMove", [(400 - 100cos(a), 300 - 100sin(a)), (400 + 100cos(a), 300 + 100sin(a))])
            sleep(0.03)
        end
        CDP.touch(page, "touchEnd", [])
        sleep(0.5)
        (by_drag, _map(page, "getBearing()"))
    end
    function pinch(page)
        CDP.touch(page, "touchStart", [(350, 300), (450, 300)])
        for d in 60:20:200
            CDP.touch(page, "touchMove", [(400 - d, 300), (400 + d, 300)])
            sleep(0.03)
        end
        CDP.touch(page, "touchEnd", [])
        sleep(0.5)
    end
    # Two fingers dragged up together tilt the map.
    function tilt(page)
        CDP.touch(page, "touchStart", [(350, 400), (450, 400)])
        for y in 390:-10:250
            CDP.touch(page, "touchMove", [(350, y), (450, y)])
            sleep(0.03)
        end
        CDP.touch(page, "touchEnd", [])
        sleep(0.5)
        _map(page, "getPitch()")
    end
    # Shift+Arrow rotates through MapLibre's keyboard handler.
    function keyrotate(page)
        b0 = _map(page, "getBearing()")
        CDP.js(page, "$(_h()).getCanvas().focus(), 0")
        CDP.key(page, "ArrowLeft"; modifiers=8, key_code=37)
        sleep(0.6)
        _map(page, "getBearing()") - b0
    end
    # One tab per variant: CDP touch input reached only the first page a tab loaded.
    CDP.with_page(BROWSER[], _routes("/" => view(true))) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        by_drag, by_touch = bearings(page)
        @test by_drag != 0
        @test by_touch != by_drag
        @test tilt(page) > 0
        @test keyrotate(page) != 0
    end
    CDP.with_page(BROWSER[], _routes("/" => view(false))) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        @test _map(page, "dragRotate.isEnabled()") == false
        zoom = _map(page, "getZoom()")
        pinch(page)
        @test _map(page, "getZoom()") > zoom + 0.5
        @test bearings(page) == (0, 0)
        # Why: with the compass hidden, a tilted map has no way back.
        @test tilt(page) == 0
        @test keyrotate(page) == 0
    end
end

@testset "browser: patching an M.markers container replaces its map markers; loose markers stay" begin
    # Why: Marker moves its element into the map, so only a rebuild from the
    # container shows what a morph changed.
    crests(labels...; lat=38.0) = MapLibre.markers(
        (MapLibre.marker(span(class="crest", l); lat=lat + i / 10, lon=-9.0) for (i, l) in enumerate(labels))...;
        id="crests")
    page_html = _browser_page(Frag(
        MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8),
        MapLibre.marker(span(class="loose", "L"); lat=38.0, lon=-9.2),
        crests("A", "B"),
        button(id="patch", on_click(ds_get("/patch")), "patch"),
        button(id="move", on_click(ds_get("/move")), "move"),
        button(id="remove", on_click(ds_get("/remove")), "remove")))
    routes = _routes("/" => page_html,
                     "/patch" => _ -> sse_response([patch_elements(crests("Z"))]),
                     "/move" => _ -> sse_response([patch_elements(crests("Z"; lat=38.2))]),
                     "/remove" => _ -> sse_response([patch_elements(""; selector="#crests", mode=:remove)]))
    labels(page) = CDP.js(page, "Array.from(document.querySelectorAll('.maplibregl-marker')).map(function (m) { return m.textContent }).sort()")
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length === 3")
        @test labels(page) == ["A", "B", "L"]
        CDP.js(page, "document.getElementById('patch').click()")
        CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length === 2")
        @test labels(page) == ["L", "Z"]
        @test CDP.js(page, "document.getElementById('crests').hidden") == true
        # Why: MapLibre rewrites each marker's style on every pan frame; a rebuild
        # per frame would thrash the DOM.
        CDP.js(page, "window.__z = document.querySelector('.maplibregl-marker .crest')")
        CDP.js(page, "$(_h()).panBy([40, 0], {duration: 0}), 0"); sleep(0.3)
        @test CDP.js(page, "document.querySelector('.maplibregl-marker .crest') === window.__z")
        # Why: a patch that only changes data-lat must still move the marker.
        top() = CDP.js(page, "document.querySelector('.maplibregl-marker .crest').closest('.maplibregl-marker').getBoundingClientRect().top")
        want = _map(page, "project([-9.0, 38.3]).y") - _map(page, "project([-9.0, 38.1]).y")
        before = top()
        CDP.js(page, "document.getElementById('move').click()")
        CDP.wait_for(() -> top() < before - 1; what="the moved marker")
        @test top() - before ≈ want atol = 1
        # Why: a patch may change only an attribute such as title or style.
        CDP.js(page, "document.querySelector('#crests .crest').setAttribute('title', 't1'), 0")
        CDP.wait_js(page, "!!document.querySelector('.maplibregl-marker .crest[title=t1]')")
        # Why: a morph that changes only a marker's text edits the text node in place.
        CDP.js(page, "document.querySelector('#crests .crest').firstChild.data = 'Q', 0")
        CDP.wait_for(() -> labels(page) == ["L", "Q"]; what="the relabelled marker")
        # Why: a removed container's markers would otherwise stay on the map.
        CDP.js(page, "document.getElementById('remove').click()")
        CDP.wait_js(page, "!document.getElementById('crests')")
        CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length === 1")
        @test labels(page) == ["L"]
    end
end

@testset "browser: markers containers reach only the map with their id_prefix" begin
    # Why: a container selector without the prefix would show every map's markers
    # on each map; ids like "constructor" must not hit Object.prototype.
    mview(prefix) = MapLibre.map_view(; id_prefix=prefix, style="/style.json", center=(-9.0, 38.0), zoom=8)
    crest(prefix, label) = MapLibre.markers(MapLibre.marker(span(label); lat=38.0, lon=-9.0, id_prefix=prefix);
                                            id=prefix == "a_" ? "constructor" : "toString", id_prefix=prefix)
    page_html = _browser_page(Frag(
        HyperSignal.style("#a_root,#b_root{width:400px;height:300px}"),
        mview("a_"), mview("b_"), crest("a_", "A"), crest("b_", "B")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/")
        _wait_maps(page, "a_", "b_")
        CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length >= 2")
        sleep(0.3)
        on_map(root) = CDP.js(page, "Array.from(document.querySelectorAll('#$root .maplibregl-marker')).map(function (m) { return m.textContent })")
        @test on_map("a_root") == ["A"]
        @test on_map("b_root") == ["B"]
        CDP.js(page, "document.getElementById('constructor').remove(), 0")
        CDP.wait_for(() -> isempty(on_map("a_root")); what="the removed container's markers to go")
        @test on_map("b_root") == ["B"]
    end
end

@testset "browser: an id_prefix named like an Object.prototype key starts its map" begin
    # Why: the handle tables are read before they are written; a prototype
    # function there would look like a live map and abort the init.
    # a_ creates the draw table first, so constructor's init reads a table that exists.
    view(prefix, signal) = MapLibre.map_view(; id_prefix=prefix, style="/style.json", center=(-9.0, 38.0), zoom=8,
                                             draw=MapLibre.draw_options(; signal))
    page_html = _browser_page(Frag(HyperSignal.style("#a_root,#constructorroot{width:400px;height:300px}"),
                                   view("a_", "da"), view("constructor", "dc")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_maps(page, "a_", "constructor")
        CDP.wait_js(page, _ready_js("$(_dh("constructor")).state"))
        @test CDP.js(page, "document.querySelectorAll('#constructorroot canvas.maplibregl-canvas').length") == 1
    end
end

@testset "browser: bounds fits the first frame to the box" begin
    view = MapLibre.map_view(; style="/style.json", bounds=(w=-10.0, s=37.0, e=-8.0, n=39.0), fit_padding=20)
    CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        b = _map(page, "getBounds().toArray()")
        @test b[1][1] <= -10 && b[1][2] <= 37 && b[2][1] >= -8 && b[2][2] >= 39
        # Why: a view far wider than the box means the fit never ran.
        @test b[2][1] - b[1][1] < 4
    end
end

@testset "browser: two drawing maps on one signal log an error" begin
    # Why: they would overwrite each other's $draw state with no other sign.
    dview(prefix) = MapLibre.map_view(; id_prefix=prefix, style="/style.json", center=(-9.0, 38.0), zoom=8,
                                      draw=MapLibre.draw_options())
    page_html = _browser_page(Frag(HyperSignal.style("#a_root,#b_root{width:400px;height:300px}"),
                                   dview("a_"), dview("b_")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_maps(page, "a_", "b_")
        shared() = any(e -> e["type"] == "error" && occursin("share the signal", string(e["args"])),
                       CDP.events(page, "Runtime.consoleAPICalled"))
        @test CDP.wait_for(shared; what="the shared-signal error")
    end
end

@testset "browser: a drawing map patched in or over another starts once and draws" begin
    # Why: Datastar runs a patched script, and a morph keeps a same-id root but
    # strips the map inside it; either way one live map must remain.
    wrap() = div(id="wrap", _draw_view(; modes=(:linestring,)))
    page_html = _browser_page(Frag(div(id="wrap"),
        button(id="add", on_click(ds_get("/add")), "add")))
    routes = _routes("/" => page_html, "/add" => _ -> sse_response([patch_elements(wrap())]))
    canvases(page) = CDP.js(page, "document.querySelectorAll('#map_root canvas.maplibregl-canvas').length")
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/")
        CDP.wait_js(page, "document.getElementById('signals').textContent.length > 0")
        for round in 1:2
            CDP.js(page, "document.getElementById('add').click()")
            sleep(0.5)
            _wait_map(page); _wait_draw(page)
            sleep(0.5)
            @test canvases(page) == 1
            n = length(_signals(page)["draw"]["features"])
            _draw_line(page, [(300, 300), (400, 350)])
            CDP.wait_for(() -> length(_signals(page)["draw"]["features"]) == n + 1; what="line $round")
        end
    end
end

@testset "browser: a map whose root leaves the page removes itself" begin
    # Why: a morph that replaces the map root never fires 'remove', so the
    # marker observer and the draw pointerup listener would keep running on a
    # dead map, and its WebGL context would stay allocated.
    crests(label) = MapLibre.markers(MapLibre.marker(span(label); lat=38.0, lon=-9.0); id="crests")
    # The draw pointerup listener, told apart by its source text.
    function draw_listeners(page)
        win = CDP.call(page, "Runtime.evaluate", Dict("expression" => "window", "objectGroup" => "listeners"))["result"]["objectId"]
        ls = CDP.call(page, "DOMDebugger.getEventListeners", Dict("objectId" => win))["listeners"]
        count(l -> l["type"] == "pointerup" && occursin("_ddown=false", l["handler"]["description"]), ls)
    end
    for (view, drawing) in ((MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8), false),
                            (_draw_view(), true))
        CDP.with_page(BROWSER[], _routes("/" => _browser_page(Frag(view, crests("A"))))) do page, base
            CDP.goto(page, base * "/"); _wait_map(page)
            CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length === 1")
            CDP.js(page, "window.__gone = false; $(_h()).on('remove', function () { window.__gone = true }); " *
                         "window.__adds = 0; const add = maplibregl.Marker.prototype.addTo; " *
                         "maplibregl.Marker.prototype.addTo = function () { window.__adds++; return add.apply(this, arguments) }; 0")
            CDP.js(page, "document.querySelector('#crests span').firstChild.data = 'B', 0")
            CDP.wait_js(page, "window.__adds === 1")
            drawing && _wait_draw(page)
            @test draw_listeners(page) == drawing
            CDP.js(page, "document.getElementById('map_root').remove(), 0")
            sleep(0.3)
            @test CDP.js(page, "window.__gone") == true
            CDP.js(page, "document.querySelector('#crests span').firstChild.data = 'C', 0")
            sleep(0.3)
            @test CDP.js(page, "window.__adds") == 1
            @test draw_listeners(page) == 0
            drawing && @test CDP.js(page, "$(_dh("map_")) === undefined")
        end
    end
end

@testset "browser: a patch that strips a drawing map rebuilds it from the patched script" begin
    # Why: the morph edits the script's text without running it, and the root's
    # data-effect does not run again, so the new map would take the old center,
    # drop the drawn lines and fall back to the first mode with an empty stamp.
    stray = Dict("type" => "Feature", "properties" => Dict("set" => 0),
                 "geometry" => Dict("type" => "LineString", "coordinates" => [[-9.2, 38.1]]))
    wrap(lon) = div(id="wrap", MapLibre.map_view(; style="/style.json", center=(lon, 38.0), zoom=8,
        draw=MapLibre.draw_options(; properties=ds"{set: $active}", features=[stray])))
    page_html = _browser_page(Frag(wrap(-9.0),
        button(id="line", on_click(ds"$draw.mode = 'linestring'; $active = 1"), "line"),
        button(id="patch", on_click(ds_get("/patch")), "patch")); signals=(active=0,))
    routes = _routes("/" => page_html, "/patch" => _ -> sse_response([patch_elements(wrap(-7.0))]))
    dh = _dh("map_")
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/"); _wait_map(page); _wait_draw(page)
        CDP.js(page, "document.getElementById('line').click()")
        CDP.wait_js(page, "$dh.state().mode === 'linestring'")
        _draw_line(page, [(300, 300), (400, 350)])
        _wait_signals(page, s -> length(s["draw"]["features"]) == 1; what="the drawn line")
        CDP.js(page, "window.__old = $(_h()); document.getElementById('patch').click()")
        CDP.wait_js(page, _ready_js("$(_h()) !== window.__old", "$(_h()).loaded()", "$dh.state().lines"); timeout=20)
        lines = CDP.js(page, "$dh.state().lines")
        @test length(lines) == 1 && lines[1]["properties"] == Dict("set" => 1)
        @test length(_signals(page)["draw"]["features"]) == 1
        @test _signals(page)["draw"]["rejected"] == [stray]
        @test _map(page, "getCenter().lng") ≈ -7.0 atol = 1e-6
        @test CDP.js(page, "$dh.state().mode") == "linestring"
        @test CDP.js(page, "$dh.state().props") == Dict("set" => 1)
        @test CDP.js(page, "document.querySelectorAll('#map_root canvas.maplibregl-canvas').length") == 1
    end
end

@testset "browser: a null in a stored stamp stays null after Datastar takes the lines" begin
    # Why: Datastar writes "" over null in the objects it is handed; sharing
    # them would change the stored stamp, and the next read would post a change.
    line(coords) = Dict("type" => "Feature", "properties" => Dict("note" => nothing),
                        "geometry" => Dict("type" => "LineString", "coordinates" => coords))
    seed = [line([[-9.2, 38.1], [-9.0, 38.2]]), line([[-9.2, 38.1]])]
    CDP.with_page(BROWSER[], _routes("/" => _browser_page(_draw_view(; features=seed)))) do page, base
        CDP.goto(page, base * "/"); _wait_map(page); _wait_draw(page)
        _wait_signals(page, s -> !isempty(s["draw"]["features"]))
        CDP.js(page, "$(_dh()).sync()")
        sleep(0.2)
        @test CDP.js(page, "$(_dh()).state().lines[0].properties.note === null")
        @test CDP.js(page, "$(_dh()).state().rejected[0].properties.note === null")
    end
end

@testset "browser: a page change outside any markers container rebuilds no markers" begin
    # Why: every childList change would otherwise re-read each container's HTML.
    page_html = _browser_page(Frag(MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8),
        MapLibre.markers(MapLibre.marker(span("C"); lat=38.0, lon=-9.0); id="crests")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length === 1")
        CDP.js(page, "window.__reads = 0; const d = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML'); " *
                     "Object.defineProperty(document.getElementById('crests'), 'innerHTML', " *
                     "{get: function () { window.__reads++; return d.get.call(this) }}); " *
                     "document.body.appendChild(document.createElement('p')), 0")
        sleep(0.3)
        @test CDP.js(page, "window.__reads") == 0
        CDP.js(page, "document.getElementById('crests').appendChild(document.createElement('i')), 0")
        CDP.wait_js(page, "window.__reads > 0")
    end
end

@testset "browser: a removed map detaches its drag-box listeners" begin
    # Why: they sit on document and would keep the dead map alive.
    view = MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8, bbox_post="/bbox")
    function listeners(page)
        doc = CDP.call(page, "Runtime.evaluate", Dict("expression" => "document", "objectGroup" => "listeners"))["result"]["objectId"]
        ls = CDP.call(page, "DOMDebugger.getEventListeners", Dict("objectId" => doc))["listeners"]
        count(l -> l["type"] in ("mousemove", "mouseup") && occursin("_bs", l["handler"]["description"]), ls)
    end
    CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        @test listeners(page) == 2
        CDP.js(page, "document.getElementById('map_root').remove(), 0")
        CDP.wait_js(page, "!$(_h())")
        @test listeners(page) == 0
    end
end

@testset "browser: a marker MapLibre rejects leaves the others placed" begin
    # Why: a throw in the rebuild would drop every later marker and record the
    # container as built, so it would never retry.
    bad = div(span("X"), Symbol("data-hs-marker") => "map_", Symbol("data-lat") => "95", Symbol("data-lon") => "0")
    good(l) = MapLibre.marker(span(l); lat=38.0, lon=-9.0)
    page_html = _browser_page(Frag(
        MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8),
        bad, good("L"), MapLibre.markers(bad, good("C"); id="crests")))
    labels(page) = CDP.js(page, "Array.from(document.querySelectorAll('#map_root .maplibregl-marker')).map(function (m) { return m.textContent }).sort()")
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        CDP.wait_for(() -> labels(page) == ["C", "L"]; what="the valid markers")
        @test labels(page) == ["C", "L"]
        CDP.js(page, "document.querySelector('#crests [data-lat=\"95\"]').dataset.lat = '38.1', 0")
        CDP.wait_for(() -> labels(page) == ["C", "L", "X"]; what="the fixed marker")
        @test labels(page) == ["C", "L", "X"]
    end
end

@testset "browser: a stripped map whose init script is gone restarts from its own" begin
    # Why: a patch may replace the scripts around the root; the map must not stay dead.
    page_html = _browser_page(Frag(MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8),
                                   button(id="patch", on_click(ds_get("/patch")), "patch")))
    root = div(id="map_root")
    routes = _routes("/" => page_html, "/patch" => _ -> sse_response([patch_elements(root)]))
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        CDP.js(page, "document.getElementById('map_init').remove(); window.__old = $(_h()); " *
                     "document.getElementById('patch').click()")
        CDP.wait_js(page, _ready_js("$(_h()) !== window.__old", "$(_h()).loaded()"); timeout=20)
        @test CDP.js(page, "document.querySelectorAll('#map_root canvas.maplibregl-canvas').length") == 1
    end
end

@testset "browser: a select-only drawing loads in select mode" begin
    # Why: with no linestring mode, setMode and the load path differ from every other drawing.
    view = _draw_view(; modes=(:select,))
    CDP.with_page(BROWSER[], _routes("/" => _browser_page(view))) do page, base
        CDP.goto(page, base * "/"); _wait_map(page); _wait_draw(page)
        @test _signals(page)["draw"]["mode"] == "select"
        @test CDP.js(page, "$(_dh()).state().mode") == "select"
    end
end

@testset "browser: a drawing map patched over another with the same signal logs no error" begin
    # Why: the patched map starts before the observer removes the one it
    # replaced, so a stale entry would look like a second live map.
    wrap(prefix) = div(id="wrap", MapLibre.map_view(; id_prefix=prefix, style="/style.json",
                                                    center=(-9.0, 38.0), zoom=8, draw=MapLibre.draw_options()))
    page_html = _browser_page(Frag(HyperSignal.style("#a_root,#b_root{width:400px;height:300px}"), wrap("a_"),
                                   button(id="patch", on_click(ds_get("/patch")), "patch")))
    routes = _routes("/" => page_html, "/patch" => _ -> sse_response([patch_elements(wrap("b_"))]))
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/"); _wait_maps(page, "a_")
        CDP.js(page, "document.getElementById('patch').click()")
        _wait_maps(page, "b_")
        CDP.wait_js(page, "!window.__hs_maps['a_']")
        sleep(0.3)  # the check runs on a timer after b_ starts
        errs = [e for e in CDP.events(page, "Runtime.consoleAPICalled") if e["type"] == "error"]
        @test !any(e -> occursin("share the signal", string(e["args"])), errs)
    end
end

@testset "browser: a drawing map that moves to another signal frees the old one" begin
    # Why: a stale owner entry would blame the next map on the old signal.
    dview(prefix, sig) = MapLibre.map_view(; id_prefix=prefix, style="/style.json", center=(-9.0, 38.0),
                                           zoom=8, draw=MapLibre.draw_options(; signal=sig))
    page_html = _browser_page(Frag(HyperSignal.style("#a_root,#b_root{width:400px;height:300px}"),
                                   div(id="wa", dview("a_", "d1")), div(id="wb"),
                                   button(id="move", on_click(ds_get("/move")), "move"),
                                   button(id="add", on_click(ds_get("/add")), "add")))
    routes = _routes("/" => page_html,
                     "/move" => _ -> sse_response([patch_elements(div(id="wa", dview("a_", "d2")); mode=:replace)]),
                     "/add" => _ -> sse_response([patch_elements(div(id="wb", dview("b_", "d1")))]))
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/"); _wait_maps(page, "a_")
        CDP.js(page, "window.__a1 = $(_h("a_")); true")
        CDP.js(page, "document.getElementById('move').click()")
        CDP.wait_js(page, _ready_js("$(_h("a_")) !== window.__a1", "$(_h("a_")).loaded()"); timeout=20)
        CDP.js(page, "document.getElementById('add').click()")
        _wait_maps(page, "b_")
        sleep(0.3)  # the check runs on a timer after b_ starts
        errs = [e for e in CDP.events(page, "Runtime.consoleAPICalled") if e["type"] == "error"]
        @test !any(e -> occursin("share the signal", string(e["args"])), errs)
    end
end

@testset "browser: a throwing properties expression keeps the last stamp" begin
    # Why: the docs promise the stamp keeps its last value and the error reaches the console.
    page_html = _browser_page(Frag(_draw_view(; modes=(:linestring,), properties=ds"{set: $bad ? null.x : $active}"),
                                   button(id="bad", on_click(ds"$bad = true; $active = 1"), "bad"));
                              signals=(active=0, bad=false))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_map(page); _wait_draw(page)
        _draw_line(page, [(200, 200), (300, 260)])
        CDP.js(page, "document.getElementById('bad').click()"); sleep(0.2)
        _draw_line(page, [(200, 400), (300, 460)])
        @test [f["properties"] for f in _signals(page)["draw"]["features"]] == [Dict("set" => 0), Dict("set" => 0)]
        errs = [e for e in CDP.events(page, "Runtime.consoleAPICalled") if e["type"] == "error"]
        @test any(e -> occursin("TypeError", string(e["args"])), errs)
    end
end

@testset "browser: the draw effect keeps its signals while the draw handle is gone" begin
    # Why: an effect that throws before it reads a signal subscribes to nothing
    # and never runs again.
    page_html = _browser_page(Frag(_draw_view(),
                                   button(id="line", on_click(ds"$draw.mode = 'linestring'"), "line"),
                                   button(id="select", on_click(ds"$draw.mode = 'select'"), "select")))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_map(page); _wait_draw(page)
        CDP.js(page, "window.__dh = $(_dh()); delete $(_dh()); true")
        CDP.js(page, "document.getElementById('line').click()"); sleep(0.2)
        CDP.js(page, "$(_dh()) = window.__dh; true")
        CDP.js(page, "document.getElementById('select').click()"); sleep(0.2)
        CDP.js(page, "document.getElementById('line').click()"); sleep(0.2)
        @test CDP.js(page, "$(_dh()).state().mode") == "linestring"
    end
end

@testset "browser: a map removed while loading leaves the loading signal false" begin
    # Why: the delay timer would fire after the map is gone and set the signal for good.
    page_html = _browser_page(MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8,
                                                loading_signal="ld", loading_delay=200); signals=(ld=false,))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        _wait_signals(page, s -> s["ld"] == false)
        CDP.js(page, "$(_h()).fire('dataloading'); $(_h()).remove(); true")
        sleep(0.5)
        @test _signals(page)["ld"] == false
    end
end

@testset "browser: a draw_call with no drawing on the page does nothing" begin
    # Why: a button clicked before the map loads, or after it is gone, would throw.
    page_html = _browser_page(button(id="undo", on_click(MapLibre.draw_call(:undo; id_prefix="map_")), "undo"))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/")
        CDP.wait_js(page, "!!document.getElementById('signals')")
        sleep(0.3)
        CDP.js(page, "document.getElementById('undo').click()"); sleep(0.3)
        errs = [CDP.events(page, "Runtime.exceptionThrown");
                [e for e in CDP.events(page, "Runtime.consoleAPICalled") if e["type"] == "error"]]
        @test !any(e -> occursin("TypeError", string(e)), errs)
    end
end

@testset "browser: clicking a marker opens its popup" begin
    # Why: setPopup is the only wiring from data-popup to a shown popup, for
    # loose markers and for a container's copies alike.
    page_html = _browser_page(Frag(
        MapLibre.map_view(; style="/style.json", center=(-9.0, 38.0), zoom=8),
        MapLibre.marker(span(class="loose", "L"); lat=38.0, lon=-9.3, popup=strong("loose pop")),
        MapLibre.markers(MapLibre.marker(span(class="kept", "K"); lat=38.0, lon=-8.7, popup=strong("kept pop"));
                         id="crests")))
    popup(page) = CDP.js(page, "(document.querySelector('.maplibregl-popup') || {}).textContent || ''")
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/"); _wait_map(page)
        CDP.wait_js(page, "document.querySelectorAll('.maplibregl-marker').length === 2")
        for (cls, text) in (("loose", "loose pop"), ("kept", "kept pop"))
            r = CDP.js(page, "(function () { const b = document.querySelector('.maplibregl-marker .$cls').getBoundingClientRect(); " *
                             "return [b.left + b.width / 2, b.top + b.height / 2] })()")
            CDP.click(page, r...)
            CDP.wait_for(() -> occursin(text, popup(page)); what="the $cls popup")
            @test occursin(text, popup(page))
        end
    end
end

@testset "browser: on_keys" begin
    page_html = _browser_page(Frag(
        div(on_keys((:mod, :z) => ds"$n = $n + 1", Symbol("?") => ds"$h = $h + 1",
                    :Escape => ds"$e = $e + 1")),
        input(id="field", type="text"), input(id="box", type="checkbox"), textarea(id="area"),
        HyperSignal.select(id="pick", option("a"), option("b")), div(id="edit", contenteditable="true", "x"));
        signals=(n=0, h=0, e=0))
    CDP.with_page(BROWSER[], _routes("/" => page_html)) do page, base
        CDP.goto(page, base * "/")
        _wait_signal_text(page, "\"n\"")

        @testset "Ctrl+Z in a text input does nothing" begin
            # Why: undo in a field must undo the typing, not the page's last edit.
            CDP.js(page, "document.getElementById('field').focus()")
            CDP.key(page, "z"; code="KeyZ", modifiers=2)
            sleep(0.2)
            @test _signals(page)["n"] == 0
        end

        @testset "Ctrl+Z in a textarea, select or contenteditable does nothing" begin
            for id in ("area", "pick", "edit")
                CDP.js(page, "document.getElementById('$id').focus()")
                CDP.key(page, "z"; code="KeyZ", modifiers=2)
                sleep(0.2)
                @test _signals(page)["n"] == 0
            end
        end

        @testset "Ctrl+Z on the page runs the binding" begin
            CDP.js(page, "document.activeElement.blur()")
            CDP.key(page, "z"; code="KeyZ", modifiers=2)
            sleep(0.2)
            @test _signals(page)["n"] == 1
        end

        @testset "modifiers match exactly; Cmd+Z counts as :mod" begin
            # Why: Ctrl+Shift+Z is redo; firing the Ctrl+Z binding there would undo instead.
            CDP.key(page, "Z"; code="KeyZ", modifiers=2 | 8)
            sleep(0.2)
            @test _signals(page)["n"] == 1
            CDP.key(page, "z"; code="KeyZ", modifiers=4)
            sleep(0.2)
            @test _signals(page)["n"] == 2
        end

        @testset "Ctrl+Z with a checkbox focused runs the binding" begin
            # Why: a checkbox takes no typing, so blocking there leaves a form page without shortcuts.
            CDP.js(page, "document.getElementById('box').focus()")
            CDP.key(page, "z"; code="KeyZ", modifiers=2)
            sleep(0.2)
            @test _signals(page)["n"] == 3
        end

        @testset "Shift+/ fires :? and Escape fires :Escape" begin
            # Why: '?' arrives with Shift held, and named keys match evt.key as written.
            CDP.key(page, "?"; code="Slash", modifiers=8, text="?")
            CDP.key(page, "Escape"; key_code=27)
            sleep(0.2)
            @test _signals(page)["h"] == 1
            @test _signals(page)["e"] == 1
        end
    end
end

@testset "browser: an execute_script script runs once and leaves the page" begin
    # Why: a script left in <body> would be found again by a later morph.
    page_html = _browser_page(button(id="run", on_click(ds_post("/run")), "run"))
    routes = _routes("/" => page_html,
                     "/run" => _ -> sse_response([execute_script("window.__ran = (window.__ran || 0) + 1")]))
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/")
        CDP.wait_js(page, "!!document.getElementById('signals')")
        sleep(0.3)
        CDP.js(page, "document.getElementById('run').click()")
        CDP.wait_js(page, "window.__ran === 1")
        sleep(0.3)
        @test CDP.js(page, "window.__ran") == 1
        @test CDP.js(page, "document.querySelectorAll('body > script').length") == 0
    end
end

@testset "browser: an execute_script body holding </script> and <!-- runs whole" begin
    # Why: the HTML parser ends a script at </script>; unescaped, the rest would show as text.
    page_html = _browser_page(button(id="run", on_click(ds_post("/run")), "run"))
    routes = _routes("/" => page_html,
                     "/run" => _ -> sse_response([execute_script("window.__s = '</script><!--x'; window.__done = 1")]))
    CDP.with_page(BROWSER[], routes) do page, base
        CDP.goto(page, base * "/")
        CDP.wait_js(page, "!!document.getElementById('signals')")
        sleep(0.3)
        CDP.js(page, "document.getElementById('run').click()")
        CDP.wait_js(page, "window.__done === 1")
        @test CDP.js(page, "window.__s") == "</script><!--x"
        @test !occursin("--x", CDP.js(page, "document.body.textContent"))
    end
end

@testset "browser: confirm_leave and navigate" begin
    page_html = _browser_page(Frag(
        div(confirm_leave()),
        button(id="save", on_click(ds_post("/save")), "save"),
        button(id="download", on_click(ds_post("/download")), "download"),
        div(id="login", button(id="login_btn", on_click(ds_post("/login")), "log in")),
        button(id="badnav", on_click(ds_post("/badnav")), "bad")); signals=(dirty=true,))
    nocontent = Ref(0)
    routes = _routes("/" => page_html,
                     "/after" => "<!doctype html><title>after</title><p id=after>after</p>",
                     "/save" => _ -> sse_response([navigate("/after")]),
                     "/nocontent" => _ -> (nocontent[] += 1; HTTP.Response(204)),
                     "/download" => _ -> sse_response([navigate("/nocontent")]),
                     "/login" => _ -> redirect_via_fragment("#login", "/after"),
                     "/badnav" => _ -> sse_response([navigate("http://[bad")]))
    dialogs(page) = length(CDP.events(page, "Page.javascriptDialogOpening"))
    CDP.with_page(BROWSER[], routes) do page, base
        @testset "an unsaved page prompts before leaving" begin
            # Why: closing the tab must not drop unsaved work silently.
            CDP.goto(page, base * "/")
            _wait_signal_text(page, "dirty")
            CDP.click(page, 700, 500)
            # Page.navigate answers only once the dialog is closed.
            nav = @async CDP.call(page, "Page.navigate", Dict("url" => base * "/after"))
            CDP.wait_for(() -> dialogs(page) == 1; what="beforeunload dialog")
            @test only(CDP.events(page, "Page.javascriptDialogOpening"))["type"] == "beforeunload"
            CDP.call(page, "Page.handleJavaScriptDialog", Dict("accept" => true))
            wait(nav)
            CDP.wait_js(page, "location.pathname === '/after'")
        end

        @testset "save → navigate leaves with no dialog" begin
            # Why: after a save the guard must stand down, or every save prompts.
            CDP.goto(page, base * "/")
            _wait_signal_text(page, "dirty")
            CDP.click(page, 700, 500)
            n = dialogs(page)
            CDP.js(page, "document.getElementById('save').click()")
            CDP.wait_js(page, "location.pathname === '/after'")
            @test dialogs(page) == n
        end

        @testset "redirect_via_fragment leaves with no dialog" begin
            # Why: a login form that redirects must not ask to keep unsaved work it just saved.
            CDP.goto(page, base * "/")
            _wait_signal_text(page, "dirty")
            CDP.click(page, 700, 500)
            n = dialogs(page)
            CDP.js(page, "document.getElementById('login_btn').click()")
            CDP.wait_js(page, "location.pathname === '/after'")
            @test dialogs(page) == n
        end

        @testset "navigate to a URL that keeps the page leaves the guard armed" begin
            # Why: a 204 or a download does not unload the page; a stuck flag
            # would let the next real exit drop unsaved work silently.
            CDP.goto(page, base * "/")
            _wait_signal_text(page, "dirty")
            CDP.click(page, 700, 500)
            CDP.js(page, "document.getElementById('download').click()")
            CDP.wait_for(() -> nocontent[] == 1; what="the /nocontent request")
            sleep(0.5)
            @test CDP.js(page, "location.pathname") == "/"
            n = dialogs(page)
            nav = @async CDP.call(page, "Page.navigate", Dict("url" => base * "/after"))
            CDP.wait_for(() -> dialogs(page) == n + 1; what="beforeunload dialog")
            CDP.call(page, "Page.handleJavaScriptDialog", Dict("accept" => true))
            wait(nav)
            CDP.wait_js(page, "location.pathname === '/after'")
        end

        @testset "navigate to a URL the browser rejects leaves the guard armed" begin
            # Why: the assignment throws, and a flag left on would let the next
            # real exit drop unsaved work silently.
            CDP.goto(page, base * "/")
            _wait_signal_text(page, "dirty")
            CDP.click(page, 700, 500)
            CDP.js(page, "document.getElementById('badnav').click()")
            sleep(0.5)
            @test CDP.js(page, "location.pathname") == "/"
            n = dialogs(page)
            nav = @async CDP.call(page, "Page.navigate", Dict("url" => base * "/after"))
            CDP.wait_for(() -> dialogs(page) == n + 1; what="beforeunload dialog")
            CDP.call(page, "Page.handleJavaScriptDialog", Dict("accept" => true))
            wait(nav)
        end
    end
end
