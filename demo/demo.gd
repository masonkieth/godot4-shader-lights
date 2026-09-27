extends Node2D
## Move the mouse to carry a light around. The label reports whether the
## point under the cursor counts as lit for gameplay, by the room's lamps only:
## the cursor's own light is skipped via `ignore_lights_of`, the same way a
## guard's torch shouldn't make the guard count as lit.
##
## The wall blocks the query (it is on the occlusion_mask physics layer) even
## though the rendered light spills straight past it — shader lights have no
## shadows. Press L to toggle the lighting.

@onready var _player: Node2D = $Player
@onready var _label: Label = $HUD/Label

var _lighting_on: bool = true


func _process(_delta: float) -> void:
	_player.global_position = get_global_mouse_position()
	var lit: bool = ShaderLighting.is_point_lit(_player.global_position, true, _player)
	_label.text = "Cursor is %s\nL: toggle lighting" % ("LIT" if lit else "in shadow")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_L:
		_lighting_on = not _lighting_on
		ShaderLighting.set_lighting_enabled(_lighting_on)
