shader_type particles;
render_mode disable_force, disable_velocity;

// Wind-blown ash and grit, from the reference's DUST/updateDust (world spec
// 21.2). The whole field is emitted once and never dies; it is wrapped
// toroidally around the camera instead, so the same 1100 motes follow the player
// across the entire map for the cost of one dispatch.
//
// The reference wraps by a single subtraction per frame, which only works if the
// camera never jumps. This uses a modulo, so a teleport, a respawn or a scene
// warp lands the field correctly on the very next frame.
//
//   CUSTOM.x  per-mote phase, radians. Decorrelates the flutter.
//   CUSTOM.y  unused.  CUSTOM.z  unused.  CUSTOM.w  per-mote size scale.

uniform vec3 camera_pos = vec3(0.0);
uniform float vfx_time = 0.0;
uniform float wrap_radius : hint_range(4.0, 200.0) = 46.0;
uniform float band_bottom : hint_range(-40.0, 0.0) = -4.0;
uniform float band_top : hint_range(1.0, 80.0) = 13.0;
uniform vec2 wind_base = vec2(1.9, -1.15);
uniform float particle_size : hint_range(0.001, 1.0) = 0.042;
uniform vec3 mote_color : source_color = vec3(0.72, 0.61, 0.44);

float hash11(float n) {
	return fract(sin(n * 12.9898) * 43758.5453123);
}

void start() {
	float i = float(INDEX);
	float band = band_top - band_bottom;
	vec3 offset = vec3(
			(hash11(i * 1.17 + 0.13) - 0.5) * 2.0 * wrap_radius,
			band_bottom + pow(hash11(i * 2.31 + 7.31), 2.1) * band,
			(hash11(i * 3.77 + 19.7) - 0.5) * 2.0 * wrap_radius
	);
	TRANSFORM[3].xyz = camera_pos + offset;
	float scale = particle_size * (0.6 + hash11(i * 5.11 + 3.7) * 0.8);
	TRANSFORM[0].xyz = vec3(scale, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, scale, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, scale);
	CUSTOM = vec4(hash11(i * 7.13 + 2.9) * 6.2832, 0.0, 0.0, scale);
	COLOR = vec4(mote_color * (0.5 + hash11(i * 11.7 + 5.1) * 0.5), 1.0);
	VELOCITY = vec3(0.0);
}

void process() {
	float phase = CUSTOM.x;
	float t = vfx_time;
	float wind = 0.75 + sin(t * 0.21) * 0.4 + sin(t * 0.083 + 1.3) * 0.32;
	vec3 p = TRANSFORM[3].xyz;
	p.x += (wind_base.x * wind + sin(t * 1.3 + phase) * 0.5) * DELTA;
	p.z += (wind_base.y * wind + cos(t * 1.1 + phase * 1.7) * 0.5) * DELTA;
	p.y += (sin(t * 0.9 + phase * 2.3) * 0.22 - 0.06) * DELTA;

	vec3 d = p - camera_pos;
	float span = wrap_radius * 2.0;
	float band = band_top - band_bottom;
	d.x = mod(d.x + wrap_radius, span) - wrap_radius;
	d.z = mod(d.z + wrap_radius, span) - wrap_radius;
	d.y = mod(d.y - band_bottom, band) + band_bottom;
	TRANSFORM[3].xyz = camera_pos + d;
}
