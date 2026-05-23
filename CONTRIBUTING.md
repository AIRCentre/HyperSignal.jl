# Contributing to HyperSignal.jl

Issues and PRs welcome. The goal of this document is to save you a round
trip — the project has a few specific conventions that aren't obvious
from skimming the source.

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

Tests run on Julia 1.10 (LTS) and the current stable; both are
exercised in CI. The CairoMakie integration test pulls a real plotting
stack — first-time precompile is several minutes.

## Benchmarks

The renderer is on the request-handler hot path. Any change to
`render.jl`, `elements.jl`, or `svg.jl` should be measured before and
after.

```bash
julia --project=benchmark benchmark/runbench.jl
```

`BenchmarkTools` lives in `benchmark/Project.toml` so it stays out of
the main runtime dependency tree.

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
5. Push and open a PR. CI runs on both Julia 1.10 and current stable.

## Reporting a security issue

Don't open a public issue. Email <joao.goncalves@aircentre.org>
instead.
