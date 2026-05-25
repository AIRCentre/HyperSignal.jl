# Component helpers — small, opinionated building blocks. Each is just a
# function returning an Element (or a String for `cls`); nothing here is
# magic. The goal is that a typical form route pulls 3-5 of these and stops
# hand-rolling identical markup.

"""
    cls(parts...) -> String

Build a CSS class attribute string from a flexible mix of inputs.
Accepts:

- `AbstractString` → kept as-is (empty strings drop).
- `"name" => bool` → included only when the bool is true.
- `Vector` of any of the above → flattened.
- `nothing` / `missing` → skipped.

Empty inputs collapse to `""` so a `class=cls(...)` attribute is safe
even when nothing matches. Pair values that aren't `Bool` raise a loud
`error` — a typo like `"active" => "yes"` would otherwise silently
include the class.

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
    error("cls: Pair value must be Bool, got $(typeof(p.second))")
# Restrict the recursive walk to actual collection types. Without this
# guard, `cls("a", 1)` matched the generic Any fallback, which iterated
# the Int (Julia treats Number as a 1-iterable yielding itself) straight
# back into the same fallback — a stack overflow rather than a useful
# error.
function _push_cls!(out, xs::Union{AbstractVector, Tuple, NamedTuple, AbstractSet})
    for x in xs
        _push_cls!(out, x)
    end
end
_push_cls!(out, x) =
    error("cls: don't know how to handle $(typeof(x)) ($(repr(x))); pass a String, a Pair{String,Bool}, or a Vector/Tuple of those")

"""
    redirect_to(location::AbstractString; cookies=String[]) -> HTTP.Response

Plain HTTP 303 redirect for non-Datastar flows (login form POST, logout,
direct navigation). Pass `cookies` as a vector of complete `Set-Cookie`
header values to attach session cookies to the redirect — useful for the
post-login flow where you want to redirect AND set the session cookie in
the same response.

For Datastar form submits that need to navigate after success, use
[`redirect_via_fragment`](@ref) instead — Datastar's morph algorithm
won't follow a 303.

