shader_type canvas_item;
render_mode blend_add, unshaded;

// Radial speed streaks for the dash. One additive full-screen quad, procedural,
// no texture and no dependent reads — it costs a fill pass and nothing else, and
// the node carrying it is hidden outright whenever `amount` is zero, so a player
// standing still pays for none of it.
//
// The lanes are a function of the ANGLE around the frame centre, not of UV, so
// they converge on the vanishing point the way motion blur does. Two beating
// sines rather than one: a single sine draws an even fan that reads as a lens
// artefact, while the beat gives the irregular spacing real streaking has.
//
// Nothing is drawn near the centre. That is the whole trick — the middle of the
// frame is where the player is looking and where the world is moving slowest in
// screen space, so streaks there read as dirt rather than as speed.

// 0 at rest, 1 at the dash top speed. Driven by `visuals_dash.gd`.
uniform float amount : hint_range(0.0, 1.0) = 0.0;
// Warm, because everything else in this scene is. Linear, not sRGB.
uniform vec3 tint : source_color = vec3(1.0, 0.72, 0.42);
// Fraction of the half-diagonal at which lanes begin and reach full strength.
uniform float inner : hint_range(0.05, 0.9) = 0.26;
uniform float outer : hint_range(0.1, 1.4) = 0.78;
// Peak added radiance at amount = 1. Deliberately under a stop: this is a cue,
// not a curtain, and the player still has to be able to see where they are going.
uniform float gain : hint_range(0.0, 2.0) = 0.55;

void fragment() {
	// Centred, aspect-corrected so the fan stays circular on a 16:9 frame.
	vec2 p = (UV - vec2(0.5)) * vec2(16.0 / 9.0, 1.0);
	float r = length(p) * 1.62;
	float ang = atan(p.y, p.x);

	float beat = sin(ang * 79.0) * sin(ang * 131.0 + 1.71);
	float lanes = smoothstep(0.42, 0.98, abs(beat));
	// A slow shimmer keeps the fan from reading as a printed pattern. Cheap: one
	// sine of TIME, and it is only ever evaluated while the overlay is visible.
	float shimmer = 0.78 + 0.22 * sin(TIME * 19.0 + ang * 37.0);
	float radial = smoothstep(inner, outer, r);

	float a = lanes * radial * shimmer * amount * amount * gain;
	COLOR = vec4(tint * a, 1.0);
}
