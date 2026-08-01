shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, unshaded, shadows_disabled;

// The translucent body: the GHOST capsule of the ash_flats race and the SPHERE a
// firefight spectator wears. One shader, two materials, `body_alpha` and `rim_alpha`
// are the whole difference.
//
// UNSHADED on purpose, and it is the decision that makes this work. A lit translucent
// body goes black the moment it steps into the long shadows this project is full of,
// and a player you lose in shade is exactly the failure a ghost exists to prevent. So
// the colour on screen is the player's colour and nothing else touches it.
//
// The read is carried by the RIM. A flat alpha wash over a capsule is a smudge with no
// shape; a Fresnel rim draws the silhouette, which is the part of a body you actually
// recognise at fifty metres. The interior stays faint so you can see the world through
// it, and `depth_draw_never` keeps it from punching a hole in what is behind it.

// Per-player, pushed with `set_instance_shader_parameter(&"tint", colour)`. The same
// uniform name the scrap shader uses, so an avatar swaps materials without the
// GDScript above it learning a second name.
instance uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float body_alpha : hint_range(0.0, 1.0) = 0.18;
uniform float rim_alpha : hint_range(0.0, 1.0) = 0.72;
// Higher is a tighter rim. 2.6 keeps a readable band on a capsule without the whole
// body lighting up on the near side.
uniform float rim_power : hint_range(0.5, 8.0) = 2.6;
// How much darker the interior is than the rim, so the volume has a front and a back.
uniform float body_shade : hint_range(0.0, 1.0) = 0.55;
// Scales the whole thing at once, for a fade-in that does not need a second material.
// Per-instance for the same reason `tint` is: four players, one material.
instance uniform float opacity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(clamp(1.0 - facing, 0.0, 1.0), rim_power);
	ALBEDO = tint.rgb * mix(body_shade, 1.0, rim);
	ALPHA = clamp(mix(body_alpha, rim_alpha, rim) * opacity, 0.0, 1.0);
}
