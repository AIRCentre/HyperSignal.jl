# Vendored MapLibre GL JS assets

Pinned, offline copies of the MapLibre GL JS library so the demo notebooks
load a fixed version without a CDN round-trip. The **basemap** is *not*
vendored — `example.jl` points `map_view`'s `style` at the live
`https://demotiles.maplibre.org/style.json`, which pulls vector tiles,
glyphs, and the `crimea` GeoJSON from MapLibre's demo server at view time.
(The demotiles vector pyramid spans z0–z6 / ~5,400 tiles, too large to
vendor; per #29 we ship the library here and fetch the basemap live.)

## Version

`maplibre-gl@6.18.0` — 3-Clause BSD.

## Files & source URLs

| File                     | Source                                                           |
|--------------------------|------------------------------------------------------------------|
| `maplibre-gl.mjs`        | https://unpkg.com/maplibre-gl@6.18.0/dist/maplibre-gl.mjs        |
| `maplibre-gl-worker.mjs` | https://unpkg.com/maplibre-gl@6.18.0/dist/maplibre-gl-worker.mjs |
| `maplibre-gl.css`        | https://unpkg.com/maplibre-gl@6.18.0/dist/maplibre-gl.css        |
| `LICENSE.txt`            | https://unpkg.com/maplibre-gl@6.18.0/LICENSE.txt                 |

6.x ships only ES modules. `maplibre-gl.mjs` loads `maplibre-gl-worker.mjs`
from its own directory, so serve both side by side.

`LICENSE.txt` is the MapLibre BSD-3 text, redistributed as the license
requires.

## Refreshing

```bash
V=6.18.0
cd docs/src/notebooks/assets/maplibre
for f in dist/maplibre-gl.mjs dist/maplibre-gl-worker.mjs dist/maplibre-gl.css LICENSE.txt; do
  curl -sS "https://unpkg.com/maplibre-gl@$V/$f" -o "$(basename "$f")"
done
# Source maps are not vendored; drop the links so devtools don't 404.
sed -i '/^\/\/# sourceMappingURL=/d' maplibre-gl.mjs maplibre-gl-worker.mjs
```

Then bump the version references above.
