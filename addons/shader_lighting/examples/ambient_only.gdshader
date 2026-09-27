shader_type canvas_item;
// For items that stay darkened by CanvasModulate but must not be lit
// (overhead lamp heads, building decorations).
#include "res://addons/shader_lighting/lighting.gdshaderinc"

void fragment() {
	COLOR.rgb = unlit(COLOR.rgb, SCREEN_UV);
}