# Examples
```jldoctest
julia> r = redirect_to("/dashboard");

julia> r.status
303

julia> Dict(r.headers)["Location"]
"/dashboard"

julia> r2 = redirect_to("/home";
                        cookies=["sid=abc; HttpOnly; Path=/"]);

julia> [v for (k, v) in r2.headers if k == "Set-Cookie"]
1-element Vector{SubString{String}}:
 "sid=abc; HttpOnly; Path=/"
```
"""
function redirect_to(location::AbstractString; cookies::AbstractVector=String[])
    headers = Pair{String, String}["Location" => String(location)]
    append!(headers, ("Set-Cookie" => String(c) for c in cookies))
    HTTP.Response(303, headers)
end

# --- HyperSignal.Helpers ---------------------------------------------
#
# App-grade building blocks. These compose the primitives above into
# the form/dialog idioms a typical HyperSignal+Datastar service reaches
# for. They live in a submodule so the top-level v1.0 surface stays
# minimal — see issue #1 and the `## Unreleased` CHANGELOG entry. No
# top-level shim: the package is pre-1.0 with no external users, so
# an outright move was cheaper than a deprecation cycle.

module Helpers

using ..HyperSignal: Element, Frag, Raw, Attribute,
                      div, span, small, label, input, legend, button,
                      dialog,
                      on, ds_signals, ds_show, ds_effect

export radio_field, checkbox_field, text_field,
       help_tooltip, form_legend, form_section,
       preset_button, signal_dialog

# Shared body for radio_field / checkbox_field. The wrapping `<label>`
# convention (label around input, with a leading space before the visible
# text) is the same for both controls; only the input `type` and the
# caller's argument order differ.
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

Render a `<label><input type="radio" name=… value=… [checked]> text</label>`
— the label-around-input convention. One call replaces ~6 lines of
hand-built input-and-label boilerplate per choice.

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
The default `value="on"` matches the form-encoded shape `parse_form_body`
(and any standard form parser) expects — keep the default unless your
backend explicitly wants a different value.

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
pair as a [`Frag`](@ref). The `for`/`id` attribute pair ties them so the
input keeps focus when the label is clicked, and screen readers
announce the label whether or not the input is the label's child.

Defaults to `type="text"`; pass `type="password"` for a masked input.
Pass `required=true` to mark the field as a constraint the browser
enforces before allowing submit.

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

The default question-mark-in-circle SVG used by [`help_tooltip`](@ref).
Pass your own [`Raw`](@ref)/[`Element`](@ref) as `help_tooltip(text;
icon=…)` if your project uses a different glyph.
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

Render
```html
<span class="help-trigger" tabindex="0"
      data-signals="{help_open: '', help_hover: ''}"
      data-on:mouseenter="\$help_hover = '<id>'"
      data-on:mouseleave="\$help_hover = ''"
      data-on:click__outside="\$help_open === '<id>' && (\$help_open = '')">
  <span class="help-icon-wrap"
        data-on:click="\$help_open = \$help_open === '<id>' ? '' : '<id>'">
    [icon]
  </span>
  <span class="help-popup" role="tooltip"
        data-show="\$help_open === '<id>' || \$help_hover === '<id>'">text</span>
</span>
```
The popup opens on hover (and closes on mouseleave) and toggles on
click of the icon, staying open until the user clicks anywhere outside
the trigger (datastar's `__outside` modifier on a document-level
listener). `id` is a stable hash of the tooltip text so two helpers
with the same copy share state — fine, since they'd say the same thing.

Tooltip text is auto-escaped so caller copy can include quotes / `<` /
`&` without worry. Override `icon` with your own [`Raw`](@ref)/[`Element`](@ref)
for projects with a different help glyph.

Most code reaches for [`form_legend`](@ref) instead — it pairs a legend
with this tooltip in one call.

# Examples
```julia
legend("Confidence ", help_tooltip("ML certainty range. Lower = ambiguous."))
```
"""
function help_tooltip(text::AbstractString; icon=DEFAULT_HELP_ICON)
    id = string(hash(text) % UInt32; base=36)
    open_expr = "\$help_open === '$(id)' || \$help_hover === '$(id)'"
    # Position the popup so it stays in-viewport. The effect re-runs
    # whenever the open/hover signals change; the `&&` short-circuits
    # when this tooltip is closed so we only measure when shown. rAF
    # defers measurement until after data-show has un-hidden the popup
    # and the browser has laid it out.
    # `el` isn't captured across nested closures in Datastar's expression
    # compiler, so snapshot it into a local before requestAnimationFrame.
    # Reset any previously-applied position before measuring; otherwise a
    # tooltip that was once flipped right would stay flipped forever.
    reposition_js = "($(open_expr)) && ((e) => requestAnimationFrame(() => {" *
        "e.style.left=''; e.style.right=''; e.style.top=''; e.style.bottom='';" *
        "const r=e.getBoundingClientRect();" *
        "if(r.right>innerWidth-8){e.style.left='auto'; e.style.right='0';}" *
        "if(r.bottom>innerHeight-8){e.style.top='auto'; e.style.bottom='calc(100% + 0.3rem)';}" *
        "}))(el)"
    span(class="help-trigger", tabindex="0",
         # Initialise both shared signals once per page. Subsequent
         # data-signals declarations are no-ops because the values are
         # already present in the store.
         ds_signals((help_open="", help_hover="")),
         on(:mouseenter, "\$help_hover = '$(id)'"),
         on(:mouseleave, "\$help_hover = ''"),
         # Click-away closes only if this is the currently-open one, so
         # opening tooltip B while A is open doesn't briefly clear both.
         on(:click, "\$help_open === '$(id)' && (\$help_open = '')";
            outside=true),
         # Toggle on click is scoped to the icon — clicks on the popup
         # itself (e.g. to select text) bubble up to the trigger without
         # hitting this handler, so the popup stays put.
         span(class="help-icon-wrap",
              on(:click, "\$help_open = \$help_open === '$(id)' ? '' : '$(id)'"),
              icon),
         span(class="help-popup", role="tooltip",
              # Inline `display: none` is the initial state until
              # Datastar's data-show toggles it on. Without this the
              # popup briefly flashes between HTML render and JS init,
              # because data-show on its own only *toggles* the inline
              # `display` style — it doesn't paint a default-hidden
              # state for SSR'd markup.
              Symbol("style") => "display: none",
              ds_show(open_expr),
              ds_effect(reposition_js),
              String(text)))
end

