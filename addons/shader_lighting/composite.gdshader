shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;
global uniform sampler2D light_buffer;
global uniform vec4 ambient_color;

void fragment() {
	// The world was already darkened by CanvasModulate (albedo * ambient).
	vec3 dark = texture(screen_tex, SCREEN_UV).rgb;
	vec3 amb = max(ambient_color.rgb, vec3(0.02));
	vec3 light = texture(light_buffer, SCREEN_UV).rgb;
	// albedo * (ambient + light), without ever needing the albedo itself.
	vec3 lit = dark * (amb + light) / amb;
	// Hue-preserving clamp: over-bright pixels keep their color ratios.
	float peak = max(lit.r, max(lit.g, lit.b));
	COLOR = vec4(lit / max(peak, 1.0), 1.0);
}
