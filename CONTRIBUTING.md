# Contributing to HyperSignal.jl

Issues and PRs welcome. This file lists the project conventions that
aren't obvious from the source.

## Required reading before any non-trivial PR

- [`README.md`](README.md) — what the lib does and the public API.
- [`CONVENTIONS.md`](CONVENTIONS.md) — composition, safety, and
  packaging rules.

## Development setup

```bash
git clone https://github.com/AIRCentre/HyperSignal.jl
cd HyperSignal.jl
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

CI runs the tests on Julia 1.10 (LTS) and the current stable, each with
HTTP.jl 1 and 2. The CairoMakie integration test pulls a real plotting
stack, so first-time precompile is several minutes.

## Benchmarks

The renderer is on the request-handler hot path. Any change to
`render.jl`, `elements.jl`, or `svg.jl` should be measured before and
after.

```bash
julia --project=benchmark benchmark/runbench.jl
```

`BenchmarkTools` lives in `benchmark/Project.toml` so it stays out of
the main runtime dependency tree. The benchmark needs Julia 1.11+:
`benchmark/Project.toml` finds HyperSignal via `[sources]`, which
Julia 1.10 ignores.

## Documentation and doctests

Any `jldoctest` block in a docstring is executed as a test, and the docs
build runs on every PR — so a doctest whose output no longer matches the
code will fail CI. Build the docs and run doctests locally with:

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl   # Julia 1.11+
```

The docs environment is separate (`docs/Project.toml`) and path-depends
on the working tree via `[sources]`, so on Julia 1.11+ it builds against
your local changes.
Exported symbols should carry a docstring (`checkdocs = :exports`).
Missing docstrings and unresolved cross-references only warn
(`warnonly = [:missing_docs, :cross_references]`); a doctest mismatch
fails the build locally and in CI.

## What goes into `CHANGELOG.md`

User-facing changes go under `## Unreleased`. Internal refactors and
test-only changes don't need an entry. New features go under `Added`,
behavior changes under `Changed`, bugfixes under `Fixed`. The release
process moves `Unreleased` to a dated heading.

## Commit messages

The repo follows imperative-mood subject lines ("Fix X" not "Fixed X")
under ~70 characters, with a blank line then a body that explains the
*why* — not the *what*, which the diff already shows.

## Submitting a PR

1. Open a branch off `main`.
2. Run the full test suite locally. Add a test for any new behavior.
3. If your change touches the hot path, attach benchmark numbers in
   the PR description.
4. Update `CHANGELOG.md` under `## Unreleased`.
5. Push and open a PR. CI runs the test suite on Julia 1.10 (LTS) and
   current stable, each with HTTP.jl 1 and 2, and builds the docs with
   doctests. For changes under
   `src/`, `ext/`, `Project.toml`, or the smoke notebooks, a headless
   Pluto smoke job (`.github/scripts/pluto_smoke.jl`) also runs: it
   asserts the `text/html` MIME render of an `Element` and that the
   Datastar-response and MapLibre example notebooks evaluate cleanly.

## Reporting a security issue

Don't open a public issue. Email <joao.goncalves@aircentre.org>
instead.
