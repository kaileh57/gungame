shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// One material for the entire map — terrain and town, two draw calls, nine surface
// types. Which type a triangle is comes in on CUSTOM0.x; how much road is painted
// over it comes in on CUSTOM0.y. Base colour is per-vertex in COLOR.
//
// MESH CONTRACT for the world bake:
//   ARRAY_COLOR    linear rgb, already converted from the sRGB palette
//   ARRAY_CUSTOM0  format ARRAY_CUSTOM_RGBA_FLOAT; .x = surface id 0-8,
//                  .y = road blend 0-1, .zw unused
//   normals        per-face (the mesher writes them; nothing here smooths)
//   triangles      non-indexed, so the surface id never interpolates between
//                  two different types across a shared vertex
//
// Surface ids: 0 metal, 1 wood, 2 poly, 3 sand, 4 concrete, 5 tin, 6 cloth,
// 7 asphalt, 8 rock.
//
// SCALE CONTRACT. Object space is world space here and one unit is one metre, so
// every frequency below is literally cycles per metre and can be read as a size:
// f = 22 is a 4.5 cm feature, f = 1.0 is a metre. The contrast budget is spent
// deliberately across three bands, and getting this split wrong is what makes a
// procedural surface read as smeared cloud instead of material:
//   micro  f 20-40   (2-5 cm)   grain, aggregate, tooth   — the dominant read
//   meso   f 1.5-8   (12-60 cm) patches, chips, stains, wear
//   macro  f 0.2-1   (1-5 m)    broad tone only, never more than +-8%
// Anything metre-scale that carries real contrast becomes a cloud blob the
// moment the camera is closer than the feature is wide. Keep macro quiet.

uniform float u_seed = 0.37;
uniform float metallic_base : hint_range(0.0, 1.0) = 0.0;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.9;

varying vec3 v_op;
varying vec3 v_on;
varying float v_type;
varying float v_blend;

