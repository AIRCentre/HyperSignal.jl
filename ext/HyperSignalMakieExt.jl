module HyperSignalMakieExt

# Front-row Makie support: render a Figure / Scene / FigureAxisPlot to
# SVG (via whatever backend the user has loaded — CairoMakie in practice)
# and hand the bytes to `patch_svg`. Lives in an extension so HyperSignal
# itself stays a tiny HTML lib that doesn't pull a plotting stack.

import HyperSignal
using HyperSignal: patch_svg, Raw
using Makie: Makie

# Cover the three things you can hand `show` for SVG MIME in Makie:
# a Figure, a Scene, and the FigureAxisPlot wrapper returned by
# convenience plotting calls (`lines(...)`, `scatter(...)`).
const _MAKIE_TYPES = Union{Makie.Figure, Makie.Scene, Makie.FigureAxisPlot}

function HyperSignal.inline_svg(fig::_MAKIE_TYPES; kwargs...)
    io = IOBuffer()
    show(io, MIME"image/svg+xml"(), fig)
    Raw(patch_svg(String(take!(io)); kwargs...))
end

end # module
