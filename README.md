# Shader Lighting for Godot 4

Unlimited 2D lights for Godot 4. `ShaderLight2D` nodes replace `PointLight2D`s
without the per-item light cap (and without a light LOD manager to work around
it), while `CanvasModulate` darkness and unshaded materials keep working
natively. Includes light layers and an `is_point_lit()` query for gameplay
(stealth, perception, anything that cares whether a spot is lit).

- **Version:** 0.2.0
- **Requires:** Godot 4.4+ (Forward+ tested). Tested on 4.7.1 in a shipped
  project and on 4.6.3 with the included demo. Other versions and renderers are
  untested.
- **License:** MIT

## Install

1. Copy `addons/shader_lighting/` into your project.
2. Project Settings -> Plugins -> enable **Shader Lighting**. It registers the
   `ShaderLighting` autoload (placed first in the autoload list, once, when it
   is created — move it afterwards and the plugin leaves it where you put it)
   and declares six shader globals. No Project Settings editing needed.
3. **Restart the editor once** so the shader globals load.
4. Keep your `CanvasModulate` nodes. Keep HUD/overlay CanvasLayers above
   layer 10.

To try it first, open this repository as a project and run the demo scene
(`demo/demo.tscn`).

## Files

```
addons/shader_lighting/
  plugin.cfg                  <- without this the plugin will not appear in the list
  plugin.gd                   registers the autoload, settings, and shader globals
  shader_lighting.gd          the autoload (light buffers, full-screen pass, is_point_lit)
  shader_light_2d.gd          the ShaderLight2D node
  globals.gd                  declares the shader globals
  composite.gdshader          the full-screen lighting pass
  lighting.gdshaderinc        lit_by() / unlit() helpers for shaders
  black.png                   1x1, the "no light" default for unused light layers
  icon.svg                    node icon
  examples/                   ready-made shaders for items that ignore lights or use layers
```

## How it works

1. Each `ShaderLight2D` creates a proxy sprite inside the `ShaderLighting`
   autoload, a hidden HDR `SubViewport` with its own world. It follows the
   light's transform, so lights work under any parent nodes.
2. The world is darkened at draw time by your `CanvasModulate` (the add-on
   finds it and follows its color, including tweens).
3. One full-screen pass (CanvasLayer 10) brightens the darkened world:
   `final = darkened * (ambient + light) / ambient`, which equals
   `albedo * (ambient + light)`, with a hue-preserving clamp.
4. Items that must ignore the lights divide themselves by that same factor
   first (`unlit()` in `lighting.gdshaderinc`), so the pass restores them to
   exactly what they were. The factor is always >= 1, so this always fits in
   8 bits.

Draw order, occlusion, and unshaded materials are native. Nothing uses z-index.

### Why items that ignore lights need a material

The lighting pass runs on finished screen pixels, so it can't see which item
drew a pixel or what that item's Light Mask is. Light Masks only exist inside
Godot's own per-item lighting, which shader lights bypass. Anything that should
ignore the lights therefore carries a small shader instead of relying on a mask.
The `examples/` folder has one for each case:

| Shader | Use for |
|---|---|
| `ambient_only.gdshader` (+ `ambient_only_material.tres`) | Items darkened by CanvasModulate but never lit (lamp heads, decorations) |
| `unlit_shader.gdshader` | Unshaded, additive items that ignore lights entirely |
| `layer_lit.gdshader` | Items lit by their own light layer (see **Light layers**) |

For an item that already has its own shader, add
`#include "res://addons/shader_lighting/lighting.gdshaderinc"` and end
`fragment()` with `COLOR.rgb = unlit(COLOR.rgb, SCREEN_UV);`.

## Migrating from PointLight2D

- Replace `PointLight2D` nodes with `ShaderLight2D`. The same light textures
  work. Any light LOD / budget manager can go.
- Give items that should ignore lights one of the example shaders above.

## Nodes and API

**ShaderLight2D**
- `texture`, `texture_scale`, `color`, `energy`, `offset`. Empty texture = soft
  radial fallback. Animate `color` / `energy` (not `modulate`) to fade it.
- `visible` switches it on and off.
- `light_layers`: which layers it feeds (default: layer 0 only).
- `lit_radius`: how far it counts as lit for `is_point_lit()`. 0 (the default)
  means decorative. Has no effect on rendering.
- Joins the groups `shader_lights` and `lit_sources`.

**ShaderLighting (autoload)**
- `set_lighting_enabled(bool)`: turn the shader lights on or off
  (CanvasModulate is unaffected).
- `ambient`: current ambient color (read-only).
- `is_point_lit(point, check_occlusion = true, ignore_lights_of = null, occlusion_mask = -1)`:
  see **Gameplay: is this point lit?**
- `debug_report()` / `debug_orphan_lights()`: what the light buffers contain,
  and which lights can't render and why. Call these when a light doesn't show up.

**Project settings** (under `shader_lighting/`)
- `composite_layer` (default 10): the CanvasLayer the full-screen pass runs on.
- `light_layers` (default 1, max 4): how many light layers to allocate.
- `ambient_color_space` (Auto / Force sRGB / Force linear). See **Colour space**.
- `preview_albedo` (default 0.25). See **Editor preview**.
- `occlusion_mask` (default: none): the physics layers that block `is_point_lit()`.
  Set it to your walls, not to layers your characters are on.

Change the ambient darkness by changing your `CanvasModulate.color`.

## Gameplay: is this point lit?

