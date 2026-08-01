shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// The face of a world-space readout panel. Two looks share one shader because the
// same scav workshop built both: a scavenged CRT still holding a charge, and a
// steel placard someone stencilled by hand and then never cleaned.
//
// The text itself arrives as `screen_tex`, a SubViewport a `ReadoutCanvas` drew
// into. Everything below is what happens to it on the way to your eye: the glass
// bends it, the phosphor stripes it, the dust on the screen eats it.

// 0 phosphor CRT, 1 painted placard.
uniform int style : hint_range(0, 1) = 0;
uniform sampler2D screen_tex : source_color, filter_linear_mipmap;
uniform sampler2D grime_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float emission_energy : hint_range(0.0, 6.0) = 1.7;
// Phosphor line count across the panel's height. Around 190 reads as a small
// tube; far more than that aliases into a grey wash at any real distance.
uniform float scan_lines = 190.0;
uniform float scan_strength : hint_range(0.0, 1.0) = 0.32;
// Barrel distortion of the glass, in UV units at the corners.
uniform float curvature : hint_range(0.0, 0.5) = 0.055;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.42;
uniform float grime_strength : hint_range(0.0, 1.0) = 0.40;
uniform float grime_scale = 3.0;
// Mains hum on the tube. Tiny — a screen that visibly pulses is a screen nobody
// can read, and this one carries the numbers you are meant to act on.
uniform float flicker : hint_range(0.0, 0.2) = 0.025;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.38;
uniform float metallic_base : hint_range(0.0, 1.0) = 0.15;

void fragment() {
	vec2 uv = UV;
	float mask = 1.0;

	if (style == 0) {
		// Bend the sample toward the centre so the image sits behind glass, then
		// throw away anything that bends off the edge instead of clamping it into
		// a smear.
		vec2 c = uv * 2.0 - 1.0;
		float r2 = dot(c, c);
		uv = (c * (1.0 + curvature * r2)) * 0.5 + 0.5;
		mask = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	}

	vec3 col = texture(screen_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb * tint_color.rgb;
	float grime = texture(grime_tex, UV * grime_scale).r;

	if (style == 0) {
		float scan = 1.0 - scan_strength * pow(sin(uv.y * scan_lines * PI) * 0.5 + 0.5, 1.5);
		// Aperture grille: every third column loses a little, which is what makes
		// a phosphor screen read as phosphor rather than as a photograph of one.
		float grille = 1.0 - 0.10 * pow(sin(uv.x * scan_lines * 1.7 * PI) * 0.5 + 0.5, 2.0);
		vec2 d = uv - 0.5;
		float vig = 1.0 - vignette_strength * dot(d, d) * 2.4;
		float hum = 1.0 + flicker * sin(TIME * 37.0);
		col *= scan * grille * vig * hum * mask;
		col *= mix(1.0, 0.55 + 0.9 * grime, grime_strength);
		ALBEDO = col * 0.14;
		EMISSION = col * emission_energy;
		ROUGHNESS = 0.12;
		METALLIC = 0.0;
	} else {
		// Painted placard: lit like any other steel in the world, with the stencil
		// worn where the dust has been rubbed off it.
		col *= mix(1.0, 0.62 + 0.8 * grime, grime_strength);
		ALBEDO = col;
		EMISSION = vec3(0.0);
		ROUGHNESS = clamp(roughness_base + (grime - 0.5) * 0.18, 0.08, 1.0);
		METALLIC = metallic_base;
	}
}
