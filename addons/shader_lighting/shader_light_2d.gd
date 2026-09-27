@tool
@icon("res://addons/shader_lighting/icon.svg")
class_name ShaderLight2D
extends Node2D
## Additive light. At runtime it draws nothing itself: it mirrors a proxy sprite
## into the ShaderLighting buffer, so it works under any parent nodes.
## Not a Light2D: no shadows, no light masks, no per-item light cap.
## Use the built-in `visible` property to switch it on and off.
## Animate `color` / `energy` (not `modulate`) to fade it.

## Light shape. Radial gradients work best. Falls back to a soft radial if empty.
@export var texture: Texture2D:
	set(value):
		texture = value
		queue_redraw()
		_sync()

@export_range(0.01, 32.0, 0.01, "or_greater") var texture_scale: float = 1.0:
	set(value):
		texture_scale = value
		queue_redraw()
		_sync()

@export var color: Color = Color.WHITE:
	set(value):
		color = value
		queue_redraw()
		_sync()

@export_range(0.0, 16.0, 0.05, "or_greater") var energy: float = 1.0:
	set(value):
		energy = value
		queue_redraw()
		_sync()

## Which light layers this light contributes to. Layer 0 is the default one the
## full-screen pass applies, so a light left alone behaves exactly as before.
## Items answer to a layer via lit_by() — see lighting.gdshaderinc.
##
## A light on several layers draws a proxy into each, so it costs one extra
## sprite per extra layer; a light on exactly one layer costs nothing extra
## however many layers the project runs.
@export_flags("Layer 0", "Layer 1", "Layer 2", "Layer 3") var light_layers: int = 1:
	set(value):
		light_layers = value
		queue_redraw()
		_rebuild_proxies()

@export var offset: Vector2 = Vector2.ZERO:
	set(value):
		offset = value
		queue_redraw()
		_sync()

## How far this light counts as ILLUMINATING for gameplay, independent of how
## far its texture visibly falls off. Kept separate on purpose: the radius
## that reads well on screen and the radius at which, say, a guard can spot you
## are different numbers, and tying them together makes both untunable.
## Zero opts the light out of gameplay entirely (pure decoration).
## Read by ShaderLighting.is_point_lit(); has no effect on rendering.
@export var lit_radius: float = 0.0

## Fallback for `shader_lighting/preview_albedo`. Night games are dark, and
## the preview blowing out is the common failure, so this leans low.
const PREVIEW_ALBEDO_DEFAULT: float = 0.25

## Shared across every light: the CanvasModulate of the scene being edited, and
## which scene that was, so it is resolved once rather than per light.
static var _editor_modulate: CanvasModulate
static var _editor_scene_id: int = 0
## Cached the same way — a ProjectSettings lookup per light per redraw is the
## kind of cost that adds up at hundreds of lights.
static var _preview_albedo: float = -1.0

static var _additive: CanvasItemMaterial
static var _fallback: GradientTexture2D

var _proxies: Array[Sprite2D] = []


func _init() -> void:
	material = _get_additive_material()  # editor preview only
	set_notify_transform(true)


func _enter_tree() -> void:
	add_to_group(&"shader_lights")
	# Separate from shader_lights: that group is the renderer's business, this
	# one is "things gameplay may ask about". See ShaderLighting.is_point_lit().
	add_to_group(&"lit_sources")
	if Engine.is_editor_hint():
		return
	_rebuild_proxies()


func _exit_tree() -> void:
	_clear_proxies()


## One proxy per layer this light is on. Called again when the mask changes, so
## a light can be moved between layers at runtime.
func _rebuild_proxies() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	_clear_proxies()
	var lighting: Node = get_node_or_null("/root/ShaderLighting")
	if lighting == null:
		push_warning("ShaderLight2D: 'ShaderLighting' autoload not found. Is the plugin enabled?")
		return
	for layer in lighting.layer_count():
		if light_layers & (1 << layer) == 0:
			continue
		var buffer: SubViewport = lighting.buffer_for(layer)
		if buffer == null:
			continue
		var proxy := Sprite2D.new()
		proxy.material = _get_additive_material()
		buffer.add_child.call_deferred(proxy)
		_proxies.append(proxy)
	if light_layers == 0:
		push_warning(
			"ShaderLight2D '%s' has light_layers = 0 — it is on no layer at all, "
			% name
			+ "so it emits nothing. Tick at least Layer 0."
		)
	elif _proxies.is_empty():
		push_warning(
			"ShaderLight2D '%s' is on layer mask %d, but the project only runs %d layer(s) "
			% [name, light_layers, lighting.layer_count()]
			+ "— raise shader_lighting/light_layers, or it will emit nothing."
		)
	_sync()


