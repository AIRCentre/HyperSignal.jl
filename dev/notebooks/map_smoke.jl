### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

# ╔═╡ 00000001-0000-0000-0000-000000000002
begin
    import Pkg
    Pkg.activate(mktempdir(); io=devnull)
    Pkg.develop(path=joinpath(@__DIR__, "..", "..", ".."); io=devnull)
    Pkg.add(name="GeoInterface"; io=devnull)
    Pkg.instantiate(; io=devnull)
end

# ╔═╡ 00000001-0000-0000-0000-000000000003
using HyperSignal, GeoInterface

# ╔═╡ 00000001-0000-0000-0000-000000000001
md"""
# MapLibre smoke fixture

Activates `HyperSignalMapLibreExt` via `using GeoInterface`, then
exercises the two most load-bearing entry points: a bare `map_view`
construction (which would fail to compile if the ext didn't load) and
a Point → GeoJSON round-trip. Asserted on by
`.github/workflows/pluto-smoke.yml`.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000004
ext = Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)

# ╔═╡ 00000001-0000-0000-0000-000000000005
ext.map_view(id_prefix="smoke_", style="/style.json",
             center=(0.0, 0.0), zoom=2)

# ╔═╡ 00000001-0000-0000-0000-000000000006
ext.geojson(GeoInterface.Wrappers.Point((0.0, 0.0)))

# ╔═╡ Cell order:
# ╟─00000001-0000-0000-0000-000000000001
# ╠═00000001-0000-0000-0000-000000000002
# ╠═00000001-0000-0000-0000-000000000003
# ╠═00000001-0000-0000-0000-000000000004
# ╠═00000001-0000-0000-0000-000000000005
# ╠═00000001-0000-0000-0000-000000000006
