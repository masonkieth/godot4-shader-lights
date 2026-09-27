@tool
extends EditorPlugin

const Globals = preload("res://addons/shader_lighting/globals.gd")
const AUTOLOAD_NAME: String = "ShaderLighting"
const AUTOLOAD_PATH: String = "res://addons/shader_lighting/shader_lighting.gd"

const SHADER_GLOBALS: Dictionary = {
	# Project Settings can only store a path, so the "no light" default that
	# globals.gd builds in code has to exist as a file here.
	"light_buffer": {"type": "sampler2D", "value": "res://addons/shader_lighting/black.png"},
	"light_buffer_1": {"type": "sampler2D", "value": "res://addons/shader_lighting/black.png"},
	"light_buffer_2": {"type": "sampler2D", "value": "res://addons/shader_lighting/black.png"},
	"light_buffer_3": {"type": "sampler2D", "value": "res://addons/shader_lighting/black.png"},
	"ambient_color": {"type": "color", "value": Color(1, 1, 1, 1)},
	"lighting_on": {"type": "bool", "value": false},
}


func _enter_tree() -> void:
	Globals.ensure_defined()  # this session
	_register_shader_globals()  # every later session
	_add_setting("shader_lighting/composite_layer", 10, TYPE_INT)
	# How many light layers to allocate. Each costs one screen-sized RGBA16F
	# render target, so this is deliberately opt-in rather than always 4.
	_add_setting("shader_lighting/light_layers", 1, TYPE_INT)
	# Which colour space the ambient is handed to the shaders in. Auto follows
	# rendering/viewport/hdr_2d, which is right unless you are matching an
	# existing look on purpose.
	_add_setting(
		"shader_lighting/ambient_color_space", 0, TYPE_INT,
		PROPERTY_HINT_ENUM, "Auto (follow HDR 2D),Force sRGB,Force linear"
	)
	# Stand-in surface brightness for the editor preview, which has no albedo
	# to multiply light by the way the composite pass does.
	_add_setting(
		"shader_lighting/preview_albedo", 0.25, TYPE_FLOAT,
		PROPERTY_HINT_RANGE, "0.0,1.0,0.01"
	)
	# Physics layers that block light for is_point_lit(). Gameplay only; the
	# rendered light has no shadows. Empty by default: every body starts on
	# layer 1, so defaulting to it would let the queried character's own shape
	# block every ray and read as permanently unlit.
	_add_setting(
		"shader_lighting/occlusion_mask", 0, TYPE_INT, PROPERTY_HINT_LAYERS_2D_PHYSICS
	)
	# Checked BEFORE adding, because adding is what would make it true.
	var is_new: bool = not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME)
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	if is_new:
		_move_autoload_first()


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _add_setting(
	path: String, default: Variant, type: int,
	hint: int = PROPERTY_HINT_NONE, hint_string: String = ""
) -> void:
	if not ProjectSettings.has_setting(path):
		ProjectSettings.set_setting(path, default)
	ProjectSettings.set_initial_value(path, default)
	ProjectSettings.add_property_info({
		"name": path, "type": type, "hint": hint, "hint_string": hint_string,
	})


func _register_shader_globals() -> void:
	var added: bool = false
	for global_name: String in SHADER_GLOBALS:
		var key: String = "shader_globals/" + global_name
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, SHADER_GLOBALS[global_name])
			added = true
	if added:
		ProjectSettings.save()
		push_warning("Shader Lighting: registered shader globals. Restart the editor once to load them.")


## The light buffer should come up before anything that might query lighting
## during its own _ready, so the autoload wants to be first in the list.
##
## Done ONCE, on the enable that actually creates the autoload. Ordering is a
## real decision — another autoload may need to precede this one — so once the
## entry exists, its position belongs to whoever is working on the project, and
## re-asserting it on every editor start would quietly undo their choice.
## (Disabling the plugin deletes the entry, so a later re-enable is a fresh
## creation and does place it first again.)
func _move_autoload_first() -> void:
	var key: String = "autoload/" + AUTOLOAD_NAME
	if not ProjectSettings.has_setting(key):
		return  # the add didn't take; nothing to position
	# Autoloads load in ProjectSettings property order, so "first" is simply
	# the lowest order value among the autoload entries.
	var lowest: int = ProjectSettings.get_order(key)
	for property: Dictionary in ProjectSettings.get_property_list():
		var name: String = property.get("name", "")
		if name.begins_with("autoload/"):
			lowest = mini(lowest, ProjectSettings.get_order(name))
	if ProjectSettings.get_order(key) == lowest:
		return
	ProjectSettings.set_order(key, lowest - 1)
	ProjectSettings.save()
