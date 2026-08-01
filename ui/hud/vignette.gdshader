shader_type canvas_item;
render_mode blend_mix, unshaded;

// Health as a screen-edge vignette instead of a number.
//
// Four layers ride on the same quad. `harm` is the sustained one: as health falls
// the edges of the screen close in and warm over, so a player who is nearly dead
// knows it from the shape of the frame rather than from reading a bar. `pulse` is
// the momentary one: a directional lobe on the side the hit came from, so the
// first thing you learn about being shot is which way to turn. `heartbeat` is
// added to `harm` by the HUD once health is low enough for the frame to breathe.
// `death` is the last one and it overrides everything: a hard iris closing from
// past the corners to the middle of the screen, which is what makes dying a state
// you can see rather than a teleport you did not ask for.

uniform float harm : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform float heartbeat : hint_range(0.0, 1.0) = 0.0;
uniform float death : hint_range(0.0, 1.0) = 0.0;
// Screen-space direction the damage came from, normalised. +X right, +Y down.
uniform vec2 hit_direction = vec2(0.0, 0.0);
uniform vec4 harm_color : source_color = vec4(0.44, 0.09, 0.07, 1.0);
uniform vec4 pulse_color : source_color = vec4(0.72, 0.16, 0.11, 1.0);
uniform vec4 death_color : source_color = vec4(0.030, 0.016, 0.014, 1.0);
// How far in from the edge the sustained vignette reaches at full harm.
uniform float harm_reach : hint_range(0.1, 1.2) = 0.86;
// Width of the directional lobe. Smaller is a tighter, more legible arrow.
uniform float lobe_focus : hint_range(1.0, 12.0) = 3.4;
// Softness of the death iris edge, in the same units as `r`.
uniform float death_feather : hint_range(0.02, 0.8) = 0.26;
// How much of the frame the closed iris LEAVES OPEN. Zero is a cut to black, which
// is not a death state you can read anything out of — at 0.34 the middle of the
// screen survives, so the thing that killed you is still on screen while you are
// down and the banner sits inside the hole rather than behind it.
uniform float death_aperture : hint_range(0.0, 1.0) = 0.34;

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	// Elliptical, not circular: a 16:9 frame vignetted with a circle darkens the
	// left and right thirds long before the top and bottom, which reads as a lens
	// fault rather than as injury.
	float r = length(c * vec2(0.78, 1.0));

	float h = clamp(harm + heartbeat, 0.0, 1.0);
	float edge = smoothstep(1.0 - harm_reach * h, 1.02, r);
	float sustained = edge * smoothstep(0.0, 0.55, h);

	float lobe = 0.0;
	if (pulse > 0.001 && length(hit_direction) > 0.001) {
		vec2 d = normalize(hit_direction);
		float facing = max(dot(normalize(c + vec2(0.0001)), d), 0.0);
		lobe = pow(facing, lobe_focus) * smoothstep(0.15, 1.0, r) * pulse;
	}

	// The iris boundary travels from past the far corner (r maxes at ~1.27 on a 16:9
	// frame) in to `death_aperture`, so death 0 draws nothing at all and death 1 is a
	// tunnel rather than a blackout.
	float iris_edge = mix(1.35, death_aperture - death_feather, death);
	float iris = smoothstep(iris_edge, iris_edge + death_feather, r);

	vec3 col = harm_color.rgb * sustained + pulse_color.rgb * lobe;
	float a = clamp(sustained * harm_color.a * 0.92 + lobe * pulse_color.a, 0.0, 1.0);
	col = mix(col, death_color.rgb, iris);
	a = max(a, iris * death_color.a);
	COLOR = vec4(col, a);
}