```gdscript
if ShaderLighting.is_point_lit(player.global_position, true, guard):
    guard.notice(player)
```

- Only lights with a `lit_radius` above 0 count, out to that radius. It is
  kept separate from the texture size on purpose: the radius that looks right
  on screen and the radius at which gameplay should call you lit are different
  numbers, and tying them together makes both hard to tune.
- With `check_occlusion` on, it raycasts from each light in range to the point
  against `occlusion_mask`, so a lamp behind a wall doesn't light you. Nothing
  blocks until you set `occlusion_mask` to your wall layers. This is
  gameplay only: the rendered light has no shadows and still spills past the wall.
- `ignore_lights_of` skips lights parented under that node, so a guard's own
  torch doesn't make the guard count as lit.
- Any `Node2D` can be counted: add it to the `lit_sources` group and give it a
  `lit_radius` property (a campfire sprite, a glowing pickup).
- It checks every light on every layer. Light layers are not considered yet.

## Light layers

Layer 0 is the default. The full-screen pass applies it, so anything without a
material is lit by it and costs nothing. An item that should answer to a
different set of lights (a train lit only by its carriage lights, an interior
lit only by its own fixtures) carries a shader ending in
`COLOR.rgb = lit_by(COLOR.rgb, SCREEN_UV, N);`. See
`examples/layer_lit.gdshader`. Put the lights it should respond to on layer N
via `ShaderLight2D.light_layers`, and raise `shader_lighting/light_layers` so
that layer exists.

`lit_by()` cancels layer 0 and substitutes layer N, so the item lands on
`albedo * (ambient + layer N)` once the pass has run. `lit_by(..., 0)` is
therefore a no-op, and `unlit()` is the same call with no layer at all.

**Cost.** The full-screen pass does not scale with layer count; it only ever
reads layer 0. Each extra layer costs one screen-sized RGBA16F render target
(~16 MB at 1080p) and its per-frame clear. Lights are partitioned across the
buffers rather than duplicated, so the total proxy count is unchanged unless a
light opts into several layers at once. A layered item costs one extra texture
sample over an unlit one.

## Editor preview

The editor has no composite pass, so a light previews as an additive quad. That
differs from the shipped frame in two ways, one fixed and one not:

- **Colour is corrected.** The preview is a CanvasItem, so your CanvasModulate
  multiplies it and lights would otherwise preview tinted toward the ambient.
  That is divided back out.
- **Blacks still lift.** Additive adds light to a pixel regardless of what is
  under it; the composite multiplies by albedo, so a dark road stays dark.
  Where many lights overlap, the preview washes out and the game does not.

`preview_albedo` stands in for the albedo the preview cannot see. Set it to the
typical brightness of the ground your lights fall on — for a dark night street
that is more like 0.15 than 0.5. Too high and dense lighting blows out; too low
and the preview under-sells it. It cannot be right for every surface at once.

## Colour space

The composite works on finished framebuffer pixels, so the ambient it divides
by has to be in the same space as those pixels. `rendering/viewport/hdr_2d`
switches Godot's 2D pipeline to **linear**, where an sRGB ambient of 0.224 is
0.041 — which turns a 5.5x light multiplier into 25.5x and blows every light
out. **Auto** follows `hdr_2d` and is what you want.

Two things worth knowing if you are matching an existing look:

- The light buffers are SubViewports with `use_hdr_2d` set, so they have
  **always** been linear, even when the screen is sRGB. Auto does not "fix"
  that mismatch, because existing projects are lit and tuned around it.
  *Force linear* with HDR off would correct it, and change how your game looks.
- `display/window/hdr/request_hdr_output` can enable HDR 2D **for you** on a
  display that supports HDR output, even with `hdr_2d` itself off. If lighting
  suddenly blows out on one machine and not another, check that setting. Auto
  reads `hdr_2d`, which is not set by that path, so pin the mode explicitly if
  you ship with HDR output requested.

## Limits

- No shadows or occluders on shader lights (real `PointLight2D`s still work
  alongside them).
- Ambient can't be pure black on any channel (values below 0.02 are treated as
  0.02); the pass recovers albedo from the darkened screen. Very dark ambient
  can show banding in smooth gradients.
- Additive neon over a strongly lit floor washes toward white, same as native.
- Screen-reading shaders see a once-per-frame copy of the screen.
- A layered item pre-multiplies itself before the pass runs, so where layer 0
  is dark and its own layer is bright the intermediate value can exceed 1.0.
  With `rendering/viewport/hdr_2d` off that clips per channel, ahead of the
  pass's hue-preserving clamp; with it on, it doesn't.
- In the editor, lights draw as plain additive glows; unlit shaders pass through.
- Hidden or missing `CanvasModulate` = ambient white. If several exist, the
  most recently added one is used.

## Troubleshooting

- **Plugin not in the list:** `plugin.cfg` must sit directly in
  `res://addons/shader_lighting/`.
- **"Global uniform 'light_buffer' does not exist":** the plugin isn't enabled,
  or the editor hasn't been restarted since enabling it.
- **Lights do nothing:** the `ShaderLighting` autoload must exist, and there
  must be a `CanvasModulate` darkening the world (otherwise ambient is white).
  `ShaderLighting.debug_orphan_lights()` lists lights that can't render and why.
- **`is_point_lit()` is always false:** the lights need a `lit_radius` above 0.
  If it's only false with occlusion on, `occlusion_mask` probably includes a
  layer the queried character is on, so its own shape blocks every ray.

## License

MIT. See [LICENSE](LICENSE).
