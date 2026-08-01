shader_type particles;
render_mode disable_force, disable_velocity;

// Smoke and dust integrator, from the reference's smokeCloud.step (range spec
// 16.2). No gravity: the horizontal velocity is bled off at a fixed fraction per
// second and the rise carries the puff up until it dies.
//
//   CUSTOM.x  darkness at birth, 0 haze .. 1 soot. Read by the draw pass.
//   CUSTOM.y  age, 0 at birth, driven to 1 here.
//   CUSTOM.z  lifetime in seconds.
//   CUSTOM.w  unused.

uniform float drag : hint_range(0.01, 1.0) = 0.25;
uniform float particle_size : hint_range(0.01, 8.0) = 0.62;

void start() {
	TRANSFORM[0].xyz = vec3(particle_size, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, particle_size, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, particle_size);
	if (RESTART_CUSTOM) {
		TRANSFORM[0].xyz = vec3(0.0);
		TRANSFORM[1].xyz = vec3(0.0);
		TRANSFORM[2].xyz = vec3(0.0);
		CUSTOM = vec4(0.0, 1.0, 0.001, 0.0);
		COLOR = vec4(0.0);
		ACTIVE = false;
	}
}

void process() {
	CUSTOM.y += DELTA / max(CUSTOM.z, 0.001);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	VELOCITY.xz *= pow(drag, DELTA);
	TRANSFORM[3].xyz += VELOCITY * DELTA;
}
