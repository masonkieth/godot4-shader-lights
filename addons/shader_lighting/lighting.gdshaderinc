global uniform sampler2D light_buffer;      // layer 0 — what the composite applies
global uniform sampler2D light_buffer_1;
global uniform sampler2D light_buffer_2;
global uniform sampler2D light_buffer_3;
global uniform vec4 ambient_color;
global uniform bool lighting_on;

// Light arriving on one layer. Layers the project isn't running still resolve:
// globals.gd leaves them on a 1x1 black texture, so an item on a layer you
// haven't enabled goes unlit rather than failing to compile.
//
// The branch is on a uniform int, so it is the same for every fragment in the
// draw call — a compare, not divergence. Samplers cannot be indexed
// dynamically, which is why this is a chain rather than an array lookup.
vec3 shader_lighting_layer(int layer, vec2 screen_uv) {
	if (layer == 0) { return texture(light_buffer, screen_uv).rgb; }
	if (layer == 1) { return texture(light_buffer_1, screen_uv).rgb; }
	if (layer == 2) { return texture(light_buffer_2, screen_uv).rgb; }
	if (layer == 3) { return texture(light_buffer_3, screen_uv).rgb; }
	return vec3(0.0);  // any other value, including -1, means lit by nothing
}

// The composite pass multiplies every finished pixel by (ambient + layer0) /
// ambient. An item that should answer to a DIFFERENT set of lights divides
// that back out and substitutes its own layer, so it lands on
// albedo * (ambient + its layer) once the pass has run.
//
// lit_by(..., 0) is therefore a no-op, which is correct: layer 0 is what an
// item with no material already gets.
//
// Call it at the end of fragment().
vec3 lit_by(vec3 color, vec2 screen_uv, int layer) {
	if (!lighting_on) {
		return color;
	}
	vec3 amb = max(ambient_color.rgb, vec3(0.02));
	vec3 base = texture(light_buffer, screen_uv).rgb;
	return color * (amb + shader_lighting_layer(layer, screen_uv)) / (amb + base);
}

// Ignore the lights entirely. Unchanged in behaviour from the single-buffer
// version: it is lit_by() with no layer, which reduces to color * amb / (amb + layer0).
vec3 unlit(vec3 color, vec2 screen_uv) {
	return lit_by(color, screen_uv, -1);
}
