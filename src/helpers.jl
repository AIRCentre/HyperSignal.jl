"""
    cls(parts...) -> String

Build a CSS class string from a mix of inputs:

- `AbstractString` → kept as-is (empty strings drop).
- `"name" => bool` → included only when the bool is true.
- `Vector`, `Tuple`, `NamedTuple` or `AbstractSet` of any of the above → flattened.
- `nothing` / `missing` → skipped.

No match → `""`, so `class=cls(...)` is always safe. Pair values that
aren't `Bool` throw `ArgumentError`; `"active" => "yes"` would otherwise
silently include the class. Other types throw `ArgumentError` too.

# Examples
```jldoctest
julia> cls("btn", "primary", "active" => true)
"btn primary active"

julia> cls("btn", "primary", "active" => false)
"btn primary"

julia> cls("btn", ["large", "rounded"], "loading" => false)
"btn large rounded"

julia> cls()
""
```
"""
function cls(parts...)
    out = String[]
    for p in parts
        _push_cls!(out, p)
    end
    join(out, " ")
end

_push_cls!(out, ::Nothing) = nothing
_push_cls!(out, ::Missing) = nothing
_push_cls!(out, s::AbstractString) = (isempty(s) || push!(out, String(s)); nothing)
_push_cls!(out, p::Pair{<:AbstractString, Bool}) =
    (p.second && push!(out, String(p.first)); nothing)
_push_cls!(out, p::Pair{<:AbstractString, <:Any}) =
    throw(ArgumentError("cls: Pair value must be Bool, got $(typeof(p.second))"))
# Collections only: a Number is a 1-iterable yielding itself, so `cls("a", 1)`
# would recurse through the Any fallback into a stack overflow.
function _push_cls!(out, xs::Union{AbstractVector, Tuple, NamedTuple, AbstractSet})
    for x in xs
        _push_cls!(out, x)
    end
end
_push_cls!(out, x) =
    throw(ArgumentError("cls: don't know how to handle $(typeof(x)) ($(repr(x))); pass a String, a Pair{String,Bool}, or a Vector/Tuple of those"))

"""
    redirect_to(location::AbstractString; cookies=String[]) -> HTTP.Response

Plain HTTP 303 redirect for non-Datastar flows (login POST, logout, direct
navigation). `cookies` is a vector of complete `Set-Cookie` header values
sent with the redirect.

For Datastar form submits that navigate on success, use
[`redirect_via_fragment`](@ref): Datastar's morph won't follow a 303.

# Examples
```jldoctest
julia> r = redirect_to("/dashboard");

julia> r.status
303

julia> Dict(r.headers)["Location"]
"/dashboard"

julia> r2 = redirect_to("/home";
                        cookies=["sid=abc; HttpOnly; Path=/"]);

julia> HTTP.header(r2, "Set-Cookie")
"sid=abc; HttpOnly; Path=/"
```
"""
function redirect_to(location::AbstractString; cookies::AbstractVector=String[])
    headers = Pair{String, String}["Location" => String(location)]
    append!(headers, ("Set-Cookie" => String(c) for c in cookies))
    HTTP.Response(303, headers)
end

module Helpers

using ..HyperSignal: Element, Frag, Raw, Attribute,
                      div, span, small, label, input, legend, button,
                      dialog,
                      on, ds_signals, ds_show, ds_effect

export radio_field, checkbox_field, text_field,
       help_tooltip, form_legend, form_section,
       preset_button, signal_dialog

_named_input_field(itype::AbstractString,
                    name::AbstractString,
                    value::AbstractString,
                    text::AbstractString,
                    checked::Bool) =
    label(input(type=String(itype), name=String(name),
                 value=String(value), checked=checked),
          " $(text)")

