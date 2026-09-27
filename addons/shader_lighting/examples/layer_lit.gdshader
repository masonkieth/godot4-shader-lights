shader_type canvas_item;
// For items that should be lit by their OWN set of lights rather than the
// world's — a train lit only by its carriage lights, an interior lit only by
// its own fixtures. Put the matching ShaderLight2Ds on the same layer.
//
// Items on layer 0 need no material at all; this shader is a no-op there.
#include "res://addons/shader_lighting/lighting.gdshaderinc"

// -1 = unlit (same as ambient_only). 0 = the default world layer.
uniform int light_layer : hint_range(-1, 3) = 1;

void fragment() {
	COLOR.rgb = lit_by(COLOR.rgb, SCREEN_UV, light_layer);
}
