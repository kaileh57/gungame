shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

// Projected light, for the two things on the movement bench that are not solid: the
// rival-time holograms beside the lap board, and the marker flare over the next gate.
//
// ONE MATERIAL SERVES BOTH, and every per-object difference rides on an instance
// uniform, so five gate beacons and three holograms cost one material and zero
// allocations. `holo_tint` carries the owner's colour, `holo_energy` is the pulse the
// gate drives every frame, and `holo_scan` turns the raster bars off for the beacon,
// whose lamp head is 16 cm tall and would alias into a moire if it kept them.
//
// Additive and depth-write-never, but depth-TEST is still on: a flare behind a wall is
// hidden by the wall, which is what keeps it reading as a thing in the yard rather than
// as an overlay drawn on your eye.

instance uniform vec4 holo_tint : source_color = vec4(0.72, 0.68, 0.59, 1.0);
instance uniform float holo_energy : hint_range(0.0, 4.0) = 1.0;
instance uniform float holo_scan : hint_range(0.0, 1.0) = 1.0;

// Raster bars across the panel, and how fast they crawl up it.
uniform float scan_density = 54.0;
uniform float scan_drift = 0.19;
uniform float scan_depth : hint_range(0.0, 1.0) = 0.42;
// Fade at the quad's rim, so the panel never shows a hard rectangle against the sky.
uniform float edge_softness : hint_range(0.0, 0.49) = 0.16;
// Two incommensurate rates, so the flicker never reads as one short loop.
uniform float flicker_rate = 8.5;
uniform float flicker_depth : hint_range(0.0, 0.5) = 0.10;
// How much dimmer the panel is edge-on. This is what makes it read as a projection
// hanging in the air instead of as paint on an invisible board.
uniform float view_falloff : hint_range(0.0, 1.0) = 0.34;
// Shape of the beacon's vertical fade. Above 1 it dies quickly, below 1 it lingers.
uniform float taper_power : hint_range(0.1, 4.0) = 0.85;

void fragment() {
	float bars = 0.5 + 0.5 * sin(UV.y * scan_density - TIME * scan_density * scan_drift);
	float scan = mix(1.0, mix(1.0 - scan_depth, 1.0, bars), holo_scan);

	vec2 rim = abs(UV - vec2(0.5)) * 2.0;
	float edge = (1.0 - smoothstep(1.0 - edge_softness, 1.0, rim.x))
		* (1.0 - smoothstep(1.0 - edge_softness, 1.0, rim.y));

	float flicker = 1.0 - flicker_depth
		* (0.5 + 0.5 * sin(TIME * flicker_rate))
		* (0.5 + 0.5 * sin(TIME * flicker_rate * 0.37 + 1.7));

	float facing = mix(1.0, abs(dot(normalize(NORMAL), normalize(VIEW))), view_falloff);

	// A shaft of light gets thinner toward its top. This rides on the INVERSE of
	// holo_scan because the raster bars belong to a panel and the vertical fade belongs
	// to a beacon, and nothing on this course is ever both.
	//
	// `1.0 - UV.y` and not `UV.y`: a QuadMesh puts v = 0 at its BOTTOM edge, which was
	// measured and not assumed — the first version had the beacon blazing at its top and
	// dying at the lamp it was supposed to be coming out of.
	float taper = mix(1.0, pow(1.0 - UV.y, taper_power), 1.0 - holo_scan);

	ALBEDO = holo_tint.rgb * (scan * edge * flicker * facing * taper * holo_energy * holo_tint.a);
	ALPHA = 1.0;
}
