using Documenter, HyperSignal
using Documenter: Remotes

# `using HTTP` so doctests can read response headers case-insensitively via
# `HTTP.header(resp, name)` — HTTP 2.0 title-cases header names, so a
# case-sensitive `Dict(resp.headers)["datastar-selector"]` would break.
DocMeta.setdocmeta!(HyperSignal, :DocTestSetup, :(using HyperSignal; using HTTP); recursive=true)
# Helpers submodule doctests want unqualified names (`radio_field(...)`),
# so layer a Helpers-specific setup on top of the recursive one.
DocMeta.setdocmeta!(HyperSignal.Helpers, :DocTestSetup,
                    :(using HyperSignal; using HyperSignal.Helpers))

makedocs(
    sitename = "HyperSignal.jl",
    modules  = [HyperSignal],
    authors  = "AIR Centre and contributors",
    repo     = Remotes.GitHub("AIRCentre", "HyperSignal.jl"),
    format   = Documenter.HTML(
        canonical = "https://AIRCentre.github.io/HyperSignal.jl",
        edit_link = "main",
        assets    = String[],
    ),
    pages = [
        "Home"          => "index.md",
        "CairoMakie"    => "cairomakie.md",
        "MapLibre"      => "maplibre.md",
        "Datastar"      => "datastar.md",
        "Security"      => "security.md",
        "Performance"   => "performance.md",
        "API reference" => "api.md",
    ],
    checkdocs = :exports,
    doctest   = true,
    warnonly  = [:missing_docs, :cross_references],
)

deploydocs(
    repo      = "github.com/AIRCentre/HyperSignal.jl",
    devbranch = "main",
    push_preview = false,
)