"""
    radio_field(name::AbstractString, value::AbstractString, text::AbstractString; checked=false)

Render `<label><input type="radio" name=… value=… [checked]> text</label>`.

# Examples
```jldoctest
julia> render(radio_field("size", "S", "Small"))
"<label><input type=\\"radio\\" name=\\"size\\" value=\\"S\\"> Small</label>"

julia> render(radio_field("size", "L", "Large"; checked=true))
"<label><input type=\\"radio\\" name=\\"size\\" value=\\"L\\" checked> Large</label>"
```
"""
radio_field(name::AbstractString, value::AbstractString, text::AbstractString;
             checked::Bool=false) =
    _named_input_field("radio", name, value, text, checked)

"""
    checkbox_field(name::AbstractString, text::AbstractString; checked=false, value="on")

Render a `<label><input type="checkbox" name=… value=… [checked]> text</label>`.
The default `value="on"` is the browser's own value for a checked checkbox
and what form parsers expect; change it only if your backend wants another.

# Examples
```jldoctest
julia> render(checkbox_field("notify_email", "Email"))
"<label><input type=\\"checkbox\\" name=\\"notify_email\\" value=\\"on\\"> Email</label>"

julia> render(checkbox_field("agree", "I agree"; checked=true))
"<label><input type=\\"checkbox\\" name=\\"agree\\" value=\\"on\\" checked> I agree</label>"

julia> render(checkbox_field("opt", "Opt-in"; value="yes"))
"<label><input type=\\"checkbox\\" name=\\"opt\\" value=\\"yes\\"> Opt-in</label>"
```
"""
checkbox_field(name::AbstractString, text::AbstractString;
                checked::Bool=false, value::AbstractString="on") =
    _named_input_field("checkbox", name, value, text, checked)

"""
    text_field(label_text::AbstractString, name::AbstractString;
               type="text", required=false)

Render a `<label for=name>text</label><input type=… id=name name=name [required]>`
pair as a [`Frag`](@ref). `for`/`id` tie them: clicking the label focuses
the input, and screen readers announce the label.

Defaults to `type="text"`; pass `type="password"` for a masked input.
`required=true` makes the browser block submit while the field is empty.

# Examples
```julia
form(on_submit(ds_post("/login"; form=true)),
    text_field("Username", "username"; required=true),
    text_field("Password", "password"; type="password", required=true),
    button(type="submit", "Log in"))
```
"""
function text_field(label_text::AbstractString, name::AbstractString;
                     type::AbstractString="text", required::Bool=false)
    n = String(name)
    Frag(
        label(:for => n, label_text),
        input(type=String(type), id=n, name=n, required=required),
    )
end

"""
    DEFAULT_HELP_ICON :: Raw

Default question-mark-in-circle SVG for [`help_tooltip`](@ref). Override
with `help_tooltip(text; icon=…)`.
"""
const DEFAULT_HELP_ICON = Raw("""
    <svg class="help-icon" viewBox="0 0 24 24" fill="none"
        stroke="currentColor" stroke-width="1.5"
        stroke-linecap="round" stroke-linejoin="round">
    <circle cx="12" cy="12" r="10"/>
    <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/>
    <path d="M12 17h.01"/></svg>""")

