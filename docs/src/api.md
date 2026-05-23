# API reference

Every exported name. Docstrings live alongside the source — this page
just indexes them so the rendered docs site has clickable cross-references.

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
redirect_via_fragment
redirect_to
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
ds_ref
ds_attr
ds_class
ds_effect
ds_init
```

## Signal decoding

```@docs
parse_signals
```

## Component helpers

```@docs
cls
radio_field
checkbox_field
text_field
form_legend
form_section
help_tooltip
preset_button
signal_dialog
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
