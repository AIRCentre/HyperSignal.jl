### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 00000001-0000-0000-0000-000000000002
begin
    import Pkg
    Pkg.activate(mktempdir(); io=devnull)
    Pkg.develop(path=joinpath(@__DIR__, "..", "..", ".."); io=devnull)
    Pkg.instantiate(; io=devnull)
end

# ╔═╡ 00000001-0000-0000-0000-000000000003
using HyperSignal

# ╔═╡ 00000001-0000-0000-0000-000000000004
HyperSignal.@using_tags

# ╔═╡ 00000001-0000-0000-0000-000000000001
md"""
# Datastar response shapes

Walk through the buffered Datastar SSE helper added in #19. One
`sse_response` can carry an HTML patch *and* a signal patch in the
same HTTP round trip — useful when the morph and the signal change
must land together (e.g. "save succeeded; clear the dirty flag").
"""

# ╔═╡ 00000001-0000-0000-0000-000000000005
md"""
## A single HTML patch

`patch_elements` builds one `datastar-patch-elements` event. With no
keywords it just morphs the rendered body into the page using the
client's default mode.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000006
resp_elements = sse_response([patch_elements(div(id="card", "Saved"); selector="#card")])

# ╔═╡ 00000001-0000-0000-0000-000000000007
String(resp_elements.body)

# ╔═╡ 00000001-0000-0000-0000-000000000008
md"""
## HTML patch + signal patch in one response

The headline use case: emit the morph and the signal update together,
so the client never sees a half-applied state.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000009
resp_combo = sse_response([
    patch_elements(div(id="card", "Saved"); selector="#card", mode=:inner),
    patch_signals((; dirty=false, saved_at="2026-05-27T12:00:00Z")),
])

# ╔═╡ 0000000a-0000-0000-0000-000000000000
String(resp_combo.body)

# ╔═╡ 0000000b-0000-0000-0000-000000000000
md"""
## Headers

`sse_response` pins the three SSE headers (`Content-Type`,
`Cache-Control`, `Connection`) so handlers don't keep retyping them.
Extras passed via `headers=…` are appended.
"""

# ╔═╡ 0000000c-0000-0000-0000-000000000000
Dict(String(k) => String(v) for (k, v) in resp_combo.headers)

# ╔═╡ Cell order:
# ╟─00000001-0000-0000-0000-000000000001
# ╠═00000001-0000-0000-0000-000000000002
# ╠═00000001-0000-0000-0000-000000000003
# ╠═00000001-0000-0000-0000-000000000004
# ╟─00000001-0000-0000-0000-000000000005
# ╠═00000001-0000-0000-0000-000000000006
# ╠═00000001-0000-0000-0000-000000000007
# ╟─00000001-0000-0000-0000-000000000008
# ╠═00000001-0000-0000-0000-000000000009
# ╠═0000000a-0000-0000-0000-000000000000
# ╟─0000000b-0000-0000-0000-000000000000
# ╠═0000000c-0000-0000-0000-000000000000
