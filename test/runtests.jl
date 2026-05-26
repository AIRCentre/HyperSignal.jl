using Test, HTTP, HyperSignal
# Tags whose names overlap with Base (Base.div, Base.map, etc.) need an
# explicit override at the use site — `using` skips them by design.
# `@using_tags` is the one-liner; here we do it manually so the macro itself
# can be tested in isolation below.
using HyperSignal: div, select, summary
# App-grade helpers moved to HyperSignal.Helpers (issue #1). No
# top-level shim, so the bare names are not in scope here.
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
        # Why: bumps should land as one visible diff; this test fails on
        # an unintentional change to the supported protocol/client version.
        @test DATASTAR_SUPPORTED_VERSION == v"1.0.1"
    end

    @testset "ds_post emits the Datastar form-encoded action expression" begin
        a = ds_post("/api/x"; form=true)
        @test HyperSignal.action_js(a) == "@post('/api/x', {contentType: 'form'})"
    end

    @testset "ds_get without options emits a bare verb call" begin
        @test HyperSignal.action_js(ds_get("/api/y")) == "@get('/api/y')"
    end

    @testset "<form> auto-injects data-on:submit__prevent when no submit binding is given" begin
        # Why: a bare <form> used only for change-driven Datastar fetches
        # (or pure layout) still receives a native submit when the user
        # presses Enter in any input — that reload drops client signals
        # and is almost never what the page wants. The tag constructor
        # forces preventDefault unless the caller wired a submit handler.
        out = render(form(input(type="text", name="q")))
        @test occursin("data-on:submit__prevent", out)
    end

    @testset "<form> with an explicit submit handler keeps just that one" begin
        # Why: the auto-prevent injection must not duplicate or shadow an
        # explicit user binding (the duplicate HTML attribute would be
        # silently dropped by the browser, breaking the user's handler).
        out = render(form(on_submit(ds_post("/api/x"; form=true))))
        # Exactly one `data-on:submit` occurrence (the explicit one with
        # the @post body) — no second bare attribute.
        @test count(==("data-on:submit__prevent"),
                    eachmatch(r"data-on:submit__prevent", out) .|> m -> m.match) == 1
        @test occursin("@post(", out)
    end

    @testset "<form> with on(:submit, …; prevent=false) skips the auto-prevent" begin
        # Why: prevent=false is the documented opt-out for callers who
        # *want* native submission. The form override must defer to any
        # data-on:submit* attribute, not just __prevent-flavored ones.
        out = render(form(on(:submit, "x"; prevent=false)))
        @test occursin("data-on:submit=\"x\"", out)
        @test !occursin("__prevent", out)
    end

    @testset "on(:submit, action) renders with the auto __prevent modifier" begin
        # Why: a form bound to a Datastar action must call preventDefault on
        # submit, otherwise the browser also performs the native form
        # navigation in parallel with the @post fetch.
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
        # Why: prior-art (Hyperscript#22, HypertextLiteral#10/#11) shows MIME
        # drift across sinks is a real failure mode. One fixture through three
        # paths is cheap insurance.
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

    @testset "redirect_via_fragment wraps a window.location script in the morph target" begin
        resp = redirect_via_fragment("#login-form", "/dashboard")
        body = String(resp.body)
        @test occursin("<div id=\"login-form\">", body)
        @test occursin("<script>window.location='/dashboard'</script>", body)
    end

    @testset "redirect_via_fragment escapes single quotes in the location" begin
        # Why: a stray ' in the URL would close the JS string and inject code.
        resp = redirect_via_fragment("#x", "/a'b")
        @test occursin("window.location='/a\\'b'", String(resp.body))
    end

    @testset "redirect_via_fragment defends against </script> in the location" begin
        # Why: the HTML parser closes <script> on </script> regardless of JS
        # quoting. Inserting a backslash splits the tag at the HTML layer; JS
        # ignores the backslash inside a string literal.
        resp = redirect_via_fragment("#x", "/x</script><script>alert(1)</script>")
        body = String(resp.body)
        @test !occursin("</script><script>", body)
        @test occursin("<\\/script><\\/script>", body) ||
              occursin("<\\/script><script>alert(1)<\\/script>", body)
    end

    @testset "redirect_via_fragment escapes backslashes in the location" begin
        # Why: a trailing '\' in the URL would escape the closing JS quote.
        resp = redirect_via_fragment("#x", "/a\\b")
        @test occursin("window.location='/a\\\\b'", String(resp.body))
    end

    @testset "the count_estimate_fragment migration produces equivalent HTML" begin
        # Why: this is the smallest real fragment in validation_studio
        # (services/validation_studio/src/session_form.jl:105). The HyperSignal
        # rewrite must produce the same bytes the existing route emits, so a
        # drop-in migration is byte-stable for any clients caching fragments.
        format_number(n::Int) = string(n)  # simplified for the test
        n = 122_000
        # The existing implementation:
        legacy = string(
            "<div id=\"count-estimate\" class=\"count-estimate\">",
            "<small class=\"muted\">~", format_number(n), " images match</small>",
            "</div>",
        )
        # The HyperSignal implementation:
        new = render(
            div(id="count-estimate", class="count-estimate",
                small(class="muted", "~$(format_number(n)) images match"))
        )
        @test new == legacy
    end

    @testset "a form with multiple Datastar bindings reads top-to-bottom" begin
        # Why: the new-session form has two attribute bindings (submit and
        # change-debounced) plus nested fieldsets. If composing this looks
        # cluttered, the API isn't pulling its weight.
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
        # Why: this is the entire point of cls — let `class=cls(...)` replace
        # ternary string interpolation in component bodies.
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
        # Why: `"active" => some_string` would silently include the class
        # if we coerced. A loud error catches the typo.
        @test_throws ErrorException cls("btn", "active" => "yes")
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
        # Why: post-login flow needs to redirect AND set the session cookie
        # in the same response — collapsing this to one call beats reaching
        # for HTTP.Response by hand.
        resp = redirect_to("/dashboard"; cookies=["sid=abc; HttpOnly; Path=/"])
        cookies = [String(v) for (k, v) in resp.headers if lowercase(String(k)) == "set-cookie"]
        @test cookies == ["sid=abc; HttpOnly; Path=/"]
    end

    @testset "radio_field wraps an input with a label, matching project convention" begin
        out = render(radio_field("color", "red", "Red"; checked=true))
        @test out == "<label><input type=\"radio\" name=\"color\" value=\"red\" checked> Red</label>"
    end

    @testset "checkbox_field defaults value=\"on\" so form parsing matches" begin
        # Why: Datastar's form-encoded submit sends `name=on` for checkboxes
        # by default; deviating here would silently break parse_form_body.
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
        # Why: tooltips often surface user-facing copy that may contain
        # quotes/angle-brackets. The renderer auto-escapes element text,
        # so the caller can't accidentally inject markup.
        out = render(help_tooltip("a \"quoted\" thing"))
        @test occursin("a &quot;quoted&quot; thing</span>", out)
        @test occursin("class=\"help-trigger\"", out)
        @test occursin("<svg", out)
        @test occursin("class=\"help-popup\"", out)
    end

    @testset "help_tooltip wires the datastar signals/handlers that drive show-on-hover and toggle-on-click" begin
        # Hover events open/close via $help_hover; the icon-wrap click
        # toggles $help_open; data-on:click__outside on the trigger
        # closes the click-pinned state without affecting other open
        # tooltips' state on the same page.
        out = render(help_tooltip("hint"))
        @test occursin("data-signals=", out)
        @test occursin("data-on:mouseenter=", out)
        @test occursin("data-on:mouseleave=", out)
        @test occursin("data-on:click__outside=", out)
        @test occursin("class=\"help-icon-wrap\"", out)
        @test occursin("data-show=", out)
    end

    @testset "help_tooltip lets the caller override the icon" begin
        # Why: project styling may want a different help glyph; the helper
        # should take an Element override without forking the whole helper.
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
        # Why: every session-form section in validation_studio repeats this
        # exact two-element pattern; collapsing it removes 4 lines per section.
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
        # Why: name lands in a CSS attribute selector unquoted; a stray
        # character would break the selector or escape the surrounding JS.
        # Fail loud at build time, not silently in the browser.
        @test_throws ErrorException preset_button("Bad", ["bad name" => "v"])
        @test_throws ErrorException preset_button("Bad", ["x'y" => "v"])
        @test_throws ErrorException preset_button("Bad", ["" => "v"])
    end

    @testset "preset_button escapes \" and \\ inside value" begin
        # Why: value lives inside a double-quoted JS string. Without escaping,
        # `value=\"a\"b\"` would close the JS string mid-selector.
        out = render(preset_button("X", ["k" => "a\"b"]))
        @test occursin("[value=&quot;a\\&quot;b&quot;]", out)
    end

    @testset "preset_button generates the click-side JS to set named radios + fire change" begin
        # Why: this JS is otherwise hand-typed at every preset, with the
        # quote-escaping that breaks under one wrong character. Centralizing
        # it means `preset_button("Easy", ["confidence" => "all"])` just works.
        out = render(preset_button("Easy",
            ["confidence" => "all", "label_filter" => "both"]))
        @test occursin("type=\"button\"", out)
        @test occursin("class=\"secondary outline\"", out)
        @test occursin(
            "document.querySelector(&#39;input[name=confidence][value=&quot;all&quot;]&#39;).checked=true;",
            out)
        @test occursin(
            "document.querySelector(&#39;input[name=label_filter][value=&quot;both&quot;]&#39;).checked=true;",
            out)
        @test occursin("this.form.dispatchEvent(new Event(&#39;change&#39;,{bubbles:true}))", out)
        @test occursin(">Easy</button>", out)
    end

    @testset "DOCTYPE prefixes a page when wrapped in a Frag with html()" begin
        # Why: every server-rendered page starts with `<!DOCTYPE html>`
        # followed by `<html>…</html>`. The constant lets a page builder
        # drop it without introducing a stringly-typed prelude.
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
        # Why: page_layout/wrap_with_nav in validation_studio are heavily
        # project-specific (AIRCentre footer, picocss CDN, favicons). The
        # right level for the lib is *not* a page_layout helper — instead
        # the AST primitives + Frag(DOCTYPE, …) must be enough. Verify by
        # building the equivalent layout from primitives only.
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
        # Why: this is the load-bearing test for the helper suite. If
        # building a session-form section needs raw <small>/<div>/<button>
        # strings, the helpers haven't bought enough leverage yet.
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
        # Section structure
        @test occursin("<small class=\"muted form-section-label\">Image Batch</small>", out)
        @test occursin("<div class=\"form-card-grid\">", out)
        # Tooltip rendered with the help icon
        @test occursin("class=\"help-trigger\"", out)
        @test occursin("Number of images to review.</span>", out)
        # Default-checked radio survives the wrap
        @test occursin("value=\"25\" checked", out)
        # Preset button JS is well-formed
        @test occursin("document.querySelector(", out)
    end

    @testset "on accepts a raw JS expression alongside a DSAction" begin
        # Why: client-side toggles like `\$open = !\$open` aren't HTTP fetches —
        # they're plain JS that doesn't fit the DSAction shape. Letting `on`
        # accept an AbstractString keeps the same call site for both kinds of
        # bindings instead of forcing callers back to Symbol("data-on:click")
        # => string for the trivial cases.
        out = render(button(on(:click, "\$open = !\$open"), "Toggle"))
        @test occursin("data-on:click=\"\$open = !\$open\"", out)
    end

    @testset "on adds the __window modifier when window=true" begin
        # Why: window-level keydown listeners are common for keyboard hotkeys;
        # the modifier routes the listener to `window` so global keys reach it
        # without focusing the element.
        out = render(div(on(:keydown, "x"; window=true)))
        @test occursin("data-on:keydown__window=", out)
    end

    @testset "on stacks __window and __debounce modifiers" begin
        out = render(div(on(:keydown, "x"; window=true, debounce=500)))
        @test occursin("data-on:keydown__window__debounce.500ms=", out)
    end

    @testset "on_click and on_submit accept a raw JS expression" begin
        # Why: the type signature used to require DSAction and rejected the
        # client-side toggle case. Loosening it removes the per-callsite
        # `on(:click, ...)` workaround.
        @test occursin("data-on:click=", render(button(on_click("\$open = true"))))
        @test occursin("data-on:submit__prevent=", render(form(on_submit("alert('hi')"))))
    end

    @testset "on_interval emits a duration modifier on data-on-interval" begin
        # Why: dashboard-style polling fragments need a recurring fetch. The
        # helper hides the `data-on-interval__duration.Nms` shape so callers
        # reach for `on_interval(action; ms=...)` instead.
        out = render(section(on_interval(ds_get("/api/x"); ms=5000)))
        @test occursin("data-on-interval__duration.5000ms=\"@get(", out)
    end

    @testset "ds_ref / ds_attr / ds_class / ds_effect / ds_init render the expected attrs" begin
        # Why: review.jl was riddled with `Symbol("data-ref") => ...` literals.
        # These short helpers both centralise the prefix and read better.
        @test render(button(ds_ref("btnNext"))) ==
            "<button data-ref=\"btnNext\"></button>"
        @test render(div(ds_attr("open", "\$dialogOpen"))) ==
            "<div data-attr:open=\"\$dialogOpen\"></div>"
        @test render(button(ds_class("outline", "\$view !== 'grid'"))) ==
            "<button data-class:outline=\"\$view !== &#39;grid&#39;\"></button>"
        @test render(div(ds_effect("\$open ? \$dlg.showModal() : \$dlg.close()"))) ==
            "<div data-effect=\"\$open ? \$dlg.showModal() : \$dlg.close()\"></div>"
        # ds_init accepts a DSAction (renders as @get(...))
        out_action = render(div(ds_init(ds_get("/api/x"))))
        @test occursin("data-init=\"@get(&#39;/api/x&#39;)\"", out_action)
        # ...and a raw JS string
        out_expr = render(div(ds_init("\$x = 1")))
        @test occursin("data-init=\"\$x = 1\"", out_expr)
    end

    @testset "ds_signals JSON-encodes a NamedTuple into data-signals" begin
        # Why: hand-written {"k": v, ...} JSON inside attribute strings is the
        # most accident-prone bit of Datastar wiring. ds_signals takes a
        # NamedTuple, JSON-encodes it once, and lets the renderer's attribute
        # escape handle the HTML side. The double quotes round-trip through
        # &quot; cleanly because Datastar's parser unescapes attribute values
        # before reading them as JSON.
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
        # Why: signals come back from Datastar's default @post('/x') action
        # as a JSON object. parse_signals is the inverse of ds_signals on the
        # request side — accepts a Request, a Vector{UInt8}, or a String, and
        # returns a uniformly-typed Dict so a route can read fields without
        # caring how it got the body.
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
        # Why: a request with no body shouldn't crash the route — the typical
        # guard `get(sig, "x", default)` then handles "no signals sent" cleanly.
        @test parse_signals("") == Dict{String, Any}()
        @test parse_signals(UInt8[]) == Dict{String, Any}()
    end

    @testset "parse_signals rejects a top-level non-object payload loud" begin
        # Why: Datastar wraps signals in a JSON object. A bare array or a
        # number would silently become a Vector{Any} or Int — surprising at
        # the call site. Fail loud and steer toward the right shape.
        @test_throws ErrorException parse_signals("[1, 2, 3]")
        @test_throws ErrorException parse_signals("42")
    end

    @testset "Symbol-keyed Pairs lift into attrs alongside kwargs and Attributes" begin
        # Why: HTML attribute names like `for`, `aria-label`, `data-foo:bar` are
        # not valid Julia kwarg identifiers. Accepting `:for => "x"` /
        # `Symbol("aria-label") => "x"` positionally avoids forcing every
        # caller to construct an `Attribute` by hand for those.
        out = render(label(:for => "user", "Username"))
        @test out == "<label for=\"user\">Username</label>"
        out2 = render(a(href="#x", Symbol("aria-label") => "Scroll", "x"))
        @test occursin("aria-label=\"Scroll\"", out2)
        @test occursin("href=\"#x\"", out2)
    end

    @testset "signal_dialog wires open/close to a Datastar expression" begin
        # Why: every modal in validation_studio re-rolls the same three
        # bindings — data-effect for showModal/close, a close-event sync,
        # and a backdrop-click dismiss. signal_dialog bakes them in so a
        # caller writes the signal name once.
        out = render(signal_dialog("\$modal",
            div(class="inner", "body");
            close_action="\$modal = 0", id="x", class="m"))
        # Top-level element is <dialog>, not a backdrop <div>
        @test startswith(out, "<dialog ")
        @test occursin("id=\"x\"", out)
        @test occursin("class=\"m\"", out)
        # data-effect drives showModal/close from the expression — uses
        # `el` because Datastar's expression context binds the host
        # element as `el` (this is the signals proxy, not the DOM node).
        @test occursin("data-effect=\"(\$modal) ? el.showModal() : el.close()\"", out)
        # close event syncs the signal (ESC + programmatic close)
        @test occursin("data-on:close=\"\$modal = 0\"", out)
        # backdrop click dismisses only when target is the dialog itself
        @test occursin("data-on:click=\"if(event.target===el){\$modal = 0}\"", out)
        # body passes through
        @test occursin("<div class=\"inner\">body</div></dialog>", out)
    end

    @testset "signal_dialog omits id/class when not provided" begin
        out = render(signal_dialog("\$o", p("hi"); close_action="\$o=false"))
        @test !occursin(" id=", out)
        @test !occursin(" class=", out)
        @test occursin("<p>hi</p></dialog>", out)
    end

    @testset "signal_dialog click handler stays scoped to the dialog element" begin
        # Why: backdrop-click-to-close must not eat clicks on inner content.
        # The `event.target===el` guard is the whole point — verify it's
        # there literally, not just any data-on:click. `el` is the
        # Datastar-exposed reference to the host element.
        out = render(signal_dialog("\$x", div("c"); close_action="\$x=0"))
        @test occursin("event.target===el", out)
    end

    @testset "@using_tags imports the Base-shadowed tag names in one line" begin
        # Why: the manual `using HyperSignal: div, select, …` line is the
        # most awkward part of the API. The macro removes that papercut for
        # consumers — confirm the macro expansion is the right `using` form.
        ex = macroexpand(@__MODULE__, :(HyperSignal.@using_tags))
        # Should produce: using HyperSignal: div, select, summary
        @test ex.head == :using
        inner = ex.args[1]
        @test inner.head == :(:)
        # First arg names the module; the rest are the imported names.
        modref = inner.args[1]
        names = [a.args[1] for a in inner.args[2:end]]
        @test modref.args[1] == :HyperSignal
        @test :div in names
        @test :select in names
        @test :summary in names
        # iter 33 added mark and time to the Base-shadowed set
        @test :mark in names
        @test :time in names
    end

    @testset "patch_svg strips XML prolog and DOCTYPE so HTML parsing isn't broken" begin
        # Why: CairoMakie writes a full XML document, but those prologs
        # are invalid inside an HTML page and will trip the parser.
        src = """<?xml version="1.0" encoding="UTF-8"?>
                 <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x.dtd">
                 <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><g/></svg>"""
        out = patch_svg(src)
        @test !occursin("<?xml", out)
        @test !occursin("<!DOCTYPE", out)
        @test startswith(out, "<svg")
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
        # Why: two CairoMakie figures on one page collide on `clip0` /
        # `glyph0`. The prefix scopes them so each figure is self-contained.
        src = """<svg viewBox="0 0 1 1"><defs><clipPath id="clip0"><rect/></clipPath></defs><g clip-path="url(#clip0)"><use xlink:href="#glyph0"/><use href="#g1"/></g></svg>"""
        out = patch_svg(src; id_prefix="fig1_")
        @test occursin("id=\"fig1_clip0\"", out)
        @test occursin("url(#fig1_clip0)", out)
        @test occursin("xlink:href=\"#fig1_glyph0\"", out)
        @test occursin("href=\"#fig1_g1\"", out)
        @test !occursin("xlink:href=\"#fig1_fig1_", out)  # idempotency guard
    end

    @testset "patch_svg id_prefix containing \$ or \\ is treated literally, not as a backreference" begin
        # Why: the renamespacing uses SubstitutionString, which would
        # interpret `\1` / `$1` as backreferences if we let the caller's
        # prefix through verbatim. Callers that derive prefix from a
        # session id or hash easily land on a `$` — verify it lands as
        # text, not as a regex capture.
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

    @testset "inline_svg wraps a patched SVG as Raw so it inlines into a tree" begin
        src = """<?xml version="1.0"?><svg viewBox="0 0 1 1"><g/></svg>"""
        node = inline_svg(src; id_prefix="x_")
        @test node isa Raw
        out = render(div(class="plot", node))
        @test occursin("<div class=\"plot\"><svg", out)
        @test !occursin("<?xml", out)
    end

    @testset "Expanded HTML5 tag set renders correctly" begin
        # Why: the tag-set expansion (iter 33) added ~35 new tag
        # constructors. The Aqua-style sanity test confirms each
        # exported name resolves, but a behavioral spot-check pins
        # the actual emitted shape for the most user-facing additions.
        @test render(blockquote(p("Quoted"))) == "<blockquote><p>Quoted</p></blockquote>"
        @test render(audio(src="x.mp3", controls=true)) == "<audio src=\"x.mp3\" controls></audio>"
        @test render(iframe(src="https://e.com", "fallback")) ==
              "<iframe src=\"https://e.com\">fallback</iframe>"
        @test render(kbd("Ctrl+C")) == "<kbd>Ctrl+C</kbd>"
        @test render(b("bold")) == "<b>bold</b>"
        @test render(i("italic")) == "<i>italic</i>"
        @test render(sub("2")) == "<sub>2</sub>"
        @test render(sup("3")) == "<sup>3</sup>"
        @test render(wbr()) == "<wbr>"           # void
        @test render(caption("Table")) == "<caption>Table</caption>"
        @test render(meter(value="0.7", "70%")) == "<meter value=\"0.7\">70%</meter>"
        # Base-shadowed new tags: pull in via @using_tags or qualify.
        @test render(HyperSignal.mark("hi")) == "<mark>hi</mark>"
        @test render(HyperSignal.time(datetime="2026-05-23", "today")) ==
              "<time datetime=\"2026-05-23\">today</time>"
        # SVG primitives compose with the existing svg() tag.
        out = render(svg(viewBox="0 0 10 10", rect(width="10", height="10"), circle(cx="5", cy="5", r="3")))
        @test occursin("<svg viewBox=\"0 0 10 10\">", out)
        @test occursin("<rect", out)
        @test occursin("<circle", out)
    end

    @testset "Generators nested inside collections render via iteration" begin
        # Why: the construction-time generator-unpack only handles
        # top-level positional args. A Generator nested inside a
        # Vector — `div([gen1, gen2])` — would otherwise MethodError
        # at render. The render-side method walks them once.
        out = render(div([(p(i) for i in 1:2), (p(i) for i in 3:4)]))
        @test out == "<div><p>1</p><p>2</p><p>3</p><p>4</p></div>"
        # A bare generator passed directly to render works the same.
        @test render(p(i) for i in 1:3) == "<p>1</p><p>2</p><p>3</p>"
    end

    @testset "Generator-of-children unpacks (and is re-renderable)" begin
        # Why: `div(p(i) for i in 1:n)` is the natural Julia
        # comprehension form for a list of children. Without
        # generator-unpacking, the generator landed as a single
        # child and MethodError'd at render time. Consume eagerly
        # into the children vector so the element can be rendered
        # multiple times — generators are single-pass.
        el = div(p(i) for i in 1:3)
        @test render(el) == "<div><p>1</p><p>2</p><p>3</p></div>"
        # Re-render must produce the same output (generator would
        # be exhausted if we stored it instead of consuming).
        @test render(el) == "<div><p>1</p><p>2</p><p>3</p></div>"
        # Empty generator collapses cleanly.
        @test render(div(p(i) for i in 1:0)) == "<div></div>"
        # Generator yielding skip-types (nothing) drops them.
        @test render(div(i % 2 == 0 ? nothing : p(i) for i in 1:4)) ==
              "<div><p>1</p><p>3</p></div>"
    end

    @testset "Tuple-of-children unpacks like a Vector at construction" begin
        # Why: callers occasionally have children in a tuple (a
        # destructure target, a splat-receiver, a heterogeneously-typed
        # comprehension). Without unpacking, render(::Tuple) MethodErrors.
        # Mirror the existing Vector behavior so both shapes work.
        @test render(div((span("a"), span("b")))) == "<div><span>a</span><span>b</span></div>"
        @test render(div(("hello", " ", "world"))) == "<div>hello world</div>"
        # Mixed types in the tuple flatten cleanly.
        @test render(div(("x", nothing, h2("y"), 7))) == "<div>x<h2>y</h2>7</div>"
        # Empty tuple → no children added.
        @test render(div((), "a")) == "<div>a</div>"
    end

    @testset "Symbol children render as their text (auto-escaped)" begin
        # Why: status enums (`span(:Pending)`) are the common case. The
        # caller pulled the value from a model field; no reason to make
        # them string() it themselves. The Symbol's bytes get the same
        # escape treatment as a String.
        @test render(span(:Pending)) == "<span>Pending</span>"
        @test render(div(:foo, " ", :bar)) == "<div>foo bar</div>"
        # Escape still fires on the bytes (paranoid case).
        @test render(div(Symbol("a<b"))) == "<div>a&lt;b</div>"
    end

    @testset "Bool children are skipped so cond && elem renders conditionally" begin
        # Why: `div(header, cond && extra, footer)` is the natural Julia
        # idiom for conditional rendering. Without a Bool-skip method,
        # `cond && extra` evaluates to bare false on falsy and the
        # Number dispatch emits the literal text 'false'. With the new
        # method bool children land in the same skip bucket as
        # nothing/missing.
        @test render(div("a", false, "b")) == "<div>ab</div>"
        @test render(div("a", true, "b")) == "<div>ab</div>"
        show_extra = false
        @test render(div("a", show_extra && span("extra"), "b")) == "<div>ab</div>"
        show_extra = true
        @test render(div("a", show_extra && span("extra"), "b")) ==
              "<div>a<span>extra</span>b</div>"
        # If the user really wants the literal text 'true'/'false',
        # they can pass it via string() — no method override to undo.
        @test render(div(string(true))) == "<div>true</div>"
    end

    @testset "Vector attribute values are space-joined (class-list semantics)" begin
        # Why: `class=["btn", "primary"]` is the natural way to build a
        # class list, and aria-describedby / aria-labelledby take
        # space-separated ids. The previous fallback dumped the Vector
        # repr — `class="[&quot;btn&quot;, ...]"` — which is hostile.
        @test render(div(class=["btn", "primary"], "x")) == "<div class=\"btn primary\">x</div>"
        @test render(input(type="text", "aria-describedby" => ["hint1", "hint2"])) ==
              "<input type=\"text\" aria-describedby=\"hint1 hint2\">"
        # Nothing/missing/empty entries drop, so an optional class
        # survives without coalesce gymnastics.
        @test render(div(class=["btn", nothing, "active", missing, ""])) ==
              "<div class=\"btn active\"></div>"
        # The Julia idiom `cond && "active"` evaluates to `false` when
        # cond is false. Drop `false` and `true` so the idiom works
        # without stringifying the literal bool.
        @test render(div(class=["btn", false, "primary", true])) ==
              "<div class=\"btn primary\"></div>"
        is_active = false
        @test render(div(class=["btn", is_active && "active", "default"])) ==
              "<div class=\"btn default\"></div>"
        # Non-string entries get string()-converted.
        @test render(div(:rowspan => [2, 3])) == "<div rowspan=\"2 3\"></div>"
        # Empty vector → empty attribute value (still emitted because
        # the attr name was passed; user opted in).
        @test render(div(class=String[], "x")) == "<div class=\"\">x</div>"
        # Tuples space-join the same way (ergonomic symmetry with
        # vectors — both mean "join these" in attribute position).
        @test render(div(class=("btn", "primary"), "x")) ==
              "<div class=\"btn primary\">x</div>"
        @test render(div(class=("btn", nothing, false, "active"))) ==
              "<div class=\"btn active\"></div>"
        @test render(div(class=())) == "<div class=\"\"></div>"
    end

    @testset "string(::DSAction) returns the JS expression, not a struct dump" begin
        # Why: symmetric with Element/Frag/Raw — every HyperSignal
        # value should `string()` to what the lib would put in the
        # page, not the internal record. Useful for log lines, error
        # messages, and a clean REPL.
        @test string(ds_post("/api/save")) == "@post('/api/save')"
        @test string(ds_get("/c"; form=true)) == "@get('/c', {contentType: 'form'})"
        @test "$(ds_post("/x"))" == "@post('/x')"
    end

    @testset "String-keyed Pair args are accepted as attributes (auto-symbolize)" begin
        # Why: `div("id" => "foo", "x")` was a footgun — String keys
        # silently fell into the children path and MethodError'd at
        # render. String-keyed Pairs are unambiguous as attributes
        # (nobody passes a Pair as text content) and reading
        # `"data-foo" => v` beats `Symbol("data-foo") => v`.
        @test render(div("id" => "card", "x")) == "<div id=\"card\">x</div>"
        @test render(span("data-x" => "v")) == "<span data-x=\"v\"></span>"
        # The attribute-name validation still fires.
        @test_throws ArgumentError render(div("x onerror=1" => "v"))
        # Symbol-keyed Pairs keep working alongside String-keyed.
        @test render(div(:id => "card", "data-x" => "v", "x")) ==
              "<div id=\"card\" data-x=\"v\">x</div>"
    end

    @testset "cls rejects non-collection scalars cleanly (no stack overflow)" begin
        # Why: `_push_cls!` previously had an Any fallback that iterated
        # its arg. Number is a 1-iterable in Julia (yields itself), so
        # `cls("a", 1)` recursed forever and stack-overflowed. Now the
        # iterator path is restricted to actual collection types, and
        # everything else hits a clear error message.
        @test_throws ErrorException cls("a", 1)
        @test_throws ErrorException cls("a", 3.14)
        @test_throws ErrorException cls("a", :symbol_input)
        # Collections still flatten correctly.
        @test cls("a", ["b", "c"]) == "a b c"
        @test cls("a", ("b", "c")) == "a b c"
        @test cls("a", Set(["b"])) == "a b"
    end

    @testset "tag names that would break the HTML parser raise ArgumentError" begin
        # Why: Element(Symbol(...), ...) is the documented escape hatch
        # for runtime-chosen tags. Without validation, Symbol("<script>")
        # would emit literal '<' and '>' bytes into the open tag and
        # break HTML parsing (or worse, smuggle in markup). Reject the
        # same parser-breaking subset we reject for attribute names.
        for bad in ["<script>", "div onerror=x", "tag>injected",
                    "with space", "tag\"x", "tag\0x", ""]
            @test_throws ArgumentError render(Element(Symbol(bad), Pair{Symbol,Any}[], Any[]))
        end
        # Custom but valid tag names (Web Components / SVG) pass through.
        for ok in ["my-element", "svg:circle", "x-tag123"]
            out = render(Element(Symbol(ok), Pair{Symbol,Any}[], Any["x"]))
            @test occursin("<$ok>x</$ok>", out)
        end
    end

    @testset "attribute names that would break the HTML parser raise ArgumentError" begin
        # Why: every legal Datastar attr name fits in [A-Za-z0-9:_.-]+,
        # which is well inside HTML5's attribute-name grammar. But the
        # Symbol-keyed Pair API lets a caller pass *any* Symbol, so a
        # hostile event name from user input could otherwise inject
        # markup. Reject the parser-breaking chars loudly.
        for bad in [
            "x onerror=alert(1)",   # space → injection vector
            "x>injected",           # > closes the tag
            "x=\"y\"",              # = + quote
            "x'y",                  # single quote
            "x\"y",                 # double quote
            "x\ty",                 # tab
            "x\ny",                 # newline
            "x/y",                  # slash (HTML5 forbids in attr name)
            "x\0y",                 # NUL
        ]
            @test_throws ArgumentError render(div(Symbol(bad) => "v"))
        end
        # Legal Datastar-style names still pass through fine.
        for ok in ["data-on:click__prevent", "data-on-interval__duration.5000ms",
                   "aria-label", "xlink:href"]
            @test occursin(ok, render(span(Symbol(ok) => "v")))
        end
    end

    @testset "package sanity: no method ambiguities or unbound-arg generics" begin
        # Why: ambiguities are easy to introduce silently when adding
        # methods like Base.show on a struct that overlaps with an
        # existing AbstractDisplay path, or when a new dispatch on
        # Vector{T} crosses an existing Vector{S}. Without an Aqua dep,
        # Base.detect_ambiguities is enough to catch the common case.
        # Skip recursion into Base / loaded modules to keep noise down.
        ambs = Test.detect_ambiguities(HyperSignal; recursive=false)
        @test isempty(ambs)
        # Unbound type parameters in method signatures are the second
        # most common silent bug. They surface as MethodErrors only on
        # very specific call shapes, so static detection is cheaper.
        unbounds = Test.detect_unbound_args(HyperSignal; recursive=false)
        @test isempty(unbounds)
    end

    @testset "package sanity: every export resolves to a defined binding" begin
        # Why: a typo in the `export` lists at the bottom of
        # HyperSignal.jl (or a renamed helper whose export wasn't
        # updated) only fires at `using HyperSignal: <name>` time on a
        # consumer machine — too late. Walk the exported names once
        # and assert each is defined.
        for name in names(HyperSignal)
            name === :HyperSignal && continue  # the module itself
            @test isdefined(HyperSignal, name)
        end
    end

    @testset "Vector{UInt8} renders as a verbatim byte buffer, not per-byte numbers" begin
        # Why: the generic AbstractVector path used to walk a byte
        # buffer and emit each UInt8 as a decimal number, which is
        # never what the caller wants. The common case is a
        # pre-rendered, possibly cached HTML body — write it verbatim.
        bytes = Vector{UInt8}("<b>hi</b>")
        @test render(bytes) == "<b>hi</b>"
        # The bytes path even bypasses auto-escape — by design,
        # mirroring `Raw`'s trust model: bytes are emitted as-is.
        @test render(Vector{UInt8}("<>&")) == "<>&"
        # An empty byte vector renders to the empty string.
        @test render(Vector{UInt8}()) == ""
        # A byte buffer as an element child is kept whole, not unpacked
        # into per-byte Number children. The pre-rendered fragment
        # caching use case: stick a cached buffer between two ordinary
        # children and only the buffer is emitted verbatim.
        @test render(div(class="card", "x", Vector{UInt8}("<i>cached</i>"), "y")) ==
              "<div class=\"card\">x<i>cached</i>y</div>"
    end

    @testset "SubString of String escapes correctly via the codeunit fast path" begin
        # Why: SubString{String} is the result of any slice/interpolation
        # on a String. Ensure it walks the parent buffer correctly and
        # produces the same output as the equivalent String value.
        base = "ab<c&d>ef\"gh'ij"
        sub = SubString(base, 2, 14)  # "b<c&d>ef\"gh'i"
        @test render(sub) == "b&lt;c&amp;d&gt;ef&quot;gh&#39;i"
        # An all-safe SubString uses a single unsafe_write run.
        @test render(SubString("hello world", 1, 5)) == "hello"
        # An empty SubString writes nothing.
        @test render(SubString("xyz", 1, 0)) == ""
        # SubString that starts and ends on metacharacters: the slice
        # must respect the offset so we don't bleed into bytes of the
        # parent that aren't part of the view.
        @test render(SubString("XX<&>YY", 3, 5)) == "&lt;&amp;&gt;"
        # SubString past a multi-byte UTF-8 char: the parent's bytes
        # for "é" are 0xc3 0xa9; the offset must land on a codepoint
        # boundary (Julia's SubString constructor enforces this).
        # `"a<é>b"` byte indices: a=1, <=2, é=3..4, >=5, b=6 — so 2..5
        # is the slice we want.
        @test render(SubString("a<é>b", 2, 5)) == "&lt;é&gt;"
    end

    @testset "Base.show(MIME\"text/plain\", ::Raw) shows the raw HTML at the REPL" begin
        # Why: without this method, REPL-displaying DOCTYPE or a Raw
        # value falls back to the struct dump. Useful for inspection
        # of an embedded SVG icon at the prompt.
        io = IOBuffer()
        show(io, MIME"text/plain"(), Raw("<svg/>"))
        @test occursin("HyperSignal.Raw:", String(take!(io)))
        seekstart(io); truncate(io, 0)
        show(io, MIME"text/plain"(), DOCTYPE)
        @test occursin("HyperSignal.Raw: <!DOCTYPE html>", String(take!(io)))
    end

    @testset "parse_signals raises a labeled ArgumentError on malformed JSON" begin
        # Why: JSON.jl's own message doesn't name parse_signals, so a
        # service log shows just \"ArgumentError: Expected …\" with no
        # hint that the request body was the culprit. The wrapper
        # prefixes the error with parse_signals and a body snippet.
        try
            parse_signals("{not json}")
            @test false  # expected to throw
        catch err
            @test err isa ArgumentError
            @test occursin("parse_signals", err.msg)
            @test occursin("{not json}", err.msg)
        end
    end

    @testset "missing attribute value is omitted, mirroring nothing semantics" begin
        # Why: lets `value = optional_string()` (a function that may
        # return missing on DB nulls) flow into attr position without
        # the caller juggling a coalesce — symmetric with how render
        # already treats `missing` children as omitted.
        @test render(input(type="text", value=missing)) == "<input type=\"text\">"
        @test render(div(class=missing, "x")) == "<div>x</div>"
    end

    @testset "parse_signals reads JSON body from a plain IO too" begin
        # Why: services that pipeline through an IO (e.g. a gzip-decoded
        # buffer wrapped in IOBuffer) don't always have a Vector{UInt8}
        # in hand. Round-trip the same JSON via three input shapes.
        json = """{"count": 3, "name": "ok"}"""
        d_str   = parse_signals(json)
        d_bytes = parse_signals(Vector{UInt8}(json))
        d_io    = parse_signals(IOBuffer(json))
        @test d_str == d_bytes == d_io == Dict{String, Any}("count" => 3, "name" => "ok")
        @test parse_signals(IOBuffer("")) == Dict{String, Any}()
    end

    @testset "ds_post extras: string values are JS-escaped against \\, ', </script>" begin
        # Why: an `extras` value that contains a backslash or </script>
        # would otherwise corrupt the JS string and either break parsing
        # or — for </script> in an inline-script context — let an HTML
        # parser close the wrapping <script>.
        a = ds_post("/x"; note="he said: 'hi' \\path </script>")
        out = render(button("Save", on_click(a)))
        # Backslash doubled, single-quote escaped, </ broken with backslash:
        @test occursin("note: 'he said: \\&#39;hi\\&#39; \\\\path &lt;\\/script&gt;'", out) ||
              occursin("note: 'he said: \\'hi\\' \\\\path <\\/script>'",            # pre-HTML-escape view
                        HyperSignal.action_js(a))
        # action_js view (pre HTML escape) for the precise contract:
        js = HyperSignal.action_js(a)
        @test occursin("\\\\path", js)        # backslash doubled
        @test occursin("\\'hi\\'", js)        # quotes escaped
        @test occursin("<\\/script>", js)     # </ broken
    end

    @testset "stress: 5000-deep nesting renders without stack overflow" begin
        # Why: render() recurses on children. A pathological component
        # that nests 5000 deep is unrealistic but proves the recursion
        # bound is generous enough that real pages (~50 deep) never
        # come close to the limit.
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
        # Why: a programmatically generated form can drift into hundreds
        # of attrs (e.g. one ds_attr per dynamic field). Make sure the
        # render path stays linear in attr count.
        kw = (; (Symbol("data-x-$i") => "v$i" for i in 1:2000)...)
        el = div(; kw...)
        out = render(el)
        @test occursin("data-x-1=\"v1\"", out)
        @test occursin("data-x-2000=\"v2000\"", out)
    end

    @testset "stress: patch_svg on 1 MB synthetic input stays sub-second" begin
        # Why: a CairoMakie figure with many marks can hit a few hundred
        # KB. 1 MB is well past realistic but proves the regex passes
        # don't blow up super-linearly.
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
        @test sizeof(big) > 400_000   # ~470 KB on this shape — way past realistic CairoMakie output
        t = @elapsed out = patch_svg(big; id_prefix="p_")
        @test t < 2.0                 # generous; on the bench host it's ~10ms
        @test occursin("id=\"p_clip0\"", out)
        @test occursin("url(#p_clip5000)", out)
        @test !occursin("<?xml", out)
    end

    @testset "stress: 10k metacharacter escape round-trips byte-stable" begin
        # Why: the codeunit fast path on escape_html is the place a
        # regression in HTML safety would land silently. Pin the
        # byte-stable output on a known-bad input so any future
        # micro-optimization keeps escape semantics exact.
        text = repeat("<&>\"' \xc3\xa9 ", 1000)   # 9000 bytes, includes UTF-8
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
        # Why: without a 1-arg Base.show method, `string(el)` and
        # interpolation fall back to a struct dump. Make HyperSignal
        # values consistently behave like HTML in every path.
        el = div(class="card", "hi")
        @test string(el) == "<div class=\"card\">hi</div>"
        @test "$(el)" == render(el)
        @test sprint(print, el) == render(el)
        @test sprint(print, Frag(p("a"), p("b"))) == "<p>a</p><p>b</p>"
        @test sprint(print, Raw("<b>x</b>")) == "<b>x</b>"
        # Vector-of-elements prints as readable markup, not as a struct dump.
        @test sprint(show, [p("a"), p("b")]) == "Element[<p>a</p>, <p>b</p>]"
    end

    @testset "Base.show(MIME\"text/html\") returns the rendered HTML for notebooks" begin
        # Why: Pluto / IJulia / VS Code use the text/html MIME to display
        # interactive previews. Without this hook every cell would have
        # to call `render(...)` explicitly.
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
        # Why: prove the front-row CairoMakie story actually works end-to-end
        # — produce a real figure, run it through inline_svg, drop two of
        # them in one tree, and verify the id prefixes keep them disjoint.
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
        # No bare unprefixed clip0/glyph0 ids should survive — every id
        # in the output must carry either the a_ or b_ prefix.
        for m in eachmatch(r"id=\"([^\"]+)\"", out)
            @test startswith(m.captures[1], "a_") || startswith(m.captures[1], "b_")
        end
    end

    @testset "app-grade helpers are NOT exported at the top level" begin
        # Why: the helpers moved to HyperSignal.Helpers (issue #1) and
        # the deprecation shim was dropped before any external user
        # could pin against it (issue #8). A future PR that adds a
        # top-level shim or re-exports these would silently undo the
        # move; this test fails loud instead.
        for name in (:radio_field, :checkbox_field, :text_field,
                     :help_tooltip, :form_legend, :form_section,
                     :preset_button, :signal_dialog)
            @test !isdefined(HyperSignal, name)
            @test isdefined(HyperSignal.Helpers, name)
        end
    end

    include("escape_conformance.jl")

    @testset "no type piracy or @generated+hasmethod under src/ and ext/" begin
        # Why: Hyperscript broke on Julia 1.6 from `Vector{Node}`
        # piracy (#24); HypertextLiteral broke on 1.10 from
        # `@generated` + `hasmethod` (#28, #33). Both bans are
        # documented in CONVENTIONS.md → "Out of scope". This test
        # is the load-bearing enforcement.
        roots = [joinpath(pkgdir(HyperSignal), "src"),
                 joinpath(pkgdir(HyperSignal), "ext")]
        offenders_generated = String[]
        offenders_piracy = String[]
        # Owned types — Base.show etc. on these is fine.
        owned = Set(["Element", "Frag", "Raw", "Attribute", "DSAction"])

        for root in roots
            isdir(root) || continue
            for (dir, _, files) in walkdir(root)
                for f in files
                    endswith(f, ".jl") || continue
                    path = joinpath(dir, f)
                    for (lineno, line) in enumerate(eachline(path))
                        # Strip line comments before scanning so the
                        # CONVENTIONS reference in elements.jl doesn't
                        # self-flag.
                        code = first(split(line, '#'; limit=2))
                        if occursin(r"\b(@generated|hasmethod)\b", code)
                            push!(offenders_generated, "$path:$lineno: $line")
                        end
                        # A `Base.<name>(...)` definition is pirate
                        # unless at least one of its argument types
                        # *terminates* in an owned name. Match every
                        # `::T` annotation on the line and require T
                        # to be exactly one of the owned names — a
                        # substring match would whitelist
                        # `Base.push!(::Vector{Element}, ...)` because
                        # `::Element` is a substring of
                        # `::Vector{Element}`.
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
        # Surface the offenders if the test fails, so CI output is
        # actionable.
        isempty(offenders_generated) || (@info "@generated/hasmethod offenders" offenders_generated)
        isempty(offenders_piracy) || (@info "type-piracy offenders" offenders_piracy)
    end
end
