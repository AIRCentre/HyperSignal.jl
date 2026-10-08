using Test, HTTP, JSON, Sockets, HyperSignal

include("maplibre.jl")
# Why: Base-shadowed tags need explicit override (`using` skips them); manual here so
# `@using_tags` is tested in isolation below.
using HyperSignal: div, select, summary
# Why: Helpers names are not exported at top level; import explicitly.
using HyperSignal.Helpers: radio_field, checkbox_field, text_field,
                            form_legend, form_section, help_tooltip,
                            preset_button, signal_dialog

@testset "HyperSignal" begin
    @testset "auto-escapes text content so user input can never break out" begin
        out = render(div("hello <world> & friends"))
        @test out == "<div>hello &lt;world&gt; &amp; friends</div>"
    end

    @testset "Raw bypasses escaping for trusted HTML fragments" begin
        out = render(div(Raw("<b>bold</b>")))
        @test out == "<div><b>bold</b></div>"
    end

    @testset "void tags emit no closing tag" begin
        @test render(br()) == "<br>"
        @test render(input(type="text", name="x")) == "<input type=\"text\" name=\"x\">"
    end

    @testset "void element with children fails loud instead of emitting invalid HTML" begin
        # Why: void element has no content model. `<br>x</br>`: browser discards closing
        # tag and reparents "children" as SIBLING nodes, so server HTML and client DOM
        # diverge and Datastar morph stops being idempotent. Children on a void tag are
        # always a caller mistake; surface it.
        @test_throws ArgumentError render(br("x"))
        @test_throws ArgumentError render(input(type="text", "oops"))
        @test_throws ArgumentError render(hr(span("a")))
        @test_throws ArgumentError render(img(src="x.png", "alt-as-child"))
        @test_throws ArgumentError render(Element(:wbr, Pair{Symbol,Any}[], Any["c"]))
        @test_throws ArgumentError render(br(0))
        @test_throws ArgumentError render(br(""))
        # Why: `nothing` dropped at construction, `Bool`/`missing` render to nothing;
        # `br(cond && extra)` (bare `false` when cond false) must still render `<br>`.
        @test render(br(nothing)) == "<br>"
        @test render(input(type="text", nothing)) == "<input type=\"text\">"
        @test render(br(false)) == "<br>"
        @test render(br(true)) == "<br>"
        @test render(br(missing)) == "<br>"
        let show_extra = false
            @test render(br(show_extra && "x")) == "<br>"
        end
        @test render(img(src="x.png", nothing, false, missing)) == "<img src=\"x.png\">"
        io = IOBuffer()
        @test_throws ArgumentError render(io, img(src="x", "alt"))
        @test String(take!(io)) == ""
    end

    @testset "Attribute nested in a container child → actionable error" begin
        # Why: Attribute lifts into attrs only as TOP-LEVEL positional arg; nested in
        # Vector/Tuple/Generator it is a child with no renderable form. Message must
        # name the fix (splat), not opaque MethodError. Common mistake: collecting attrs
        # in a vector (as signal_dialog does) and forgetting to splat.
        @test_throws ArgumentError render(div([on(:click, ds_get("/x"))], "child"))
        @test_throws ArgumentError render(div((on(:click, ds_get("/x")),), "child"))
        @test_throws ArgumentError render(div(on(:click, ds_get("/x")) for _ in 1:1))
        err = try
            render(div([on(:click, ds_get("/x"))]))
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("Splat", err.msg)
        @test occursin("data-on:click",
                       render(div([on(:click, ds_get("/x"))]..., "child")))
    end

    @testset "boolean attribute true → bare; false/nothing → omitted" begin
        @test render(input(type="checkbox", checked=true))  == "<input type=\"checkbox\" checked>"
        @test render(input(type="checkbox", checked=false)) == "<input type=\"checkbox\">"
        @test render(input(type="checkbox", checked=nothing)) == "<input type=\"checkbox\">"
    end

    @testset "Frag groups children without adding a wrapper tag" begin
        out = render(div(Frag(h1("a"), h2("b"))))
        @test out == "<div><h1>a</h1><h2>b</h2></div>"
    end

    @testset "vectors of children render in order" begin
        items = [li("one"), li("two"), li("three")]
        out = render(ul(items))
        @test out == "<ul><li>one</li><li>two</li><li>three</li></ul>"
    end

    @testset "DATASTAR_SUPPORTED_VERSION pins the targeted Datastar release" begin
        # Why: version bumps land as one visible diff.
        @test DATASTAR_SUPPORTED_VERSION == v"1.0.4"
    end

    @testset "ds_post emits the Datastar form-encoded action expression" begin
        a = ds_post("/api/x"; form=true)
        @test HyperSignal.action_js(a) == "@post('/api/x', {contentType: 'form'})"
    end

    @testset "ds_get without options emits a bare verb call" begin
        @test HyperSignal.action_js(ds_get("/api/y")) == "@get('/api/y')"
    end

    @testset "<form> auto-injects data-on:submit__prevent when no submit binding is given" begin
        # Why: bare <form> still gets native submit on Enter; reload drops client
        # signals. Tag constructor forces preventDefault unless caller wired a submit
        # handler.
        out = render(form(input(type="text", name="q")))
        # Why: Datastar throws `ValueRequired` on valueless data-on:*, which also stops
        # every other attribute on the page initialising.
        @test occursin("data-on:submit__prevent=\"void 0\"", out)
    end

    @testset "<form> with an explicit submit handler keeps just that one" begin
        # Why: auto-prevent must not duplicate or shadow explicit user binding; browser
        # drops duplicate attribute, breaking user's handler.
        out = render(form(on_submit(ds_post("/api/x"; form=true))))
        @test count(==("data-on:submit__prevent"),
                    eachmatch(r"data-on:submit__prevent", out) .|> m -> m.match) == 1
        @test occursin("@post(", out)
    end

    @testset "<form> with on(:submit, …; prevent=false) skips the auto-prevent" begin
        # Why: prevent=false is documented opt-out for native submission; form override
        # must defer to any data-on:submit* attribute, not just __prevent ones.
        out = render(form(on(:submit, "x"; prevent=false)))
        @test occursin("data-on:submit=\"x\"", out)
        @test !occursin("__prevent", out)
    end

    @testset "on(:submit, action) renders with the auto __prevent modifier" begin
        # Why: form bound to Datastar action must preventDefault, else browser also
        # navigates natively in parallel with @post fetch.
        out = render(form(on(:submit, ds_post("/api/x"; form=true)), "body"))
        @test occursin("data-on:submit__prevent=\"@post(&#39;/api/x&#39;, {contentType: &#39;form&#39;})\"", out)
    end

    @testset "on(:submit, …; prevent=false) opts out of the auto preventDefault" begin
        out = render(form(on(:submit, "alert('hi')"; prevent=false)))
        @test occursin("data-on:submit=\"alert(", out)
        @test !occursin("__prevent", out)
    end

    @testset "on(:click, …) does not get the auto __prevent modifier" begin
        out = render(button(on(:click, "x = 1")))
        @test !occursin("__prevent", out)
    end

    @testset "on(...) with debounce emits the __debounce.Nms modifier" begin
        out = render(form(on(:change, ds_get("/api/c"); debounce=300), "body"))
        @test occursin("data-on:change__debounce.300ms=", out)
    end

    @testset "ds_indicator() drops in as a positional Attribute on the element" begin
        out = render(button("Loading", ds_indicator()))
        @test occursin("data-indicator>", out) || occursin("data-indicator ", out)
    end

    @testset "MIME round-trip: text/html, text/plain, and html_response agree byte-for-byte" begin
        # Why: MIME drift across sinks is a real failure mode; one fixture through three
        # paths.
        fixture = div(class="card", h2("Hi"), p("a < b"))

        html_buf = IOBuffer()
        show(html_buf, MIME"text/html"(), fixture)
        html_out = String(take!(html_buf))

        plain_buf = IOBuffer()
        show(plain_buf, MIME"text/plain"(), fixture)
        plain_out = String(take!(plain_buf))

        body = String(html_response(fixture).body)

        @test html_out == "<div class=\"card\"><h2>Hi</h2><p>a &lt; b</p></div>"
        @test body == html_out
        @test plain_out == "HyperSignal.Element: " * html_out
    end

    @testset "fragment_response sets the datastar-selector header" begin
        resp = fragment_response(div("ok"), "#card")
        sel = nothing
        for (k, v) in resp.headers
            lowercase(String(k)) == "datastar-selector" && (sel = String(v); break)
        end
        @test sel == "#card"
        @test String(resp.body) == "<div>ok</div>"
    end

    @testset "fragment_response kwarg form works without a selector" begin
        # Why: `mode=:inner` without selector must work.
        resp = fragment_response(div("ok"))
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test !haskey(h, "datastar-selector")
        @test String(resp.body) == "<div>ok</div>"
    end

    @testset "fragment_response mode kwarg sets datastar-mode header" begin
        for m in (:outer, :inner, :replace, :prepend, :append, :before, :after, :remove)
            resp = fragment_response(div("x"); mode=m)
            h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
            @test h["datastar-mode"] == String(m)
        end
    end

    @testset "fragment_response mode=nothing omits the datastar-mode header" begin
        # Why: Datastar default is `outer`; omit redundant header.
        resp = fragment_response(div("x"))
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test !haskey(h, "datastar-mode")
    end

    @testset "fragment_response rejects unknown mode symbols loud" begin
        # Why: typo like `:innner` would silently send header Datastar ignores; fail at
        # call time.
        @test_throws ArgumentError fragment_response(div("x"); mode=:bogus)
    end

    @testset "fragment_response view_transition=true sets the header" begin
        resp = fragment_response(div("x"); view_transition=true)
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test h["datastar-use-view-transition"] == "true"
    end

    @testset "fragment_response view_transition default omits the header" begin
        resp = fragment_response(div("x"))
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test !haskey(h, "datastar-use-view-transition")
    end

    @testset "fragment_response combines selector + mode + view_transition" begin
        resp = fragment_response(div("x"); selector="#card", mode=:inner,
                                  view_transition=true)
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test h["datastar-selector"] == "#card"
        @test h["datastar-mode"] == "inner"
        @test h["datastar-use-view-transition"] == "true"
    end

    @testset "redirect_via_fragment wraps a window.location script in the morph target" begin
        resp = redirect_via_fragment("#login-form", "/dashboard")
        body = String(resp.body)
        @test occursin("<div id=\"login-form\">", body)
        @test occursin("<script>window.location='/dashboard'</script>", body)
    end

    @testset "redirect_via_fragment escapes single quotes in the location" begin
        # Why: stray ' in URL would close JS string and inject code.
        resp = redirect_via_fragment("#x", "/a'b")
        @test occursin("window.location='/a\\'b'", String(resp.body))
    end

    @testset "redirect_via_fragment defends against </script> in the location" begin
        # Why: HTML parser closes <script> on </script> regardless of JS quoting;
        # backslash splits tag at HTML layer, JS ignores it inside string literal.
        resp = redirect_via_fragment("#x", "/x</script><script>alert(1)</script>")
        body = String(resp.body)
        @test !occursin("</script><script>", body)
        @test occursin("<\\/script><\\/script>", body) ||
              occursin("<\\/script><script>alert(1)<\\/script>", body)
    end

    @testset "redirect_via_fragment escapes backslashes in the location" begin
        # Why: trailing '\' in URL would escape closing JS quote.
        resp = redirect_via_fragment("#x", "/a\\b")
        @test occursin("window.location='/a\\\\b'", String(resp.body))
    end

    @testset "redirect_via_fragment attaches Set-Cookie headers and honors wrapper_tag" begin
        # Why: post-login flow sets session cookie AND navigates in one response;
        # dropped/misattached Set-Cookie silently leaves user logged out.
        resp = redirect_via_fragment("#login-form", "/dashboard";
            cookies=["sid=abc; HttpOnly; Path=/; SameSite=Lax"],
            wrapper_tag=:li)
        body = String(resp.body)
        @test occursin("<li id=\"login-form\">", body)
        @test occursin("<script>window.location='/dashboard'</script>", body)
        cookies = [String(v) for (k, v) in resp.headers if lowercase(String(k)) == "set-cookie"]
        @test cookies == ["sid=abc; HttpOnly; Path=/; SameSite=Lax"]
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test h["datastar-selector"] == "#login-form"
        resp2 = redirect_via_fragment("#x", "/home"; cookies=["a=1", "b=2"])
        c2 = [String(v) for (k, v) in resp2.headers if lowercase(String(k)) == "set-cookie"]
        @test c2 == ["a=1", "b=2"]
    end

    @testset "redirect_via_fragment rejects a selector that isn't a single #id" begin
        # Why: helper renders morph target with `id` = selector minus leading `#`, so
        # only single `#id` works. Class/compound/whitespace selector yields `id`
        # selector can't match (redirect silently no-ops); CR/LF would inject into
        # datastar-selector header. Fail loud at call site.
        @test_throws ArgumentError redirect_via_fragment(".card", "/x")
        @test_throws ArgumentError redirect_via_fragment("#a #b", "/x")
        @test_throws ArgumentError redirect_via_fragment("#a\nb", "/x")
        @test_throws ArgumentError redirect_via_fragment("login", "/x")
        @test_throws ArgumentError redirect_via_fragment("#", "/x")
        @test occursin("id=\"ok\"", String(redirect_via_fragment("#ok", "/x").body))
    end

    @testset "signals_response emits JSON body with the right Content-Type" begin
        resp = signals_response((; count=3, label="hi"))
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test resp.status == 200
        @test h["content-type"] == "application/json; charset=utf-8"
        @test !haskey(h, "datastar-only-if-missing")
        parsed = JSON.parse(String(resp.body))
        @test parsed == Dict("count" => 3, "label" => "hi")
    end

    @testset "signals_response only_if_missing=true adds the header" begin
        resp = signals_response(Dict("x" => 1); only_if_missing=true)
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test h["datastar-only-if-missing"] == "true"
    end

    @testset "signals_response passes through status + extra headers" begin
        resp = signals_response(Dict("x" => 1); status=202, headers=["X-Tag" => "v1"])
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test resp.status == 202
        @test h["x-tag"] == "v1"
        @test h["content-type"] == "application/json; charset=utf-8"
    end

    @testset "script_response writes the JS verbatim with text/javascript" begin
        js = "console.log('hi')"
        resp = script_response(js)
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test resp.status == 200
        @test h["content-type"] == "text/javascript; charset=utf-8"
        @test String(resp.body) == js
        @test !haskey(h, "datastar-script-attributes")
    end

    @testset "script_response with a string script_attributes sets the header verbatim" begin
        resp = script_response("doStuff()"; script_attributes="type=\"module\"")
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test h["datastar-script-attributes"] == "type=\"module\""
    end

    @testset "script_response JSON-encodes a NamedTuple of script_attributes" begin
        resp = script_response("x"; script_attributes=(; type="module", defer=true))
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        parsed = JSON.parse(h["datastar-script-attributes"])
        @test parsed == Dict("type" => "module", "defer" => true)
    end

    @testset "script_response JSON-encodes a Dict of script_attributes" begin
        resp = script_response("x"; script_attributes=Dict("type" => "module"))
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test JSON.parse(h["datastar-script-attributes"]) == Dict("type" => "module")
    end

    @testset "sse_response emits text/event-stream with SSE headers" begin
        resp = sse_response([patch_elements(div("ok"))])
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test resp.status == 200
        @test h["content-type"] == "text/event-stream; charset=utf-8"
        @test h["cache-control"] == "no-cache"
        @test h["connection"] == "keep-alive"
    end

    @testset "patch_elements with defaults emits only the elements data line" begin
        body = String(sse_response([patch_elements(div("ok"))]).body)
        @test body == "event: datastar-patch-elements\ndata: elements <div>ok</div>\n\n"
    end

    @testset "patch_elements with selector, mode, view_transition emits all data lines" begin
        ev = patch_elements(div("ok"); selector="#card", mode=:inner, view_transition=true)
        body = String(sse_response([ev]).body)
        @test body == string(
            "event: datastar-patch-elements\n",
            "data: selector #card\n",
            "data: mode inner\n",
            "data: useViewTransition true\n",
            "data: elements <div>ok</div>\n",
            "\n",
        )
    end

    @testset "patch_elements splits multi-line HTML into separate data lines" begin
        ev = patch_elements(Raw("<div>\n  <p>x</p>\n</div>"))
        body = String(sse_response([ev]).body)
        @test body == string(
            "event: datastar-patch-elements\n",
            "data: elements <div>\n",
            "data: elements   <p>x</p>\n",
            "data: elements </div>\n",
            "\n",
        )
    end

    @testset "patch_elements rejects unknown mode symbols loud" begin
        @test_throws ArgumentError patch_elements(div("x"); mode=:bogus)
    end

    @testset "sse_response rejects a selector containing a newline" begin
        # Why: literal newline in selector ends SSE line early, corrupts rest of event.
        @test_throws ArgumentError sse_response([patch_elements(div("x");
                                                                selector="#a\n#b")])
    end

    @testset "sse_response rejects a selector containing a carriage return" begin
        # Why: EventSource treats bare CR (and CRLF) as line terminator like LF; same
        # failure mode as '\n', reject same way.
        @test_throws ArgumentError sse_response([patch_elements(div("x");
                                                                selector="#a\r#b")])
    end

    @testset "patch_elements validates the selector at build time, not just at encode time" begin
        # Why: CR/LF selector check fires in patch_elements, so stacktrace points at
        # call site, not deep in sse_response/sse_stream encode loop.
        @test_throws ArgumentError patch_elements(div("x"); selector="#a\nb")
        @test_throws ArgumentError patch_elements(div("x"); selector="#a\rb")
        @test patch_elements(div("x"); selector="#card") isa
              HyperSignal.PatchElementsEvent
    end

    @testset "patch_elements splits payload on lone CR and CRLF, not just LF" begin
        # Why: HTML authored on Windows (or SVG with CRLF endings) carries '\r';
        # splitting on '\n' alone leaves lone '\r' in a `data: elements` line, which
        # client reads as early terminator and drops remainder.
        crlf = String(sse_response([patch_elements(Raw("<div>\r\n  <p>x</p>\r\n</div>"))]).body)
        @test crlf == string(
            "event: datastar-patch-elements\n",
            "data: elements <div>\n",
            "data: elements   <p>x</p>\n",
            "data: elements </div>\n",
            "\n",
        )
        cr = String(sse_response([patch_elements(Raw("a\rb"))]).body)
        @test cr == "event: datastar-patch-elements\ndata: elements a\ndata: elements b\n\n"
        trailing = String(sse_response([patch_elements(Raw("<div>x</div>\r\n"))]).body)
        @test trailing == "event: datastar-patch-elements\ndata: elements <div>x</div>\n\n"
    end

    @testset "patch_elements drops a single trailing newline from rendered HTML" begin
        # Why: render() output ending in '\n' would emit stray empty `data: elements `
        # line; client reassembles it as phantom trailing newline.
        body = String(sse_response([patch_elements(Raw("<div>x</div>\n"))]).body)
        @test body == "event: datastar-patch-elements\ndata: elements <div>x</div>\n\n"
    end

    @testset "patch_signals encodes signals JSON in a single data line" begin
        body = String(sse_response([patch_signals((; count=3))]).body)
        @test body == "event: datastar-patch-signals\ndata: signals {\"count\":3}\n\n"
    end

    @testset "patch_signals only_if_missing=true adds the onlyIfMissing data line" begin
        body = String(sse_response([patch_signals(Dict("x" => 1); only_if_missing=true)]).body)
        @test body == string(
            "event: datastar-patch-signals\n",
            "data: onlyIfMissing true\n",
            "data: signals {\"x\":1}\n",
            "\n",
        )
    end

    @testset "sse_response concatenates multiple events separated by blank lines" begin
        body = String(sse_response([
            patch_elements(div("ok"); selector="#card"),
            patch_signals((; count=3)),
        ]).body)
        @test body == string(
            "event: datastar-patch-elements\n",
            "data: selector #card\n",
            "data: elements <div>ok</div>\n",
            "\n",
            "event: datastar-patch-signals\n",
            "data: signals {\"count\":3}\n",
            "\n",
        )
    end

    @testset "sse_response passes through status and extra headers" begin
        resp = sse_response([patch_elements(div("ok"))]; status=202,
                            headers=["X-Tag" => "v1"])
        h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
        @test resp.status == 202
        @test h["x-tag"] == "v1"
        @test h["content-type"] == "text/event-stream; charset=utf-8"
    end

    @testset "a single sse event round-trips through a naive SSE parser" begin
        # Why: parse emitted bytes as a client would (split on blank line, then data
        # lines) to catch terminator/encoding regressions.
        ev = patch_elements(div("ok"); selector="#card", mode=:inner)
        body = String(sse_response([ev]).body)
        chunks = split(body, "\n\n"; keepempty=false)
        @test length(chunks) == 1
        lines = split(chunks[1], "\n")
        @test lines[1] == "event: datastar-patch-elements"
        data_lines = [chopprefix(l, "data: ") for l in lines if startswith(l, "data: ")]
        @test data_lines == ["selector #card", "mode inner", "elements <div>ok</div>"]
    end

    @testset "sse_stream" begin
        function _hit_stream(handler)
            # Why: `listen!` takes `::HTTP.Stream` handler on both majors (2.x `serve!`
            # only calls `handler(::Request)`); only bound-port lookup differs.
            srv = HTTP.listen!(handler, "127.0.0.1", 0)
            port = pkgversion(HTTP) >= v"2" ? srv.bound_port :
                Sockets.getsockname(srv.listener.server)[2]
            try
                resp = HTTP.get("http://127.0.0.1:$port/"; retry=false,
                                decompress=false, status_exception=false)
                h = Dict(lowercase(String(k)) => String(v) for (k, v) in resp.headers)
                return resp.status, h, String(resp.body)
            finally
                close(srv)
            end
        end

        @testset "streams chunked text/event-stream with SSE headers" begin
            handler = sse_stream() do writer
                writer(patch_elements(div("ok"); selector="#card"))
            end
            status, h, _ = _hit_stream(handler)
            @test status == 200
            @test h["content-type"] == "text/event-stream; charset=utf-8"
            @test h["cache-control"] == "no-cache"
            @test get(h, "transfer-encoding", "") == "chunked"
        end

        @testset "emits each writer call as a separate SSE event in order" begin
            handler = sse_stream() do writer
                writer(patch_elements(div("step 1"); selector="#p", mode=:inner))
                writer(patch_elements(div("step 2"); selector="#p", mode=:inner))
                writer(patch_signals((; done=true)))
            end
            _, _, body = _hit_stream(handler)
            events = split(body, "\n\n"; keepempty=false)
            @test length(events) == 3
            @test occursin("event: datastar-patch-elements", events[1])
            @test occursin("data: elements <div>step 1</div>", events[1])
            @test occursin("data: elements <div>step 2</div>", events[2])
            @test occursin("event: datastar-patch-signals", events[3])
            @test occursin("data: signals {\"done\":true}", events[3])
        end

        @testset "per-event body bytes match the buffered encoder" begin
            # Why: streaming must encode each event identically to sse_response; client
            # can't tell them apart.
            ev1 = patch_elements(div("ok"); selector="#card", mode=:inner)
            ev2 = patch_signals((; n=3))
            handler = sse_stream() do writer
                writer(ev1); writer(ev2)
            end
            _, _, body = _hit_stream(handler)
            expected = String(sse_response([ev1, ev2]).body)
            @test body == expected
        end

        @testset "passes through status and extra headers" begin
            handler = sse_stream(; status=202, headers=["X-Tag" => "v1"]) do writer
                writer(patch_elements(div("ok")))
            end
            status, h, _ = _hit_stream(handler)
            @test status == 202
            @test h["x-tag"] == "v1"
            @test h["content-type"] == "text/event-stream; charset=utf-8"
        end

        @testset "handler with zero writes still completes with SSE headers" begin
            handler = sse_stream() do writer
            end
            status, h, body = _hit_stream(handler)
            @test status == 200
            @test h["content-type"] == "text/event-stream; charset=utf-8"
            # Why: chunked transfer must apply even to zero-write handler; trivial
            # Response stub would not satisfy this.
            @test get(h, "transfer-encoding", "") == "chunked"
            @test body == ""
        end

        @testset "events written before f throws still reach the client" begin
            # Why: handlers may fail mid-task; already-flushed output must stay visible
            # so client sees progress up to failure.
            handler = sse_stream() do writer
                writer(patch_elements(div("progress 1"); selector="#p", mode=:inner))
                writer(patch_elements(div("progress 2"); selector="#p", mode=:inner))
                error("boom")
            end
            _, _, body = _hit_stream(handler)
            @test occursin("data: elements <div>progress 1</div>", body)
            @test occursin("data: elements <div>progress 2</div>", body)
        end
    end

    @testset "the count_estimate_fragment migration produces equivalent HTML" begin
        # Why: drop-in migration of validation_studio's smallest real fragment must be
        # byte-stable for clients caching fragments.
        format_number(n::Int) = string(n)
        n = 122_000
        legacy = string(
            "<div id=\"count-estimate\" class=\"count-estimate\">",
            "<small class=\"muted\">~", format_number(n), " images match</small>",
            "</div>",
        )
        new = render(
            div(id="count-estimate", class="count-estimate",
                small(class="muted", "~$(format_number(n)) images match"))
        )
        @test new == legacy
    end

    @testset "a form with multiple Datastar bindings reads top-to-bottom" begin
        # Why: new-session form has two attribute bindings (submit, change-debounced)
        # plus nested fieldsets; clutter here = API not pulling its weight.
        out = render(
            form(
                on(:submit, ds_post("/session/new"; form=true)),
                on_change_debounced(ds_get("/api/session/count"; form=true)),
                fieldset(
                    legend("Confidence"),
                    label(input(type="radio", name="confidence", value="all", checked=true), " All"),
                ),
                button("Start", type="submit"),
            )
        )
        @test occursin("data-on:submit__prevent=\"@post(", out)
        @test occursin("data-on:change__debounce.300ms=\"@get(", out)
        @test occursin("<fieldset><legend>Confidence</legend>", out)
        @test occursin("<input type=\"radio\" name=\"confidence\" value=\"all\" checked>", out)
    end

    @testset "cls keeps simple strings and skips empties" begin
        @test cls("btn", "primary") == "btn primary"
        @test cls("btn", "", "primary") == "btn primary"
        @test cls() == ""
    end

    @testset "cls includes Pair-conditional classes only when the flag is true" begin
        # Why: `class=cls(...)` replaces ternary string interpolation in component
        # bodies.
        @test cls("card", "active" => true) == "card active"
        @test cls("card", "active" => false) == "card"
        @test cls("card", "active" => false, "loading" => true) == "card loading"
    end

    @testset "cls flattens vectors so callers can build lists imperatively" begin
        modifiers = ["large", "rounded"]
        @test cls("btn", modifiers, "active" => true) == "btn large rounded active"
    end

    @testset "cls skips nothing/missing without a runtime error" begin
        @test cls("btn", nothing, missing, "primary") == "btn primary"
    end

    @testset "cls rejects Pair values that aren't Bool — fail loud, not silent" begin
        # Why: coercing `"active" => some_string` would silently include the class; loud
        # error catches typo.
        @test_throws ArgumentError cls("btn", "active" => "yes")
    end

    @testset "redirect_to emits a 303 with the Location header" begin
        resp = redirect_to("/dashboard")
        @test resp.status == 303
        loc = nothing
        for (k, v) in resp.headers
            lowercase(String(k)) == "location" && (loc = String(v); break)
        end
        @test loc == "/dashboard"
    end

    @testset "redirect_to attaches Set-Cookie headers when given" begin
        # Why: post-login flow must redirect AND set session cookie in one response.
        resp = redirect_to("/dashboard"; cookies=["sid=abc; HttpOnly; Path=/"])
        cookies = [String(v) for (k, v) in resp.headers if lowercase(String(k)) == "set-cookie"]
        @test cookies == ["sid=abc; HttpOnly; Path=/"]
    end

    @testset "radio_field wraps an input with a label, matching project convention" begin
        out = render(radio_field("color", "red", "Red"; checked=true))
        @test out == "<label><input type=\"radio\" name=\"color\" value=\"red\" checked> Red</label>"
    end

    @testset "checkbox_field defaults value=\"on\" so form parsing matches" begin
        # Why: Datastar form-encoded submit sends `name=on` for checkboxes by default;
        # deviating silently breaks parse_form_body.
        out = render(checkbox_field("agree", "I agree"; checked=true))
        @test occursin("type=\"checkbox\"", out)
        @test occursin("name=\"agree\"", out)
        @test occursin("value=\"on\"", out)
        @test occursin("checked", out)
        @test occursin(" I agree</label>", out)
    end

    @testset "on_click is a single-event shorthand for on(:click, ...)" begin
        out = render(button("X", on_click(ds_post("/api/dismiss"))))
        @test occursin("data-on:click=\"@post(", out)
    end

    @testset "help_tooltip auto-escapes the tooltip text in the popup body" begin
        # Why: tooltips carry user-facing copy with quotes/angle-brackets; auto-escaped
        # element text blocks markup injection.
        out = render(help_tooltip("a \"quoted\" thing"))
        @test occursin("a &quot;quoted&quot; thing</span>", out)
        @test occursin("class=\"help-trigger\"", out)
        @test occursin("<svg", out)
        @test occursin("class=\"help-popup\"", out)
    end

    @testset "help_tooltip wires the datastar signals/handlers that drive show-on-hover and toggle-on-click" begin
        # Why: hover events open/close via $help_hover; icon-wrap click toggles
        # $help_open; data-on:click__outside on trigger closes click-pinned state
        # without affecting other tooltips on the page.
        out = render(help_tooltip("hint"))
        @test occursin("data-signals=", out)
        @test occursin("data-on:mouseenter=", out)
        @test occursin("data-on:mouseleave=", out)
        @test occursin("data-on:click__outside=", out)
        @test occursin("class=\"help-icon-wrap\"", out)
        @test occursin("data-show=", out)
    end

    @testset "help_tooltip lets the caller override the icon" begin
        # Why: project styling may want a different help glyph; Element override avoids
        # forking helper.
        out = render(help_tooltip("hint"; icon=Raw("<i>?</i>")))
        @test occursin("<i>?</i>", out)
        @test occursin("class=\"help-icon-wrap\"", out)
    end

    @testset "form_legend without tooltip is a plain muted legend" begin
        @test render(form_legend("Size")) ==
            "<legend class=\"muted\">Size</legend>"
    end

    @testset "form_legend with tooltip pairs the label with a help-trigger span" begin
        out = render(form_legend("Size"; tooltip="number of items"))
        @test occursin("<legend class=\"muted\">Size <span class=\"help-trigger\"", out)
        @test occursin("number of items</span>", out)
    end

    @testset "form_section emits a muted section label and a card-grid container" begin
        # Why: every validation_studio session-form section repeats this two-element
        # pattern; helper saves 4 lines per section.
        out = render(form_section("Image Batch",
            article(p("a")),
            article(p("b")),
        ))
        @test out ==
            "<small class=\"muted form-section-label\">Image Batch</small>\
<div class=\"form-card-grid\"><article><p>a</p></article>\
<article><p>b</p></article></div>"
    end

    @testset "preset_button rejects names that aren't [A-Za-z0-9_-]" begin
        # Why: name lands unquoted in CSS attribute selector; stray character breaks
        # selector or escapes surrounding JS. Fail loud at build time.
        @test_throws ArgumentError preset_button("Bad", ["bad name" => "v"])
        @test_throws ArgumentError preset_button("Bad", ["x'y" => "v"])
        @test_throws ArgumentError preset_button("Bad", ["" => "v"])
    end

    @testset "preset_button escapes \" and \\ inside value" begin
        # Why: value sits in double-quoted JS string; unescaped `"` closes it
        # mid-selector.
        out = render(preset_button("X", ["k" => "a\"b"]))
        @test occursin("[value=&quot;a\\&quot;b&quot;]", out)
    end

    @testset "preset_button escapes ' inside value" begin
        # Why: selector is single-quoted arg to `querySelector('…')`; `'` in value
        # (`it's`) closes outer JS string → SyntaxError. Backslash-escape survives HTML
        # un-escape as `\'`, JS parser yields literal `'` that CSS receives unchanged.
        out = render(preset_button("X", ["mode" => "it's"]))
        @test occursin("[value=&quot;it\\&#39;s&quot;]", out)
    end

    @testset "preset_button rejects a digit-leading name (invalid unquoted CSS selector)" begin
        # Why: name lands UNQUOTED in `input[name=…]`; CSS identifier can't start with
        # digit (nor hyphen-then-digit), so `name=123` makes querySelector throw at
        # click time. Fail loud at build.
        @test_throws ArgumentError preset_button("X", ["123" => "a"])
        @test_throws ArgumentError preset_button("X", ["-1" => "a"])
        @test render(preset_button("X", ["-data-x" => "a"])) isa AbstractString
        @test render(preset_button("X", ["_k" => "a"])) isa AbstractString
        # Why: trailing newline must be rejected: anchor with `\z` not `$`, since PCRE
        # `$` matches before final \n and `"foo\n"` would land raw in CSS selector.
        @test_throws ArgumentError preset_button("X", ["foo\n" => "v"])
        @test_throws ArgumentError preset_button("X", ["foo\nbar" => "v"])
    end

    @testset "preset_button generates the click-side JS to set named radios + fire change" begin
        # Why: hand-typed JS at every preset breaks under one wrong quote-escape;
        # centralized here.
        out = render(preset_button("Easy",
            ["confidence" => "all", "label_filter" => "both"]))
        @test occursin("type=\"button\"", out)
        @test occursin("class=\"secondary outline\"", out)
        # Why: Datastar 1.0.2+ updates `data-bind` input on `input`, which bubbles up,
        # never down from form; each radio gets own `input` event. Form-level `change`
        # keeps `data-on:change` handlers firing.
        @test occursin(
            "{const e=document.querySelector(&#39;input[name=confidence][value=&quot;all&quot;]&#39;);" *
            "e.checked=true;e.dispatchEvent(new Event(&#39;input&#39;,{bubbles:true}));}",
            out)
        @test occursin(
            "{const e=document.querySelector(&#39;input[name=label_filter][value=&quot;both&quot;]&#39;);" *
            "e.checked=true;e.dispatchEvent(new Event(&#39;input&#39;,{bubbles:true}));}",
            out)
        @test occursin("this.form.dispatchEvent(new Event(&#39;change&#39;,{bubbles:true}))", out)
        @test occursin(">Easy</button>", out)
    end

    @testset "DOCTYPE prefixes a page when wrapped in a Frag with html()" begin
        # Why: DOCTYPE constant avoids stringly-typed prelude in page builders.
        page = Frag(
            DOCTYPE,
            html(lang="en",
                head(meta(charset="UTF-8"), title("Page")),
                body(p("hi")),
            ),
        )
        out = render(page)
        @test startswith(out, "<!DOCTYPE html><html lang=\"en\">")
        @test occursin("<head><meta charset=\"UTF-8\"><title>Page</title></head>", out)
        @test occursin("<body><p>hi</p></body>", out)
        @test endswith(out, "</html>")
    end

    @testset "a full page composes from primitives without a layout helper" begin
        # Why: validation_studio page_layout/wrap_with_nav are project-specific (footer,
        # CDN, favicons); lib ships AST primitives + Frag(DOCTYPE, …), not a page_layout
        # helper. Build equivalent layout from primitives only.
        nav_html = nav(
            ul(li(class="secondary", strong(class="nav-title", "Validation Studio"))),
            ul(
                li(a(href="/dashboard", "Dashboard")),
                li(button(type="button", on_click(ds_post("/logout")), "Log out")),
            ),
        )
        page = Frag(
            DOCTYPE,
            html(lang="en",
                head(
                    meta(charset="UTF-8"),
                    meta(name="viewport", content="width=device-width, initial-scale=1.0"),
                    title("Dashboard — Validation Studio"),
                    link(rel="stylesheet", href="/static/style.css"),
                    script(type="module", src="/static/js/datastar.js"),
                ),
                body(
                    nav_html,
                    main(class="container", h2("Welcome")),
                    footer(class="container", small(class="muted", "© 2026 AIRCentre")),
                ),
            ),
        )
        out = render(page)
        @test startswith(out, "<!DOCTYPE html><html lang=\"en\">")
        @test occursin("<title>Dashboard — Validation Studio</title>", out)
        @test occursin("<link rel=\"stylesheet\" href=\"/static/style.css\">", out)
        @test occursin("<script type=\"module\" src=\"/static/js/datastar.js\"></script>", out)
        @test occursin("<nav>", out)
        @test occursin("data-on:click=\"@post(&#39;/logout&#39;)\"", out)
        @test occursin("<main class=\"container\"><h2>Welcome</h2></main>", out)
    end

    @testset "a realistic session-form section composes from the helpers without ad-hoc strings" begin
        # Why: load-bearing test for helper suite; raw <small>/<div>/<button> strings
        # needed here = helpers haven't bought enough leverage.
        section = form_section("Image Batch",
            article(
                fieldset(
                    form_legend("Size"; tooltip="Number of images to review."),
                    radio_field("target_count", "10", "10"),
                    radio_field("target_count", "25", "25"; checked=true),
                    radio_field("target_count", "50", "50"),
                ),
            ),
            article(
                fieldset(
                    form_legend("Confidence"),
                    radio_field("confidence", "all", "0.0 – 1.0"; checked=true),
                    radio_field("confidence", "medium", "0.3 – 0.7"),
                    preset_button("Easy", ["confidence" => "all"]),
                ),
            ),
        )
        out = render(section)
        @test occursin("<small class=\"muted form-section-label\">Image Batch</small>", out)
        @test occursin("<div class=\"form-card-grid\">", out)
        @test occursin("class=\"help-trigger\"", out)
        @test occursin("Number of images to review.</span>", out)
        @test occursin("value=\"25\" checked", out)
        @test occursin("document.querySelector(", out)
    end

    @testset "on accepts a raw JS expression alongside a DSAction" begin
        # Why: client-side toggles like `$open = !$open` are plain JS, not HTTP fetches;
        # `on` accepting AbstractString keeps one call site instead of
        # `Symbol("data-on:click") => string`.
        out = render(button(on(:click, "\$open = !\$open"), "Toggle"))
        @test occursin("data-on:click=\"\$open = !\$open\"", out)
    end

    @testset "on adds the __window modifier when window=true" begin
        # Why: `window` modifier routes listener to `window`, so global hotkeys work
        # without focusing the element.
        out = render(div(on(:keydown, "x"; window=true)))
        @test occursin("data-on:keydown__window=", out)
    end

    @testset "on stacks __window and __debounce modifiers" begin
        out = render(div(on(:keydown, "x"; window=true, debounce=500)))
        @test occursin("data-on:keydown__window__debounce.500ms=", out)
    end

    @testset "on_click and on_submit accept a raw JS expression" begin
        # Why: client-side toggles need raw JS, not just DSAction.
        @test occursin("data-on:click=", render(button(on_click("\$open = true"))))
        @test occursin("data-on:submit__prevent=", render(form(on_submit("alert('hi')"))))
    end

    @testset "on_interval emits a duration modifier on data-on-interval" begin
        # Why: polling fragments need recurring fetch; helper hides
        # `data-on-interval__duration.Nms` shape.
        out = render(section(on_interval(ds_get("/api/x"); ms=5000)))
        @test occursin("data-on-interval__duration.5000ms=\"@get(", out)
    end

    @testset "ds_ref / ds_attr / ds_class / ds_effect / ds_init render the expected attrs" begin
        # Why: helpers centralise `data-*` prefix; beats `Symbol("data-ref") => ...`
        # literals.
        @test render(button(ds_ref("btnNext"))) ==
            "<button data-ref=\"btnNext\"></button>"
        @test render(div(ds_attr("open", "\$dialogOpen"))) ==
            "<div data-attr:open=\"\$dialogOpen\"></div>"
        @test render(button(ds_class("outline", "\$view !== 'grid'"))) ==
            "<button data-class:outline=\"\$view !== &#39;grid&#39;\"></button>"
        @test render(div(ds_effect("\$open ? \$dlg.showModal() : \$dlg.close()"))) ==
            "<div data-effect=\"\$open ? \$dlg.showModal() : \$dlg.close()\"></div>"
        out_action = render(div(ds_init(ds_get("/api/x"))))
        @test occursin("data-init=\"@get(&#39;/api/x&#39;)\"", out_action)
        out_expr = render(div(ds_init("\$x = 1")))
        @test occursin("data-init=\"\$x = 1\"", out_expr)
        # Why: Datastar plugin is `data-signals` (plural); no `data-signal` attribute
        # exists, so singular form silently no-ops. Keyed form is `data-signals:<name>`.
        @test render(div(ds_signal("count", 0))) ==
            "<div data-signals:count=\"0\"></div>"
        @test render(div(ds_computed("total", "\$price * \$qty"))) ==
            "<div data-computed:total=\"\$price * \$qty\"></div>"
        @test render(div(ds_style("display", "\$hiding && 'none'"))) ==
            "<div data-style:display=\"\$hiding &amp;&amp; &#39;none&#39;\"></div>"
    end

    @testset "a Symbol names one signal: \$name in expressions, bare in bind/indicator" begin
        # Why: `"$x"` needs Julia escape; forgetting `$` (`"count"`) makes Datastar read
        # an undefined JS name instead of signal.
        @test render(span(ds_show(:open))) == "<span data-show=\"\$open\"></span>"
        @test render(span(ds_text(Symbol("form.email")))) ==
            "<span data-text=\"\$form.email\"></span>"
        @test render(div(ds_attr("disabled", :busy))) ==
            "<div data-attr:disabled=\"\$busy\"></div>"
        @test render(div(ds_class("active", :isActive))) ==
            "<div data-class:active=\"\$isActive\"></div>"
        @test render(div(ds_style("width", :w))) == "<div data-style:width=\"\$w\"></div>"
        @test render(div(ds_computed("copy", :total))) ==
            "<div data-computed:copy=\"\$total\"></div>"
        @test render(div(ds_bind(:query))) == "<div data-bind=\"query\"></div>"
        @test render(div(ds_indicator(:saving))) == "<div data-indicator=\"saving\"></div>"
        # Why: Datastar camel-cases hyphens, so `:my-signal` would name nothing.
        for bad in (Symbol("my-signal"), Symbol("a..b"), Symbol("x y"), Symbol(""), Symbol("1a"))
            @test_throws ArgumentError ds_show(bad)
        end
        @test_throws ArgumentError ds_bind(Symbol("my-signal"))
    end

    @testset "ds\"…\" keeps \$signal literal and splices \$(julia) as a JS literal" begin
        # Why: plain string makes `$count` Julia interpolation, forcing `\\\$`
        # everywhere; splicing v unquoted into JS = injection.
        @test ds"$open = !$open" == "\$open = !\$open"
        @test ds"$open" isa DSExpr
        n, s = 3, "a'b\"c"
        @test ds"$count = $(n)" == "\$count = 3"
        @test ds"$label = $(s)" == "\$label = 'a\\'b\\\"c'"
        t = "a</b"
        @test ds"$x = $(t)" == "\$x = 'a<\\/b'"
        @test ds"$x = $(Inf)" == "\$x = Infinity"
        @test ds"$x = $((a=1,))" == "\$x = {\"a\":1}"
        @test ds"$x = $(nothing)" == "\$x = null"
        # Why: bare `"` ends custom string literal, even inside `$(…)`.
        @test ds"""$(ds_get("/feed")); $ready = true""" == "@get('/feed'); \$ready = true"
        inner = ds"$a + 1"
        @test ds"$b = $(inner)" == "\$b = \$a + 1"
        @test ds"$$(x)" == "\$(x)"
        @test ds"$v = 'it\'s $w'" == "\$v = 'it\\'s \$w'"
        @test render(button(on(:click, ds"$x = $(s)"))) ==
            "<button data-on:click=\"\$x = &#39;a\\&#39;b\\&quot;c&#39;\"></button>"
        # Why: quote inside each regex flips parser's quote tracking, so splices are
        # accepted though inside real JS strings; escaping every delimiter keeps value
        # inert in any quote context.
        dq, bt, sq = "\"+alert(1)+\"", "\${alert(1)}", (a="'+alert(1)+'",)
        @test ds"$ok = /\"/.test($a) ? \"$(dq)\" : /\"/" ==
            "\$ok = /\"/.test(\$a) ? \"'\\\"+alert(1)+\\\"'\" : /\"/"
        @test ds"$ok = /`/.test($a) ? `$(bt)` : /`/" ==
            "\$ok = /`/.test(\$a) ? `'\\\${alert(1)}'` : /`/"
        @test ds"$ok = /'/.test($a) ? '$(sq)' : /'/" ==
            "\$ok = /'/.test(\$a) ? '{\"a\":\"\\'+alert(1)+\\'\"}' : /'/"
        # Why: errors raise at macro expansion; call parser directly.
        @test_throws ArgumentError HyperSignal._ds_parse("\\\$x")
        @test_throws ArgumentError HyperSignal._ds_parse("'hi \$(name)'")
        @test_throws ArgumentError HyperSignal._ds_parse("\$(a")
        @test_throws ArgumentError HyperSignal._ds_parse("'open")
    end

    @testset "ds_json_signals renders the bare debug attribute (and an optional filter)" begin
        # Why: in-page debugger; bare form is valueless attribute like ds_indicator(),
        # filter overload scopes to matching signal names.
        @test render(pre(ds_json_signals())) == "<pre data-json-signals></pre>"
        a = ds_json_signals()
        @test (a.key, a.value) == (Symbol("data-json-signals"), true)
        @test render(pre(ds_json_signals("{include: /user/}"))) ==
            "<pre data-json-signals=\"{include: /user/}\"></pre>"
    end

    @testset "ds_signals JSON-encodes a NamedTuple into data-signals" begin
        # Why: hand-written JSON in attribute strings is most accident-prone Datastar
        # wiring. ds_signals JSON-encodes once; renderer's attribute escape handles HTML
        # side. `&quot;` round-trips because Datastar unescapes attribute values before
        # reading JSON.
        out = render(
            div(ds_signals((showDetails=false, count=0)), "x"))
        @test occursin("data-signals=\"", out)
        @test occursin("&quot;showDetails&quot;:false", out)
        @test occursin("&quot;count&quot;:0", out)
    end

    @testset "ds_signals accepts a Dict and emits a JSON object body" begin
        out = render(
            div(ds_signals(Dict("k" => "v")), "x"))
        @test occursin("&quot;k&quot;:&quot;v&quot;", out)
    end

    @testset "parse_signals decodes a JSON body into a Dict{String, Any}" begin
        # Why: signals arrive as JSON object from Datastar's default @post('/x');
        # parse_signals inverts ds_signals on request side, returns uniform Dict whether
        # given Request, Vector{UInt8}, or String.
        body = "{\"count\": 7, \"label\": \"hi\"}"
        d = parse_signals(body)
        @test d isa Dict{String, Any}
        @test d["count"] == 7
        @test d["label"] == "hi"
    end

    @testset "parse_signals accepts an HTTP.Request and a Vector{UInt8}" begin
        body = "{\"a\": true}"
        @test parse_signals(Vector{UInt8}(body))["a"] === true
        req = HTTP.Request("POST", "/x", [], Vector{UInt8}(body))
        @test parse_signals(req)["a"] === true
    end

    @testset "parse_signals returns an empty Dict for an empty body" begin
        # Why: bodyless request must not crash route; `get(sig, "x", default)` handles
        # "no signals sent".
        @test parse_signals("") == Dict{String, Any}()
        @test parse_signals(UInt8[]) == Dict{String, Any}()
        # Why: HTTP 2.x gives bodyless request `HTTP.EmptyBody`, not a Vector.
        @test parse_signals(HTTP.Request("GET", "/")) == Dict{String, Any}()
    end

    @testset "parse_signals rejects a top-level non-object payload loud" begin
        # Why: Datastar wraps signals in JSON object; bare array/number would silently
        # become Vector{Any}/Int. Fail loud with ArgumentError, matching malformed-JSON
        # path.
        @test_throws ArgumentError parse_signals("[1, 2, 3]")
        @test_throws ArgumentError parse_signals("42")
    end

    @testset "Symbol-keyed Pairs lift into attrs alongside kwargs and Attributes" begin
        # Why: `for`, `aria-label`, `data-foo:bar` aren't valid Julia kwarg identifiers;
        # Pair form avoids hand-building `Attribute`.
        out = render(label(:for => "user", "Username"))
        @test out == "<label for=\"user\">Username</label>"
        out2 = render(a(href="#x", Symbol("aria-label") => "Scroll", "x"))
        @test occursin("aria-label=\"Scroll\"", out2)
        @test occursin("href=\"#x\"", out2)
    end

    @testset "signal_dialog wires open/close to a Datastar expression" begin
        # Why: every validation_studio modal re-rolls same three bindings (data-effect
        # for showModal/close, close-event sync, backdrop-click dismiss); signal_dialog
        # bakes them in.
        out = render(signal_dialog("\$modal",
            div(class="inner", "body");
            close_action="\$modal = 0", id="x", class="m"))
        @test startswith(out, "<dialog ")
        @test occursin("id=\"x\"", out)
        @test occursin("class=\"m\"", out)
        # Why: Datastar expression context binds host element as `el`.
        @test occursin("data-effect=\"(\$modal) ? el.showModal() : el.close()\"", out)
        @test occursin("data-on:close=\"\$modal = 0\"", out)
        @test occursin("data-on:click=\"if(event.target===el){\$modal = 0}\"", out)
        @test occursin("<div class=\"inner\">body</div></dialog>", out)
    end

    @testset "signal_dialog omits id/class when not provided" begin
        out = render(signal_dialog("\$o", p("hi"); close_action="\$o=false"))
        @test !occursin(" id=", out)
        @test !occursin(" class=", out)
        @test occursin("<p>hi</p></dialog>", out)
    end

    @testset "signal_dialog click handler stays scoped to the dialog element" begin
        # Why: backdrop-click-to-close must not eat clicks on inner content;
        # `event.target===el` guard must be present literally, not just any
        # data-on:click.
        out = render(signal_dialog("\$x", div("c"); close_action="\$x=0"))
        @test occursin("event.target===el", out)
    end

    @testset "@using_tags imports the Base-shadowed tag names in one line" begin
        # Why: macro replaces manual `using HyperSignal: div, select, …`, the API's most
        # awkward line; expansion must be same `using` form.
        ex = macroexpand(@__MODULE__, :(HyperSignal.@using_tags))
        @test ex.head == :using
        inner = ex.args[1]
        @test inner.head == :(:)
        modref = inner.args[1]
        names = [a.args[1] for a in inner.args[2:end]]
        @test modref.args[1] == :HyperSignal
        @test :div in names
        @test :select in names
        @test :summary in names
        @test :mark in names
        @test :time in names
    end

    @testset "patch_svg strips XML prolog and DOCTYPE so HTML parsing isn't broken" begin
        # Why: CairoMakie writes full XML document; prologs are invalid inside HTML page
        # and trip parser.
        src = """<?xml version="1.0" encoding="UTF-8"?>
                 <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x.dtd">
                 <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><g/></svg>"""
        out = patch_svg(src)
        @test !occursin("<?xml", out)
        @test !occursin("<!DOCTYPE", out)
        @test startswith(out, "<svg")
    end

    @testset "patch_svg strips HTML comments anywhere in the document" begin
        # Why: backends emit generator-note comments that add bytes without affecting
        # figure. Prolog pass folds comment removal into same walk; pin that
        # mid-document comments drop, not just leading one.
        out = patch_svg("""<svg viewBox="0 0 1 1"><!-- gen note --><g><!-- inner --><rect/></g></svg>""")
        @test !occursin("<!--", out)
        @test occursin("<svg viewBox=\"0 0 1 1\"><g><rect/></g></svg>", out)
    end

    @testset "patch_svg strips width/height by default for responsive embedding" begin
        src = """<svg xmlns="http://www.w3.org/2000/svg" width="400px" height="300px" viewBox="0 0 4 3"><g/></svg>"""
        out = patch_svg(src)
        @test !occursin("width=", out)
        @test !occursin("height=", out)
        @test occursin("viewBox=\"0 0 4 3\"", out)
    end

    @testset "patch_svg keeps width/height when strip_size=false" begin
        src = """<svg width="400" height="300" viewBox="0 0 4 3"><g/></svg>"""
        out = patch_svg(src; strip_size=false)
        @test occursin("width=\"400\"", out)
        @test occursin("height=\"300\"", out)
    end

    @testset "patch_svg namespaces ids, url(#…), and href fragments" begin
        # Why: two CairoMakie figures on one page collide on `clip0`/`glyph0`; prefix
        # scopes them.
        src = """<svg viewBox="0 0 1 1"><defs><clipPath id="clip0"><rect/></clipPath></defs><g clip-path="url(#clip0)"><use xlink:href="#glyph0"/><use href="#g1"/></g></svg>"""
        out = patch_svg(src; id_prefix="fig1_")
        @test occursin("id=\"fig1_clip0\"", out)
        @test occursin("url(#fig1_clip0)", out)
        @test occursin("xlink:href=\"#fig1_glyph0\"", out)
        @test occursin("href=\"#fig1_g1\"", out)
        @test !occursin("xlink:href=\"#fig1_fig1_", out)
    end

    @testset "patch_svg id namespacing leaves *-id / xml:id attributes alone" begin
        # Why: id matcher anchors on name-char boundary, not bare \b;
        # `data-id`/`xml:id`/`aria-id` are NOT SVG `id` and keep values verbatim under
        # id_prefix.
        src = """<svg viewBox="0 0 1 1"><rect data-id="keep" xml:id="x" id="real"/></svg>"""
        out = patch_svg(src; id_prefix="p_")
        @test occursin("data-id=\"keep\"", out)
        @test occursin("xml:id=\"x\"", out)
        @test occursin("id=\"p_real\"", out)
    end

    @testset "patch_svg id_prefix containing \$ or \\ is treated literally, not as a backreference" begin
        # Why: renamespacing uses SubstitutionString, which reads `\1`/`$1` as
        # backreferences if caller's prefix passes verbatim; prefixes derived from
        # session id/hash easily contain `$`. Must land as text.
        src = """<svg><defs><clipPath id="c0"><rect/></clipPath></defs><g clip-path="url(#c0)"/></svg>"""
        out = patch_svg(src; id_prefix="\$ses1_")
        @test occursin("id=\"\$ses1_c0\"", out)
        @test occursin("url(#\$ses1_c0)", out)
        out2 = patch_svg(src; id_prefix="a\\b_")
        @test occursin("id=\"a\\b_c0\"", out2)
        @test occursin("url(#a\\b_c0)", out2)
    end

    @testset "patch_svg leaves non-fragment href values alone" begin
        src = """<svg viewBox="0 0 1 1"><a href="https://example.com"><text>x</text></a></svg>"""
        out = patch_svg(src; id_prefix="p_")
        @test occursin("href=\"https://example.com\"", out)
    end

    @testset "patch_svg adds aria-label + role for screen readers" begin
        src = """<svg viewBox="0 0 1 1"><g/></svg>"""
        out = patch_svg(src; aria_label="Sales by quarter")
        @test occursin("role=\"img\"", out)
        @test occursin("aria-label=\"Sales by quarter\"", out)
    end

    @testset "patch_svg escapes aria-label so user-supplied text is safe" begin
        src = """<svg viewBox="0 0 1 1"><g/></svg>"""
        out = patch_svg(src; aria_label="A & B \"quoted\"")
        @test occursin("aria-label=\"A &amp; B &quot;quoted&quot;\"", out)
    end

    @testset "patch_svg merges add_class with an existing root class" begin
        src1 = """<svg viewBox="0 0 1 1"><g/></svg>"""
        out1 = patch_svg(src1; add_class="figure")
        @test occursin("class=\"figure\"", out1)
        src2 = """<svg class="base" viewBox="0 0 1 1"><g/></svg>"""
        out2 = patch_svg(src2; add_class="figure")
        @test occursin("class=\"base figure\"", out2)
    end

    @testset "patch_svg escapes add_class so it can't inject root-tag attributes" begin
        # Why: add_class lands inside quoted class attribute of root <svg>; unescaped
        # `"` closes it and lets crafted value inject attributes (e.g. onload),
        # symmetric with aria_label escape.
        out = patch_svg("""<svg viewBox="0 0 1 1"><g/></svg>""";
                        add_class="x\" onload=\"alert(1)")
        @test !occursin("onload=\"", out)
        @test occursin("class=\"x&quot; onload=&quot;alert(1)\"", out)
        @test occursin("class=\"a&lt;b\"",
                       patch_svg("""<svg viewBox="0 0 1 1"><g/></svg>"""; add_class="a<b"))
        @test occursin("class=\"base x&quot;y\"",
                       patch_svg("""<svg class="base" viewBox="0 0 1 1"><g/></svg>""";
                                 add_class="x\"y"))
    end

    @testset "patch_svg resumes correctly past a multi-byte char in the root tag" begin
        # Why: _patch_root_svg rebuilds opening <svg …> tag and splices rest back.
        # Resume offset must be in BYTES (string is byte-indexed); character count lands
        # short of tag end when root tag holds multi-byte UTF-8, re-emitting trailing
        # '>' and corrupting markup.
        src = """<svg data-title="Café résumé" viewBox="0 0 1 1"><g/></svg>"""
        out = patch_svg(src; add_class="figure")
        @test occursin("class=\"figure\"", out)
        @test occursin("class=\"figure\"><g/>", out)
        @test !occursin(">>", out)
        @test occursin("data-title=\"Café résumé\"", out)
        out2 = patch_svg("""<svg título="Olá" viewBox="0 0 1 1"><rect/><g/></svg>""";
                         aria_label="Açaí")
        @test occursin("role=\"img\"", out2)
        @test occursin("<rect/><g/></svg>", out2)
        @test !occursin(">>", out2)
    end

    @testset "inline_svg wraps a patched SVG as Raw so it inlines into a tree" begin
        src = """<?xml version="1.0"?><svg viewBox="0 0 1 1"><g/></svg>"""
        node = inline_svg(src; id_prefix="x_")
        @test node isa Raw
        out = render(div(class="plot", node))
        @test occursin("<div class=\"plot\"><svg", out)
        @test !occursin("<?xml", out)
    end

    @testset "Expanded HTML5 tag set renders correctly" begin
        # Why: Aqua-style export test only confirms names resolve; behavioral spot-check
        # pins emitted shape for most user-facing new tags.
        @test render(blockquote(p("Quoted"))) == "<blockquote><p>Quoted</p></blockquote>"
        @test render(audio(src="x.mp3", controls=true)) == "<audio src=\"x.mp3\" controls></audio>"
        @test render(iframe(src="https://e.com", "fallback")) ==
              "<iframe src=\"https://e.com\">fallback</iframe>"
        @test render(kbd("Ctrl+C")) == "<kbd>Ctrl+C</kbd>"
        @test render(b("bold")) == "<b>bold</b>"
        @test render(i("italic")) == "<i>italic</i>"
        @test render(sub("2")) == "<sub>2</sub>"
        @test render(sup("3")) == "<sup>3</sup>"
        @test render(wbr()) == "<wbr>"
        @test render(caption("Table")) == "<caption>Table</caption>"
        @test render(meter(value="0.7", "70%")) == "<meter value=\"0.7\">70%</meter>"
        @test render(HyperSignal.mark("hi")) == "<mark>hi</mark>"
        @test render(HyperSignal.time(datetime="2026-05-23", "today")) ==
              "<time datetime=\"2026-05-23\">today</time>"
        out = render(svg(viewBox="0 0 10 10", rect(width="10", height="10"), circle(cx="5", cy="5", r="3")))
        @test occursin("<svg viewBox=\"0 0 10 10\">", out)
        @test occursin("<rect", out)
        @test occursin("<circle", out)
    end

    @testset "Generators nested inside collections render via iteration" begin
        # Why: construction-time generator-unpack handles only top-level positional
        # args; Generator nested in Vector (`div([gen1, gen2])`) would MethodError at
        # render. Render-side method walks them once.
        out = render(div([(p(i) for i in 1:2), (p(i) for i in 3:4)]))
        @test out == "<div><p>1</p><p>2</p><p>3</p><p>4</p></div>"
        @test render(p(i) for i in 1:3) == "<p>1</p><p>2</p><p>3</p>"
    end

    @testset "Generator-of-children unpacks (and is re-renderable)" begin
        # Why: `div(p(i) for i in 1:n)` is the natural form for a list of children;
        # consume eagerly into children vector so element re-renders (generators are
        # single-pass).
        el = div(p(i) for i in 1:3)
        @test render(el) == "<div><p>1</p><p>2</p><p>3</p></div>"
        @test render(el) == "<div><p>1</p><p>2</p><p>3</p></div>"
        @test render(div(p(i) for i in 1:0)) == "<div></div>"
        @test render(div(i % 2 == 0 ? nothing : p(i) for i in 1:4)) ==
              "<div><p>1</p><p>3</p></div>"
    end

    @testset "Tuple-of-children unpacks like a Vector at construction" begin
        # Why: children arrive in tuples (destructure target, splat-receiver,
        # heterogeneously-typed comprehension); unpack like Vector, else render(::Tuple)
        # MethodErrors.
        @test render(div((span("a"), span("b")))) == "<div><span>a</span><span>b</span></div>"
        @test render(div(("hello", " ", "world"))) == "<div>hello world</div>"
        @test render(div(("x", nothing, h2("y"), 7))) == "<div>x<h2>y</h2>7</div>"
        @test render(div((), "a")) == "<div>a</div>"
    end

    @testset "Symbol children render as their text (auto-escaped)" begin
        # Why: status enums (`span(:Pending)`) are common; callers shouldn't string()
        # model fields. Symbol bytes get same escaping as String.
        @test render(span(:Pending)) == "<span>Pending</span>"
        @test render(div(:foo, " ", :bar)) == "<div>foo bar</div>"
        @test render(div(Symbol("a<b"))) == "<div>a&lt;b</div>"
    end

    @testset "Bool children are skipped so cond && elem renders conditionally" begin
        # Why: `cond && extra` evaluates to bare false when falsy and Number dispatch
        # would emit literal text 'false'; Bool children join nothing/missing skip
        # bucket.
        @test render(div("a", false, "b")) == "<div>ab</div>"
        @test render(div("a", true, "b")) == "<div>ab</div>"
        show_extra = false
        @test render(div("a", show_extra && span("extra"), "b")) == "<div>ab</div>"
        show_extra = true
        @test render(div("a", show_extra && span("extra"), "b")) ==
              "<div>a<span>extra</span>b</div>"
        @test render(div(string(true))) == "<div>true</div>"
    end

    @testset "Vector attribute values are space-joined (class-list semantics)" begin
        # Why: `class=["btn", "primary"]` is natural class-list form; aria-describedby /
        # aria-labelledby take space-separated ids.
        @test render(div(class=["btn", "primary"], "x")) == "<div class=\"btn primary\">x</div>"
        @test render(input(type="text", "aria-describedby" => ["hint1", "hint2"])) ==
              "<input type=\"text\" aria-describedby=\"hint1 hint2\">"
        @test render(div(class=["btn", nothing, "active", missing, ""])) ==
              "<div class=\"btn active\"></div>"
        # Why: `cond && "active"` evaluates to `false` when cond false; drop
        # `false`/`true` so idiom works without stringifying bool.
        @test render(div(class=["btn", false, "primary", true])) ==
              "<div class=\"btn primary\"></div>"
        is_active = false
        @test render(div(class=["btn", is_active && "active", "default"])) ==
              "<div class=\"btn default\"></div>"
        @test render(div(:rowspan => [2, 3])) == "<div rowspan=\"2 3\"></div>"
        # Why: empty vector still emits empty value; attr name was passed (user opted
        # in).
        @test render(div(class=String[], "x")) == "<div class=\"\">x</div>"
        @test render(div(class=("btn", "primary"), "x")) ==
              "<div class=\"btn primary\">x</div>"
        @test render(div(class=("btn", nothing, false, "active"))) ==
              "<div class=\"btn active\"></div>"
        @test render(div(class=())) == "<div class=\"\"></div>"
    end

    @testset "string(::DSAction) returns the JS expression, not a struct dump" begin
        # Why: symmetric with Element/Frag/Raw; `string()` gives what lib puts in page,
        # not internal record (log lines, error messages, REPL).
        @test string(ds_post("/api/save")) == "@post('/api/save')"
        @test string(ds_get("/c"; form=true)) == "@get('/c', {contentType: 'form'})"
        @test "$(ds_post("/x"))" == "@post('/x')"
    end

    @testset "String-keyed Pair args are accepted as attributes (auto-symbolize)" begin
        # Why: String-keyed Pairs are unambiguous as attributes (nobody passes a Pair as
        # text content); `"data-foo" => v` beats `Symbol("data-foo") => v`.
        @test render(div("id" => "card", "x")) == "<div id=\"card\">x</div>"
        @test render(span("data-x" => "v")) == "<span data-x=\"v\"></span>"
        @test_throws ArgumentError render(div("x onerror=1" => "v"))
        @test render(div(:id => "card", "data-x" => "v", "x")) ==
              "<div id=\"card\" data-x=\"v\">x</div>"
    end

    @testset "duplicate attribute names collapse with the last value winning" begin
        # Why: HTML5 parser keeps FIRST duplicate attribute (§13.2.5.33), so `class="a"
        # class="b"` silently applies "a". Caller setting attribute twice means later
        # overrides (base then computed); collapse at construction, last value wins,
        # each name emitted once.
        @test render(div("class" => "later", class="earlier")) ==
              "<div class=\"later\"></div>"
        @test render(button(on_click("x"), on_click("y"))) ==
              "<button data-on:click=\"y\"></button>"
        @test render(div(:a => "1", :b => "2", :a => "3")) ==
              "<div a=\"3\" b=\"2\"></div>"
        @test render(form(on_submit("a"), on_submit("b"))) ==
              "<form data-on:submit__prevent=\"b\"></form>"
        @test render(div(class="a", id="b", "data-x" => "y")) ==
              "<div class=\"a\" id=\"b\" data-x=\"y\"></div>"
    end

    @testset "cls rejects non-collection scalars cleanly (no stack overflow)" begin
        # Why: Number is a 1-iterable (yields itself), so an Any iterator fallback made
        # `cls("a", 1)` recurse forever; iterate real collections only, error otherwise.
        @test_throws ArgumentError cls("a", 1)
        @test_throws ArgumentError cls("a", 3.14)
        @test_throws ArgumentError cls("a", :symbol_input)
        @test cls("a", ["b", "c"]) == "a b c"
        @test cls("a", ("b", "c")) == "a b c"
        @test cls("a", Set(["b"])) == "a b"
    end

    @testset "tag names that would break the HTML parser raise ArgumentError" begin
        # Why: Element(Symbol(...), ...) is the escape hatch for runtime-chosen tags;
        # unvalidated `Symbol("<script>")` would emit literal '<' and '>' into open tag,
        # breaking parsing or smuggling markup. Reject same parser-breaking subset as
        # attribute names.
        for bad in ["<script>", "div onerror=x", "tag>injected",
                    "with space", "tag\"x", "tag\0x", ""]
            @test_throws ArgumentError render(Element(Symbol(bad), Pair{Symbol,Any}[], Any[]))
        end
        for ok in ["my-element", "svg:circle", "x-tag123"]
            out = render(Element(Symbol(ok), Pair{Symbol,Any}[], Any["x"]))
            @test occursin("<$ok>x</$ok>", out)
        end
    end

    @testset "attribute names that would break the HTML parser raise ArgumentError" begin
        # Why: legal Datastar attr names fit [A-Za-z0-9:_.-]+, well inside HTML5
        # grammar; Symbol-keyed Pair API accepts any Symbol, so hostile event name from
        # user input could inject markup.
        for bad in [
            "x onerror=alert(1)",
            "x>injected",
            "x=\"y\"",
            "x'y",
            "x\"y",
            "x\ty",
            "x\ny",
            "x/y",
            "x\0y",
        ]
            @test_throws ArgumentError render(div(Symbol(bad) => "v"))
        end
        for ok in ["data-on:click__prevent", "data-on-interval__duration.5000ms",
                   "aria-label", "xlink:href"]
            @test occursin(ok, render(span(Symbol(ok) => "v")))
        end
    end

    @testset "package sanity: no method ambiguities or unbound-arg generics" begin
        # Why: ambiguities creep in silently (Base.show on struct overlapping an
        # AbstractDisplay path, Vector{T} dispatch crossing Vector{S}). Without Aqua
        # dep, Base.detect_ambiguities catches common case; recursive=false skips
        # Base/loaded modules to keep noise down.
        ambs = Test.detect_ambiguities(HyperSignal; recursive=false)
        @test isempty(ambs)
        # Why: unbound type parameters surface as MethodErrors only on specific call
        # shapes; static detection is cheaper.
        unbounds = Test.detect_unbound_args(HyperSignal; recursive=false)
        @test isempty(unbounds)
    end

    @testset "package sanity: every export resolves to a defined binding" begin
        # Why: typo in `export` lists (or renamed helper with stale export) only fires
        # at `using HyperSignal: <name>` on a consumer machine, too late. Assert each
        # exported name is defined.
        for name in names(HyperSignal)
            name === :HyperSignal && continue
            @test isdefined(HyperSignal, name)
        end
    end

    @testset "Vector{UInt8} renders as a verbatim byte buffer, not per-byte numbers" begin
        # Why: generic AbstractVector path would emit each UInt8 as decimal number;
        # common case is pre-rendered, possibly cached HTML body, written verbatim.
        bytes = Vector{UInt8}("<b>hi</b>")
        @test render(bytes) == "<b>hi</b>"
        # Why: bytes bypass auto-escape by design, mirroring `Raw`'s trust model.
        @test render(Vector{UInt8}("<>&")) == "<>&"
        @test render(Vector{UInt8}()) == ""
        # Why: byte buffer as element child stays whole, not unpacked into per-byte
        # Number children; cached pre-rendered fragments sit between ordinary children.
        @test render(div(class="card", "x", Vector{UInt8}("<i>cached</i>"), "y")) ==
              "<div class=\"card\">x<i>cached</i>y</div>"
    end

    @testset "SubString of String escapes correctly via the codeunit fast path" begin
        # Why: SubString{String} results from any slice/interpolation; must walk parent
        # buffer correctly and match String output.
        base = "ab<c&d>ef\"gh'ij"
        sub = SubString(base, 2, 14)
        @test render(sub) == "b&lt;c&amp;d&gt;ef&quot;gh&#39;i"
        @test render(SubString("hello world", 1, 5)) == "hello"
        @test render(SubString("xyz", 1, 0)) == ""
        # Why: slice must respect offset, not bleed into parent bytes outside the view.
        @test render(SubString("XX<&>YY", 3, 5)) == "&lt;&amp;&gt;"
        # Why: "é" is 0xc3 0xa9 in parent; offset must land on codepoint boundary.
        # `"a<é>b"` byte indices: a=1, <=2, é=3..4, >=5, b=6, so 2..5 is the slice.
        @test render(SubString("a<é>b", 2, 5)) == "&lt;é&gt;"
    end

    @testset "Base.show(MIME\"text/plain\", ::Raw) shows the raw HTML at the REPL" begin
        # Why: without this method, REPL-displaying DOCTYPE or Raw falls back to struct
        # dump.
        io = IOBuffer()
        show(io, MIME"text/plain"(), Raw("<svg/>"))
        @test occursin("HyperSignal.Raw:", String(take!(io)))
        seekstart(io); truncate(io, 0)
        show(io, MIME"text/plain"(), DOCTYPE)
        @test occursin("HyperSignal.Raw: <!DOCTYPE html>", String(take!(io)))
    end

    @testset "parse_signals raises a labeled ArgumentError on malformed JSON" begin
        # Why: JSON.jl's message doesn't name parse_signals, so service log shows bare
        # `ArgumentError: Expected …` with no hint that request body was the culprit.
        # Wrapper prefixes parse_signals and body snippet.
        try
            parse_signals("{not json}")
            @test false
        catch err
            @test err isa ArgumentError
            @test occursin("parse_signals", err.msg)
            @test occursin("{not json}", err.msg)
        end
    end

    @testset "missing attribute value is omitted, mirroring nothing semantics" begin
        # Why: `value = optional_string()` (may return missing on DB nulls) flows into
        # attr position without coalesce; symmetric with `missing` children omitted.
        @test render(input(type="text", value=missing)) == "<input type=\"text\">"
        @test render(div(class=missing, "x")) == "<div>x</div>"
    end

    @testset "parse_signals reads JSON body from a plain IO too" begin
        # Why: pipelined services (e.g. gzip-decoded IOBuffer) may not hold a
        # Vector{UInt8}; same JSON via three input shapes.
        json = """{"count": 3, "name": "ok"}"""
        d_str   = parse_signals(json)
        d_bytes = parse_signals(Vector{UInt8}(json))
        d_io    = parse_signals(IOBuffer(json))
        @test d_str == d_bytes == d_io == Dict{String, Any}("count" => 3, "name" => "ok")
        @test parse_signals(IOBuffer("")) == Dict{String, Any}()
    end

    @testset "ds_post extras: string values are JS-escaped against \\, ', </script>" begin
        # Why: `extras` value with backslash or </script> would corrupt JS string;
        # </script> in inline-script context lets HTML parser close wrapping <script>.
        a = ds_post("/x"; note="he said: 'hi' \\path </script>")
        out = render(button("Save", on_click(a)))
        @test occursin("note: 'he said: \\&#39;hi\\&#39; \\\\path &lt;\\/script&gt;'", out) ||
              occursin("note: 'he said: \\'hi\\' \\\\path <\\/script>'",
                        HyperSignal.action_js(a))
        js = HyperSignal.action_js(a)
        @test occursin("\\\\path", js)
        @test occursin("\\'hi\\'", js)
        @test occursin("<\\/script>", js)
    end

    @testset "action_js: the URL is JS-escaped just like extras values" begin
        # Why: URL lands in same single-quoted JS string as extras; raw `'` (e.g.
        # `?q=it's`) closes it early and breaks action. Escape is transparent to fetched
        # URL: `\'` parses back to `'`, `<\/` to `</`.
        @test HyperSignal.action_js(ds_get("/search?q=it's")) ==
              "@get('/search?q=it\\'s')"
        # Why: </script> in URL is broken same way as extras, so action survives
        # inline-<script> context (e.g. script_response).
        @test HyperSignal.action_js(ds_get("/a</script>")) == "@get('/a<\\/script>')"
        @test HyperSignal.action_js(ds_post("/a\\b")) == "@post('/a\\\\b')"
        @test HyperSignal.action_js(ds_get("/api/refresh")) == "@get('/api/refresh')"
        @test HyperSignal.action_js(ds_post("/session/new"; form=true)) ==
              "@post('/session/new', {contentType: 'form'})"
        out = render(button("Go", on_click(ds_get("/search?q=it's"))))
        @test occursin("@get(&#39;/search?q=it\\&#39;s&#39;)", out)
    end

    @testset "action_js: JS line terminators in URL/extras are escaped, not emitted raw" begin
        # Why: raw LF/CR (or U+2028/U+2029) in single-quoted JS string is ECMAScript
        # SyntaxError; whole Datastar action silently fails to compile. They reach URL
        # via reflected query params / multi-line search boxes. JS escapes round-trip to
        # same character, so fetched URL is unchanged. \u2028/\u2029 written as escapes
        # since literals are invisible.
        @test HyperSignal.action_js(ds_get("/s?q=a\nb")) == "@get('/s?q=a\\nb')"
        @test HyperSignal.action_js(ds_get("/s?q=a\rb")) == "@get('/s?q=a\\rb')"
        @test HyperSignal.action_js(ds_get("/s?q=a\u2028b")) == "@get('/s?q=a\\u2028b')"
        @test HyperSignal.action_js(ds_get("/s?q=a\u2029b")) == "@get('/s?q=a\\u2029b')"
        # Why: backslash then real newline must not double-decode; backslash doubles, LF
        # escapes independently.
        @test HyperSignal.action_js(ds_get("/x\\\ny")) == "@get('/x\\\\\\ny')"
        # Why: redirect path shares _js_str_escape (response.jl); newline in location
        # must not land raw in inline <script>.
        let body = String(redirect_via_fragment("#x", "/a\nb").body)
            @test occursin("window.location='/a\\nb'", body)
            @test !occursin("'/a\nb'", body)
        end
    end

    @testset "ds_post extras: structured values serialize as JSON object/array literals" begin
        # Why: `headers`/`filterSignals` are objects; Julia `repr` of Dict/NamedTuple
        # isn't valid JS (`Dict("a"=>"b")` → "Dict{...}(...)"), JSON gives valid object
        # literals. JSON's double quotes round-trip through attribute escape as &quot;.
        @test HyperSignal.action_js(ds_post("/x"; headers=Dict("X-Csrf" => "abc"))) ==
              "@post('/x', {headers: {\"X-Csrf\":\"abc\"}})"
        # Why: NamedTuple keeps field order; multi-key Dict is not deterministic.
        @test HyperSignal.action_js(ds_post("/x"; filterSignals=(include="^foo",))) ==
              "@post('/x', {filterSignals: {\"include\":\"^foo\"}})"
        @test HyperSignal.action_js(ds_get("/x"; ids=[1, 2, 3])) == "@get('/x', {ids: [1,2,3]})"
        # Why: any AbstractString quotes, not just String; SubString (from split/match)
        # would fall through to `string(v)` unquoted.
        @test HyperSignal.action_js(ds_get("/x"; tag=SubString("a'b", 1, 3))) ==
              "@get('/x', {tag: 'a\\'b'})"
        out = render(button("Go", on_click(ds_post("/x"; headers=Dict("X-Csrf" => "abc")))))
        @test occursin("headers: {&quot;X-Csrf&quot;:&quot;abc&quot;}", out)
    end

    @testset "ds_post extras: non-finite floats render as JS globals, not Julia's Inf" begin
        # Why: `string(Inf)`/`string(-Inf)` give `Inf`/`-Inf`, a JS ReferenceError;
        # `Infinity`/`-Infinity`/`NaN` are valid JS. Options like retryMaxCount make
        # Infinity natural (unlimited retries).
        @test HyperSignal.action_js(ds_post("/x"; retryMaxCount=Inf)) ==
              "@post('/x', {retryMaxCount: Infinity})"
        @test HyperSignal.action_js(ds_post("/x"; t=-Inf)) == "@post('/x', {t: -Infinity})"
        @test HyperSignal.action_js(ds_post("/x"; t=NaN)) == "@post('/x', {t: NaN})"
        @test HyperSignal.action_js(ds_post("/x"; t=1.5)) == "@post('/x', {t: 1.5})"
    end

    @testset "stress: 5000-deep nesting renders without stack overflow" begin
        # Why: render() recurses on children; 5000-deep nesting proves recursion bound
        # far exceeds real pages (~50 deep).
        node = "leaf"
        for _ in 1:5000
            node = div(node)
        end
        out = render(node)
        @test count("<div>", out) == 5000
        @test count("</div>", out) == 5000
        @test occursin(">leaf<", out)
    end

    @testset "stress: 2000-attribute element survives" begin
        # Why: generated forms can reach hundreds of attrs (one ds_attr per dynamic
        # field); render must stay linear in attr count.
        kw = (; (Symbol("data-x-$i") => "v$i" for i in 1:2000)...)
        el = div(; kw...)
        out = render(el)
        @test occursin("data-x-1=\"v1\"", out)
        @test occursin("data-x-2000=\"v2000\"", out)
    end

    @testset "stress: patch_svg on 1 MB synthetic input stays sub-second" begin
        # Why: CairoMakie figure with many marks hits a few hundred KB; 1 MB is past
        # realistic, proves regex passes don't blow up super-linearly.
        io = IOBuffer()
        print(io, """<svg viewBox="0 0 1 1"><defs>""")
        for i in 0:5000
            print(io, """<clipPath id="clip$i"><rect/></clipPath>""")
        end
        print(io, "</defs>")
        for i in 0:5000
            print(io, """<g clip-path="url(#clip$i)"><use href="#g$i"/></g>""")
        end
        print(io, "</svg>")
        big = String(take!(io))
        @test sizeof(big) > 400_000
        t = @elapsed out = patch_svg(big; id_prefix="p_")
        @test t < 2.0
        @test occursin("id=\"p_clip0\"", out)
        @test occursin("url(#p_clip5000)", out)
        @test !occursin("<?xml", out)
    end

    @testset "stress: 10k metacharacter escape round-trips byte-stable" begin
        # Why: codeunit fast path in escape_html is where an HTML-safety regression
        # would land silently; pin byte-stable output on known-bad input so
        # micro-optimizations keep escape semantics exact.
        text = repeat("<&>\"' \xc3\xa9 ", 1000)
        out = render(text)
        @test count("&lt;", out) == 1000
        @test count("&amp;", out) == 1000
        @test count("&gt;", out) == 1000
        @test count("&quot;", out) == 1000
        @test count("&#39;", out) == 1000
        @test occursin("é", out)
        @test !occursin("<", out)
        @test !occursin(">", out)
    end

    @testset "string(::Element)/print(io, ::Element) returns the rendered HTML" begin
        # Why: without 1-arg Base.show, `string(el)` and interpolation fall back to
        # struct dump.
        el = div(class="card", "hi")
        @test string(el) == "<div class=\"card\">hi</div>"
        @test "$(el)" == render(el)
        @test sprint(print, el) == render(el)
        @test sprint(print, Frag(p("a"), p("b"))) == "<p>a</p><p>b</p>"
        @test sprint(print, Raw("<b>x</b>")) == "<b>x</b>"
        @test sprint(show, [p("a"), p("b")]) == "Element[<p>a</p>, <p>b</p>]"
    end

    @testset "Base.show(MIME\"text/html\") returns the rendered HTML for notebooks" begin
        # Why: Pluto / IJulia / VS Code display via text/html MIME; without this hook
        # every cell must call `render(...)` explicitly.
        el = div(class="card", h2("Hi"), p("hello"))
        io = IOBuffer()
        show(io, MIME"text/html"(), el)
        @test String(take!(io)) == render(el)

        show(io, MIME"text/html"(), Frag(p("a"), p("b")))
        @test String(take!(io)) == "<p>a</p><p>b</p>"

        show(io, MIME"text/html"(), Raw("<b>x</b>"))
        @test String(take!(io)) == "<b>x</b>"
    end

    @testset "patch_svg with CairoMakie figure renders + namespaces collision-safely" begin
        # Why: end-to-end CairoMakie story: real figures through inline_svg, two in one
        # tree, id prefixes keep them disjoint.
        using CairoMakie
        fig1 = CairoMakie.Figure()
        CairoMakie.lines(fig1[1, 1], 1:5, [1, 3, 2, 4, 3])
        fig2 = CairoMakie.Figure()
        CairoMakie.scatter(fig2[1, 1], 1:5, [2, 1, 3, 1, 2])
        n1 = inline_svg(fig1; id_prefix="a_", aria_label="Lines")
        n2 = inline_svg(fig2; id_prefix="b_", aria_label="Scatter")
        @test n1 isa Raw
        @test n2 isa Raw
        out = render(div(n1, n2))
        @test occursin("aria-label=\"Lines\"", out)
        @test occursin("aria-label=\"Scatter\"", out)
        for m in eachmatch(r"id=\"([^\"]+)\"", out)
            @test startswith(m.captures[1], "a_") || startswith(m.captures[1], "b_")
        end
    end

    @testset "app-grade helpers are NOT exported at the top level" begin
        # Why: a top-level shim or re-export of HyperSignal.Helpers names would silently
        # undo the move.
        for name in (:radio_field, :checkbox_field, :text_field,
                     :help_tooltip, :form_legend, :form_section,
                     :preset_button, :signal_dialog)
            @test !isdefined(HyperSignal, name)
            @test isdefined(HyperSignal.Helpers, name)
        end
    end

    include("escape_conformance.jl")

    @testset "no type piracy or @generated+hasmethod under src/ and ext/" begin
        # Why: Hyperscript broke on Julia 1.6 from `Vector{Node}` piracy;
        # HypertextLiteral broke on 1.10 from `@generated` + `hasmethod`. Both bans live
        # in CONVENTIONS.md → "Out of scope"; this test enforces them.
        roots = [joinpath(pkgdir(HyperSignal), "src"),
                 joinpath(pkgdir(HyperSignal), "ext")]
        offenders_generated = String[]
        offenders_piracy = String[]
        owned = Set(["Element", "Frag", "Raw", "Attribute", "DSAction", "DSExpr"])

        for root in roots
            isdir(root) || continue
            for (dir, _, files) in walkdir(root)
                for f in files
                    endswith(f, ".jl") || continue
                    path = joinpath(dir, f)
                    for (lineno, line) in enumerate(eachline(path))
                        # Why: strip line comments so CONVENTIONS reference in
                        # elements.jl doesn't self-flag.
                        code = first(split(line, '#'; limit=2))
                        if occursin(r"\b(@generated|hasmethod)\b", code)
                            push!(offenders_generated, "$path:$lineno: $line")
                        end
                        # Why: `Base.<name>(...)` definition is pirate unless an
                        # argument type *terminates* in an owned name; require `::T` to
                        # equal an owned name exactly, since substring match would
                        # whitelist `Base.push!(::Vector{Element}, ...)` via
                        # `::Element`.
                        if occursin(r"\bBase\.[A-Za-z_][A-Za-z0-9_!]*\s*\(", code)
                            ann_types = [String(m.captures[1])
                                         for m in eachmatch(
                                             r"::\s*([A-Za-z_][A-Za-z0-9_]*)\b",
                                             code)]
                            if !any(t -> t in owned, ann_types)
                                push!(offenders_piracy, "$path:$lineno: $line")
                            end
                        end
                    end
                end
            end
        end
        @test isempty(offenders_generated)
        @test isempty(offenders_piracy)
        isempty(offenders_generated) || (@info "@generated/hasmethod offenders" offenders_generated)
        isempty(offenders_piracy) || (@info "type-piracy offenders" offenders_piracy)
    end
end
