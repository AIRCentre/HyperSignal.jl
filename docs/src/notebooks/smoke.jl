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

# ╔═╡ 00000001-0000-0000-0000-000000000001
md"""
# CI smoke fixture

Minimal notebook asserted on by `.github/workflows/pluto-smoke.yml`.
A regression in `Base.show(::IO, ::MIME"text/html", ::Element)` flips
the cell below red before users see broken pages. Kept thin on purpose
— no CairoMakie, no HTTP server — so CI runs in seconds rather than
minutes.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000004
HyperSignal.@using_tags

# ╔═╡ 00000001-0000-0000-0000-000000000005
div(class="card", "hello")

# ╔═╡ Cell order:
# ╟─00000001-0000-0000-0000-000000000001
# ╠═00000001-0000-0000-0000-000000000002
# ╠═00000001-0000-0000-0000-000000000003
# ╠═00000001-0000-0000-0000-000000000004
# ╠═00000001-0000-0000-0000-000000000005
