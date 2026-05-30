# MapLibre maps

HyperSignal ships an optional [MapLibre GL](https://maplibre.org)
integration as a package extension. It turns a map into a Datastar
input surface: the server renders the map and its layers, the browser
reports viewport / cursor / click / drag-box back as signals or
`@post`s, and the server answers with JS snippets that recolor, fly, or
swap data in place — no client-side map code to write.

## Loading the extension

The extension is gated on the `GeoInterface` weakdep, so top-level
`HyperSignal` exports nothing new. Bring `GeoInterface` (or anything
that loads it) into your session to trigger loading, then reach the API
by name:

```julia
using HyperSignal, GeoInterface
const M = Base.get_extension(HyperSignal, :HyperSignalMapLibreExt)

# now M.map_view, M.fill_layer, M.geojson_source, … are available
```

Aliasing the extension to a short name (`M`) keeps call sites readable.
You also need the MapLibre GL JS/CSS on the page — HyperSignal vendors a
pinned `maplibre-gl@5.24.0` bundle under
`docs/src/notebooks/assets/maplibre/`; serve those two files and link
them in your `<head>`.

## A map on the page — `map_view`

`map_view` returns an `Element` tree: a namespaced container `div` plus
a `<script>` that constructs the `maplibregl.Map`, publishes the
instance to `window.__hs_maps[id_prefix]`, and wires the channels you
opt into.

```julia
M.map_view(;
    id_prefix = "sst_",
    style     = "https://demotiles.maplibre.org/style.json",
    center    = (-30.0, 38.0),   # (lon, lat)
    zoom      = 3,
    sources   = (sst = M.geojson_source(fc),),
    layers    = (M.fill_layer("sst-fill"; source="sst", paint=paint),),
    bounds_signal = "view_bounds",
    cursor_signal = "cursor",
    bbox_post     = "/timeseries",
    click_post    = "/inspect",
    click_layers  = ["sst-fill"],
)
```

| Keyword | Effect |
| --- | --- |
| `id_prefix` | Namespaces the container id, the instance handle, and every channel event. Defaults to `"map_"`; set a unique value per map so two maps on a page don't collide. |
| `style` | MapLibre style URL or inline style object. Required. |
| `center` / `zoom` | Initial camera. `center` is `(lon, lat)`. |
| `sources` | `NamedTuple` of `name => source`; added on the map's `load` event. |
| `layers` | Tuple of layer specs; added after the sources. |
| `center_signal` / `zoom_signal` / `bounds_signal` | Signal names written on `moveend` (idle). |
| `cursor_signal` | Signal name written `[lon, lat]` on every `mousemove`. |
| `click_post` | URL `@post`ed on click; the payload signal `$payload` holds `{lat, lon, properties}` from the top feature under the cursor (restricted to `click_layers`). |
| `bbox_post` | URL `@post`ed after a shift-drag rectangle; `$payload` holds `{w, s, e, n}`. |
| `click_layers` | Layer ids `queryRenderedFeatures` restricts to for the click payload. |

Each channel you leave at `nothing` emits no handler — the script body
carries no dead stubs.

### How the Datastar bridge works

`map_view` follows Datastar's "props down, events up" pattern. The
script body is plain JS: a map event (`moveend`, `mousemove`, `click`,
shift-drag) dispatches a `CustomEvent` on `document` with `bubbles:
true`. `map_view` renders a matching `data-on:hs-<prefix><channel>__window`
attribute on the container; that attribute is where the real Datastar
expression lives — a `$signal = evt.detail` assignment for the viewport
/ cursor channels, or `$payload = evt.detail; @post('…')` for the click
/ bbox channels. Keeping `@post` and `$signal` inside attribute context
(the only place Datastar parses them) lets the script body stay plain
JS.

## Markers — `marker`

`marker` renders a `<div data-hs-marker="<prefix>">`; `map_view`'s init
script scans for those divs on `load` and attaches each as a real
`maplibregl.Marker`. The div itself becomes the marker element, so its
(auto-escaped) HyperSignal content renders inside the marker.

```julia
div(
    M.map_view(; id_prefix="m_", style=STYLE, center=(-28.0, 38.5), zoom=6),
    M.marker(span(class="pin", "⚓"); lat=38.53, lon=-28.63,
             popup=strong("Azores"), id_prefix="m_"),
)
```

Pass the **same `id_prefix`** to `marker` as to its `map_view`. The
optional `popup` is rendered and wired to a `maplibregl.Popup`.

## Sources

```julia
M.geojson_source(data; cluster=false, cluster_radius=50)
M.raster_xyz_source(tiles; tile_size=256, attribution="")
```

- `geojson_source` — `data` is an inline GeoJSON object (a `Dict`, e.g.
  from `feature_collection` below) or a URL string MapLibre fetches.
  Set `cluster=true` for point clustering.
- `raster_xyz_source` — XYZ basemap tiles; `tiles` is a vector of URL
  templates (at least one, or it throws).

## Layers

```julia
M.fill_layer(id;   source, paint=…, layout=…, filter=…, source_layer=…)
M.line_layer(id;   source, …)
M.circle_layer(id; source, …)
M.raster_layer(id; source, …)
```

All four forward the same keywords to a shared builder. `paint` and
`layout` take a `Dict` or a paint expression (below); `filter` takes a
MapLibre filter expression; `source_layer` selects a layer inside a
vector source.

## Paint expression DSL

MapLibre paint properties are JSON expression arrays. The DSL builds
them as typed values that JSON-encode to the right wire form:

| Helper | Wire form | Use |
| --- | --- | --- |
| `prop_get(:mean_sst)` | `["get", "mean_sst"]` | Read a feature property (accepts `Symbol` or `String`). |
| `literal(x)` | `["literal", x]` | Force a value to be data, not a nested expression. |
| `linear()` | `["linear"]` | Interpolation-kind marker for `interpolate`. |
| `interpolate(kind, input, stops...)` | `["interpolate", …]` | Interpolate a numeric input across `value => paint` stop pairs (needs ≥1 stop). |
| `expr_step(input, default, stops...)` | `["step", …]` | Step function: leading `default`, then `threshold => value` pairs. |
| `expr_match(input, cases...; default)` | `["match", …]` | Match on a value; `default` is **required** (a missing default would silently paint unmatched features transparent). |

```julia
paint = Dict(
    "fill-color" => M.interpolate(M.linear(), M.prop_get(:mean_sst),
                                  10 => "#2c7bb6",
                                  18 => "#ffffbf",
                                  26 => "#d7191c"),
    "fill-opacity" => 0.8,
)
```

`prop_get`/`expr_step`/`expr_match` are named with the `prop_`/`expr_`
prefix (rather than `get`/`step`/`match`) to avoid shadowing the `Base`
functions of those names inside the extension.

## Building GeoJSON from geometry

The GeoInterface bridge converts any GeoInterface-conformant geometry
into the GeoJSON shape a `geojson_source` consumes:

```julia
M.geojson(geom)                          # one geometry → GeoJSON Dict
M.feature_collection(rows; geometry_col=:geom, properties_cols=(:name, :mean_sst))
```

- `geojson` dispatches on the geometry trait, so `Point`,
  `LineString`, `Polygon`, **and** the `Multi*` forms plus
  `GeometryCollection` all flow through. An unsupported trait raises a
  named `ArgumentError` (not an opaque `MethodError`).
- `feature_collection` builds a `FeatureCollection` from row-like
  records (anything iterable of `NamedTuple`s or objects with the named
  columns). A row whose `geometry_col` is `nothing` / `missing` emits
  `"geometry": null` (GeoJSON RFC 7946 §3.2) rather than crashing the
  whole collection.

## Server-returned JS helpers

Each helper returns a `Raw` JS snippet that the Datastar client runs.
They act on `window.__hs_maps[id_prefix]`, so pass the same `id_prefix`
the map was created with. Return them from a handler (e.g. via
`script_response` or inside an SSE event) in response to a `@post`.

```julia
M.fly_to(; id_prefix, center, zoom=nothing, duration_ms=600)
M.set_source_data(; id_prefix, source, data)
M.add_source(; id_prefix, id, spec)        # spec :: a Source
M.remove_source(; id_prefix, id)
M.add_layer(; id_prefix, spec)             # spec :: a Layer
M.remove_layer(; id_prefix, id)
M.set_paint_property(; id_prefix, layer, prop, value)
M.map_call(method, args...; id_prefix)     # escape hatch: m.<method>(args…)
```

`set_source_data` is the workhorse for "recolor in place": it guards
against the source not existing yet (a data swap can fire before the
map's `load`), applying immediately if the source is present or
deferring to a one-shot `load` otherwise — and always `setData`
(never re-adding the source) so layers keep their binding. `map_call`
is the escape hatch for any map method the typed helpers don't cover.

## End-to-end example

[`example.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/example.jl)
is a runnable Pluto notebook building the full map-as-input loop on
vendored NOAA ERSSTv5 sea-surface-temperature data: a `geojson_source`
of one polygon per grid cell colored by mean SST, date sliders that
`@post` a range and get back a `set_source_data` recolor, a shift-drag
box that posts `{w, s, e, n}` and gets a CairoMakie timeseries, plus
`cursor_signal`, `fly_to`, and `click_post`.
[`map_smoke.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/map_smoke.jl)
is the thin CI smoke fixture.
