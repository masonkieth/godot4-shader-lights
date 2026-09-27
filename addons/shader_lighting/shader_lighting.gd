extends Node
## Autoload "ShaderLighting".
##
## Every ShaderLight2D mirrors itself as a proxy sprite inside one of the HDR
## SubViewports owned here (each has its own world), and each viewport renders
## a lightmap for one LIGHT LAYER. One full-screen pass then brightens the
## already-darkened world using layer 0:
##     final = darkened * (ambient + light) / ambient
## The world is darkened at draw time by your own CanvasModulate (found and
## followed automatically), so unshaded materials keep working natively and draw
## order is untouched.
##
## LAYERS. Layer 0 is the default: it is what the full-screen pass applies, so
## anything without a material is lit by it and costs nothing extra. An item
## that should answer to a different set of lights carries a small shader
## calling lit_by(COLOR.rgb, SCREEN_UV, layer), which cancels layer 0 and
## substitutes its own. unlit() is that same call with no layer at all.
##
## Cost: the full-screen pass does NOT scale with layer count -- it only ever
## reads layer 0. What each extra layer costs is one more screen-sized RGBA16F
## render target and its per-frame clear. Lights are PARTITIONED across the
## buffers rather than duplicated, so the total proxy count is unchanged unless
## a light opts into several layers at once.
##
## GAMEPLAY. is_point_lit() answers "is this point standing in light?" for
## stealth, perception and the like. It is separate from rendering: it counts
## only lights given a lit_radius, and walls block it even though shader lights
## cast no shadows.

const Globals = preload("res://addons/shader_lighting/globals.gd")
const COMPOSITE_SHADER: Shader = preload("res://addons/shader_lighting/composite.gdshader")

## Global uniform each layer publishes to. Index 0 keeps the original name, so
## every shader written against the single-buffer version still compiles and
## behaves identically.
const LAYER_UNIFORMS: Array[StringName] = [
	&"light_buffer", &"light_buffer_1", &"light_buffer_2", &"light_buffer_3",
]
## Raising this means adding uniforms here, in globals.gd, in plugin.gd and a
## branch in lighting.gdshaderinc — shaders cannot index samplers dynamically.
const MAX_LAYERS: int = 4

## Current ambient color, as authored — always the CanvasModulate's own sRGB
## value, whatever colour space the shaders are being fed.
var ambient: Color = Color.WHITE
var composite_layer: int = 10

## Whether `ambient_color` is published to the shaders converted to linear.
## See _resolve_color_space() for why this is not simply "is HDR on".
var ambient_is_linear: bool = false

var _buffers: Array[SubViewport] = []
var _composite: CanvasLayer
var _modulate: CanvasModulate


func _ready() -> void:
	_ensure_buffers()
	get_tree().node_added.connect(_on_node_added)
	_build_composite()


## Allocates the light buffers and binds them to their global uniforms.
##
## Called from _ready(), but ALSO from layer_count()/buffer_for(), because a
## ShaderLight2D asks for its buffer in _enter_tree() and there is no ordering
## guarantee that beats that. Getting this wrong is silent and permanent: a
## light that finds zero layers gets no proxy, and nothing ever retries, so it
## stays dark for the whole session. Building on demand removes the ordering
## question rather than relying on the autoload being first in the list.
func _ensure_buffers() -> void:
	if not _buffers.is_empty() or not is_inside_tree():
		return
	composite_layer = int(ProjectSettings.get_setting("shader_lighting/composite_layer", composite_layer))
	ambient_is_linear = _resolve_color_space()
	var count: int = clampi(
		int(ProjectSettings.get_setting("shader_lighting/light_layers", 1)), 1, MAX_LAYERS
	)
	Globals.ensure_defined()

	for i in count:
		_buffers.append(_make_buffer())
	if not get_tree().root.size_changed.is_connected(_resize):
		get_tree().root.size_changed.connect(_resize)
	_resize()

	# Layers the project didn't ask for keep the 1x1 black texture globals.gd
	# registered, so a shader reading one contributes no light instead of
	# failing to compile.
	for i in _buffers.size():
		RenderingServer.global_shader_parameter_set(LAYER_UNIFORMS[i], _buffers[i].get_texture())
	RenderingServer.global_shader_parameter_set(&"ambient_color", _published_ambient())
	RenderingServer.global_shader_parameter_set(&"lighting_on", true)


