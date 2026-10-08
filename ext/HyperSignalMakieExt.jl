module HyperSignalMakieExt

import HyperSignal
using HyperSignal: patch_svg, Raw
using Makie: Makie

# FigureAxisPlot: what convenience plots (`lines(...)`, `scatter(...)`) return
const _MAKIE_TYPES = Union{Makie.Figure, Makie.Scene, Makie.FigureAxisPlot}

function HyperSignal.inline_svg(fig::_MAKIE_TYPES; kwargs...)
    io = IOBuffer()
    show(io, MIME"image/svg+xml"(), fig)
    Raw(patch_svg(String(take!(io)); kwargs...))
end

end # module
