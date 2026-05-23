## What this PR changes

A sentence on what changed and why. Link the issue if there is one.

## How to verify

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` passes.
- [ ] If the change touches `render.jl`, `elements.jl`, or `svg.jl`:
      benchmarks ran (`julia --project=benchmark benchmark/runbench.jl`)
      and no >10% regression on any case.
- [ ] If the change is user-facing: `CHANGELOG.md` updated under
      `## Unreleased`.

## Test coverage

What's the new test (or which existing test exercises the change)?
For renderer changes, prefer a byte-stable assertion so any future
micro-optimization keeps the same output.

## Notes for the reviewer

Anything subtle, edge cases worth pointing out, or follow-up work
deliberately left for another PR.
