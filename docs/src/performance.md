# Performance

The renderer sits on the request-handler hot path: a typical Datastar
page may swap fragments dozens of times per interaction, and each swap
goes through [`render`](@ref) / [`fragment_response`](@ref).
`benchmark/` holds a benchmark suite for that cost.

## Regenerating these numbers

```bash
julia --project=benchmark benchmark/runbench.jl   # Julia 1.11+
```

The script defines a `BenchmarkGroup`, runs it with
`run(SUITE; verbose=true)`, and prints the full trial results per case.
Re-run before and after touching `elements.jl`, `render.jl`, or `svg.jl`:
a regression that doubles allocation count won't surface in the
correctness tests but will show up here.

## Indicative numbers

| benchmark                           | time      |
|-------------------------------------|-----------|
| render small fragment               | ~290 ns   |
| render 50-row table                 | ~14 µs    |
| render 100-field form               | ~24 µs    |
| escape 10k adversarial chars        | ~48 µs    |
| `html_response` of a small fragment | ~460 ns   |
| `fragment_response` with selector   | ~670 ns   |
| `patch_svg` on a 200-path SVG       | ~130 µs   |
| `patch_svg` on a 1000-path SVG      | ~630 µs   |
| `parse_signals` of a 4-key body     | ~640 ns   |
| `parse_signals` of a 50-key body    | ~5 µs     |

Numbers vary with CPU and Julia version. Treat the relative shape
(small fragment ≪ table ≪ form ≪ svg patch) as the contract, not the
absolute nanoseconds. Regenerate with the command above after renderer
changes.

## Workloads

### `render small fragment`

A `div(id=…, class=…, small(class=…, "~12,345 images match"))` — the
shape a `fragment_response` handler typically emits to update a count
or status line. Stresses the per-attribute and per-child cost
without amortizing it across a large tree.

### `render table 50 rows`

A `<table>` of 50 `<tr>`s, three `<td>`s each. The realistic upper
bound for a Datastar-morph data view; bigger tables paginate.

### `render wide form 100 fields`

A `<form>` carrying one `data-on:submit` binding
(`on_submit(ds_post("/save"; form=true))`) and wrapping a
`<fieldset>`/`<legend>` of 100 `radio_field` entries. Each entry renders
as a `<label>` around an `<input type="radio">` with `name`, `value`,
and (on the first only) a `checked` flag. Stresses attribute emission,
the form-helper layer (`radio_field` / `fieldset` / `legend`), and the
`on(...)` / `DSAction` formatting path.

### `escape 10k adversarial chars`

A 10 KB string that's 100% HTML metacharacters (`<>&"'`). Pins the
cost of the `escape_html` inner loop; the run-of-safe-bytes
fast path doesn't help here. This is the worst case by construction —
real text is mostly safe runs, each flushed with a single
`unsafe_write`, so the per-character entity branch fires rarely; treat
~48 µs/10 KB as a ceiling, not a typical cost.

### `html_response` / `fragment_response`

The render benchmark plus the `HTTP.Response` allocation and (for
`fragment_response`) the `datastar-selector` header. Measures the
end-to-end cost of returning a body from a handler.

### `patch_svg` on 200- and 1000-path SVGs

A synthetic CairoMakie-shaped *input* SVG with N `<path>`-like elements:
XML prolog, fixed `width="800px"` / `height="600px"`, and
`clip0…clipN` / `glyph0…glyphN` ids. `patch_svg` exercises both the
regex passes and the `id_prefix` rewrite over that input. The 1000-path
case roughly matches a busy histogram or scatter.

### `parse_signals` of 4- and 50-key JSON bodies

[`parse_signals`](@ref) runs on every Datastar action POST that
carries form state. Both sizes are realistic — a 4-key body is a
filter form, a 50-key body is a settings dialog.

## Concurrent serving

[`render`](@ref) is safe to call from many threads at once — the
expected shape when HTTP.jl serves requests on a thread pool. `render`
itself holds no shared mutable state. The only shared state is the
tag-name / attribute-name validator cache: a `Set` of validated
`Symbol`s behind a `ReentrantLock`. A bare concurrent `push!` could
corrupt the `Set`, so every lookup takes the lock, hits included. A hit
is lock, `Set` membership test, unlock. A miss validates the name
outside the lock, then re-takes it to insert. Inserts happen only during
the first burst of traffic, one per distinct tag/attribute name, so the
lock is uncontended in steady state.

## Future work

Threshold-gated CI is a 1.0 concern. A nightly job that records per-case
medians on a `bench-history` branch, a paper trail with no regression
alarm, is planned.