"""
    help_tooltip(text::AbstractString; icon=DEFAULT_HELP_ICON)

Render (attribute values shown unescaped; `data-effect`, which positions
the popup inside the viewport, omitted)
```html
<span class="help-trigger" tabindex="0"
      data-signals='{"help_open":"","help_hover":""}'
      data-on:mouseenter="\$help_hover = '<id>'"
      data-on:mouseleave="\$help_hover = ''"
      data-on:click__outside="\$help_open === '<id>' && (\$help_open = '')">
  <span class="help-icon-wrap"
        data-on:click="\$help_open = \$help_open === '<id>' ? '' : '<id>'">
    [icon]
  </span>
  <span class="help-popup" role="tooltip" style="display: none"
        data-show="\$help_open === '<id>' || \$help_hover === '<id>'">text</span>
</span>
```
The popup opens on hover, closes on mouseleave, and toggles on click of
the icon. It stays open until a click outside the trigger (Datastar's
`__outside` modifier). `<id>` is a base-36 hash of the tooltip text, so
equal texts share state. `hash` is stable within one Julia version only,
so don't persist or compare ids across versions.

Tooltip text is escaped. Override `icon` with any [`Raw`](@ref) or
[`Element`](@ref).

[`form_legend`](@ref) pairs a legend with this tooltip in one call.

# Examples
```julia
legend("Confidence ", help_tooltip("ML certainty range. Lower = ambiguous."))
```
"""
function help_tooltip(text::AbstractString; icon=DEFAULT_HELP_ICON)
    id = string(hash(text) % UInt32; base=36)
    open_expr = "\$help_open === '$(id)' || \$help_hover === '$(id)'"
    # `&&` skips measuring while closed; rAF waits for data-show to unhide
    # and layout. `el` isn't captured across nested closures in Datastar's
    # expression compiler, so it's passed into an arrow fn. Position resets
    # first, else a once-flipped tooltip stays flipped.
    reposition_js = "($(open_expr)) && ((e) => requestAnimationFrame(() => {" *
        "e.style.left=''; e.style.right=''; e.style.top=''; e.style.bottom='';" *
        "const r=e.getBoundingClientRect();" *
        "if(r.right>innerWidth-8){e.style.left='auto'; e.style.right='0';}" *
        "if(r.bottom>innerHeight-8){e.style.top='auto'; e.style.bottom='calc(100% + 0.3rem)';}" *
        "}))(el)"
    span(class="help-trigger", tabindex="0",
         # Repeat declarations are no-ops: the signals already exist in the store.
         ds_signals((help_open="", help_hover="")),
         on(:mouseenter, "\$help_hover = '$(id)'"),
         on(:mouseleave, "\$help_hover = ''"),
         # Only the open tooltip closes; else opening B while A is open briefly clears both.
         on(:click, "\$help_open === '$(id)' && (\$help_open = '')";
            outside=true),
         # Scoped to the icon: clicks inside the popup (selecting text) must not toggle it.
         span(class="help-icon-wrap",
              on(:click, "\$help_open = \$help_open === '$(id)' ? '' : '$(id)'"),
              icon),
         span(class="help-popup", role="tooltip",
              # data-show only toggles inline `display`; without this the SSR'd
              # popup flashes visible until Datastar initialises.
              Symbol("style") => "display: none",
              ds_show(open_expr),
              ds_effect(reposition_js),
              String(text)))
end

"""
    form_legend(text::AbstractString; tooltip=nothing)

Render `<legend class="muted">text [help-tooltip]</legend>`. `tooltip`
attaches an inline [`help_tooltip`](@ref); without it the legend is plain.

# Examples
```jldoctest
julia> render(form_legend("Size"))
"<legend class=\\"muted\\">Size</legend>"
```

With a tooltip the output embeds a hashed id, so there is no doctest; see
[`help_tooltip`](@ref) for the markup.
"""
function form_legend(text::AbstractString; tooltip::Union{Nothing, AbstractString}=nothing)
    if isnothing(tooltip)
        legend(class="muted", String(text))
    else
        legend(class="muted", String(text), " ", help_tooltip(tooltip))
    end
end

"""
    form_section(label_text::AbstractString, cards...)

Wrap "card" elements (typically `<article>`s) under a muted section
header. Returns a [`Frag`](@ref) of `<small class="muted
form-section-label">label</small>` and `<div
class="form-card-grid">cards…</div>`. No wrapper element, so it inlines
into a `<form>`.

# Examples
```julia
form_section("Image Batch",
    article(fieldset(form_legend("Size"), radio_field("n", "10", "10"))),
    article(fieldset(form_legend("Source"), radio_field("src", "a", "A"))),
)
```
"""
function form_section(label_text::AbstractString, cards...)
    Frag(
        small(class="muted form-section-label", String(label_text)),
        div(class="form-card-grid", cards...),
    )
end

