shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled,
	fog_disabled;

// The laser-pointer dot: where another player is aiming, sitting on the surface they
// are aiming at. One quad, one draw call, no beam.
//
// Three things this has to survive, and each one costs a term:
//
//   1. PALE SAND AND DEEP SHADE IN THE SAME FRAME. A bright dot alone disappears
//      against bleached ground the moment the sun is on it. So the dot is a bright
//      core inside a DARK RING, the same trick `CombatReticle` uses for every line it
//      draws — the ring is what makes it findable on sand, the core is what makes it
//      findable on rusted steel.
//   2. IT MUST NOT BE A LIGHT. `blend_add` on 0.7-luminance sand adds nothing you can
//      see, and on dark steel it blooms into a lamp. Alpha blend, unshaded, so the
//      colour on screen is the player's colour and not the player's colour times
//      whatever light happens to be falling there.
//   3. IT IS A DOT, NOT A DECAL. It faces the eye rather than the surface, because a
//      decal lying on a floor is an ellipse from anywhere except directly above it and
//      an ellipse does not read as a point. The billboard below keeps the node's own
//      scale, so the GDScript side can hold the dot at a sane angular size.
//
// `depth_draw_never` with the depth TEST left on is deliberate: the dot is occluded by
// the wall in front of it (a dot you can see through a building is a beam, and the
// brief says no beam), but it never writes depth over the world behind it.

uniform vec4 dot_color : source_color = vec4(1.0, 0.2, 0.15, 1.0);
// Radius of the bright core, in UV units from the quad's centre. 0.5 fills the quad,
// so 0.30 is 60% of the half-width and the ring plus the core just fit inside it.
// `LaserCursor.size_angle` is stated in terms of this split; changing one means
// re-reading the other.
uniform float core_radius : hint_range(0.02, 0.5) = 0.30;
// Width of the dark ring outside the core, same units.
uniform float ink_width : hint_range(0.0, 0.4) = 0.10;
// Softness of both edges. Wide enough that the dot never crawls with pixels at range.
uniform float edge_softness : hint_range(0.002, 0.2) = 0.045;
// The project's ink. Nothing in this game is black.
uniform vec4 ink_color : source_color = vec4(0.035, 0.031, 0.028, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
// Alpha of the ring relative to the core's. The ring is a backing, not a second dot.
uniform float ink_opacity : hint_range(0.0, 1.0) = 0.72;
// How much brighter the very middle of the core is than its rim. A flat disc reads as
// a sticker; a hot centre reads as a point of light on a surface.
uniform float core_hotspot : hint_range(0.0, 1.0) = 0.45;

void vertex() {
	// Godot's documented keep-scale billboard. The three basis columns are taken from
	// the inverse view matrix (so the quad faces the eye), each rescaled by the length
	// of the model's own column (so a scaled node still scales), and the translation
	// column is left as the node's world position.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0]),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1]),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2]),
		MODEL_MATRIX[3]);
}

void fragment() {
	float r = length(UV - vec2(0.5));
	float e = max(edge_softness, 0.0001);
	float core = 1.0 - smoothstep(core_radius - e, core_radius + e, r);
	float outer = core_radius + ink_width;
	float ring = (1.0 - smoothstep(outer - e, outer + e, r)) - core;
	float alpha = (core + ring * ink_opacity) * opacity;
	if (alpha < 0.004) {
		discard;
	}
	float hot = 1.0 + core_hotspot * (1.0 - smoothstep(0.0, core_radius, r));
	ALBEDO = mix(ink_color.rgb, dot_color.rgb * hot, core);
	ALPHA = clamp(alpha, 0.0, 1.0);
}
