const _CHORD_MODIFIERS = (:mod, :ctrl, :meta, :alt, :shift)
# evt.key names of the modifier keys; as the chord's key they need their own flag set.
const _MODIFIER_EVT_KEYS = (:Shift, :Control, :Alt, :Meta, :AltGraph)
# Common key names that evt.key never reports, with the name it does.
const _KEY_MISNAMES = Dict(:Space => Symbol(" "), :Spacebar => Symbol(" "), :Esc => :Escape,
                           :Del => :Delete, :Return => :Enter, :Left => :ArrowLeft,
                           :Right => :ArrowRight, :Up => :ArrowUp, :Down => :ArrowDown)

# Set by `navigate` and `redirect_via_fragment` so `confirm_leave` lets that one exit through.
const _LEAVING_FLAG = "window.__hs_leaving"

# The flag drops on the next task: `beforeunload` has run by then, and a URL
# that does not unload the page (a download, a 204) or that throws must not
# disarm the guard.
_leave_js(url::AbstractString) =
    "$_LEAVING_FLAG=true;try{window.location.href='$(_js_str_escape(url))'}" *
    "finally{setTimeout(function(){$_LEAVING_FLAG=false})}"

function _key_test(chord)
    chord isa Symbol || (chord isa Tuple && all(k -> k isa Symbol, chord)) || throw(ArgumentError(
        "on_keys: a chord is a Symbol or a tuple of Symbols, got $(repr(chord))"))
    keys = chord isa Symbol ? (chord,) : chord
    isempty(keys) && throw(ArgumentError("on_keys: a key chord needs at least a key"))
    mods = keys[1:end-1]
    name = String(keys[end])
    # `__k === ''` would match a keydown with no evt.key, such as autofill's.
    isempty(name) && throw(ArgumentError("on_keys: a key name is empty"))
    # A modifier or a lowercase named key (:escape) as the key builds a test no
    # key event passes; evt.key names are capitalised (Escape, ArrowUp).
    (keys[end] in _CHORD_MODIFIERS || keys[end] in _MODIFIER_EVT_KEYS || (length(name) > 1 && islowercase(name[1]))) && throw(ArgumentError(
        "on_keys: $(repr(keys[end])) is not a key; end a chord with a character or an evt.key name such as :Escape"))
    haskey(_KEY_MISNAMES, keys[end]) && throw(ArgumentError(
        "on_keys: no key event is named $(repr(keys[end])); use $(repr(_KEY_MISNAMES[keys[end]]))"))
    # :mod already is Ctrl or Cmd; a second one would be dropped from the test.
    :mod in mods && (:ctrl in mods || :meta in mods) && throw(ArgumentError(
        "on_keys: :mod is Ctrl or Cmd; use it without :ctrl or :meta"))
    for m in mods
        m in _CHORD_MODIFIERS || throw(ArgumentError(
            "on_keys: unknown modifier :$m; expected :mod (Ctrl or Cmd), :ctrl, :meta, :alt or :shift"))
    end
    key = length(name) == 1 ? lowercase(name) : name
    flag(m, v) = m in mods ? v : "!" * v
    ctrl_meta = :mod in mods ? "(__c || __m)" : flag(:ctrl, "__c") * " && " * flag(:meta, "__m")
    # Shift picks the character on a punctuation key ('?' is Shift+/ on a US
    # layout), so there it counts only when the chord names it.
    shift = length(name) == 1 && !isletter(name[1]) && :shift ∉ mods ? "" : " && " * flag(:shift, "__s")
    "__k === $(_js_value(key)) && $ctrl_meta && $(flag(:alt, "__a"))" * shift
end

_key_action(a::DSAction) = action_js(a)
_key_action(a::AbstractString) = String(a)

"""
    on_keys(chord => action, ...) -> Attribute

Bind keyboard shortcuts with one `data-on:keydown__window` listener. A chord
is a key Symbol (`:l`, `:Delete`) or a tuple of modifiers and a key
(`(:shift, :mod, :z)`). `:mod` is Ctrl or Cmd; the other modifiers are
`:ctrl`, `:meta`, `:alt` and `:shift`, and an unknown one throws
`ArgumentError`. Modifiers match exactly, so `(:mod, :z)` does not fire on
Ctrl+Shift+Z; Shift is ignored on a punctuation key unless the chord names
it, so `:?` fires on Shift+/. `:L` and `:l` bind the same key; named keys
match `evt.key` as written, and a lowercase one throws. Keys match on
`evt.key`, so an `(:alt, letter)` chord does not fire on macOS, where Option
turns the letter into another character, and a letter chord does not fire
on a layout that types another script (Cyrillic, Greek). A match calls `preventDefault`. No
shortcut fires while focus is in a text field, textarea, select or
contenteditable element.

# Examples
```julia
on_keys((:mod, :z) => ds"\$count = \$count - 1",
        :Escape => ds"\$open = false")
```
"""
function on_keys(bindings::Pair...)
    isempty(bindings) && throw(ArgumentError("on_keys needs at least one chord => action"))
    io = IOBuffer()
    print(io, "const __t = document.activeElement; ",
          raw"if (__t && (__t.isContentEditable || /^(TEXTAREA|SELECT)$/.test(__t.tagName) || ",
          raw"(__t.tagName === 'INPUT' && !/^(checkbox|radio|range|button|submit|reset|color|file|image)$/.test(__t.type)))) return; ",
          "const __e = evt.key || ''; ",
          "const __k = __e.length === 1 ? __e.toLowerCase() : __e; ",
          "const __c = evt.ctrlKey, __m = evt.metaKey, __a = evt.altKey, __s = evt.shiftKey;")
    tests = String[]
    for (chord, action) in bindings
        test = _key_test(chord)
        # Only the first of two equal tests ever runs.
        test in tests && throw(ArgumentError("on_keys: $(repr(chord)) repeats an earlier chord"))
        push!(tests, test)
        print(io, " if (", test, ") { evt.preventDefault(); ",
              _key_action(action), "; return }")
    end
    on(:keydown, String(take!(io)); window=true)
end

"""
    confirm_leave(when = ds"\$dirty") -> Attribute

Ask the browser to confirm leaving the page while the Datastar expression
`when` is true. A [`navigate`](@ref) event or a
[`redirect_via_fragment`](@ref) leaves without asking.
"""
confirm_leave(when::AbstractString = ds"$dirty") = on(:beforeunload,
    "if (($when) && !$_LEAVING_FLAG) { evt.preventDefault(); evt.returnValue = '' }"; window=true)
