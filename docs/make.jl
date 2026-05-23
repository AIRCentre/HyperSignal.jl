using Documenter, HyperSignal

DocMeta.setdocmeta!(HyperSignal, :DocTestSetup, :(using HyperSignal); recursive=true)

makedocs(
    sitename = "HyperSignal.jl",
    modules  = [HyperSignal],
    authors  = "AIR Centre and contributors",
    repo     = "https://github.com/AIRCentre/HyperSignal.jl/blob/{commit}{path}#{line}",
    format   = Documenter.HTML(
        canonical = "https://AIRCentre.github.io/HyperSignal.jl",
        edit_link = "main",
        assets    = String[],
    ),
    pages = [
        "Home"          => "index.md",
        "CairoMakie"    => "cairomakie.md",
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
