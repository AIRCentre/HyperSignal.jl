---
name: Bug report
about: A reproducible incorrect behavior — wrong output, error, regression
labels: bug
---

**What happened**

What did the code do? Include the exact rendered HTML or the error
message and stack trace.

**What you expected**

What did you expect to happen instead?

**Minimal reproducer**

```julia
using HyperSignal
# … the smallest snippet that triggers the bug
```

**Environment**

- HyperSignal version (`pkgversion(HyperSignal)` after `using HyperSignal`, or `Pkg.status("HyperSignal")`):
- Julia version (`versioninfo()`):
- OS:
- If the bug involves CairoMakie inlining: CairoMakie / Makie versions.

**Anything else**

Logs, screenshots, related issues, suspicions about the cause.
