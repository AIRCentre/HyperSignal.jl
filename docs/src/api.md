# API reference

Every exported name. Docstrings live alongside the source — this page
just indexes them so the rendered docs site has clickable cross-references.

## Module overview

```@docs
HyperSignal
```

## Element tree

```@docs
Element
Frag
Raw
Attribute
HyperSignal.DOCTYPE
```

## Rendering

```@docs
render
```

## HTTP response wrappers

```@docs
html_response
fragment_response
signals_response
script_response
sse_response
sse_stream
patch_elements
patch_signals
redirect_via_fragment
redirect_to
```

## Version pinning

```@docs
DATASTAR_SUPPORTED_VERSION
```

## Datastar actions

```@docs
DSAction
ds_get
ds_post
ds_put
ds_delete
on
on_click
on_submit
on_change_debounced
on_interval
```

## Datastar attributes

```@docs
ds_indicator
ds_ignore_morph
ds_bind
ds_signal
ds_signals
ds_show
ds_text
ds_json_signals
ds_ref
ds_attr
ds_class
ds_computed
ds_style
ds_effect
ds_init
```

## Signal decoding

```@docs
parse_signals
```

## Component helpers

Top-level — primitives that don't pull in an app idiom:

```@docs
cls
```

### HyperSignal.Helpers

App-grade building blocks. Pull them in with `using HyperSignal.Helpers:
…` — there is no top-level export and no deprecation shim.

```@docs
HyperSignal.Helpers.radio_field
HyperSignal.Helpers.checkbox_field
HyperSignal.Helpers.text_field
HyperSignal.Helpers.form_legend
HyperSignal.Helpers.form_section
HyperSignal.Helpers.help_tooltip
HyperSignal.Helpers.preset_button
HyperSignal.Helpers.signal_dialog
```

## CairoMakie SVG inlining

```@docs
patch_svg
inline_svg
```

## Macros

```@docs
@using_tags
```