func _clear_proxies() -> void:
	for proxy: Sprite2D in _proxies:
		if is_instance_valid(proxy):
			proxy.queue_free()
	_proxies.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_VISIBILITY_CHANGED:
		_sync()


# Editor preview only. In game the proxies in the light buffers do the drawing.
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var tex: Texture2D = _get_texture()
	var size: Vector2 = tex.get_size() * texture_scale
	draw_texture_rect(tex, Rect2(offset - size * 0.5, size), false, _get_tint())


func _sync() -> void:
	for proxy: Sprite2D in _proxies:
		if not is_instance_valid(proxy):
			continue
		proxy.texture = _get_texture()
		proxy.offset = offset / texture_scale
		proxy.transform = global_transform.scaled_local(Vector2(texture_scale, texture_scale))
		proxy.modulate = _get_tint()
		proxy.visible = is_visible_in_tree()


func _get_texture() -> Texture2D:
	return texture if texture != null else _get_fallback_texture()


func _get_tint() -> Color:
	var tint := Color(color.r * energy, color.g * energy, color.b * energy, color.a)
	if not Engine.is_editor_hint():
		return tint
	# EDITOR ONLY. The preview is a plain additive CanvasItem, so the scene's
	# CanvasModulate multiplies it like anything else: a magenta lamp previews
	# as grey-green at ambient brightness. Dividing the ambient back out
	# restores the light's real colour.
	#
	# The PREVIEW_ALBEDO factor matters. In game the light term is
	# `albedo * light`; here there is no albedo to multiply by, so cancelling
	# the ambient alone overshoots and clips every light above ~1.0 into a flat
	# white blob. Standing in a mid-tone surface keeps the preview inside the
	# same range the game produces.
	#
	# This does NOT fix the other half of the mismatch: an additive quad lifts
	# black pixels to grey, where the game multiplies by albedo and leaves them
	# black. That needs the full-screen composite pass, not a tint.
	var amb := _editor_ambient()
	var albedo := _preview_albedo_setting()
	return Color(
		tint.r * albedo / maxf(amb.r, 0.02),
		tint.g * albedo / maxf(amb.g, 0.02),
		tint.b * albedo / maxf(amb.b, 0.02),
		tint.a
	)


## How bright the preview assumes your surfaces are. There is no real albedo to
## multiply by here, so this stands in for one: too high and dense lighting
## washes the scene out, too low and the preview under-sells it. Match it to
## the typical brightness of the ground your lights fall on.
static func _preview_albedo_setting() -> float:
	if _preview_albedo < 0.0:
		_preview_albedo = clampf(float(ProjectSettings.get_setting(
			"shader_lighting/preview_albedo", PREVIEW_ALBEDO_DEFAULT)), 0.0, 1.0)
	return _preview_albedo


## The ambient the composite pass would be working against, so the preview can
## cancel it out.
##
## Searched ONCE per edited scene and shared by every light via static state.
## Scenes can hold hundreds of lights; resolving this per light, per frame
## makes the editor unusable. The instance-id
## compare below is the entire per-call cost after the first light.
static func _editor_ambient() -> Color:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return Color.WHITE
	var scene: Node = tree.edited_scene_root
	if scene == null:
		return Color.WHITE
	if scene.get_instance_id() != _editor_scene_id:
		_editor_scene_id = scene.get_instance_id()
		# Cached even when it finds nothing, so a scene with no CanvasModulate
		# is searched once rather than on every redraw.
		var found := scene.find_children("*", "CanvasModulate", true, false)
		_editor_modulate = found[0] if not found.is_empty() else null
	if not is_instance_valid(_editor_modulate) or not _editor_modulate.is_visible_in_tree():
		return Color.WHITE  # matches the runtime rule: no CanvasModulate, no darkening
	return _editor_modulate.color


# Hide properties that would break the light if edited.
func _validate_property(property: Dictionary) -> void:
	if property.name in ["material", "use_parent_material", "modulate", "self_modulate"]:
		property.usage = PROPERTY_USAGE_NONE


static func _get_additive_material() -> CanvasItemMaterial:
	if _additive == null:
		_additive = CanvasItemMaterial.new()
		_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _additive


static func _get_fallback_texture() -> GradientTexture2D:
	if _fallback == null:
		var gradient := Gradient.new()
		gradient.set_color(0, Color.WHITE)
		gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		_fallback = GradientTexture2D.new()
		_fallback.gradient = gradient
		_fallback.fill = GradientTexture2D.FILL_RADIAL
		_fallback.fill_from = Vector2(0.5, 0.5)
		_fallback.fill_to = Vector2(1.0, 0.5)
		_fallback.width = 256
		_fallback.height = 256
	return _fallback