func _process(_delta: float) -> void:
	# Keep every buffer looking at the same part of the world as the main camera.
	var main: Window = get_tree().root
	for buffer: SubViewport in _buffers:
		buffer.canvas_transform = main.canvas_transform
		buffer.global_canvas_transform = main.global_canvas_transform
	_update_ambient()


## How many light layers this project is running. Layer indices are 0..n-1.
func layer_count() -> int:
	_ensure_buffers()
	return _buffers.size()


## The buffer a ShaderLight2D should put its proxy in, or null for a layer
## this project isn't running.
func buffer_for(layer: int) -> SubViewport:
	_ensure_buffers()
	if layer < 0 or layer >= _buffers.size():
		return null
	return _buffers[layer]


## Turns the shader lights on or off (CanvasModulate is unaffected).
func set_lighting_enabled(on: bool) -> void:
	_composite.visible = on
	RenderingServer.global_shader_parameter_set(&"lighting_on", on)
	for buffer: SubViewport in _buffers:
		buffer.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
		)


## What the light buffers actually contain right now. Call it from the game
## (a debug key, the terminal) when a light isn't showing up: it answers
## "is this light in a buffer at all?" without guessing from the scene tree.
func debug_report() -> Dictionary:
	var layers := []
	for i in _buffers.size():
		var lit := 0
		for child: Node in _buffers[i].get_children():
			if child is Sprite2D and (child as Sprite2D).visible:
				lit += 1
		layers.append({
			"layer": i, "proxies": _buffers[i].get_child_count(), "visible": lit,
			"size": _buffers[i].size,
			"bound": RenderingServer.global_shader_parameter_get(LAYER_UNIFORMS[i]) != null,
		})
	var sources := get_tree().get_nodes_in_group(&"lit_sources")
	var illuminating := 0
	for light: Node in sources:
		if light is CanvasItem and (light as CanvasItem).is_visible_in_tree() and _lit_radius(light) > 0.0:
			illuminating += 1
	return {
		"ambient": ambient,
		"lights_in_tree": get_tree().get_nodes_in_group(&"shader_lights").size(),
		"layers": layers,
		"lit_sources": sources.size(),
		"illuminating": illuminating,
	}


## Every ShaderLight2D that ended up with no proxy — i.e. every light that
## cannot possibly render — and why.
func debug_orphan_lights() -> Array:
	var orphans := []
	for light: Node in get_tree().get_nodes_in_group(&"shader_lights"):
		if light.get("_proxies") != null and (light.get("_proxies") as Array).is_empty():
			orphans.append({
				"name": light.name,
				"path": String(light.get_path()),
				"light_layers": light.get("light_layers"),
				"visible_in_tree": (light as Node2D).is_visible_in_tree(),
			})
	return orphans


