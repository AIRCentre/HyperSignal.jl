# Why: regex-only assertions drift from real-parser semantics; EzXML round-trip pins
# output to what an HTML5 parser sees.

using EzXML

# Why: libxml2 needs charset declaration to decode non-ASCII bytes, so wrap fragment in
# a minimal UTF-8 page.
function parse_p(html::AbstractString)
    doc = parsehtml("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>" *
                    html * "</body></html>")
    findfirst("//p", doc)
end

# Why: no lone-surrogate case: Julia `String` is UTF-8 and `\udc00` is a parse-time
# error; hand-crafted invalid UTF-8 renders as bytes, not text. Valid-char corruption is
# covered by the UTF-8 + metacharacters case below.

@testset "HTML5 escape conformance" begin
    @testset "the five metacharacters in child text" begin
        out = render(HyperSignal.p("a < b & c > d \"e\" 'f'"))
        @test out == "<p>a &lt; b &amp; c &gt; d &quot;e&quot; &#39;f&#39;</p>"
        @test nodecontent(parse_p(out)) == "a < b & c > d \"e\" 'f'"
    end

    @testset "the five metacharacters in attribute value" begin
        out = render(HyperSignal.p(title="< > & \" '"))
        @test out == "<p title=\"&lt; &gt; &amp; &quot; &#39;\"></p>"
        @test parse_p(out)["title"] == "< > & \" '"
    end

    @testset "NUL byte in attribute name is rejected" begin
        # Why: attribute names that could break out of their token (NUL, whitespace,
        # `<`, `>`, `"`, `'`, `/`, `=`) raise rather than render (security-model
        # contract).
        @test_throws ArgumentError render(HyperSignal.p(Symbol("foo\0bar") => "v"))
    end

    @testset "NUL byte in attribute value renders verbatim" begin
        # Why: escape walker branches only on the five HTML metacharacters, so NUL
        # passes through. HTML5 parsers replace it with U+FFFD on read: documented
        # divergence, not faked by writer.
        out = render(HyperSignal.p(title="a\0b"))
        @test out == "<p title=\"a\0b\"></p>"
    end

    @testset "NUL byte in child text renders verbatim" begin
        out = render(HyperSignal.p("a\0b"))
        @test out == "<p>a\0b</p>"
    end

    @testset "CR/LF inside attribute values are preserved" begin
        # Why: HTML5 keeps newlines inside quoted attribute values; only the unquoted
        # form forbids them. Values are always quoted.
        out = render(HyperSignal.p(title="a\r\nb"))
        @test out == "<p title=\"a\r\nb\"></p>"
        # Why: parser may normalize CR to LF (HTML5 §13.2.5.36 record-end tokenization);
        # either form is conformant, so compare after canonicalizing.
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
        # Why: 10 KiB safe-byte run punctuated by all five escapes stresses
        # `escape_html` run-of-safe-bytes fast path against slow branches; a regression
        # either skips an escape (byte-equality asserts fail) or breaks a run
        # boundary (EzXML parse asserts fail).
        pad = repeat("x", 10 * 1024)
        input = pad * "<&>\"'" * pad
        out = render(HyperSignal.p(input))
        @test out == "<p>" * pad * "&lt;&amp;&gt;&quot;&#39;" * pad * "</p>"
        @test nodecontent(parse_p(out)) == input
    end

    @testset "attribute and text payload round-trip through EzXML" begin
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
