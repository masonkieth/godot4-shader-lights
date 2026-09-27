shader_type canvas_item;
// For truly unlit, additive things (neon). Replace your unshaded additive
// material with a ShaderMaterial that uses this shader.
render_mode unshaded;
#include "res://addons/shader_lighting/lighting.gdshaderinc"

void fragment() {
	COLOR.rgb = unlit(COLOR.rgb, SCREEN_UV);
}
