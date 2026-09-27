@tool
extends RefCounted
## Declares the shader globals the add-on's shaders read, unless the project
## already defines them. Safe to call repeatedly (editor and game).

static func ensure_defined() -> void:
	# One per light layer. Layers the project isn't running keep the black
	# texture, so a shader reading them gets no light rather than an error.
	_add_if_missing(&"light_buffer", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, _black_texture())
	_add_if_missing(&"light_buffer_1", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, _black_texture())
	_add_if_missing(&"light_buffer_2", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, _black_texture())
	_add_if_missing(&"light_buffer_3", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, _black_texture())
	_add_if_missing(&"ambient_color", RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE)
	_add_if_missing(&"lighting_on", RenderingServer.GLOBAL_VAR_TYPE_BOOL, false)


static func _add_if_missing(param: StringName, type: RenderingServer.GlobalShaderParameterType, default: Variant) -> void:
	if ProjectSettings.has_setting("shader_globals/" + String(param)):
		return  # defined in Project Settings -> Shader Globals
	# Querying globals is only allowed in the editor; in game we add exactly once.
	if Engine.is_editor_hint() \
			and RenderingServer.global_shader_parameter_get_type(param) != RenderingServer.GLOBAL_VAR_TYPE_MAX:
		return  # already added earlier this editor session
	RenderingServer.global_shader_parameter_add(param, type, default)


static func _black_texture() -> Texture2D:
	return ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
