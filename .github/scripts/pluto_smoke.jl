# Headless Pluto smoke for examples/pluto_demo.jl.
#
# Spin up a Pluto session, open the notebook, wait for all cells to
# settle, then assert that the cell rendering `div(class="card",
# "hello")` produces HTML containing both substrings via Pluto's
# `text/html` MIME hook. This is how a Pluto user would actually see
# the value — a regression in `Base.show(::IO, ::MIME"text/html",
# ::Element)` flips this assertion red.

using Pkg
Pkg.activate(mktempdir(); io=devnull)
Pkg.develop(path=joinpath(@__DIR__, "..", ".."); io=devnull)
Pkg.add(name="Pluto"; io=devnull)

using Pluto

notebook_path = abspath(joinpath(@__DIR__, "..", "..",
                                  "docs", "src", "notebooks", "datastar_form.jl"))

session = Pluto.ServerSession()
session.options.evaluation.workspace_use_distributed = false
notebook = Pluto.SessionActions.open(session, notebook_path; run_async=false)

# Find the smoke cell — the one whose code is exactly the fragment.
# Wrapped in a function so the loop binding isn't soft-scope-local.
function find_smoke_cell(nb)
    # Match on exact code so a description in a markdown cell that
    # mentions the fragment doesn't shadow the real target cell.
    for c in nb.cells
        strip(c.code) == "div(class=\"card\", \"hello\")" && return c
    end
    return nothing
end
smoke_cell = find_smoke_cell(notebook)
smoke_cell === nothing && error("smoke cell not found in $notebook_path")

if smoke_cell.errored
    error("smoke cell raised: $(smoke_cell.output.body)")
end

# Pluto stores the MIME output on `cell.output.body` (with
# `mime` describing which one was used). For an Element value the
# text/html hook fires, so body is the rendered HTML string.
body = String(smoke_cell.output.body)
mime = string(smoke_cell.output.mime)

mime == "text/html" ||
    error("expected text/html MIME, got $mime; body=$(repr(body))")
occursin("<div class=\"card\">", body) ||
    error("missing opening div in body=$(repr(body))")
occursin("hello", body) ||
    error("missing \"hello\" in body=$(repr(body))")

println("pluto smoke ok: MIME=$mime, body=$(repr(body))")

Pluto.SessionActions.shutdown(session, notebook)
