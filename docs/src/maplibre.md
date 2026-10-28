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

You also need the MapLibre GL JS/CSS on the page — HyperSignal vendors a
pinned `maplibre-gl` bundle under
`docs/src/notebooks/assets/maplibre/`; serve those two files and link
them in your `<head>`. A map with [`draw`](#Drawing-—-draw) also needs the
Terra Draw scripts, loaded after MapLibre.

## A map on the page — `map_view`

`map_view` returns a `Frag`: a namespaced container `div` plus
a `<script>` that constructs the `maplibregl.Map`, publishes the
instance to `window.__hs_maps[id_prefix]`, and wires the signals and
posts you opt into.

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
| `id_prefix` | Namespaces the container id, the instance handle, and every bridge event. Defaults to `"map_"`; set a unique value per map so two maps on a page don't collide. |
| `style` | MapLibre style URL string. Required. |
| `center` / `zoom` | Initial camera. `center` is `(lon, lat)`. Give these or `bounds`, not both. |
| `bounds` / `fit_padding` | Fit the first frame to `(w=…, s=…, e=…, n=…)`, with optional pixel padding: a number, or `(top=…, bottom=…, left=…, right=…)`. |
| `rotate` | `false` turns off rotation by right-drag, touch and keyboard, and two-finger tilt; pinch-zoom still works. |
| `double_click_zoom` | `false` turns off zoom on double-click. |
| `nav_control` | Adds MapLibre's zoom buttons at `:top_left`, `:top_right`, `:bottom_left` or `:bottom_right`. The compass shows only when `rotate` is on. |
| `draw` | Line drawing with Terra Draw; see [Drawing](#Drawing-—-draw). |
| `sources` | `NamedTuple` of `name => source`; added on the map's `load` event. |
| `layers` | Tuple of layer specs; added after the sources. |
| `center_signal` / `zoom_signal` / `bounds_signal` | Signal names written on `moveend` (idle). |
| `cursor_signal` | Signal name written `[lon, lat]` on every `mousemove`. |
| `loading_signal` | Signal name set `true` once MapLibre has been fetching data (`dataloading`) for `loading_delay` ms, and `false` on `idle`. |
| `loading_delay` | Milliseconds of loading before `loading_signal` turns `true`, so short loads never flash a spinner. Defaults to `200`; `0` sets it on the next tick. |
| `click_post` | URL `@post`ed on click; the payload signal `$payload` holds `{lat, lon, properties}` from the top feature under the cursor (restricted to `click_layers`). |
| `bbox_post` | URL `@post`ed after a shift-drag rectangle; `$payload` holds `{w, s, e, n}`. |
| `click_layers` | Layer ids `queryRenderedFeatures` restricts to for the click payload. |

Each `*_signal` / `*_post` keyword you leave at `nothing` emits no
handler, so the script body carries no dead stubs.

A `map_view` patched into the page starts one map. A patch over a live
map replaces it with a fresh one, built from the patched script, with
the drawing's lines and stamp kept, and its mode when the patch morphs the
root (a `mode=:replace` patch starts from the first mode); the patch's own `features` seed
only a drawing that had not loaded. A map whose root leaves the page
removes itself; putting the same root back does not start it again. The
init script has the id `<id_prefix>init`, so no other element may use it.

### Loading indicator

`ds_indicator` can't show a map load: its request ends when the server's
script arrives, before MapLibre fetches any tiles or parses the
GeoJSON. `loading_signal` covers that wait instead, for every source,
including a `set_source_data` swap:

```julia
div(ds_signals((; map_loading = true)),
    M.map_view(; style, center, zoom, sources, layers,
               loading_signal = "map_loading"),
    span(ds_show(:map_loading), "Loading map…"))
```

Nothing is dispatched until the first `dataloading` or `idle` event, so
initialise the signal to `true` to show the indicator before the
first paint. `idle` fires once the map has also finished rendering, so
the signal can stay `true` a little after the last tile arrives. A
failed source load also ends with `false`; a tile that 404s after a
delay fires no MapLibre event and can leave it `true` until the next
render.

### How the Datastar bridge works

`map_view` follows Datastar's "props down, events up" pattern. The
script body is plain JS: a map event (`moveend`, `mousemove`, `click`,
shift-drag, `dataloading`/`idle`, and with `draw` a Terra Draw change)
dispatches a `CustomEvent` on `document` with `bubbles: true`. `map_view` renders a matching `data-on:hs-<prefix><event>__window`
attribute on the container; that attribute is where the real Datastar
expression lives — a `$signal = evt.detail` assignment for the viewport
/ cursor / loading / `$draw` signals, `$payload = evt.detail; @post('…')` for the click
/ bbox posts, or a bare `@post('…')` for `change_post`, which sends the updated `$draw`. `@post` and `$signal` stay in attribute context (the only
place Datastar parses them), so the script body stays plain JS.

## Markers — `marker`

`marker` renders a `<div data-hs-marker="<prefix>">`; `map_view`'s init
script scans for those divs on `load` and attaches each one outside a
`markers` container as a real `maplibregl.Marker`. The div itself becomes
the marker element, so its (auto-escaped) HyperSignal content renders
inside the marker.

```julia
div(
    M.map_view(; id_prefix="m_", style=STYLE, center=(-28.0, 38.5), zoom=6),
    M.marker(span(class="pin", "⚓"); lat=38.53, lon=-28.63,
             popup=strong("Azores"), id_prefix="m_"),
)
```

Pass the **same `id_prefix`** to `marker` and `markers` as to their
`map_view`. The
optional `popup` is rendered and wired to a `maplibregl.Popup`. A `lat`
outside [-90, 90] or a `lon` that is not finite throws `ArgumentError`.

A marker attaches once, at `load`. For markers the server updates, put
them in a `markers` container. It stays hidden in the page, and the map
shows copies of its children, rebuilt whenever the container changes, so a
Datastar patch of the container replaces the map's markers. The container
must be in the page when the map loads; render it empty if it starts with
no markers:

```julia
crests(sets) = M.markers((M.marker(span(class="crest", "A"); lat, lon)
                          for (lat, lon) in sets)...; id="crests")
# in a handler
sse_response([patch_elements(crests(new_sets))])
```

## Sources

```julia
M.geojson_source(data; cluster=false, cluster_radius=50)
M.raster_xyz_source(tiles; tile_size=256, attribution="")
M.image_source(url; coordinates)
```

- `geojson_source` — `data` is an inline GeoJSON object (a `Dict`, e.g.
  from `feature_collection` below) or a URL string MapLibre fetches.
  Set `cluster=true` for point clustering.
- `raster_xyz_source` — XYZ basemap tiles; `tiles` is a vector of URL
  templates (at least one, or it throws).
- `image_source` — one image placed by its 4 corners, `(lon, lat)` each,
  in the order top-left, top-right, bottom-right, bottom-left. Show it
  with a `raster_layer`.

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

## Drawing — `draw`

`map_view(; draw=M.draw_options(…))` adds line drawing with
[Terra Draw](https://github.com/JamesLMilner/terra-draw). The page loads
`terra-draw.js` and its MapLibre adapter itself, as it loads MapLibre.
HyperSignal is tested against `terra-draw@1.38.0` and
`terra-draw-maplibre-gl-adapter@1.5.0`, from their `dist/*.umd.js` builds
on unpkg.

```julia
M.map_view(; style, bounds, rotate=false, double_click_zoom=false,
    draw = M.draw_options(;
        modes = (:select, :linestring),
        properties = ds"{set: $active}",
        line_color = M.by_property("set", 0 => "#e4572e", 1 => "#17bebb"; default="#888"),
        line_dash = M.by_property("set", 0 => [], 1 => [2.5, 1.7]; default=[]),
        selected_color = "#ffffff",
        features = saved_lines,
        change_post = "/drawing/preview"))

button(on_click(M.draw_call(:undo; id_prefix="map_")),
       ds_attr("disabled", ds"!$draw.can_undo"), "Undo")
div(ds_show(ds"$draw.drawing"), "Click the last point to finish the line.")
```

| Keyword | Effect |
| --- | --- |
| `modes` | Terra Draw modes, `:select` and `:linestring`. The first one is active at start. |
| `signal` | Name of the signal object, `"draw"` by default. A dotted name or one starting with `_` throws `ArgumentError`. Two drawing maps on one page need different names. |
| `properties` | Datastar expression, re-evaluated as its signals change; its value when a line is finished is stamped on the line. If it throws, the stamp keeps its last value and the error goes to the console. |
| `line_color` / `line_dash` / `selected_color` | Line styles: a value, or `M.by_property(key, value => style…; default)` to pick by a stamped property. |
| `features` | GeoJSON `LineString` Features loaded at start. Their `properties` are their stamps. Loading them is not an undo step. Needs `:linestring` in `modes`. |
| `change_post` | URL `@post`ed after each finished edit, with the updated signals. |

Terra Draw state is in signals under `$draw`:

| Signal | Holds |
| --- | --- |
| `$draw.features` | Finished lines as GeoJSON Features with their stamps. Written after a line is finished, edited, deleted, undone or redone, never while the pointer moves. |
| `$draw.mode` | The active mode. Set it to switch modes. |
| `$draw.drawing` | `true` while a line is in progress. |
| `$draw.selected` | Ids of the selected lines. |
| `$draw.can_undo` / `$draw.can_redo` | Whether undo and redo have anything to do. |
| `$draw.rejected` | Features from `features` that Terra Draw refused as invalid. |

`M.draw_call(:undo | :redo | :delete_selected; id_prefix)` returns a
Datastar expression for a button or [`on_keys`](@ref), not a `Raw` snippet
like the server-returned helpers below. Double-clicking after a line
cancels the one-point line the second click starts.

## Server-returned JS helpers

Each helper returns a `Raw` JS snippet that the Datastar client runs.
They act on `window.__hs_maps[id_prefix]`, so pass the same `id_prefix`
the map was created with. Return them from a handler in response to a
`@post`, via `script_response` or, inside an SSE response, as
`execute_script(snippet.html)`.

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
`cursor_signal`, `fly_to`, `click_post`, and `loading_signal`.
[`map_smoke.jl`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/docs/src/notebooks/map_smoke.jl)
is the thin CI smoke fixture.
