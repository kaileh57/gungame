shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Procedural grime, rust, wear and weave for every scavenged surface in the game.
// One shader with a `surface_type` branch, so the whole project needs six
// materials, not six hundred.
//
// Everything is evaluated in OBJECT space (`v_op`), never world space. That is what
// keeps the pattern welded to the object: a viewmodel that swims because its grime
// is world-space is the single most obvious tell that a surface is fake.
//
// SCALE CONTRACT. `detail_scale` is object units per metre of intended detail:
// 3.2 for world- and creature-scale geometry where one unit is one metre, 1.0 for
// gun parts, where one unit is 90 mm. Every frequency below is therefore cycles
// per DETAIL unit, and one number gives both scales at once — f = 7 is a 4.5 cm
// feature on a crate and a 13 mm feature on a rifle, which is the right ratio for
// something held at arm's length against something seen at three metres.
//
// The contrast budget is spent across three bands and the split is the whole
// difference between "material" and "smeared cloud":
//   micro  f 6-18     grain, tooth, fibre, pores  — the dominant read
//   meso   f 1-3.5    patches, wear, chips, stains
//   macro  f 0.2-0.6  broad tone only, never more than +-8%

// 0 steel, 1 timber, 2 polymer, 3 canvas, 4 flesh, 5 chitin.
uniform int surface_type : hint_range(0, 5) = 0;
uniform vec4 albedo : source_color = vec4(0.302, 0.290, 0.267, 1.0);
uniform float metallic_base : hint_range(0.0, 1.0) = 0.74;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.50;
uniform float detail_scale = 3.2;
// Contrast multiplier on the micro and meso terms of the steel, timber and
// polymer branches. `detail_scale` sets how BIG the detail is; this sets how much
// of it you can see, and the two are not the same judgement. A crate read at
// three metres and a receiver read at forty centimetres want the same feature
// SIZE relative to themselves and very different amounts of contrast: at the
// world value a gun part fills a quarter of the screen with a four-per-cent
// modulation, which is under the threshold at which anything reads as material at
// all, and the magazine of a shotgun came back as a blank grey plate. 1.0 is the
// world default and nothing but the three gun materials raises it.
uniform float detail_gain : hint_range(0.25, 4.0) = 1.0;
// Micro-relief frequency in cycles per OBJECT unit and the bump depth. Both keep
// exactly the meaning and the useful range they had, so the values `beast_mat.gd`
// and `build_ui_assets.gd` pass still do what those files intend.
uniform float bump_scale = 26.0;
uniform float bump_amount : hint_range(0.0, 0.2) = 0.011;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;
// For hand-built primitive geometry (enemy rigs) that ships with smooth normals.
// Baked meshes are already flat-shaded and should leave this off.
uniform bool flat_shaded = false;

// Per-object variation without a per-object material. Set with
// `set_instance_shader_parameter()`; MultiMesh instances add INSTANCE_CUSTOM.x
// on top, so a field of drums can be seeded from its custom data buffer.
instance uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
instance uniform float surface_seed = 0.37;

varying vec3 v_op;
varying vec3 v_on;
varying float v_seed;

// Converts `bump_amount` from the reference's depth units to the tangent of the
// steepest normal tilt the derivative bump may apply. See the bump block below.
const float BUMP_TILT = 9.0;

