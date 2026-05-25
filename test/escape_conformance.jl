# HTML5 escape conformance suite.
#
# Two assertions per rule:
#   - positive: the rendered bytes equal the expected literal.
#   - round-trip: re-parsing the rendered bytes with `EzXML.parsehtml`
#     recovers the original input.
#
# A regex-only assertion can drift from real-parser semantics (one of
# the failure modes documented in HypertextLiteral#42 and
# Hyperscript#20). The EzXML cross-check pins the lib to what an
# actual HTML5 parser sees.

using EzXML

# `parsehtml` returns a Document; this convenience wraps the fragment
# in a minimal page with a UTF-8 charset hint (libxml2 needs the
# declaration to decode non-ASCII bytes correctly) and pulls the
# single Element back out.
function parse_p(html::AbstractString)
    doc = parsehtml("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>" *
                    html * "</body></html>")
    findfirst("//p", doc)
end

# Lone-surrogate coverage (e.g. `\udc00`) is intentionally absent:
# Julia's `String` is UTF-8 and rejects lone surrogates at construction
# (`\udc00` is a parse-time error), so the only way to materialize one
# is to hand-craft a Vector{UInt8} of invalid UTF-8 — which the
# renderer treats as bytes, not text. The realistic regression we
# would catch (renderer corrupts a valid char) is already covered by
# the UTF-8 + metacharacters case below.

@testset "HTML5 escape conformance" begin
    @testset "the five metacharacters in child text" begin
        # One bag covering all five — keeps the doctest-style table tight.
        out = render(HyperSignal.p("a < b & c > d \"e\" 'f'"))
        @test out == "<p>a &lt; b &amp; c &gt; d &quot;e&quot; &#39;f&#39;</p>"
        # Real parser sees the original characters back.
        @test nodecontent(parse_p(out)) == "a < b & c > d \"e\" 'f'"
    end

    @testset "the five metacharacters in attribute value" begin
        out = render(HyperSignal.p(title="< > & \" '"))
        @test out == "<p title=\"&lt; &gt; &amp; &quot; &#39;\"></p>"
        @test parse_p(out)["title"] == "< > & \" '"
    end

    @testset "NUL byte in attribute name is rejected" begin
        # Per the security-model contract: attribute names that could
        # break out of their token (NUL, whitespace, `<`, `>`, `"`,
        # `'`, `/`, `=`) raise rather than render.
        @test_throws ArgumentError render(HyperSignal.p(Symbol("foo\0bar") => "v"))
    end

    @testset "NUL byte in attribute value renders verbatim" begin
        # The escape walker only branches on the five HTML
        # metacharacters; NUL passes through. HTML5 parsers replace
        # the byte with U+FFFD on read — documented divergence, not
        # something the writer fakes.
        out = render(HyperSignal.p(title="a\0b"))
        @test out == "<p title=\"a\0b\"></p>"
    end

    @testset "NUL byte in child text renders verbatim" begin
        out = render(HyperSignal.p("a\0b"))
        @test out == "<p>a\0b</p>"
    end

    @testset "CR/LF inside attribute values are preserved" begin
        # HTML5 keeps newlines inside quoted attribute values; only
        # the *unquoted* attribute form forbids them. Our values are
        # always quoted.
        out = render(HyperSignal.p(title="a\r\nb"))
        @test out == "<p title=\"a\r\nb\"></p>"
        # Real parser sees a single attribute value, possibly with
        # the CR normalized to LF (HTML5 §13.2.5.36 — record-end
        # tokenization). Either form is conformant; the round-trip
        # is correct as long as the parser yields *some* string that
        # canonicalizes back.
        v = parse_p(out)["title"]
        @test replace(v, "\r\n" => "\n", "\r" => "\n") == "a\nb"
    end

    @testset "mixed UTF-8 and metacharacters" begin
        out = render(HyperSignal.p("é & <foo>"))
        @test out == "<p>é &amp; &lt;foo&gt;</p>"
        @test nodecontent(parse_p(out)) == "é & <foo>"

        out2 = render(HyperSignal.p(title="é & <foo>"))
        @test out2 == "<p title=\"é &amp; &lt;foo&gt;\"></p>"
        @test parse_p(out2)["title"] == "é & <foo>"
    end

    @testset "long safe-byte run with embedded metacharacters" begin
        # 10 KiB of safe bytes punctuated by all five escapes. Stresses
        # the run-of-safe-bytes fast path in `escape_html` against
        # the slow branches — a regression would either skip the
        # escape (smoke) or break the byte-run boundary (parsing
        # asserts catch that).
        pad = repeat("x", 10 * 1024)
        input = pad * "<&>\"'" * pad
        out = render(HyperSignal.p(input))
        @test out == "<p>" * pad * "&lt;&amp;&gt;&quot;&#39;" * pad * "</p>"
        @test nodecontent(parse_p(out)) == input
    end

    @testset "attribute and text payload round-trip through EzXML" begin
        # One realistic fixture covering both vectors in the same
        # element — the shape a real fragment_response handler emits.
        node = HyperSignal.div(class="card", title="\"hi\" & 'bye'",
                                HyperSignal.h2("a < b"),
                                HyperSignal.p("é & <foo>"))
        out = render(node)
        doc = parsehtml("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>" *
                        out * "</body></html>")
        d = findfirst("//div", doc)
        @test d["class"] == "card"
        @test d["title"] == "\"hi\" & 'bye'"
        @test nodecontent(findfirst("//h2", doc)) == "a < b"
        @test nodecontent(findfirst("//p", doc)) == "é & <foo>"
    end
end