## Is a given point standing in light, for gameplay purposes?
##
## A light only counts out to its own `lit_radius`, which is deliberately NOT
## its visual falloff — see ShaderLight2D.lit_radius. A light with no
## lit_radius, or zero, is pure decoration and never counts. Any Node2D can
## join the `lit_sources` group with a `lit_radius` property to be counted too
## (a campfire sprite, a glowing pickup); every ShaderLight2D joins it already.
##
## `check_occlusion` raycasts from the light to the point so a lamp on the far
## side of a wall doesn't light you through it. Costs one ray per light that is
## close enough to matter, which is why the radius test comes first.
## `occlusion_mask` picks which physics layers block it; -1 means the project
## setting `shader_lighting/occlusion_mask`.
##
## `ignore_lights_of` skips lights parented under that node — a guard's own
## torch lights the ground in front of them, not the guard, so asking "is this
## guard lit?" must not count it.
func is_point_lit(
	point: Vector2, check_occlusion: bool = true, ignore_lights_of: Node = null,
	occlusion_mask: int = -1
) -> bool:
	if occlusion_mask < 0:
		occlusion_mask = int(ProjectSettings.get_setting("shader_lighting/occlusion_mask", 0))
	var space_state: PhysicsDirectSpaceState2D = null
	for node: Node in get_tree().get_nodes_in_group(&"lit_sources"):
		var light := node as Node2D
		if light == null or not light.is_visible_in_tree():
			continue
		if ignore_lights_of != null and ignore_lights_of.is_ancestor_of(light):
			continue
		var radius: float = _lit_radius(light)
		if radius <= 0.0:
			continue
		var origin: Vector2 = _light_origin(light)
		if origin.distance_to(point) > radius:
			continue
		if not check_occlusion or occlusion_mask == 0:
			return true
		if space_state == null:
			space_state = light.get_world_2d().direct_space_state
		var query := PhysicsRayQueryParameters2D.create(origin, point, occlusion_mask)
		if space_state.intersect_ray(query).is_empty():
			return true
	return false


static func _lit_radius(light: Node) -> float:
	var radius: Variant = light.get(&"lit_radius")
	return float(radius) if radius != null else 0.0


## Where the light visibly is. ShaderLight2D draws around `offset`, so a light
## nudged off its node's origin is measured from the glow, not the node.
static func _light_origin(light: Node2D) -> Vector2:
	var offset: Variant = light.get(&"offset")
	return light.to_global(offset) if offset is Vector2 else light.global_position


## The ambient as the shaders should see it.
##
## The composite works on finished framebuffer pixels, so `ambient` has to be
## in the same colour space as those pixels or `(amb + light) / amb` is
## comparing unlike things. With `rendering/viewport/hdr_2d` on, the 2D
## pipeline is LINEAR -- an sRGB ambient of 0.224 is 0.041 there, which turns a
## 5.5x light multiplier into 25.5x and blows every light out.
func _published_ambient() -> Color:
	return ambient.srgb_to_linear() if ambient_is_linear else ambient


## Auto follows the main viewport, which is what you want almost always.
##
## Note it deliberately does NOT also convert the light buffers. Those are
## SubViewports with use_hdr_2d set, which means they have ALWAYS been linear,
## even while the screen was sRGB. That mismatch is baked into how existing
## projects are lit and tuned, so "correcting" it would change their look. Auto
## therefore leaves the sRGB path exactly as it has always behaved and only
## makes the linear path self-consistent.
func _resolve_color_space() -> bool:
	match int(ProjectSettings.get_setting("shader_lighting/ambient_color_space", 0)):
		1: return false  # Force sRGB
		2: return true   # Force linear
		_: return bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false))


func _make_buffer() -> SubViewport:
	var buffer := SubViewport.new()
	buffer.disable_3d = true
	buffer.transparent_bg = true
	buffer.use_hdr_2d = true  # lets light accumulate past 1.0
	buffer.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(buffer)
	return buffer


func _resize() -> void:
	var visible_size: Vector2 = get_tree().root.get_visible_rect().size
	var to: Vector2i = Vector2i(maxi(1, int(visible_size.x)), maxi(1, int(visible_size.y)))
	for buffer: SubViewport in _buffers:
		buffer.size = to


func _on_node_added(node: Node) -> void:
	if node is CanvasModulate:
		_modulate = node


func _update_ambient() -> void:
	var color: Color = Color.WHITE
	if is_instance_valid(_modulate) and _modulate.is_visible_in_tree():
		color = _modulate.color
	if color != ambient:
		ambient = color
		RenderingServer.global_shader_parameter_set(&"ambient_color", _published_ambient())


func _build_composite() -> void:
	var material := ShaderMaterial.new()
	material.shader = COMPOSITE_SHADER

	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = material

	_composite = CanvasLayer.new()
	_composite.layer = composite_layer
	_composite.add_child(rect)
	# Must live in the main viewport, not under one of the buffers.
	get_tree().root.add_child.call_deferred(_composite)
