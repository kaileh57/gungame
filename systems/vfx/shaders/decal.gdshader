shader_type spatial;
render_mode
		unshaded,
		blend_premul_alpha,
		depth_draw_never,
		cull_back,
		shadows_disabled,
		fog_disabled;

// Bullet holes. One MultiMesh of unit quads, one draw call for the whole pool,
// offset 14 mm along the surface normal and rolled at random, exactly as the
// reference does it (range spec 16.3).
//
// Premultiplied alpha is what lets one material carry both looks. A hole writes
// premultiplied colour with its own alpha and blends over the surface; fresh
// spall on steel writes colour with alpha 0, which is a pure add and glows. The
// reference needs two materials and two pools for that; this needs neither.
//
//   INSTANCE_CUSTOM.x  atlas tile index
//   INSTANCE_CUSTOM.y  vfx_time the hole was punched
//   INSTANCE_CUSTOM.z  lifetime in seconds, or 0 to live until the slot is reused
//   INSTANCE_CUSTOM.w  0 hole, 1 spall

uniform sampler2D hole_atlas : source_color, filter_linear_mipmap;
uniform float tile_count : hint_range(1.0, 16.0) = 4.0;
uniform float vfx_time = 0.0;
uniform float fade_in : hint_range(0.001, 1.0) = 0.05;
uniform float fade_out : hint_range(0.05, 20.0) = 2.5;
uniform float spall_gain : hint_range(0.0, 8.0) = 2.4;

// INSTANCE_CUSTOM is a vertex-stage input in Godot's spatial shaders, so the
// slot's record has to be carried across by hand.
varying flat vec4 v_slot;

void vertex() {
	v_slot = INSTANCE_CUSTOM;
}

void fragment() {
	float tile = floor(v_slot.x + 0.5);
	vec2 uv = vec2((clamp(UV.x, 0.002, 0.998) + tile) / tile_count, UV.y);
	vec4 texel = texture(hole_atlas, uv);

	float elapsed = vfx_time - v_slot.y;
	float life = v_slot.z;
	float fade = clamp(elapsed / fade_in, 0.0, 1.0);
	if (life > 0.0) {
		fade *= clamp((life - elapsed) / fade_out, 0.0, 1.0);
	}

	float hot = clamp(v_slot.w, 0.0, 1.0);
	float coverage = texel.a * fade;
	ALBEDO = texel.rgb * coverage * mix(1.0, spall_gain, hot);
	ALPHA = coverage * (1.0 - hot);
}
