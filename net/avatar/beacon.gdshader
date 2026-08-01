shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, unshaded,
	shadows_disabled, fog_disabled;

// The cross-map presence mark: a tapering shaft with a diamond on top, drawn THROUGH
// the world, in the player's colour. GHOST mode wears it and the ash_flats race is why
// it exists — a race across a large map is unrunnable if you cannot tell where the
// other three are, and every other mark in this system is deliberately occluded by
// walls.
//
// `depth_test_disabled` is the whole point and it is the only place in the project that
// uses it. Everything that follows is about paying for it:
//
//   - It is a SHAFT, not a blob. A mark drawn over the world with no depth cue reads as
//     stuck to the lens; a vertical shaft that fades out at the bottom reads as coming
//     up off the ground, which is the only depth cue left once the depth buffer is out
//     of the conversation.
//   - Everything is drawn over its own dark border, for the same reason every line in
//     `CombatReticle` is: at 300 m this thing is twenty pixels wide over bleached sand.
//   - It BREATHES, slowly and shallowly. A static mark at twenty pixels is something
//     you have to go looking for; a mark that moves is something peripheral vision
//     finds for you. 0.55 Hz and 18% is under the threshold at which it becomes noise.
//
// The quad is billboarded with the keep-scale form, so the GDScript above it sizes the
// whole mark by scaling the node and the proportions never shear.

uniform vec4 mark_color : source_color = vec4(1.0, 0.2, 0.15, 1.0);
uniform vec4 ink_color : source_color = vec4(0.035, 0.031, 0.028, 1.0);
// Quad height divided by quad width. Written by the builder to match the mesh, and it
// is what keeps the diamond a diamond on a very tall quad.
uniform float aspect : hint_range(1.0, 64.0) = 8.0;
// Where the diamond sits, 0 at the foot of the shaft and 1 at the top.
uniform float cap_height : hint_range(0.0, 1.0) = 0.87;
// Half-diagonal of the diamond, in quad WIDTHS.
uniform float cap_size : hint_range(0.05, 0.5) = 0.30;
// Half-width of the shaft, in quad widths.
uniform float shaft_half : hint_range(0.005, 0.3) = 0.055;
// Dark border on both, same units.
uniform float ink_width : hint_range(0.0, 0.2) = 0.030;
uniform float edge_softness : hint_range(0.002, 0.1) = 0.012;
uniform float opacity : hint_range(0.0, 1.0) = 0.88;
// Alpha the shaft reaches at the top. It fades to nothing at its foot.
uniform float shaft_alpha : hint_range(0.0, 1.0) = 0.55;
uniform float pulse_hz : hint_range(0.0, 4.0) = 0.55;
uniform float pulse_depth : hint_range(0.0, 0.6) = 0.18;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0]),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1]),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2]),
		MODEL_MATRIX[3]);
}

// A soft inside-ness for a signed distance, 1 inside and 0 outside.
float inside(float d, float e) {
	return 1.0 - smoothstep(-e, e, d);
}

void fragment() {
	float e = max(edge_softness, 0.0001);
	// Quad units: x in widths either side of the centre line, y in widths up from the
	// foot. Multiplying v by the aspect is what makes both shapes isotropic.
	float x = UV.x - 0.5;
	float v = 1.0 - UV.y;
	float y = (v - cap_height) * aspect;

	float diamond = abs(x) + abs(y) - cap_size;
	float cap_core = inside(diamond, e);
	float cap_ink = inside(diamond - ink_width, e) - cap_core;

	// The shaft stops at the diamond rather than running through it, and it thins as it
	// falls so the mark points at the ground instead of hanging in the air.
	float taper = mix(0.45, 1.0, clamp(v / max(cap_height, 0.001), 0.0, 1.0));
	float below = step(v, cap_height);
	float shaft = inside(abs(x) - shaft_half * taper, e) * below;
	float shaft_ink = inside(abs(x) - (shaft_half * taper + ink_width), e) * below - shaft;
	float rise = smoothstep(0.0, cap_height * 0.85, v);

	float core_a = max(cap_core, shaft * shaft_alpha * rise);
	float ink_a = max(cap_ink, shaft_ink * shaft_alpha * rise);
	float pulse = 1.0 - pulse_depth * (0.5 - 0.5 * cos(TIME * pulse_hz * 6.2831853));
	float alpha = max(core_a, ink_a) * opacity * pulse;
	if (alpha < 0.004) {
		discard;
	}
	ALBEDO = mix(ink_color.rgb, mark_color.rgb, core_a / max(core_a + ink_a, 0.0001));
	ALPHA = clamp(alpha, 0.0, 1.0);
}