// GLSL's smoothstep is UNDEFINED when edge0 > edge1 and several calls below want
// a falling ramp. Hand-rolled so it is defined in both directions.
float ss(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

float h31(vec3 p) {
	p = fract(p * 0.1031 + u_seed * 0.137);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vn(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float x00 = mix(h31(i), h31(i + vec3(1.0, 0.0, 0.0)), f.x);
	float x10 = mix(h31(i + vec3(0.0, 1.0, 0.0)), h31(i + vec3(1.0, 1.0, 0.0)), f.x);
	float x01 = mix(h31(i + vec3(0.0, 0.0, 1.0)), h31(i + vec3(1.0, 0.0, 1.0)), f.x);
	float x11 = mix(h31(i + vec3(0.0, 1.0, 1.0)), h31(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

// --- mip-aware fractal noise -------------------------------------------------
//
// This is the whole fix. The old shader faded an ENTIRE fbm to its mean as soon
// as the finest of its four octaves stopped fitting inside a pixel, which threw
// away the three octaves that still resolved perfectly well and left only the
// hand-authored metre-scale terms standing — hence floors and walls covered in
// smeared cloud. Here each octave carries its own weight and dissolves on its
// own schedule, so a surface loses grain, then grit, then patches, in that order,
// and never snaps. Nyquist is pxf = 0.5; the ramp is centred on it.
float oct_w(float pxf) {
	return 1.0 - smoothstep(0.32, 0.86, pxf);
}

// Value noise is built on an integer lattice and its level sets remember it:
// threshold one and the patches come out as rounded BOXES with their edges lying
// along world X and Z, which on a floor — the one surface whose triangles are
// also axis-aligned — reads as pixelation rather than as material. Every octave
// after the first is therefore sampled through this rotation, so the lattices
// stack at angles to each other and to the geometry. Orthonormal, so it moves the
// lattice without stretching it and every footprint below stays exact.
const mat3 ROT = mat3(
	vec3(0.00, 0.80, 0.60), vec3(-0.80, 0.36, -0.48), vec3(-0.60, -0.48, 0.64)
);

// Four octaves, lacunarity 2.03, signed, mean zero. Value noise has a standard
// deviation near 0.115 per octave, so the raw sum sits at about 0.066 — an
// invisible wobble. The 3.8 gain puts one sigma near 0.24, which makes
// `0.5 + n` behave like a unit-interval field and lets every threshold below be
// read directly as "how much of the surface".
float fb4(vec3 p, float pxf) {
	float s = 0.0;
	float a = 0.5;
	float f = 1.0;
	vec3 q = p;
	for (int i = 0; i < 4; i++) {
		float w = oct_w(pxf * f);
		if (w > 0.004) {
			s += a * w * (vn(q) - 0.5);
		}
		// The base octave is left on the caller's own axes so an anisotropic
		// frequency vector still lays its streaks where the caller asked; it
		// carries half the amplitude, which is what the direction reads off.
		q = ROT * q * 2.03;
		f *= 2.03;
		a *= 0.5;
	}
	return s * 3.8;
}

// Two octaves for the broad terms, which never need four. Same normalisation.
float fb2(vec3 p, float pxf) {
	float s = 0.0;
	float a = 0.5;
	float f = 1.0;
	vec3 q = p;
	for (int i = 0; i < 2; i++) {
		float w = oct_w(pxf * f);
		if (w > 0.004) {
			s += a * w * (vn(q) - 0.5);
		}
		q = ROT * q * 2.11;
		f *= 2.11;
		a *= 0.5;
	}
	return s * 4.4;
}

// How much finer than the WIDE screen axis of the pixel footprint the fractal
// terms are allowed to keep resolving. See `fragment()`.
const float ANISO = 8.0;

// `pw` is the object-space footprint of one pixel per axis. Scaling it by the
// same frequency vector as the sample point gives the exact footprint in noise
// space, which is what makes anisotropic streaks fade on their NARROW axis
// rather than on some isotropic average of the two.
float d4(vec3 p, vec3 pw, vec3 f, float o) {
	return fb4(p * f + o, length(pw * f));
}

float d2(vec3 p, vec3 pw, vec3 f, float o) {
	return fb2(p * f + o, length(pw * f));
}

float u4(vec3 p, vec3 pw, vec3 f, float o) {
	return clamp(0.5 + d4(p, pw, f, o), 0.0, 1.0);
}

float u2(vec3 p, vec3 pw, vec3 f, float o) {
	return clamp(0.5 + d2(p, pw, f, o), 0.0, 1.0);
}

// A sine band that folds to its mean once its wavelength stops fitting in a
// pixel. Sines have no octaves to hide behind and alias far harder than noise,
// so they get a tighter ramp. `cyc` is the pattern's frequency in cycles per
// metre; `x` is the phase, already multiplied by 2*pi*cyc by the caller.
float wave(float x, float px, float cyc) {
	return mix(0.5, sin(x) * 0.5 + 0.5, 1.0 - smoothstep(0.24, 0.72, px * cyc));
}

// A recolour target — rust, a spalled chip, blown sand — is an absolute colour,
// but the surface it lands on is whatever the mesher put in COLOR, and the
// palette spans nearly a stop and a half. The same mix that reads as a stain on
// dark adobe reads as two-tone camouflage on bone. These clamp the target to a
// ratio of the base so a feature's CONTRAST, not its colour, is what is authored:
// `stain` can never darken past the floor, `bleach` never lighten past the
// ceiling, whatever the mesh is coloured.
vec3 stain(vec3 base, vec3 target, vec3 floor_ratio) {
	return max(target, base * floor_ratio);
}

vec3 bleach(vec3 base, vec3 target, float ceil_ratio) {
	return min(target, base * ceil_ratio);
}

void vertex() {
	v_op = VERTEX;
	v_on = normalize(NORMAL);
	v_type = CUSTOM0.x;
	v_blend = CUSTOM0.y;
}

void fragment() {
	vec3 p = v_op;
	// TWO footprints, because two families of pattern need different answers.
	//
	// `px` is the isotropic one — the worst screen axis — and the sine bands use
	// it. A sine has no octaves to hide behind and moirés the instant it is
	// undersampled on ANY axis, so it has to fade on the pessimistic measure.
	//
	// `pw` is anisotropy-limited, and the fractal terms use it. A floor or a wall
	// seen at a grazing angle has a pixel footprint tens of times longer along the
	// view than across it; measuring that isotropically throws away every octave
	// that still resolves perfectly well ACROSS the view, and what is left is the
	// hand-authored metre-scale terms on their own — which is exactly the smeared
	// cloud this shader exists to avoid, arriving through the back door on every
	// surface the camera does not happen to face square on. This is what 8x
	// anisotropic filtering does to a mip chain, done to a procedural: resolve
	// down to the NARROW axis, but never finer than an eighth of the wide one, so
	// a surface still converges with distance instead of shimmering. On a surface
	// faced square on the two axes are equal and this is exactly `fwidth`.
	vec3 fw = fwidth(p);
	float px = length(fw);
	vec3 ddx = dFdx(p);
	vec3 ddy = dFdy(p);
	float hi = max(length(ddx), length(ddy));
	float aniso = max(min(length(ddx), length(ddy)), hi / ANISO) / max(hi, 0.000001);
	vec3 pw = fw * aniso;
	vec3 n = normalize(v_on);
	float t = v_type;
	float up = clamp(n.y, 0.0, 1.0);
	float vert = clamp(1.0 - abs(n.y), 0.0, 1.0);

	vec3 col = COLOR.rgb;
	float rough = roughness_base;
	float metal = metallic_base;

	// Micro-relief, in cycles per metre, chosen per type. It is evaluated once and
	// spent twice: it tilts the normal at the bottom of this function AND drives
	// the albedo wear inside each branch, so grime sits in the hollows and wear
	// sits on the proud edges of the same physical relief instead of being an
	// unrelated second field. That correlation is most of what sells it.
	// `bamt` is the tangent of the steepest tilt the bump may apply, not a raw
	// gradient scale: the relief gradient is 2*pi*bsc*amplitude and would otherwise
	// make every surface's bump strength a hostage to its frequency.
	float bsc = 12.0;
	float bamt = 0.24;
	if (t < 0.5) {
		bsc = 26.0;
		bamt = 0.09;
	} else if (t < 1.5) {
		bsc = 22.0;
		bamt = 0.11;
	} else if (t < 2.5) {
		bsc = 28.0;
		bamt = 0.07;
	} else if (t < 3.5) {
		bsc = 15.0;
		bamt = 0.20;
	} else if (t < 4.5) {
		bsc = 20.0;
		bamt = 0.12;
	} else if (t < 5.5) {
		bsc = 24.0;
		bamt = 0.10;
	} else if (t < 6.5) {
		bsc = 30.0;
		bamt = 0.09;
	} else if (t < 7.5) {
		bsc = 25.0;
		bamt = 0.19;
	}
	float relief = d4(p, pw, vec3(bsc), 0.0);

	// Gravity. Grime runs DOWN a vertical face, so the streak field is squashed
	// 20:1 along Y and its strength is gated by a coarse source sampled 0.7 m
	// HIGHER up the same wall — a run only exists below something that leaked.
	// Both are only evaluated on faces steep enough to shed water.
	float run = 0.0;
	if (vert > 0.04) {
		float src = smoothstep(0.38, 0.80,
			u2(p + vec3(0.0, 0.70, 0.0), pw, vec3(1.7, 0.75, 1.7), 27.0));
		run = smoothstep(0.44, 0.84, u4(p, pw, vec3(9.0, 0.45, 9.0), 8.0));
		run *= (0.16 + 0.84 * src) * vert;
	}

	if (t < 0.5) {
		// Steel: mill tooth at 4 cm, rust in 20 cm patches that pool on the faces
		// water cannot leave, scratches drawn along the length of the stock.
		float tooth = d4(p, pw, vec3(24.0), 0.0);
		// Wide ramp, high threshold. A narrow ramp turns a smooth noise field into a
		// hard-edged blob mask and the surface reads as camouflage; and a threshold
		// near the field's own mean paints half the sheet, which reads as
		// camouflage whatever the ramp does. Rust bleeds in over centimetres and
		// covers a sixth of a face, with the rest of it arriving as runs from
		// wherever water actually sat.
		float rust = smoothstep(0.52, 1.00, u4(p, pw, vec3(5.2), 7.3));
		rust *= smoothstep(0.05, 0.95, 0.62 - n.y * 0.40);
		rust = clamp(rust * 0.85 + run * 0.40, 0.0, 1.0);
		float scr = smoothstep(0.58, 0.90, u4(p, pw, vec3(1.4, 26.0, 26.0), 2.0));
		float pit = smoothstep(0.70, 0.96, u2(p, pw, vec3(16.0), 5.0));
		vec3 ore = mix(vec3(0.088, 0.042, 0.024), vec3(0.150, 0.062, 0.026),
			clamp(0.5 + tooth, 0.0, 1.0));
		col *= 1.0 + tooth * 0.20 + relief * 0.12;
		col = mix(col, stain(col, ore * (1.0 + tooth * 0.7), vec3(0.62, 0.42, 0.30)), rust * 0.50);
		// Relative, not absolute. Gunmetal sits near 0.06 in linear, so adding a
		// flat 0.045 for a scratch was lifting it most of the way to mid grey and
		// scattering pale patches over every dark prop in the game.
		col *= 1.0 + scr * 0.32 * (1.0 - rust);
		col = mix(col, col * 0.74, pit * 0.32);
		// Roughness and metallic carry more of the rust read than albedo ever did:
		// bare steel at 0.72 metallic and 0.45 rough MIRRORS the desert sky, so the
		// clean patches came back near-white while the rusted ones went dull brown,
		// and that specular two-tone was the camouflage on every beam and drum in
		// the game — no albedo change could have fixed it. Compressed to a swing a
		// scavenged, oxidised sheet would actually have.
		rough = clamp(0.60 + rust * 0.26 + pit * 0.10 - scr * 0.08 + tooth * 0.10, 0.34, 1.0);
		metal = clamp(0.66 * (1.0 - rust * 0.55), 0.0, 1.0);
	} else if (t < 1.5) {
		// Timber, grain axis X. Rings are sampled ACROSS the grain, never along it:
		// the old shader took sin(k*p.x), which lays the growth rings at right
		// angles to the length of the board — the one thing wood never does, and
		// the reason every plank read as corrugation. Which transverse coordinate
		// drives the rings depends on the face, and since the world mesh is
		// flat-shaded the normal is constant per triangle, so the choice cannot
		// seam inside a face. Latewood is a narrow cube of the wave, not a
		// symmetric sine: dark lines on a light field, spacing drifting along the
		// board and each line's darkness drawn independently.
		float rate = d2(p, pw, vec3(0.35, 0.12, 0.12), 17.0);
		float warp = d2(p, pw, vec3(0.90, 0.25, 0.25), 3.0);
		float tr = mix(p.y, p.z, step(abs(n.z), abs(n.y)));
		float ring = wave(tr * 94.2 * (1.0 + rate * 0.5) + warp * 5.0, px, 15.0);
		float late = (1.0 - ring) * (1.0 - ring) * (1.0 - ring);
		float lwm = clamp(0.40 + 1.4 * u2(p, pw, vec3(0.30, 6.0, 6.0), 23.0), 0.0, 1.4);
		float fibre = d4(p, pw, vec3(1.6, 62.0, 62.0), 5.0);
		float board = d2(p, pw, vec3(0.7), 11.0);
		col *= 1.0 - (late - 0.3125) * 0.30 * lwm + fibre * 0.09 + board * 0.07 + relief * 0.09;
		float wear = smoothstep(0.56, 0.98, u4(p, pw, vec3(3.4), 21.0));
		col = mix(col, col * vec3(0.80, 0.79, 0.76) + vec3(0.024, 0.022, 0.019), wear * 0.48);
		col = mix(col, col * 1.16 + vec3(0.020, 0.018, 0.014), up * 0.30);
		col = mix(col, col * 0.74, clamp(-relief * 2.2, 0.0, 1.0) * 0.28);
		col = mix(col, col * vec3(0.56, 0.52, 0.48), run * 0.34);
		rough = clamp(0.86 + late * 0.08 + wear * 0.08, 0.34, 1.0);
		metal = 0.02;
	} else if (t < 2.5) {
		// Polymer: moulding speckle at 3.5 cm, scuffs across the mould line, grime
		// settling into half-metre patches.
		float sp = d4(p, pw, vec3(28.0), 0.0);
		float scuff = smoothstep(0.56, 0.88, u4(p, pw, vec3(2.0, 30.0, 30.0), 5.0));
		float dirt = smoothstep(0.54, 0.90, u2(p, pw, vec3(1.8), 9.0));
		// Moulded polymer is nearly black in linear — 0x26282b is 0.02 — so a scuff
		// has to be a proportion of it, never a fixed offset.
		col *= (1.0 + sp * 0.16 + relief * 0.09) * (1.0 + scuff * 0.26);
		col = mix(col, col * 0.80, clamp(dirt + run * 0.5, 0.0, 1.0) * 0.28);
		rough = clamp(0.84 + sp * 0.16 - scuff * 0.12, 0.34, 1.0);
		metal = 0.03;
	} else if (t < 3.5) {
		// Sand. Dunes are genuinely macro and keep their scale, but their contrast
		// is cut to a third: what the eye is supposed to read is the 4 cm grit and
		// the half-metre megaripple, not a fifty-metre brightness ramp.
		float dune = d2(p, pw, vec3(0.022), 13.0);
		float coarse = d2(p, pw, vec3(0.09), 0.0);
		float patch = d4(p, pw, vec3(0.9), 31.0);
		float grit = d4(p, pw, vec3(22.0), 0.0);
		float slope = 1.0 - up;
		// Megaripples: half-metre crests, direction and pitch both drifting over
		// tens of metres so the flats never show one uniform corduroy.
		float rdir = d2(p, pw, vec3(0.045), 41.0);
		float rf = mix(1.3, 2.8, clamp(0.5 + rdir, 0.0, 1.0));
		float rsw = d2(p, pw, vec3(0.03), 83.0);
		float rph = (p.x * (0.62 + rsw) + p.z * (0.78 - rsw)) * rf * 6.2832
			+ d2(p, pw, vec3(0.09), 5.0) * 22.0;
		// Deliberately told it is running half again faster than it is. The phase
		// is warped by a noise term worth twenty-two radians, so the LOCAL spatial
		// frequency of this band runs well above the nominal `rf` wherever the warp
		// is steep, and fading on the nominal number left the flats moiring into a
		// cross-hatch at middle distance. Fading on 1.5x kills it a little early
		// instead, which costs nothing a still frame can see.
		float rip = wave(rph, px, rf * 1.5);
		rip = pow(rip, 2.4) * (1.0 - smoothstep(0.10, 0.30, slope));
		col *= 1.0 + dune * 0.15 + coarse * 0.17 + patch * 0.13 + grit * 0.14 + relief * 0.08;
		col += rip * 0.032;
		col = mix(col, stain(col, vec3(0.219, 0.167, 0.119), vec3(0.42, 0.38, 0.34)),
			smoothstep(0.24, 0.66, slope) * 0.70);
		float cru = smoothstep(0.52, 0.82, u4(p, pw, vec3(2.6), 4.0));
		col = mix(col, col * vec3(1.16, 1.08, 0.94), cru * 0.50);
		if (v_blend > 0.004) {
			// Asphalt painted over the sand. Chippings first, then the cracks.
			float rb = smoothstep(0.10, 0.80, v_blend);
			float agg = d4(p, pw, vec3(26.0), 53.0);
			float crack = smoothstep(0.66, 0.92, u4(p, pw, vec3(2.4, 2.4, 7.0), 6.0));
			float wheel = d2(p, pw, vec3(0.22), 71.0);
			vec3 tar = col * vec3(0.46, 0.45, 0.44) * (1.0 + agg * 0.40 + wheel * 0.14);
			tar = mix(tar, vec3(0.055, 0.052, 0.048), crack * 0.66);
			col = mix(col, tar, rb);
			rough = mix(rough, 0.88, rb);
		}
		rough = clamp(rough - rip * 0.05 + grit * 0.10, 0.45, 1.0);
		metal = 0.0;
	} else if (t < 4.5) {
		// Adobe and concrete. This is the surface that was worst: a three-metre
		// blotch at +-35% and a six-metre panel at +-20% over nothing else. Now the
		// carrying detail is 4.5 cm aggregate, the render patches are knee-high with
		// a hard edge (a patch, not a cloud), the brick courses are 32 cm apart, and
		// the broad tone is down to +-7%.
		// Coverage is the thing to watch here. A term that paints half the surface a
		// second colour is camouflage no matter how fine its frequency; a chip has
		// to be RARE. 0.74->0.97 on a field whose sigma is 0.24 leaves about a
		// tenth of the surface spalled, which is what a scav-town slab looks like.
		float agg = d4(p, pw, vec3(26.0), 0.0);
		float tone = d2(p, pw, vec3(0.45), 3.0);
		// A threshold sitting on the field's own mean paints half the slab a
		// second tone, and half a surface in a second tone is camouflage however
		// fine the frequency. Raised until the render patches are a quarter of it.
		float patch = smoothstep(0.58, 0.76, u2(p, pw, vec3(1.05), 29.0));
		float chip = smoothstep(0.74, 0.97, u4(p, pw, vec3(11.0), 13.0));
		// A crack network, from the contour where the field crosses its own mean.
		// The bare contour is the wrong SHAPE, and that was the most obviously
		// hand-drawn thing left in the game: a contour closes on itself and runs
		// unbroken for tens of metres at a constant width, which is a topographic
		// map, not a failed slab. Two gates fix the shape without touching the
		// cost. `field` decides WHERE the slab has failed, over a few metres, so
		// long stretches stay sound instead of every wall being webbed end to end;
		// `seg` breaks what survives that into hand-sized segments, so a run
		// terminates and restarts rather than circumnavigating the building.
		// Ridged terms also need an explicit distance kill: the mip fade converges
		// a field ON its mean, which is precisely where the ridge peaks, so without
		// this the cracks would widen with distance until they swallowed the
		// surface instead of fading out of it.
		float cr = 1.0 - abs(2.0 * u4(p, pw, vec3(1.6), 6.0) - 1.0);
		float seg = smoothstep(0.34, 0.72, u4(p, pw, vec3(6.5), 44.0));
		float field = smoothstep(0.44, 0.82, u2(p, pw, vec3(0.30), 91.0));
		float crack = (
			smoothstep(0.952, 0.998, cr) * seg * field
			* (1.0 - smoothstep(0.018, 0.070, px))
		);
		col *= 1.0 + agg * 0.16 + tone * 0.05 + relief * 0.10;
		col = mix(col, col * vec3(1.09, 1.05, 0.98) + vec3(0.012, 0.010, 0.007), patch * 0.30);
		col = mix(col, stain(col, vec3(0.098, 0.082, 0.066) * (1.0 + agg * 0.9),
			vec3(0.50, 0.47, 0.44)), chip * 0.42);
		col = mix(col, col * 0.50, crack * 0.80);
		if (vert > 0.04) {
			// A mud-brick course is laid level. Warping it by a whole wavelength,
			// which is what a generous warp does, turns a wall into wood grain.
			float course = wave(p.y * 19.6 + d2(p, pw, vec3(0.8), 7.0) * 1.5, px, 3.12);
			col *= 1.0 + (course - 0.5) * 0.11 * vert;
			col = mix(col, col * vec3(0.50, 0.46, 0.43), run * 0.60);
		}
		if (up > 0.30) {
			// Sand drifting across the slab. Two things keep this from reading as
			// camouflage, which is what an even scatter of round same-sized patches
			// always reads as: the field is stretched 3:1 downwind, because drift
			// comes in tongues and not in spots, and the coverage is itself
			// modulated over a couple of metres so whole stretches stay swept.
			float cover = clamp(0.5 + d2(p, pw, vec3(0.40), 61.0) * 1.3, 0.0, 1.0);
			float dn = u4(p, pw, vec3(2.1, 6.0, 6.4), 0.0);
			// Was thresholded low enough to bleach roughly half of every slab in
			// the game a shade lighter, which on a big flat pad — the firefight
			// yard, the movement course — is leopard print at knee scale and
			// nothing else. A third of it, a shade nearer the slab's own colour.
			float dust = smoothstep(0.72 - cover * 0.20, 1.16 - cover * 0.20, dn);
			float sandg = d4(p, pw, vec3(30.0), 77.0);
			col = mix(col, bleach(col, vec3(0.398, 0.336, 0.248) * (1.0 + sandg * 0.34), 1.45),
				dust * smoothstep(0.30, 0.95, up) * 0.26);
		}
		rough = clamp(0.93 - chip * 0.10 + agg * 0.12, 0.5, 1.0);
		metal = 0.0;
	} else if (t < 5.5) {
		// Corrugated tin. The ribs were on a 67 cm pitch, which is not corrugation,
		// it is a hillside. Real sheet is 8-10 cm, so 11 cycles a metre.
		//
		// Rust starts in the valleys of the corrugation, where the water sits, and
		// creeps out from there. An isotropic rust mask sprayed evenly over the
		// whole sheet at full saturation is the fastest way there is to turn a roof
		// into camouflage netting, which is exactly what this used to do: 74% of a
		// pure orange over half the area, with nothing tying it to the geometry.
		float sel = step(0.5, fract(u_seed * 7.0));
		float ra = mix(p.z * 69.1 + p.x * 4.0, p.x * 69.1 + p.z * 4.0, sel);
		float ribs = wave(ra, px, 11.0);
		float tooth = d4(p, pw, vec3(26.0), 6.0);
		float grime = d2(p, pw, vec3(1.1), 31.0);
		float rust = smoothstep(0.46, 0.98, u4(p, pw, vec3(3.2), 2.7));
		rust = clamp(rust * (0.30 + 0.90 * (1.0 - ribs)) + run * 0.30, 0.0, 1.0);
		vec3 ore = mix(vec3(0.105, 0.055, 0.032), vec3(0.196, 0.086, 0.036), clamp(0.5 + tooth, 0.0, 1.0));
		col *= 1.0 + (ribs - 0.5) * 0.32 + tooth * 0.12 + grime * 0.14 + relief * 0.10;
		col = mix(col, stain(col, ore * (1.15 + tooth * 0.9), vec3(0.62, 0.42, 0.30)),
			clamp(rust * 0.62, 0.0, 0.72));
		rough = clamp(0.66 + rust * 0.24, 0.34, 1.0);
		metal = clamp(0.58 * (1.0 - rust * 0.55), 0.0, 1.0);
	} else if (t < 6.5) {
		// Cloth and tarp. Folds are shading, not paint. They used to be a third of
		// a metre across at +-22% with a further 40% of darkening in the troughs,
		// which on a stretched screen is two-tone camouflage and nothing else; the
		// read now sits on the 4 cm weave and the 2.5 cm slub, with the folds only
		// tilting the tone under them.
		float wu = wave(p.x * 163.4, px, 26.0) - 0.5;
		float wv = wave(p.z * 163.4, px, 26.0) - 0.5;
		float weave = wu * wv * 4.0;
		float fold = d2(p, pw, vec3(5.0), 0.0);
		float slub = d4(p, pw, vec3(40.0), 7.0);
		col *= 1.0 + fold * 0.14 + slub * 0.16 + weave * 0.08 + relief * 0.08;
		col = mix(col, col * 1.24 + vec3(0.030, 0.027, 0.021), smoothstep(0.15, 1.0, n.y) * 0.34);
		col = mix(col, col * 0.70, ss(0.02, -0.26, fold) * 0.22);
		col = mix(col, col * vec3(0.62, 0.58, 0.54), run * 0.34);
		rough = 0.97;
		metal = 0.0;
	} else if (t < 7.5) {
		// Asphalt: 4 cm chippings carry it, cracks run in a 40 cm network, sand
		// drifts across in knee-high tongues, patched repairs sit a shade lighter.
		float agg = d4(p, pw, vec3(24.0), 0.0);
		float crack = smoothstep(0.68, 0.93, u4(p, pw, vec3(2.2, 2.2, 6.5), 6.0));
		float drift = smoothstep(0.56, 1.00, u4(p, pw, vec3(1.5), 2.0)) * smoothstep(0.5, 1.0, up);
		float patch = smoothstep(0.55, 0.72, u2(p, pw, vec3(0.55), 17.0));
		col *= 1.0 + agg * 0.32 + relief * 0.12;
		col = mix(col, vec3(0.050, 0.045, 0.040), crack * 0.75);
		col = mix(col, col * vec3(1.22, 1.16, 1.08), patch * 0.35);
		col = mix(col, bleach(col, vec3(0.545, 0.451, 0.325), 4.0), drift * 0.55);
		rough = clamp(0.90 - agg * 0.14, 0.5, 1.0);
		metal = 0.0;
	} else {
		// Rock: an 11 cm broken face over 3 cm grain, level strata at 57 cm, wind
		// polish on the exposed shoulders, dust caught on anything flat enough to
		// hold it. Strata warped by a third of their own spacing and tinted
		// eighteen per cent warmer, which is what this was, is not geology — on
		// anything smaller than an outcrop it is two-tone camouflage, and the
		// range's target backers are exactly that size.
		float band = wave(p.y * 11.0 + d2(p, pw, vec3(0.35), 0.0) * 2.4, px, 1.75);
		float rgh = d4(p, pw, vec3(9.0), 0.0);
		float fine = d4(p, pw, vec3(34.0), 21.0);
		float pol = smoothstep(0.62, 0.98, u2(p, pw, vec3(1.6), 9.0));
		col *= 1.0 + rgh * 0.22 + fine * 0.18 + relief * 0.12;
		col = mix(col, col * vec3(1.09, 1.04, 0.95), band * 0.20);
		col = mix(col, col * 0.74, pol * 0.26);
		col = mix(col, bleach(col, vec3(0.478, 0.396, 0.286), 1.5),
			smoothstep(0.62, 1.0, n.y) * 0.30);
		rough = clamp(0.92 - pol * 0.16, 0.45, 1.0);
		metal = 0.0;
	}

	ALBEDO = max(col, vec3(0.0));
	ROUGHNESS = rough;
	METALLIC = metal;

	// Derivative bump off the same micro-relief the branch above already spent.
	// No tangents, no UVs, no texture, and no second noise evaluation: build the
	// object-space height gradient from screen derivatives, project it into the
	// screen-space tangent frame, and tilt the normal against it.
	// A screen-space derivative bump goes wrong at grazing angles, where the pixel
	// footprint stretches along the view and the height gradient it measures picks
	// up that stretch — the relief stops being relief and becomes streaks lying in
	// the view direction. The cutoff is therefore well inside Nyquist rather than
	// at it: the bump is gone by the time one pixel spans a quarter of a feature.
	float ba = bamt * (1.0 - smoothstep(0.05, 0.26, px * bsc));
	if (ba > 0.0001) {
		vec3 dpx = dFdx(VERTEX);
		vec3 dpy = dFdy(VERTEX);
		float hx = dFdx(relief);
		float hy = dFdy(relief);
		vec3 rr1 = cross(dpy, NORMAL);
		vec3 rr2 = cross(NORMAL, dpx);
		float det = dot(dpx, rr1);
		vec3 grad = (hx * rr1 + hy * rr2) / (abs(det) + 0.000001);
		// Soft-saturating: the direction is what carries the relief, and the
		// magnitude is normalised out so `ba` alone sets the tilt. The 3.0 knee
		// lets shallow gradients — distant surfaces, dying octaves — fade out
		// smoothly instead of holding full strength right up to the cutoff.
		NORMAL = normalize(NORMAL - ba * grad / (length(grad) + 3.0));
	}
}