"""
    form_legend(text::AbstractString; tooltip=nothing)

Render `<legend class="muted">text [help-tooltip]</legend>`. Pass
`tooltip` to attach an inline help icon via [`help_tooltip`](@ref).
Without a tooltip the result is just a plain muted legend.

# Examples
```jldoctest
julia> render(form_legend("Size"))
"<legend class=\\"muted\\">Size</legend>"
```

For the with-tooltip variant the output includes a hashed id that
isn't byte-stable across the tooltip text, so see the help_tooltip
docstring for the structural details.
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

Wrap a list of "card" elements (typically `<article>`s) under a muted
section header. Renders a [`Frag`](@ref) of `<small class="muted
form-section-label">label</small>` and `<div
class="form-card-grid">cards…</div>` — collapses the section-header +
grid pattern that opens every section in this codebase's session form.

Returns a `Frag` (no wrapper element), so it inlines into a `<form>`
without forcing an extra `<div>` you'd then have to style around.

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
`checked` (matching `value`), then dispatches a bubbling `change` event
on the form so any `data-on:change` handler (e.g. a live-count GET)
recomputes. The `<button onclick="…">` JS is built once here so each
preset doesn't repeat the escape-prone querySelector boilerplate.

`settings` is a vector of `name => value` pairs identifying the radios
to flip.

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
        print(io, "document.querySelector('input[name=", name,
              "][value=\"", _escape_preset_value(val), "\"]').checked=true;")
    end
    print(io, "this.form.dispatchEvent(new Event('change',{bubbles:true}))")
    button(type="button", class="secondary outline", onclick=String(take!(io)),
           String(text))
end

# A preset's `name` ends up as a CSS attribute selector with no quoting, so it
# must be a plain identifier — anything else would let a stray character break
# the selector or the surrounding JS. We refuse rather than silently mangle.
function _validate_preset_name(name::AbstractString)
    # `^[A-Za-z0-9_-]+$` enforces what the error message advertises: ASCII
    # identifier chars only. An earlier per-char loop used `isletter`,
    # which would have let non-ASCII letters (é, ñ, …) through despite
    # the comment promising ASCII; the regex pins the rule strictly.
    occursin(r"^[A-Za-z0-9_-]+$", name) ||
        error("preset_button: input name must match [A-Za-z0-9_-], got $(repr(name))")
end

# A preset's `val` lives inside the JS-string delimited by double-quotes inside
# the selector. Escape the JS string boundary characters; the surrounding HTML
# attribute escape handles the outer layer.
_escape_preset_value(v::AbstractString) =
    replace(v, "\\" => "\\\\", "\"" => "\\\"")

"""
    signal_dialog(open_expr, body...; close_action, id=nothing, class="")

Render a `<dialog>` whose open/close state is mirrored to a Datastar
expression. Collapses the boilerplate of pairing
`ds_effect("\$x ? \$dlg.showModal() : \$dlg.close()")` with a hand-rolled
backdrop div and gives every dialog the same close semantics:

- `data-effect` reads `open_expr`; truthy → `el.showModal()` (puts the
  dialog in the top layer with native focus trap, ESC, and `::backdrop`),
  falsy → `el.close()`. Datastar exposes the host element as `el`
  inside expressions; `this` is the signals proxy, not the DOM node.
- `data-on:close` runs `close_action` whenever the dialog closes by any
  means (ESC, programmatic, form `method=dialog`) so the bound signal
  stays in sync without the caller threading it through every dismiss
  site.
- `data-on:click` checks `event.target === el` and runs `close_action`
  — that's the standard "click the backdrop area to close" affordance.
  Inner content must be wrapped in a child element so its clicks don't
  match (a top-level child `<div>` / `<article>` is enough).

`close_action` is a JS statement (no trailing semicolon needed) that
restores the signal to its closed state — typically `"\$modal = 0"` or
`"\$confirmOpen = false"`. The same statement runs from both the
`:close` listener (ESC, programmatic) and the backdrop click, so the
signal converges to `false`/`0` no matter how the user dismissed.

# Examples
```julia
# Page-level lightbox indexed by an integer signal
signal_dialog("\$lightbox",
    div(class="lightbox-frame",
        # Each panel ds_show-gated by the signal value
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
        # Backdrop click: only fires when the user clicks the dialog
        # element itself (the area outside the inner wrapper). Inner
        # content must live in a child element so its clicks don't match.
        on(:click, "if(event.target===el){$(close_action)}"),
    ]
    isnothing(id)  || push!(attrs, :id => String(id))
    isempty(class) || push!(attrs, :class => String(class))
    dialog(attrs..., body...)
end

end # module Helpers
