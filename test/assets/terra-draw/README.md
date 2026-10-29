# Vendored Terra Draw

The browser tests (`test/browser.jl`) run `map_view(; draw=…)` against these
copies, so they need no network. Both are MIT; `LICENSE.txt` is the Terra Draw
license text, which covers both packages.

## Version

`terra-draw@1.38.0` and `terra-draw-maplibre-gl-adapter@1.5.0`, each with a
version header prepended to the unpkg file. `docs/src/maplibre.md` names the
same versions.

| File                                | Source                                                                               |
|-------------------------------------|--------------------------------------------------------------------------------------|
| `terra-draw.js`                     | https://unpkg.com/terra-draw@1.38.0/dist/terra-draw.umd.js                           |
| `terra-draw-maplibre-gl-adapter.js` | https://unpkg.com/terra-draw-maplibre-gl-adapter@1.5.0/dist/terra-draw-maplibre-gl-adapter.umd.js |
| `LICENSE.txt`                       | https://github.com/JamesLMilner/terra-draw/blob/main/LICENSE                         |