"""
    preset_button(text::AbstractString, settings::AbstractVector{<:Pair{<:AbstractString,<:AbstractString}})

Render a "preset" button: clicking it sets each named radio input to
`checked` (matching `value`) and fires `input` on it, so a `data-bind`
on the radio updates its signal. It then dispatches a bubbling `change`
event on the form so any `data-on:change` handler (e.g. a live-count GET)
recomputes. `settings` is a vector of `name => value` pairs identifying
the radios to flip. Each name must be an ASCII CSS identifier, else
`ArgumentError`.

# Examples
```julia
fieldset(
    form_legend("Quick presets"),
    preset_button("Easy", ["confidence" => "all", "label_filter" => "both"]),
    preset_button("Hard", ["confidence" => "hard", "label_filter" => "iw"]),
)
```
"""
function preset_button(text::AbstractString,
                       settings::AbstractVector{<:Pair{<:AbstractString, <:AbstractString}})
    io = IOBuffer()
    for (name, val) in settings
        _validate_preset_name(name)
        print(io, "{const e=document.querySelector('input[name=", name,
              "][value=\"", _escape_preset_value(val), "\"]');",
              "e.checked=true;e.dispatchEvent(new Event('input',{bubbles:true}));}")
    end
    print(io, "this.form.dispatchEvent(new Event('change',{bubbles:true}))")
    button(type="button", class="secondary outline", onclick=String(take!(io)),
           String(text))
end

# `name` lands unquoted in `input[name=…]`. A digit start (`123`, `-1`) makes
# querySelector throw SyntaxError at click time, silently disabling the preset.
# `\z`, not `$`: PCRE `$` also matches before a trailing newline.
function _validate_preset_name(name::AbstractString)
    occursin(r"^-?[A-Za-z_][A-Za-z0-9_-]*\z", name) ||
        throw(ArgumentError("preset_button: input name must be an ASCII CSS identifier " *
              "(letter or underscore start, then [A-Za-z0-9_-]), got $(repr(name))"))
end

# `val` sits in the CSS `[value="…"]` inside the single-quoted `querySelector('…')`
# arg, so both quote kinds terminate a JS string. HTML layer: attribute escape.
_escape_preset_value(v::AbstractString) =
    replace(v, "\\" => "\\\\", "\"" => "\\\"", "'" => "\\'")

"""
    signal_dialog(open_expr, body...; close_action, id=nothing, class="")

Render a `<dialog>` whose open/close state is mirrored to a Datastar
expression:

- `data-effect` reads `open_expr`; truthy → `el.showModal()` (top layer,
  native focus trap, ESC, `::backdrop`), falsy → `el.close()`. Datastar
  exposes the host element as `el`; `this` is the signals proxy, not the
  DOM node.
- `data-on:close` runs `close_action` however the dialog closes (ESC,
  programmatic, form `method=dialog`), keeping the bound signal in sync.
- `data-on:click` runs `close_action` when `event.target === el`
  (backdrop click). Wrap inner content in a child element (`<div>` /
  `<article>`) so its clicks don't match.

`close_action` is a JS statement (no trailing semicolon needed) that
resets the signal to its closed state, e.g. `"\$modal = 0"` or
`"\$confirmOpen = false"`.

# Examples
```julia
# Lightbox indexed by an integer signal
signal_dialog("\$lightbox",
    div(class="lightbox-frame",
        (panel(i) for i in 1:n)...);
    close_action="\$lightbox = 0", class="image-lightbox")

# Boolean-driven confirm dialog
signal_dialog("\$confirmOpen",
    article(header(strong("Confirm")), p("Commit?"),
        button(on_click(ds_post("/api/commit")), "Yes"),
        button(on_click("\$confirmOpen = false"), "No"));
    close_action="\$confirmOpen = false", id="confirm-commit-dialog")
```
"""
function signal_dialog(open_expr::AbstractString, body...;
                       close_action::AbstractString,
                       id::Union{Nothing, AbstractString}=nothing,
                       class::AbstractString="")
    attrs = Any[
        ds_effect("($(open_expr)) ? el.showModal() : el.close()"),
        on(:close, close_action),
        on(:click, "if(event.target===el){$(close_action)}"),
    ]
    isnothing(id)  || push!(attrs, :id => String(id))
    isempty(class) || push!(attrs, :class => String(class))
    dialog(attrs..., body...)
end

end # module Helpers
