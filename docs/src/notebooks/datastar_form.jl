### A Pluto.jl notebook ###
# v0.20.27

using Markdown
using InteractiveUtils

# ╔═╡ 00000001-0000-0000-0000-000000000002
using HyperSignal

# ╔═╡ 00000001-0000-0000-0000-000000000003
using HyperSignal.Helpers: radio_field, checkbox_field

# ╔═╡ 00000001-0000-0000-0000-000000000001
md"""
# HyperSignal + Datastar in Pluto

A live demo of building a Datastar form with `HyperSignal`, rendered
inline through Pluto's `text/html` MIME hook. Doubles as the fixture
for the [`pluto-smoke`](https://github.com/AIRCentre/HyperSignal.jl/blob/main/.github/workflows/pluto-smoke.yml)
CI workflow — the cell containing `div(class="card", "hello")` is what
the smoke script greps.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000004
HyperSignal.@using_tags

# ╔═╡ 00000001-0000-0000-0000-000000000005
md"""
## Smoke target

The minimal cell every CI revision asserts on: a `div` with a class
and a text node. A regression in `Base.show(::IO, ::MIME"text/html",
::Element)` flips this cell red.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000006
div(class="card", "hello")

# ╔═╡ 00000001-0000-0000-0000-000000000007
md"""
## A Datastar form

`on_submit(ds_post(...; form=true))` builds the `data-on:submit__prevent
="@post('/login', {contentType: 'form'})"` attribute the Datastar
runtime expects. The element constructor lifts `Attribute`-returning
helpers out of the children list, so they drop in positionally.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000008
login_form = form(
    on_submit(ds_post("/api/login"; form=true)),
    fieldset(
        legend("Role"),
        radio_field("role", "admin", "Admin"),
        radio_field("role", "user", "User"; checked=true),
    ),
    label(:for => "remember", checkbox_field("remember", "Keep me signed in")),
    button(type="submit", "Sign in"),
)

# ╔═╡ 00000001-0000-0000-0000-000000000009
md"""
## What a fragment_response would emit

`fragment_response(value, selector)` wraps `render(value)` in an
`HTTP.Response` with `Content-Type: text/html; charset=utf-8` and the
`datastar-selector` header. We can't run an HTTP server inside a
Pluto cell, but the rendered body is the bytes the Datastar runtime
would morph into the page.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000010
resp = fragment_response(div(id="status", "Signed in ✓"), "#status")

# ╔═╡ 00000001-0000-0000-0000-000000000011
(status = resp.status,
 selector = Dict(resp.headers)["datastar-selector"],
 body = String(resp.body))

# ╔═╡ 00000001-0000-0000-0000-000000000012
md"""
## Auto-escape, by default

Children are auto-escaped — the `<` below renders as `&lt;` in the
HTML, and the browser shows the literal character.
"""

# ╔═╡ 00000001-0000-0000-0000-000000000013
p("user said: ", "<script>alert('xss')</script>")

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.12.6"
manifest_format = "2.0"
project_hash = "71853c6197a6a7f222db0f1978c7cb232b87c5ee"

[deps]
"""

# ╔═╡ Cell order:
# ╟─00000001-0000-0000-0000-000000000001
# ╠═00000001-0000-0000-0000-000000000002
# ╠═00000001-0000-0000-0000-000000000003
# ╠═00000001-0000-0000-0000-000000000004
# ╟─00000001-0000-0000-0000-000000000005
# ╠═00000001-0000-0000-0000-000000000006
# ╟─00000001-0000-0000-0000-000000000007
# ╠═00000001-0000-0000-0000-000000000008
# ╟─00000001-0000-0000-0000-000000000009
# ╠═00000001-0000-0000-0000-000000000010
# ╠═00000001-0000-0000-0000-000000000011
# ╟─00000001-0000-0000-0000-000000000012
# ╠═00000001-0000-0000-0000-000000000013
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