// GLSL's smoothstep is UNDEFINED when edge0 > edge1, and the canvas branch calls
// it that way on purpose to fade grime downward. Hand-rolled so it is defined.
float ss(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

float h31(vec3 p, float sd) {
	p = fract(p * 0.1031 + sd * 0.137);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vn(vec3 x, float sd) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = h31(i, sd);
	float n100 = h31(i + vec3(1.0, 0.0, 0.0), sd);
	float n010 = h31(i + vec3(0.0, 1.0, 0.0), sd);
	float n110 = h31(i + vec3(1.0, 1.0, 0.0), sd);
	float n001 = h31(i + vec3(0.0, 0.0, 1.0), sd);
	float n101 = h31(i + vec3(1.0, 0.0, 1.0), sd);
	float n011 = h31(i + vec3(0.0, 1.0, 1.0), sd);
	float n111 = h31(i + vec3(1.0, 1.0, 1.0), sd);
	float x00 = mix(n000, n100, f.x);
	float x10 = mix(n010, n110, f.x);
	float x01 = mix(n001, n101, f.x);
	float x11 = mix(n011, n111, f.x);
	return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

// --- mip-aware fractal noise -------------------------------------------------
//
// `length(fwidth(P))` is the object-space footprint of one pixel. The old shader
// collapsed an ENTIRE fbm toward its mean as soon as its finest octave stopped
// fitting inside that footprint, which threw away the three coarser octaves that
// still resolved fine and left only the hand-authored low-frequency terms
// standing — the reason every surface in the game read as a cloud. Here each
// octave carries its own weight and dissolves on its own schedule, so a surface
// loses grain, then grit, then patches, in that order, and never snaps.
// Nyquist is pxf = 0.5; the ramp straddles it.
float oct_w(float pxf) {
	return 1.0 - smoothstep(0.32, 0.86, pxf);
}

// Value noise is built on an integer lattice and its level sets remember it:
// threshold one and the patches come out as rounded BOXES with their edges lying
// along the object's own axes — which for a crate, a plinth or a receiver flank
// are the same axes its faces lie on, so the result reads as pixelation rather
// than as material. Every octave after the first is therefore sampled through
// this rotation, so the lattices stack at angles to each other and to the
// geometry. Orthonormal, so it moves the lattice without stretching it and every
// footprint below stays exact.
const mat3 ROT = mat3(
	vec3(0.00, 0.80, 0.60), vec3(-0.80, 0.36, -0.48), vec3(-0.60, -0.48, 0.64)
);

// Four octaves, lacunarity 2.03, signed, mean zero. Value noise has a standard
// deviation near 0.115 per octave, so the raw sum sits near 0.066 — an invisible
// wobble on its own. The 3.8 gain puts one sigma near 0.24, which makes
// `0.5 + n` behave like a unit-interval field and lets every threshold below be
// read directly as "how much of the surface".
float fb4(vec3 p, float pxf, float sd) {
	float s = 0.0;
	float a = 0.5;
	float f = 1.0;
	vec3 q = p;
	for (int i = 0; i < 4; i++) {
		float w = oct_w(pxf * f);
		if (w > 0.004) {
			s += a * w * (vn(q, sd) - 0.5);
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
float fb2(vec3 p, float pxf, float sd) {
	float s = 0.0;
	float a = 0.5;
	float f = 1.0;
	vec3 q = p;
	for (int i = 0; i < 2; i++) {
		float w = oct_w(pxf * f);
		if (w > 0.004) {
			s += a * w * (vn(q, sd) - 0.5);
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

// `pw` is the pixel footprint per axis. Scaling it by the same frequency vector
// as the sample point gives the exact footprint in noise space, which is what
// lets an anisotropic streak field fade on its NARROW axis instead of on some
// isotropic average that would blur the streaks away far too early.
float d4(vec3 p, vec3 pw, vec3 f, float o, float sd) {
	return fb4(p * f + o, length(pw * f), sd);
}

float d2(vec3 p, vec3 pw, vec3 f, float o, float sd) {
	return fb2(p * f + o, length(pw * f), sd);
}

float u4(vec3 p, vec3 pw, vec3 f, float o, float sd) {
	return clamp(0.5 + d4(p, pw, f, o, sd), 0.0, 1.0);
}

float u2(vec3 p, vec3 pw, vec3 f, float o, float sd) {
	return clamp(0.5 + d2(p, pw, f, o, sd), 0.0, 1.0);
}

// A sine band that folds to its mean once its wavelength stops fitting in a
// pixel. Sines have no octaves to hide behind and alias harder than noise, so
// they get a tighter ramp. `cyc` is the pattern frequency in cycles per detail
// unit; `x` is the phase, already multiplied by 2*pi*cyc by the caller.
float wave(float x, float px, float cyc) {
	return mix(0.5, sin(x) * 0.5 + 0.5, 1.0 - smoothstep(0.24, 0.72, px * cyc));
}

// A recolour target — rust, a spalled chip, blown sand — is an absolute colour,
// but the surface it lands on is whatever albedo * tint * COLOR gives it, and the
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
	v_seed = surface_seed + INSTANCE_CUSTOM.x;
}

void fragment() {
	float sd = v_seed;
	float ds = max(detail_scale, 0.0001);
	vec3 p = v_op * ds;
	// TWO footprints, because two families of pattern need different answers.
	//
	// `px` is the isotropic one — the worst screen axis — and the sine bands (the
	// weave, the growth banding) use it. A sine has no octaves to hide behind and
	// moirés the instant it is undersampled on ANY axis.
	//
	// `pw` is anisotropy-limited, and the fractal terms use it. A crate flank or a
	// tarp seen at a grazing angle has a pixel footprint many times longer along
	// the view than across it; measuring that isotropically throws away every
	// octave that still resolves perfectly well ACROSS the view, and what is left
	// is the hand-authored coarse terms on their own — the smeared cloud this
	// shader exists to avoid, arriving on every surface not faced square on. This
	// is 8x anisotropic filtering done to a procedural: resolve down to the NARROW
	// axis, never finer than an eighth of the wide one. Faced square on, the two
	// axes are equal and this is exactly `fwidth`.
	vec3 fw = fwidth(v_op) * ds;
	float px = length(fw);
	vec3 ddx = dFdx(p);
	vec3 ddy = dFdy(p);
	float hi = max(length(ddx), length(ddy));
	float aniso = max(min(length(ddx), length(ddy)), hi / ANISO) / max(hi, 0.000001);
	vec3 pw = fw * aniso;
	vec3 n = normalize(v_on);
	float upf = clamp(n.y, 0.0, 1.0);
	float vert = clamp(1.0 - abs(n.y), 0.0, 1.0);

	vec3 col = albedo.rgb * tint.rgb * COLOR.rgb;
	float rough = roughness_base;
	float metal = metallic_base;

	// Micro-relief, evaluated once and spent twice: it tilts the normal at the
	// bottom of this function AND drives the albedo wear inside each branch, so
	// grime sits in the hollows and wear sits on the proud edges of the same
	// physical relief instead of being an unrelated second field.
	float bsc = bump_scale / ds;
	float relief = d4(p, pw, vec3(bsc), 0.0, sd);

	// Gravity. Grime runs DOWN a face, so the streak field is squashed 20:1 along
	// the object's own Y and its strength is gated by a coarser source sampled
	// further up the same face — a run only exists below something that leaked.
	// Only evaluated on faces steep enough to shed water.
	float run = 0.0;
	if (vert > 0.04) {
		float src = smoothstep(0.38, 0.80,
			u2(p + vec3(0.0, 2.2, 0.0), pw, vec3(0.55, 0.24, 0.55), 27.0, sd));
		run = smoothstep(0.44, 0.84, u4(p, pw, vec3(2.9, 0.145, 2.9), 8.0, sd));
		run *= (0.16 + 0.84 * src) * vert;
	}

	if (surface_type == 0) {
		// Pitted, rusting steel. Mill tooth carries it; rust pools on the faces
		// water cannot leave and runs down the ones it can.
		float tooth = d4(p, pw, vec3(7.5), 0.0, sd);
		// Wide ramp, high threshold. A narrow ramp turns a smooth noise field into a
		// hard-edged blob mask and the surface reads as camouflage; and a threshold
		// near the field's own mean paints half the part, which reads as camouflage
		// whatever the ramp does. Rust bleeds in over centimetres and covers a
		// sixth of a face, with the rest arriving as runs from wherever water sat.
		// 3.2 cycles per detail unit is a 10 cm patch on a drum and a 28 mm patch on
		// a receiver. At the 1.7 it was, a 55-gallon drum carried three patches
		// across its whole face, which is a camouflage pattern, not corrosion.
		float rust = smoothstep(0.52, 1.00, u4(p, pw, vec3(3.2), 7.3, sd));
		rust *= smoothstep(0.05, 0.95, 0.66 - n.y * 0.38);
		rust = clamp(rust * 0.85 + run * 0.36, 0.0, 1.0);
		float scr = smoothstep(0.58, 0.90, u4(p, pw, vec3(0.5, 8.2, 8.2), 2.0, sd));
		float pit = smoothstep(0.70, 0.96, u2(p, pw, vec3(7.5), 5.0, sd));
		vec3 ore = mix(vec3(0.088, 0.042, 0.024), vec3(0.150, 0.062, 0.026),
			clamp(0.5 + tooth, 0.0, 1.0));
		col *= 1.0 + (tooth * 0.18 + relief * 0.10) * detail_gain;
		col = mix(col, stain(col, ore * (1.0 + tooth * 0.7), vec3(0.62, 0.42, 0.30)),
			clamp(rust * 0.55 * detail_gain, 0.0, 1.0));
		// Relative, not absolute. Gunmetal sits near 0.06 in linear, so adding a
		// flat 0.042 for a scratch was lifting it most of the way to mid grey and
		// scattering pale camouflage patches over every drum and every receiver.
		col *= 1.0 + scr * 0.30 * detail_gain * (1.0 - rust);
		col = mix(col, col * 0.76, clamp(pit * 0.30 * detail_gain, 0.0, 1.0));
		// Roughness and metallic carry more of the rust read than albedo ever did:
		// bare steel at 0.72 metallic and 0.45 rough MIRRORS the desert sky, so the
		// clean patches came back near-white while the rusted ones went dull brown,
		// and that specular two-tone was the camouflage on every beam and drum in
		// the game — no albedo change could have fixed it. Compressed to a swing a
		// scavenged, oxidised sheet would actually have.
		rough = clamp(rough + 0.10 + rust * 0.26 + pit * 0.10 - scr * 0.08 + tooth * 0.10, 0.34, 1.0);
		metal = clamp(metal * (1.0 - rust * 0.55), 0.0, 1.0);
	} else if (surface_type == 1) {
		// Timber, grain axis local X — which for a gun is the bore, so the figure
		// runs down the stock the way a stock is cut. Rings are sampled ACROSS the
		// grain, never along it: the old shader took sin(k*p.x), which lays the
		// growth rings at right angles to the length of the part, the one thing
		// wood never does, and the reason a stock read as corrugation. Which
		// transverse coordinate drives the rings depends on the face, and the
		// baked meshes are flat-shaded, so the normal is constant per triangle and
		// the choice cannot seam inside a face. Latewood is a narrow cube of the
		// wave rather than a symmetric sine — dark lines on a light field, spacing
		// drifting down the part, each line's darkness drawn independently.
		float rate = d2(p, pw, vec3(0.11, 0.04, 0.04), 17.0, sd);
		float warp = d2(p, pw, vec3(0.28, 0.08, 0.08), 3.0, sd);
		float tr = mix(p.y, p.z, step(abs(n.z), abs(n.y)));
		float ring = wave(tr * 41.47 * (1.0 + rate * 0.5) + warp * 5.0, px, 6.6);
		float late = (1.0 - ring) * (1.0 - ring) * (1.0 - ring);
		float lwm = clamp(0.40 + 1.4 * u2(p, pw, vec3(0.10, 1.9, 1.9), 23.0, sd), 0.0, 1.4);
		float fibre = d4(p, pw, vec3(0.5, 20.0, 20.0), 5.0, sd);
		float board = d2(p, pw, vec3(0.22), 11.0, sd);
		col *= (
			1.0
			+ (
				-(late - 0.3125) * 0.28 * lwm
				+ fibre * 0.09
				+ board * 0.07
				+ relief * 0.09
			)
			* detail_gain
		);
		float wear = smoothstep(0.56, 0.98, u4(p, pw, vec3(1.05), 21.0, sd));
		col = mix(col, col * vec3(0.80, 0.79, 0.76) + vec3(0.022, 0.020, 0.017),
			clamp(wear * 0.46 * detail_gain, 0.0, 1.0));
		col = mix(col, col * 1.14 + vec3(0.018, 0.016, 0.013), upf * 0.20);
		col = mix(col, col * 0.76,
			clamp(clamp(-relief * 2.2, 0.0, 1.0) * 0.26 * detail_gain, 0.0, 1.0));
		col = mix(col, col * vec3(0.60, 0.56, 0.52), clamp(run * 0.30 * detail_gain, 0.0, 1.0));
		rough = clamp(0.86 + late * 0.08 + wear * 0.08, 0.34, 1.0);
	} else if (surface_type == 2) {
		// Moulded polymer and rubber. Speckle in the mix, scuffs across the mould
		// line, grime settling into the shallow patches.
		float sp = d4(p, pw, vec3(9.0), 0.0, sd);
		float scuff = smoothstep(0.56, 0.88, u4(p, pw, vec3(0.6, 9.5, 9.5), 5.0, sd));
		float dirt = smoothstep(0.54, 0.90, u2(p, pw, vec3(1.5), 9.0, sd));
		// Moulded polymer is nearly black in linear — 0x26282b is 0.02 — so a scuff
		// has to be a proportion of it, never a fixed offset.
		col *= (
			(1.0 + (sp * 0.15 + relief * 0.09) * detail_gain)
			* (1.0 + scuff * 0.28 * detail_gain)
		);
		col = mix(col, col * 0.82,
			clamp(clamp(dirt + run * 0.5, 0.0, 1.0) * 0.26 * detail_gain, 0.0, 1.0));
		rough = clamp(0.84 + sp * 0.16 - scuff * 0.12, 0.34, 1.0);
	} else if (surface_type == 3) {
		// Canvas, webbing, hide. Weave in both directions, slubs in the yarn,
		// grime settling underneath and running down the folds.
		float wu = wave(p.x * 56.55, px, 9.0) - 0.5;
		float wv = wave(p.y * 56.55, px, 9.0) - 0.5;
		float weave = wu * wv * 4.0;
		float slub = d4(p, pw, vec3(12.0), 7.0, sd);
		// Folds are shading, not paint. Wide and deep enough and they stop being
		// cloth and become two-tone camouflage, which is a screen, not a tarp.
		float fold = d2(p, pw, vec3(1.6), 0.0, sd);
		// A threshold set AT the field's own mean stains half the surface, and half a
		// surface in a second tone is camouflage — it was doing exactly that to every
		// tarp and webbing strap in the game. 0.62 leaves grime on a sixth of it.
		float grime = smoothstep(0.62, 1.02, u4(p, pw, vec3(1.4), 3.7, sd)) * ss(0.6, -0.4, n.y);
		col *= 1.0 + fold * 0.14 + slub * 0.16 + weave * 0.08 + relief * 0.08;
		col = mix(col, stain(col, vec3(0.055, 0.045, 0.036), vec3(0.44, 0.42, 0.40)),
			clamp(grime + run * 0.6, 0.0, 1.0) * 0.38);
		rough = clamp(0.94 + weave * 0.03 + grime * 0.05, 0.55, 1.0);
	} else if (surface_type == 4) {
		// Flesh. Blotching, veins, old bruises, and a wet sheen where it is thinnest.
		float blotch = d4(p, pw, vec3(1.6), 13.0, sd);
		// Ridged, so it needs an explicit distance kill: the mip fade converges a
		// field ON its mean, which is exactly where the ridge peaks, and without
		// this the veins would widen with distance until they covered the animal
		// instead of fading off it.
		float ridge = 1.0 - abs(2.0 * u4(p, pw, vec3(2.4, 2.8, 2.4), 4.0, sd) - 1.0);
		float vein = smoothstep(0.62, 0.94, ridge) * (1.0 - smoothstep(0.05, 0.20, px));
		float pore = d4(p, pw, vec3(16.0), 0.0, sd);
		float bruise = smoothstep(0.55, 0.92, u2(p, pw, vec3(0.9), 31.0, sd));
		col *= 1.0 + blotch * 0.26 + pore * 0.10 + relief * 0.08;
		col = mix(col, stain(col, vec3(0.230, 0.085, 0.078), vec3(0.62, 0.44, 0.40)), bruise * 0.40);
		col = mix(col, vec3(0.330, 0.110, 0.105), vein * 0.46);
		rough = clamp(0.70 - smoothstep(0.0, 0.35, blotch) * 0.24 + bruise * 0.06, 0.26, 1.0);
	} else {
		// Chitin and bone. Growth banding up the vertical, chips along the ridges.
		float band = wave(p.y * 31.42 + d2(p, pw, vec3(0.8), 0.0, sd) * 6.0, px, 5.0);
		float shell = d4(p, pw, vec3(2.4), 17.0, sd);
		float fine = d4(p, pw, vec3(10.0), 3.0, sd);
		float chip = smoothstep(0.64, 0.92, u4(p, pw, vec3(3.4), 7.0, sd));
		col *= 1.0 + shell * 0.24 + fine * 0.13 + relief * 0.10;
		col += (band - 0.5) * 0.06;
		col = mix(col, col * vec3(1.14, 1.05, 0.90), chip * 0.50);
		rough = clamp(0.40 + band * 0.14 + shell * 0.16 - chip * 0.14, 0.16, 1.0);
	}

	ALBEDO = max(col, vec3(0.0));
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = emission_color.rgb * emission_energy;

	vec3 sn = NORMAL;
	if (flat_shaded) {
		vec3 fn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		sn = dot(fn, NORMAL) < 0.0 ? -fn : fn;
	}

	// Derivative bump off the same micro-relief the branch above already spent.
	// Build the object-space height gradient from screen derivatives, project it
	// into the screen-space tangent frame, and tilt the normal against it. No
	// tangents, no UVs, no texture — the only way this works on procedurally
	// welded geometry that has neither.
	// A screen-space derivative bump goes wrong at grazing angles, where the pixel
	// footprint stretches along the view and the height gradient it measures picks
	// up that stretch — the relief stops being relief and becomes streaks lying in
	// the view direction. The cutoff is therefore well inside Nyquist rather than
	// at it: the bump is gone by the time one pixel spans a quarter of a feature.
	float ba = bump_amount * (1.0 - smoothstep(0.05, 0.26, px * bsc));
	if (ba > 0.0001) {
		vec3 dpx = dFdx(VERTEX);
		vec3 dpy = dFdy(VERTEX);
		float hx = dFdx(relief);
		float hy = dFdy(relief);
		vec3 rr1 = cross(dpy, sn);
		vec3 rr2 = cross(sn, dpx);
		float det = dot(dpx, rr1);
		vec3 grad = (hx * rr1 + hy * rr2) / (abs(det) + 0.000001);
		// Soft-saturating. The raw gradient of a micro-relief field is 2*pi*f times
		// its amplitude, so scaling by it directly would make bump strength a
		// hostage to `bump_scale`: raise the frequency and every surface silently
		// turns to gravel. Normalising the magnitude out leaves `bump_amount` in
		// sole charge of the tilt, and the 3.0 knee lets shallow gradients — far
		// surfaces, dying octaves — fade out instead of holding full strength up to
		// the cutoff. BUMP_TILT maps the reference's depth numbers onto the tangent
		// of a tilt: 0.011 becomes about five degrees.
		sn = normalize(sn - ba * BUMP_TILT * grad / (length(grad) + 3.0));
	}
	NORMAL = sn;
}
