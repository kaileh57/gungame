# WORLD + PLAYER — implementation spec

Source: `reference/ash_flats (1).html`, readable JS lines 202–3536 (lines 199 and 201
are the minified three.js bundle and the base64 part blob — ignore them).
Every number below is transcribed literally from that file. Nothing here is
approximated, rounded, or "to be tuned".

Owners: `res://systems/player/` (movement, camera), `res://tools/build_world.gd`
(terrain + town bake), `res://art/` (world material / sky / fog).

---

## 0. Source map

| section | lines | what |
|---|---|---|
| `02_core.js` | 204–755 | prelude, rng, noise, MAP/terrain, surfaces, palette, scene, GLSL, Mesher |
| `03_world.js` | 756–1485 | colliders, terrain mesh, building + prop generators |
| `04_layout.js` | 1486–1859 | BSP town layout, plaza, roof bridges, wilds, exfils, assemble |
| `05_player.js` | 1860–2478 | MOVEMENT, camera rig, exfil flow |
| `06_weapons.js` | 2479–3104 | guns (GUNS agent's domain; `raycastWorld` at 2867 is shared) |
| `07_atmos.js` | 3105–3536 | sky shader, dust, audio, HUD, loop |

---

## 1. Determinism — rng, seeds, stream order

### 1.1 `WORLD_SEED`
```js
const WORLD_SEED = (() => {
  const q = new URLSearchParams(location.search).get('seed');
  if (q && /^\d+$/.test(q)) return (+q) >>> 0;
  return 4471;
})() || 4471;
```
Default **4471**.

### 1.2 `rng(seed)` — xorshift32
```js
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0;
                 return s / 4294967296; };
}
```

**GOTCHA — the middle shift is a SIGNED shift.** `s >> 17` (not `>>>`). JS coerces
`s` to int32 first, so when `s >= 2^31` the shift sign-extends. Godot ints are
64-bit; a naive `s >> 17` gives a different sequence and the entire world changes.
Exact port:

```gdscript
class_name XorShift32
extends RefCounted

var _s: int = 1

func _init(seed_value: int) -> void:
	_s = seed_value & 0xFFFFFFFF
	if _s == 0:
		_s = 1

## Returns a float in [0, 1). Bit-exact with the reference's xorshift32.
func next() -> float:
	_s = (_s ^ (_s << 13)) & 0xFFFFFFFF
	# JS `s >> 17` is an ARITHMETIC shift on ToInt32(s): the top 17 bits are
	# filled with the sign bit, i.e. with 1s whenever bit 31 is set.
	var t: int = (_s >> 17) & 0x7FFF
	if _s & 0x80000000:
		t |= 0xFFFF8000
	_s = (_s ^ t) & 0xFFFFFFFF
	_s = (_s ^ (_s << 5)) & 0xFFFFFFFF
	return float(_s) / 4294967296.0
```

### 1.3 Draw helpers (each consumes exactly one `next()` unless noted)
```js
const pick   = (r, a) => a[Math.floor(r() * a.length)];   // 1 draw
const rr     = (r, a, b) => a + (b - a) * r();            // 1 draw
const ri     = (r, a, b) => Math.floor(a + (b - a + 1) * r());  // 1 draw, INCLUSIVE both ends
const chance = (r, p) => r() < p;                         // 1 draw
```
`vary(hex, r, amt)` consumes **3** draws (see §10.3). Any change in the number or
order of draws re-rolls the whole town.

### 1.4 Independent streams
| stream | seed | used by |
|---|---|---|
| noise permutation | `WORLD_SEED ^ 0x9e3779b9` | `NP[]` Fisher–Yates shuffle |
| `G.r` | `WORLD_SEED ^ 0xA51F` | ALL of `layoutTown`, every building/prop generator |
| wilds | `WORLD_SEED ^ 0x77E5` | `scatterWilds` placement decisions |
| exfils | `WORLD_SEED ^ 0xE1F1` | `placeExfils` (declared, effectively unused) |
| weapon base | `WORLD_SEED ^ 0x1F00D` | `wseedBase` for F-scavenge |
| starting loadout | `(WORLD_SEED * 2654435761 + i * 1013904223) >>> 0` | slots 0–3 |

**GOTCHA — `scatterWilds` interleaves two streams.** Its local `r` drives placement
(`a`, `rad`, `u`, camp offsets, fence angles) but every generator it calls
(`rockCluster(G,…)`, `deadTree(G,…)`, `barrel(G,…)`, `bAdobe(G,…)`) reads `g.r`,
which is `G.r`. Both advance. Reproduce the interleaving exactly.

### 1.5 Build order (must not change)
```js
const wmat = worldMaterial();
layoutTown();      // fills ROADS, BLOCKS, G.buildings, POIS, LADDERS, COL, W
scatterWilds();
placeExfils();
const TERR = buildTerrain();   // reads ROADS via roadAt() — MUST run after layoutTown
const townMesh = W.build(wmat);
const terrainMesh = TERR.build(wmat);
```
`buildTerrain` calls `roadAt()`, which walks `ROADS`. If terrain is baked before
the town, every street disappears from the ground colour.

---

## 2. Math primitives

```js
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;
const lerp  = (a, b, t) => a + (b - a) * t;
const smoothstep = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0), 0, 1);
                                    return t * t * (3 - 2 * t); };
const TAU = Math.PI * 2;
const damp = (a, b, rate, dt) => lerp(a, b, 1 - Math.exp(-rate * dt));
```

Godot equivalents: `clampf`, `lerpf`, `smoothstep`, `TAU`.

**`smoothstep` is called with `e0 > e1` in five places** (`smoothstep(-40,-300,…)`,
`smoothstep(-60,-110,z)`, `smoothstep(0.0,-0.10,h)` in the sky shader, and twice
inside GLSL). Godot's built-in `smoothstep(from, to, x)` handles `from > to`
identically (same clamped-ratio formula), so it ports 1:1. GLSL's `smoothstep`
is **undefined** for `edge0 > edge1` — inside shader code, hand-roll it:

```glsl
float ss(float e0, float e1, float x){ float t = clamp((x-e0)/(e1-e0), 0.0, 1.0);
                                       return t*t*(3.0-2.0*t); }
```

`damp` is the frame-rate-independent exponential approach used everywhere in the
camera/stance code. Port verbatim:
```gdscript
static func damp(a: float, b: float, rate: float, dt: float) -> float:
	return lerpf(a, b, 1.0 - exp(-rate * dt))
```

---

## 3. Value noise (CPU side)

### 3.1 Permutation table
```js
const NP = new Uint8Array(512);
(function () {
  const r = rng(WORLD_SEED ^ 0x9e3779b9);
  const p = new Uint8Array(256);
  for (let i = 0; i < 256; i++) p[i] = i;
  for (let i = 255; i > 0; i--) { const j = Math.floor(r() * (i + 1));
                                  const t = p[i]; p[i] = p[j]; p[j] = t; }
  for (let i = 0; i < 512; i++) NP[i] = p[i & 255];
})();
```

### 3.2 `vnoise2`
```js
function vnoise2(x, y) {
  const X = Math.floor(x) & 255, Y = Math.floor(y) & 255;
  let fx = x - Math.floor(x), fy = y - Math.floor(y);
  fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
  const a = NP[NP[X] + Y] / 255, b = NP[NP[X + 1] + Y] / 255;
  const c = NP[NP[X] + Y + 1] / 255, d = NP[NP[X + 1] + Y + 1] / 255;
  return lerp(lerp(a, b, fx), lerp(c, d, fx), fy);
}
```
Range `[0,1]`. Note `NP[X+1]` can index 256 — that is why `NP` is 512 long.

`Math.floor(x) & 255` for negative `x`: `Math.floor(-3.2) = -4`, `-4 & 255 = 252`.
GDScript `-4 & 255` is also `252` (low 8 bits of 64-bit two's complement). Same.

```gdscript
func vnoise2(x: float, y: float) -> float:
	var fxi: int = int(floor(x))
	var fyi: int = int(floor(y))
	var X: int = fxi & 255
	var Y: int = fyi & 255
	var fx: float = x - float(fxi)
	var fy: float = y - float(fyi)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a: float = float(NP[NP[X] + Y]) / 255.0
	var b: float = float(NP[NP[X + 1] + Y]) / 255.0
	var c: float = float(NP[NP[X] + Y + 1]) / 255.0
	var d: float = float(NP[NP[X + 1] + Y + 1]) / 255.0
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)
```

### 3.3 `fbm2` / `ridged`
```js
function fbm2(x, y, oct = 4, lac = 2.03, gain = 0.5) {
  let s = 0, a = 0.5, n = 0;
  for (let i = 0; i < oct; i++) { s += a * vnoise2(x, y); n += a;
                                  x *= lac; y *= lac; a *= gain; }
  return s / n;
}
function ridged(x, y, oct = 4) {
  let s = 0, a = 0.5, n = 0;
  for (let i = 0; i < oct; i++) { s += a * (1 - Math.abs(vnoise2(x, y) * 2 - 1)); n += a;
                                  x *= 2.07; y *= 2.07; a *= 0.5; }
  return s / n;
}
```
Defaults: `oct=4`, `lac=2.03`, `gain=0.5`; `ridged` hard-codes lacunarity **2.07**,
gain **0.5**. Both normalise by the summed amplitude, so output is `[0,1]`.

**GOTCHA:** the offset is not perturbed per octave — only the coordinate is scaled.
Octaves are therefore correlated near the origin. This is the reference behaviour
and the terrain shape depends on it; do not "improve" it.

---

## 4. The map — terrain height field

### 4.1 `MAP`
```js
const MAP = { half: 460, townR: 132, pan: 0.0 };
```
`half` (playable half-extent, metres) is declared but never read — the real extent
comes from `TW = 880` (§7). `townR = 132`, `pan = 0.0`.

### 4.2 `wadiX` — dry-river centre line, x as a function of z
```js
function wadiX(z) { return z * 0.62 - 34 + Math.sin(z * 0.019) * 26
                                          + Math.sin(z * 0.0071 + 2.0) * 44; }
```
```gdscript
static func wadi_x(z: float) -> float:
	return z * 0.62 - 34.0 + sin(z * 0.019) * 26.0 + sin(z * 0.0071 + 2.0) * 44.0
```

### 4.3 `MESAS`
```js
const MESAS = [
  { x:  300, z:  -40, r: 118, h: 46, s: 0.62 },
  { x:  258, z:  168, r:  74, h: 33, s: 0.55 },
  { x:  348, z:  210, r:  88, h: 40, s: 0.60 },
  { x: -286, z: -238, r:  62, h: 27, s: 0.50 },
  { x:  214, z: -282, r:  70, h: 31, s: 0.55 },
];
```
`r` = radius, `h` = height added at the plateau, `s` = normalised radius at which
the plateau starts falling off.

### 4.4 `terrainH(x, z)` — the authoritative height function
```js
function terrainH(x, z) {
  const d = Math.hypot(x, z);
  const detail = 1 - smoothstep(170, 400, d);
  let h = fbm2(x * 0.0032 + 11, z * 0.0032 - 7, 4) * 26 - 9;
  h += fbm2(x * 0.011 - 3, z * 0.011 + 5, 3) * 5.5 * (0.25 + 0.75 * detail);

  const duneMask = smoothstep(MAP.townR - 6, MAP.townR + 150, d) *
                   (0.45 + 0.55 * smoothstep(-40, -300, z * 0.8 + x * 0.3));
  const dn = ridged(x * 0.0072 + 31, z * 0.0043 - 17, 4);
  h += dn * dn * 30 * duneMask;
  h += ridged(x * 0.021, z * 0.013 + 9, 2) * 2.4 * duneMask * detail;

  for (const m of MESAS) {
    const md = Math.hypot(x - m.x, z - m.z) / m.r;
    const wob = 1 + (fbm2(x * 0.02 + m.x, z * 0.02 - m.z, 3) - 0.5) * 0.30 * (0.2 + 0.8 * detail);
    const t = 1 - smoothstep(m.s * wob, 1.0 * wob, md);
    h += m.h * Math.pow(t, 0.55);
  }

  const pan = 1 - smoothstep(MAP.townR * 0.52, MAP.townR * 1.34, d);
  h = lerp(h, MAP.pan + fbm2(x * 0.03, z * 0.03, 2) * 1.5 - 0.75, pan * 0.985);

  const wd = Math.abs(x - wadiX(z));
  const bank = 1 - smoothstep(9, 32, wd);
  const floorCut = 5.2 * bank * bank * (0.65 + 0.35 * smoothstep(0, 40, Math.abs(z)));
  h -= floorCut;
  if (wd < 11) h += (fbm2(x * 0.09, z * 0.09, 2) - 0.5) * 0.6;

  const roadT = 1 - smoothstep(6.5, 13, Math.abs(x + 8 + Math.sin(z * 0.008) * 18));
  if (z < -60) h = lerp(h, h * 0.55 + 1.2, roadT * smoothstep(-60, -110, z) * 0.9);

  return h;
}
```

Derived constants used above, spelled out: `MAP.townR - 6 = 126`,
`MAP.townR + 150 = 282`, `MAP.townR * 0.52 = 68.64`, `MAP.townR * 1.34 = 176.88`.

Term-by-term:
* **detail fade** `1 - smoothstep(170, 400, d)` — kills high-frequency terms where
  the render grid coarsens past ~20 m cells (see §7.1). Without it the far mesh
  aliases into a diamond hatch.
* **base** fbm at 0.0032 scale × 26, offset −9; plus fbm at 0.011 × 5.5 faded.
* **dunes** ridged² × 30, masked to outside the town and biased south+west via
  `smoothstep(-40, -300, z*0.8 + x*0.3)` (descending edges → mask rises as
  `z*0.8 + x*0.3` goes negative). Plus a fine ridged term × 2.4.
* **mesas** additive `m.h * pow(t, 0.55)` with a per-mesa fbm wobble on the radius.
* **pan** flattens the town: lerps toward `0 + fbm2(x*0.03, z*0.03, 2)*1.5 - 0.75`
  with weight `pan * 0.985` — the 0.985 leaves 1.5 % of the wild terrain so the pan
  is not perfectly dead flat.
* **wadi** subtracts up to 5.2 m, squared bank falloff, deepening with |z| via
  `0.65 + 0.35*smoothstep(0, 40, |z|)`; a ±0.3 m gravel jitter inside `wd < 11`.
* **rim road** north of `z = -60` only: flattens toward `h*0.55 + 1.2` inside a
  13 m half-width band centred on `x = -8 - sin(z*0.008)*18`.

**GOTCHA:** `Math.abs(x + 8 + Math.sin(z*0.008)*18)` — the band centre is
`x = -8 - sin(z*0.008)*18`, NOT `-8 + …`. The exfil `NORTH GATE` is placed at
`-8 + Math.sin(nz*0.008)*18` (opposite sign) — see §17.2; that is a reference
inconsistency, keep it or the exfil moves off the shelf.

### 4.5 `terrainN`
```js
function terrainN(x, z, e = 0.9) {
  const hL = terrainH(x - e, z), hR = terrainH(x + e, z);
  const hD = terrainH(x, z - e), hU = terrainH(x, z + e);
  return new THREE.Vector3(hL - hR, 2 * e, hD - hU).normalize();
}
```
Epsilon **0.9 m**. Declared but never called at runtime — `groundNormal` (§7.4) is
what the player uses. Port it only if the bake needs it.

---

## 5. Surface ids

```js
const S = { METAL: 0, WOOD: 1, POLY: 2, SAND: 3, CONCRETE: 4,
            TIN: 5, CLOTH: 6, ASPHALT: 7, ROCK: 8 };
const SURF_NAME = ['metal','wood','poly','sand','concrete','tin','cloth','asphalt','rock'];
```
The integer is simultaneously (a) the per-vertex `aType` attribute that selects the
fragment-shader branch, (b) the collider's `surf` field, and (c) the footstep
synth key. Keep the numbering.

```gdscript
enum Surf { METAL = 0, WOOD = 1, POLY = 2, SAND = 3, CONCRETE = 4,
	TIN = 5, CLOTH = 6, ASPHALT = 7, ROCK = 8 }
const SURF_NAME: PackedStringArray = ["metal", "wood", "poly", "sand",
	"concrete", "tin", "cloth", "asphalt", "rock"]
```

---

## 6. Palette

```js
const PAL = {
  sand:     [0x9a8163, 0xa88d6b, 0x8d7458, 0xb09a7a, 0x877051],
  adobe:    [0x9a8468, 0xa89076, 0x8b7357, 0xb2997c, 0x7e6a52, 0xa2764c,
             0x6f6a60, 0x8f8778, 0xb6ac96, 0x7d8378, 0x94694a, 0x6a5f4f],
  concrete: [0x6f6c66, 0x7a7770, 0x63605b, 0x84817a],
  rust:     [0x6b4028, 0x7a4a2c, 0x5a3522, 0x8a5230],
  tin:      [0x6a6560, 0x776f66, 0x5c574f],
  wood:     [0x6b4423, 0x7a5230, 0x5c3f26, 0x8a5a2b],
  metal:    [0x4a4c50, 0x3f4247, 0x5a5049, 0x43464a],
  cloth:    [0x8f7a52, 0xa03636, 0x5f6448, 0x9a7d4a, 0x6a6d73],
  rock:     [0x7d6a55, 0x8b7862, 0x6c5b49, 0x94806a],
  asphalt:  [0x3a3835, 0x434140, 0x312f2d],
};
```
`PAL.sand` and `PAL.rust` are never read by the world build (terrain colour is
computed directly in `buildTerrain`, §7.5). All values are **sRGB hex**.

Terrain-only colours (also sRGB hex):
`sandLo 0x7f6a4e`, `sandHi 0xb5a082`, `rockLo 0x6c5b49`, `rockHi 0x998672`,
`gravel 0x8a8071`.

Sky / fog: `SKY_LOW = 0xc7ab86`, `SKY_HI = 0x6f88a8`, `HAZE = 0xb49a78`.
(`SKY_LOW`/`SKY_HI` are declared and never used — the sky shader in §21 hard-codes
its own linear triple. `HAZE` is used for both `scene.fog` and `scene.background`.)

Hard-coded one-off colours that appear in generators (all sRGB hex):
`0x5a5049` ladder rails · `0x5c4a36` default door/window trim · `0x63605b` slab grey ·
`0x4a4c50` steel rail/post · `0x5c584f` catwalk / platform deck · `0x5c3f26` post timber ·
`0x4d3323` dead branch · `0x2b2d30` tyre · `0x2f3134` power wire · `0x63656a` vent block /
crash wing · `0x6a6544` olive drum · `0x5f6448` green drum · `0x7a4a2c` rust drum ·
`0x5b4838` hauler brown · `0x8f7a52` sandbag · `0x6a6d73` crash fuselage ·
`0xd8822f` exfil orange · `0x2a2724` viewmodel tint mix target.

Container colours: `[0x7a4a2c, 0x5f6448, 0x4a4d52, 0x6a6544, 0x5b4838, 0x6b4028]`.

---

## 7. Terrain mesh, `groundH`, `groundNormal`

### 7.1 The warped axis
```js
const TN = 200, TW = 880, TA = 0.42;
const AX = new Float32Array(TN + 1);
for (let i = 0; i <= TN; i++) {
  const u = i / TN * 2 - 1, s = Math.sign(u) || 1, a = Math.abs(u);
  AX[i] = TW * (TA * u + (1 - TA) * s * Math.pow(a, 5));
}
const HG = new Float32Array((TN + 1) * (TN + 1));
for (let j = 0; j <= TN; j++) for (let i = 0; i <= TN; i++)
  HG[j * (TN + 1) + i] = terrainH(AX[i], AX[j]);
```
201×201 = **40401** vertices, 200×200×2 = **80000** triangles.
`AX` spans `[-880, +880]`. The same array warps both X and Z (the grid is
symmetric). Cell size: ≈**3.70 m** at the centre, ≈**29.2 m** at the rim
(d/du = `TW*(TA + 5*(1-TA)*u^4)`, du = 0.01).

`Math.sign(0) === 0`, hence the `|| 1`; at `u = 0` the result is 0 either way.
GDScript `sign(0.0)` also returns `0.0` — keep the `if s == 0.0: s = 1.0` guard for
literal fidelity.

### 7.2 `axIndex` — binary search
```js
function axIndex(v) {
  if (v <= AX[0]) return 0; if (v >= AX[TN]) return TN - 1;
  let lo = 0, hi = TN;
  while (hi - lo > 1) { const m = (lo + hi) >> 1; if (AX[m] <= v) lo = m; else hi = m; }
  return lo;
}
```

### 7.3 `groundH`
```js
function groundH(x, z) {
  if (x <= AX[0] || x >= AX[TN] || z <= AX[0] || z >= AX[TN]) return terrainH(x, z);
  const i = axIndex(x), j = axIndex(z);
  const x0 = AX[i], x1 = AX[i + 1], z0 = AX[j], z1 = AX[j + 1];
  const s = (x - x0) / (x1 - x0), t = (z - z0) / (z1 - z0);
  const W = TN + 1;
  const h00 = HG[j*W + i], h10 = HG[j*W + i+1], h01 = HG[(j+1)*W + i], h11 = HG[(j+1)*W + i+1];
  if (s + t <= 1) return h00 + (h10 - h00) * s + (h01 - h00) * t;
  return h11 + (h01 - h11) * (1 - s) + (h10 - h11) * (1 - t);
}
```

**GOTCHA — `groundH` and the rendered mesh disagree on the quad diagonal.**
`buildTerrain` emits `triV(a,d,c)` and `triV(a,c,b)` where
`a=(i,j) b=(i+1,j) c=(i+1,j+1) d=(i,j+1)`, i.e. the shared edge is **a–c**
(`t = s`). `groundH` splits on `s + t <= 1`, i.e. the **b–d** diagonal. The comment
above the code even claims the a–c split. The player therefore floats/sinks by up
to the quad's non-planarity — negligible on 3.7 m town cells, up to ~1 m on the
29 m rim cells. **Fix it in the port** (the whole purpose of `groundH` is exactness):

```gdscript
## Exact height on the rendered terrain surface. The quad (i,j)..(i+1,j+1) is
## split along its a-c diagonal, matching the two triangles the mesher emits.
func ground_h(x: float, z: float) -> float:
	if x <= AX[0] or x >= AX[TN] or z <= AX[0] or z >= AX[TN]:
		return terrain_h(x, z)
	var i: int = ax_index(x)
	var j: int = ax_index(z)
	var s: float = (x - AX[i]) / (AX[i + 1] - AX[i])
	var t: float = (z - AX[j]) / (AX[j + 1] - AX[j])
	var w: int = TN + 1
	var h00: float = HG[j * w + i]
	var h10: float = HG[j * w + i + 1]
	var h01: float = HG[(j + 1) * w + i]
	var h11: float = HG[(j + 1) * w + i + 1]
	if t >= s:                      # triangle a-d-c
		return h00 + (h01 - h00) * t + (h11 - h01) * s
	return h00 + (h10 - h00) * s + (h11 - h10) * t   # triangle a-c-b
```

### 7.4 `groundNormal`
```js
function groundNormal(x, z, e = 1.2) {
  const hL = groundH(x - e, z), hR = groundH(x + e, z),
        hD = groundH(x, z - e), hU = groundH(x, z + e);
  return new THREE.Vector3(hL - hR, 2 * e, hD - hU).normalize();
}
```
Epsilon **1.2 m**. Returns `Vector3(hL-hR, 2.4, hD-hU).normalized()`. Used by the
movement controller for slope projection and slide acceleration, and by
`scatterWilds` to reject dune faces.

### 7.5 `buildTerrain` — per-vertex colour, road amount, rock mask
```js
const VC = new Float32Array(W*W*3);   // linear rgb
const VR = new Float32Array(W*W);     // road blend 0..1 -> aBlend
const VK = new Float32Array(W*W);     // rock mask 0..1

for (let j = 0; j < W; j++) for (let i = 0; i < W; i++) {
  const k = j*W + i, x = AX[i], z = AX[j], h = HG[k];
  const iL = Math.max(0, i-1), iR = Math.min(TN, i+1);
  const jD = Math.max(0, j-1), jU = Math.min(TN, j+1);
  const gx = (HG[j*W+iR] - HG[j*W+iL]) / Math.max(AX[iR] - AX[iL], 1e-3);
  const gz = (HG[jU*W+i] - HG[jD*W+i]) / Math.max(AX[jU] - AX[jD], 1e-3);
  const slope = Math.hypot(gx, gz);
  const rk = clamp(smoothstep(0.50, 0.95, slope) + smoothstep(13, 24, h) * 0.8, 0, 1);
  VK[k] = rk;
  const tone = fbm2(x*0.0045 + 3, z*0.0045 - 8, 3);
  tmp.copy(sandLo).lerp(sandHi, clamp((tone - 0.30) * 2.1, 0, 1));
  tmp2.copy(rockLo).lerp(rockHi, clamp((fbm2(x*0.012 + 21, z*0.012, 2) - 0.32) * 2.4, 0, 1));
  tmp.lerp(tmp2, rk);
  const wd = Math.abs(x - wadiX(z));
  if (wd < 16 && h < 6) tmp.lerp(gravel, (1 - smoothstep(7, 15, wd)) * 0.8);
  const jit = 1 + (fbm2(x*0.085 + 11, z*0.085 - 5, 2) - 0.5) * 0.30
                + (vnoise2(x*0.32 + 7, z*0.32 - 3) - 0.5) * 0.10;
  tmp.multiplyScalar(clamp(jit, 0.65, 1.35));
  tmp.convertSRGBToLinear();
  VC[k*3] = tmp.r; VC[k*3+1] = tmp.g; VC[k*3+2] = tmp.b;
  VR[k] = (Math.abs(x) < 175 && Math.abs(z) < 210 && rk < 0.5) ? roadAt(x, z) : 0;
}
```
All colour lerps happen in **sRGB space**, then `convertSRGBToLinear()` at the end.
In Godot: build the `Color` from sRGB components, lerp there, then
`.srgb_to_linear()` before writing to the vertex-colour array (Godot's
`BaseMaterial3D`/shader treats vertex colour as linear unless
`vertex_color_is_srgb` is set).

Triangle emission:
```js
for (let j = 0; j < TN; j++) for (let i = 0; i < TN; i++) {
  const ka = j*W+i, kb = j*W+i+1, kc = (j+1)*W+i+1, kd = (j+1)*W+i;
  const a = [AX[i],   HG[ka], AX[j]  ], b = [AX[i+1], HG[kb], AX[j]  ];
  const c = [AX[i+1], HG[kc], AX[j+1]], d = [AX[i],   HG[kd], AX[j+1]];
  const type = (VK[ka] + VK[kb] + VK[kc] + VK[kd]) > 2.0 ? S.ROCK : S.SAND;
  M.triV(a, d, c, ca, cd, cc, VR[ka], VR[kd], VR[kc], type);
  M.triV(a, c, b, ca, cc, cb, VR[ka], VR[kc], VR[kb], type);
}
```
Type is **per-quad**, colour and road-blend are **per-vertex**. Winding a-d-c /
a-c-b gives an upward face normal (verified: cross of (d-a)×(c-a) has +Y).

The terrain mesh is `receiveShadow = true, castShadow = false`.
Godot: `GeometryInstance3D.cast_shadow = SHADOW_CASTING_SETTING_OFF`.

---

## 8. Scene / renderer / lighting

```js
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.outputEncoding = THREE.sRGBEncoding;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

scene.fog = new THREE.FogExp2(HAZE /*0xb49a78*/, 0.0024);
scene.background = new THREE.Color(HAZE);

const camera = new THREE.PerspectiveCamera(78, 1, 0.06, 1400);
const gunCam = new THREE.PerspectiveCamera(52, 1, 0.006, 6);

const hemi    = new THREE.HemisphereLight(0x93a7bd, 0x3b2b1c, 0.30);
const sun     = new THREE.DirectionalLight(0xffeeda, 1.05);
const SUN_DIR = new THREE.Vector3(-0.52, 0.60, -0.61).normalize();
sun.position.copy(SUN_DIR).multiplyScalar(120);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.camera.near = 1;  sun.shadow.camera.far = 320;
sun.shadow.camera.left = -62; sun.shadow.camera.right = 62;
sun.shadow.camera.top  =  62; sun.shadow.camera.bottom = -62;
sun.shadow.bias = -0.0011; sun.shadow.normalBias = 0.045;
const bounce  = new THREE.DirectionalLight(0xc79a68, 0.18); bounce.position.set(0.3, -1, 0.2);
const skyFill = new THREE.DirectionalLight(0x7d96c4, 0.15); skyFill.position.set(0.6, 0.5, 0.8);
```

`SUN_DIR` normalised: `(-0.52, 0.60, -0.61)` / `|·| = 1.00224…` →
**(-0.518838, 0.598660, -0.608604)**. A Godot `DirectionalLight3D` points along its
local −Z, so set `look_at_from_position(SUN_DIR * 120, Vector3.ZERO, Vector3.UP)`
or `basis = Basis.looking_at(-SUN_DIR)`.

Per-frame the sun rig follows the player so the 124 m shadow box stays tight:
```js
sun.position.set(P.x + SUN_DIR.x * 110, P.y + SUN_DIR.y * 110, P.z + SUN_DIR.z * 110);
sun.target.position.set(P.x, P.y, P.z);
```

### 8.1 GOTCHAS on the render setup

**Fog formula differs.** three.js `FogExp2` is
`factor = 1 - exp(-(density * depth)^2)`. Godot's `Environment` exponential fog is
`1 - exp(-depth * density)` — squared vs linear in depth. Density 0.0024 in
three.js gives 5.6 % fog at 100 m and 60 % at 400 m; Godot with the same number
gives 21 % at 100 m. Either drive Godot's `fog_depth_*` depth-fog with
`fog_depth_curve = 2.0` (Godot depth fog raises the normalised depth to
`fog_depth_curve`), or write the exact term in a custom sky/fog shader:
```glsl
float fogf = 1.0 - exp(-0.0024 * 0.0024 * depth * depth);
```

**Two cameras, two passes.** The world camera is 78° / near 0.06 / far 1400; the
viewmodel camera is 52° / near 0.006 / far 6, rendered into a **cleared depth
buffer** after the world (`renderer.autoClear = false; renderer.clearDepth();`).
Godot renders one camera per viewport — implement the viewmodel as a `SubViewport`
with its own `Camera3D` composited over the main view, or put the viewmodel on a
separate `VisualInstance3D` layer with a dedicated near-plane camera in a second
viewport. Do not try to squeeze a 0.006 near plane into the main camera.

**FOV axis.** three.js `PerspectiveCamera.fov` is the **vertical** FOV in degrees.
Godot `Camera3D.fov` is vertical **only when `keep_aspect == KEEP_HEIGHT`** (the
default). Leave `keep_aspect` alone and 78 / 52 port 1:1.

**Tone mapping.** three.js `ACESFilmicToneMapping` is the Narkowicz fit; Godot's
`TONE_MAPPER_ACES` is a different approximation. Expect a small shift in the
highlights; match by eye against the reference rather than assuming parity.

### 8.2 Environment probe
A 256×128 canvas is drawn and used as an equirect PMREM:
```
vertical gradient stops: 0.00 #5d7ea8 · 0.34 #93a7bd · 0.49 #d9c09a
                         0.52 #a08862 · 0.72 #7a6446 · 1.00 #4a3c2a
radial 1 at (178,30) r 2→56 : rgba(255,244,220,1) → rgba(255,244,220,0)   (sun)
radial 2 at ( 70,62) r 2→90 : rgba(255,170,95,.42) → rgba(255,170,95,0)   (bounce)
```
In Godot: a `PanoramaSkyMaterial` fed a baked 256×128 texture built by the bake
script, or a `ProceduralSkyMaterial` tuned to these stops. `envMapIntensity` on
the world material is **0.32**.

---

## 9. The world material — procedural surface shader

One `MeshStandardMaterial` covers every static surface in the map (terrain + town),
with `aType` (surface id) and `aBlend` (road amount) as per-vertex attributes so the
whole town is one draw call.

```js
function worldMaterial() {
  const m = new THREE.MeshStandardMaterial({
    vertexColors: true, flatShading: true, metalness: 0.0, roughness: 0.9,
    envMapIntensity: 0.32, dithering: true,
  });
  return injectSurface(m, { attrType: true, seed: 0.37 });
}
```
Base: `metalness 0.0`, `roughness 0.9`, `envMapIntensity 0.32`, uSeed **0.37**.

`injectSurface(m, {attrType, type, seed})` splices three GLSL chunks in:
* vertex, after `<common>`: `varying vec3 vOP; varying vec3 vON;` plus, when
  `attrType`, `attribute float aType; attribute float aBlend; varying float vTypeF; varying float vBlend;`
* vertex, after `<begin_vertex>`: `vOP=position; vON=normalize(normal); vTypeF=aType; vBlend=aBlend;`
* fragment, after `<common>`: `GLSL_NOISE`
* fragment, after `<metalnessmap_fragment>`: `GLSL_DETAIL`
* fragment, after `<normal_fragment_maps>`: `GLSL_BUMP`

The non-`attrType` path (`uniform float uType`, `vBlend` forced to 0.0) is used only
by the gun viewmodel materials.

### 9.1 Godot mapping table

| three.js | Godot spatial shader |
|---|---|
| `vOP` (object-space position) | `varying vec3 v_op;` set in `vertex()` from `VERTEX` |
| `vON` (object-space normal) | `varying vec3 v_on;` set in `vertex()` from `NORMAL` |
| `attribute float aType` | `CUSTOM0.x` (`ARRAY_CUSTOM0`, format `ARRAY_CUSTOM_RGBA_FLOAT`); declare its varying **`flat`** |
| `attribute float aBlend` | `CUSTOM0.y`, smooth varying |
| `diffuseColor.rgb` | `ALBEDO` |
| `roughnessFactor` | `ROUGHNESS` |
| `metalnessFactor` | `METALLIC` |
| `normal` inside `<normal_fragment_maps>` (view space) | `NORMAL` inside `fragment()` |
| `-vViewPosition` (view-space frag position) | `VERTEX` inside `fragment()` |
| `uSeed` | `uniform float u_seed = 0.37;` |
| vertex colour | `COLOR` — already linear, do **not** set `vertex_color_is_srgb` |

`fwidth`, `dFdx`, `dFdy` all exist in Godot 4's shading language. `flatShading: true`
is redundant here: the Mesher already writes per-face normals.

### 9.2 `GLSL_NOISE` — verbatim

    varying vec3 vOP; varying vec3 vON;
    uniform float uSeed;
    #ifdef ATTR_TYPE
      varying float vTypeF; varying float vBlend;
      #define TYPE vTypeF
    #else
      uniform float uType;
      #define TYPE uType
      #define vBlend 0.0
    #endif
    float h31(vec3 p){ p=fract(p*0.1031+uSeed*0.137); p+=dot(p,p.yzx+33.33); return fract((p.x+p.y)*p.z); }
    float vn(vec3 x){ vec3 i=floor(x), f=fract(x); f=f*f*(3.0-2.0*f);
      return mix(mix(mix(h31(i),h31(i+vec3(1,0,0)),f.x),mix(h31(i+vec3(0,1,0)),h31(i+vec3(1,1,0)),f.x),f.y),
                 mix(mix(h31(i+vec3(0,0,1)),h31(i+vec3(1,0,1)),f.x),mix(h31(i+vec3(0,1,1)),h31(i+vec3(1,1,1)),f.x),f.y),f.z); }
    float fbmA(vec3 p){ float a=0.5,s=0.0; for(int i=0;i<4;i++){ s+=a*vn(p); p*=2.07; a*=0.5; } return s; }
    float fbmB(vec3 p){ float a=0.55,s=0.0; for(int i=0;i<3;i++){ s+=a*vn(p); p*=2.11; a*=0.5; } return s; }
    float nA(vec3 p){ return clamp((fbmA(p)-0.469)*1.95+0.5,0.0,1.0); }
    float nB(vec3 p){ return clamp((fbmB(p)-0.481)*1.75+0.5,0.0,1.0); }

`fbmA`: 4 octaves, start amplitude **0.5**, lacunarity **2.07**, gain 0.5, **not**
normalised (max ≈ 0.9375). `fbmB`: 3 octaves, start **0.55**, lacunarity **2.11**.
`nA`/`nB` contrast-stretch around the empirical means **0.469** / **0.481** by gains
**1.95** / **1.75** — the raw fbm clusters so tightly around its mean that every
effect built on it is otherwise a 5 % invisible wobble.

### 9.3 `GLSL_DETAIL` — verbatim

Inserted after `<metalnessmap_fragment>`, where `diffuseColor`, `roughnessFactor`
and `metalnessFactor` already exist.

    {
    vec3 P=vOP; vec3 N=normalize(vON); float T=TYPE;
    float px=length(fwidth(P));
    #define FD(f) (1.0-smoothstep(0.22,0.95,px*(f)))
    #define NA(f,o) mix(0.5, nA(P*(f)+(o)), FD((f)*9.0))
    #define NB(f,o) mix(0.5, nB(P*(f)+(o)), FD((f)*4.4))
    float fade=FD(6.0);
    if(T<0.5){
      /* --- steel: rust blooms downward, scratches along the length --- */
      float g=mix(0.5,fbmA(P*3.0),FD(27.0));
      float rust=smoothstep(0.54,0.84,mix(0.469,fbmA(P*1.7+7.3),FD(15.0)));
      rust*=smoothstep(0.05,0.95,0.62-N.y*0.40);
      float scr=smoothstep(0.74,0.96,fbmA(P*vec3(1.2,9.0,9.0)+2.0))*fade;
      float pit=smoothstep(0.80,1.00,fbmA(P*6.5))*fade;
      diffuseColor.rgb*=(0.86+0.28*g);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.150,0.056,0.022)*(0.62+0.95*g),rust*0.62);
      diffuseColor.rgb+=scr*0.055*(1.0-rust);
      roughnessFactor=clamp(0.50+rust*0.40+pit*0.10-scr*0.10+(g-0.5)*0.12,0.10,1.0);
      metalnessFactor=clamp(0.72*(1.0-rust*0.80),0.0,1.0);
    }else if(T<1.5){
      /* --- timber: ring grain along X, wear on the exposed faces --- */
      float g=mix(0.5,fbmA(P*3.0),FD(27.0));
      float ring=fbmA(P*vec3(0.9,4.0,4.0));
      float grain=pow(sin((P.x*2.0+ring*2.6)*7.0)*0.5+0.5,1.6);
      float blotch=mix(0.469,fbmA(P*2.2+11.0),FD(20.0));
      diffuseColor.rgb*=mix(0.70,1.16,mix(0.5,grain,fade)*0.66+0.34*blotch);
      float wear=smoothstep(0.62,0.95,mix(0.469,fbmA(P*3.2+21.0),FD(29.0)));
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(0.76,0.72,0.68),wear*0.45);
      roughnessFactor=clamp(0.86-grain*0.12*fade+wear*0.06,0.34,1.0);
      metalnessFactor=0.02;
    }else if(T<2.5){
      /* --- polymer --- */
      float sp=mix(0.469,fbmA(P*7.0),FD(63.0));
      float scuff=smoothstep(0.70,0.96,fbmA(P*vec3(1.6,7.0,7.0)+5.0))*fade;
      diffuseColor.rgb*=(0.92+0.16*sp);
      diffuseColor.rgb+=scuff*0.035;
      roughnessFactor=clamp(0.84+(sp-0.5)*0.14-scuff*0.10,0.34,1.0);
      metalnessFactor=0.03;
    }else if(T<3.5){
      /* --- sand: drift, grit, wind ripple; road blended in via vBlend --- */
      float coarse=NB(0.075,0.0);
      float drift=NB(0.021,13.0);
      float grit=NA(2.6,0.0);
      float slope=1.0-clamp(N.y,0.0,1.0);
      float ripDir=NB(0.006,41.0);
      float rip=sin((P.x*0.44+P.z*0.30)*mix(0.7,1.5,ripDir)+nA(P*0.055)*9.0)*0.5+0.5;
      rip=pow(rip,2.6)*FD(4.0)*(1.0-smoothstep(0.12,0.34,slope));
      vec3 dark=vec3(0.129,0.098,0.070);
      diffuseColor.rgb*=(0.68+0.60*coarse)*(0.84+0.34*drift);
      diffuseColor.rgb+=rip*0.060;
      diffuseColor.rgb+=(grit-0.5)*0.085;
      diffuseColor.rgb=mix(diffuseColor.rgb,dark*1.7,smoothstep(0.24,0.66,slope)*0.80);
      float cru=smoothstep(0.50,0.80,NB(0.30,4.0));
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(1.20,1.10,0.93),cru*0.62);
      if(vBlend>0.004){
        float rb=smoothstep(0.10,0.80,vBlend);
        float aggR=NA(7.0,53.0);
        float crack=smoothstep(0.70,0.93,mix(0.5,nA(P*vec3(1.0,1.0,3.4)+6.0),FD(30.0)));
        float wheel=smoothstep(0.42,0.86,NB(0.05,71.0));
        vec3 tar=diffuseColor.rgb*vec3(0.46,0.45,0.44)*(0.78+0.50*aggR);
        tar=mix(tar,vec3(0.055,0.052,0.048),crack*0.70);
        tar=mix(tar,tar*1.75+vec3(0.02,0.017,0.012),wheel*0.42);
        diffuseColor.rgb=mix(diffuseColor.rgb,tar,rb);
        roughnessFactor=mix(roughnessFactor,0.88,rb);
      }
      roughnessFactor=clamp(roughnessFactor-rip*0.05,0.45,1.0);
      metalnessFactor=0.0;
    }else if(T<4.5){
      /* --- adobe / concrete: courses of mud brick under a patched render --- */
      float agg=NA(4.5,0.0);
      float blot=NB(0.34,3.0);
      float panel=smoothstep(0.44,0.60,NB(0.16,29.0));
      float chip=smoothstep(0.58,0.84,NA(1.9,13.0));
      float streak=smoothstep(0.38,0.84,mix(0.5,nA(vec3(P.x*3.0,P.y*0.16,P.z*3.0)+8.0),FD(27.0)));
      streak*=smoothstep(0.0,0.6,1.0-abs(N.y));
      float course=sin(P.y*3.1+nB(P*0.5)*3.4)*0.5+0.5;
      diffuseColor.rgb*=(0.62+0.70*blot)*(0.88+0.24*agg);
      diffuseColor.rgb*=mix(1.0,0.91+0.15*course,0.70*FD(3.1));
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(1.20,1.10,0.95)+vec3(0.04,0.034,0.024),panel*0.62);
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(0.44,0.40,0.38),streak*0.54);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.28,0.19,0.125)*(0.6+0.9*agg),chip*0.74);
      float dust=smoothstep(0.55,0.98,N.y)*smoothstep(0.26,0.68,NB(0.9,0.0));
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.462,0.384,0.278),dust*0.55);
      roughnessFactor=clamp(0.93-chip*0.14+(blot-0.5)*0.10,0.5,1.0);
      metalnessFactor=0.0;
    }else if(T<5.5){
      /* --- corrugated tin: ribs, rust running with gravity --- */
      float rib=sin(P.z*9.4+P.x*0.6)*0.5+0.5;
      float rib2=sin(P.x*9.4+P.z*0.6)*0.5+0.5;
      float ribs=mix(mix(rib,rib2,step(0.5,fract(uSeed*7.0))),0.5,1.0-FD(9.4));
      float rust=smoothstep(0.40,0.80,mix(0.469,fbmA(P*0.9+2.7),FD(8.0)));
      float run=smoothstep(0.45,0.95,mix(0.469,fbmA(vec3(P.x*4.0,P.y*0.35,P.z*4.0)+19.0),FD(36.0)));
      diffuseColor.rgb*=(0.72+0.42*ribs);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.196,0.078,0.031)*(0.7+0.9*rust),clamp(rust*0.78+run*0.30,0.0,0.92));
      roughnessFactor=clamp(0.58+rust*0.38,0.18,1.0);
      metalnessFactor=clamp(0.62*(1.0-rust*0.85),0.0,1.0);
    }else if(T<6.5){
      /* --- cloth / tarp: weave, sun bleach on the up side, dirt in folds --- */
      float weave=(sin(P.x*70.0)*sin(P.z*70.0)*0.5+0.5);
      float fold=mix(0.481,fbmB(P*2.2),FD(10.0));
      float bleach=smoothstep(0.2,1.0,N.y);
      diffuseColor.rgb*=(0.80+0.30*fold)*(0.94+0.12*mix(0.5,weave,FD(70.0)));
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*1.35+vec3(0.05,0.045,0.035),bleach*0.42);
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*0.55,smoothstep(0.62,0.9,1.0-fold)*0.35);
      roughnessFactor=0.97; metalnessFactor=0.0;
    }else if(T<7.5){
      /* --- asphalt: aggregate, cracks, sand drifting back over the top --- */
      float agg=NA(7.0,0.0);
      float crack=smoothstep(0.72,0.94,mix(0.5,nA(P*vec3(1.0,1.0,3.4)+6.0),FD(30.0)));
      float drift=smoothstep(0.34,0.82,NB(0.11,2.0))*smoothstep(0.6,1.0,N.y);
      float worn=smoothstep(0.40,0.86,NB(0.045,17.0));
      diffuseColor.rgb*=(0.74+0.48*agg);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.05,0.045,0.04),crack*0.8);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.545,0.451,0.325),drift*0.62);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.38,0.33,0.27),worn*0.35);
      roughnessFactor=clamp(0.90-agg*0.10,0.5,1.0); metalnessFactor=0.0;
    }else{
      /* --- rock: strata banding by height, wind-polished faces --- */
      float band=sin(P.y*1.35+nA(P*0.30)*5.0)*0.5+0.5;
      float rough=NA(1.4,0.0);
      float pol=smoothstep(0.48,0.88,NB(0.45,9.0));
      diffuseColor.rgb*=(0.70+0.52*rough);
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(1.24,1.09,0.88),band*0.46*FD(1.35));
      diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*0.68,pol*0.38);
      float dust=smoothstep(0.60,1.0,N.y);
      diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.478,0.396,0.286),dust*0.34);
      roughnessFactor=clamp(0.92-pol*0.16,0.45,1.0); metalnessFactor=0.0;
    }
    #undef FD
    #undef NA
    #undef NB
    }

**The mip-fade system is load-bearing, not decoration.**
`px = length(fwidth(vOP))` is the object-space footprint of one pixel.
`FD(f) = 1 - smoothstep(0.22, 0.95, px*f)` collapses a term of base frequency `f`
toward its mean once its finest octave stops fitting inside a pixel. `NA`/`NB` fade
by `f*9.0` and `f*4.4` respectively, because `fbmA` reaches 2.07³ ≈ 8.87× its base
frequency and `fbmB` reaches 2.11² ≈ 4.45×. Remove it and every distant or
edge-on surface becomes salt-and-pepper noise.

Godot 4's shader preprocessor does support function-like `#define`, so `FD/NA/NB`
can be transcribed as-is; if a target backend rejects them, inline them as
`float fd(float px, float f)` etc. Also note **GLSL `smoothstep` is undefined when
`edge0 > edge1`**, and this chunk calls `smoothstep(0.62, 0.9, …)` etc. — all
ascending, so the built-in is safe here. The sky shader (§21.1) is the one that
needs a hand-rolled version.

### 9.4 `GLSL_BUMP` — verbatim

Inserted after `<normal_fragment_maps>`, where `normal` is the view-space shading
normal.

    {
      float T2=TYPE;
      float bsc  = T2<0.5?3.6 : T2<3.5? (T2<2.5?3.0:0.62) : T2<4.5?1.7 : T2<5.5?2.4 : T2<6.5?3.0 : T2<7.5?2.4 : 1.15;
      float bamt = T2<0.5?0.010 : T2<3.5? (T2<2.5?0.008:0.085) : T2<4.5?0.058 : T2<5.5?0.030 : T2<6.5?0.016 : T2<7.5?0.034 : 0.075;
      float bpx  = length(fwidth(vOP))*bsc;
      bamt *= 1.0-smoothstep(0.05,0.45,bpx);
      float hgt  = fbmB(vOP * bsc);
      vec3 dpx = dFdx(-vViewPosition);
      vec3 dpy = dFdy(-vViewPosition);
      float hx = dFdx(hgt);
      float hy = dFdy(hgt);
      vec3 rr1 = cross(dpy, normal);
      vec3 rr2 = cross(normal, dpx);
      float det = dot(dpx, rr1);
      vec3 grad = (hx * rr1 + hy * rr2) / (abs(det) + 0.000001);
      float gl = length(grad);
      grad *= min(1.0, 6.0/(gl+0.0001));
      normal = normalize(normal - bamt * grad);
    }

Per-type bump scale and amount, spelled out (the nested ternary gives WOOD and POLY
the same numbers):

| type | id | `bsc` | `bamt` |
|---|---|---|---|
| METAL | 0 | 3.6 | 0.010 |
| WOOD | 1 | 3.0 | 0.008 |
| POLY | 2 | 3.0 | 0.008 |
| SAND | 3 | 0.62 | 0.085 |
| CONCRETE | 4 | 1.7 | 0.058 |
| TIN | 5 | 2.4 | 0.030 |
| CLOTH | 6 | 3.0 | 0.016 |
| ASPHALT | 7 | 2.4 | 0.034 |
| ROCK | 8 | 1.15 | 0.075 |

In Godot, `-vViewPosition` ≡ `VERTEX` inside `fragment()` and `normal` ≡ `NORMAL`.
This is a screen-space derivative bump (Morten Mikkelsen's method); it needs no
tangents, which is why the Mesher never generates any.

---

## 10. The Mesher

Accumulates un-indexed triangle soup with per-vertex position / normal / colour /
`aType` / `aBlend`. Two instances exist: `W` (the whole town, module-level) and a
local one inside `buildTerrain`.

### 10.1 Yaw convention — ports 1:1 to Godot

Every primitive places local coordinates with
```js
const P = (lx, ly, lz) => [cx + lx * co + lz * s, cy + ly, cz - lx * s + lz * co];
//  s = sin(ry), co = cos(ry)
```
That is exactly the right-handed rotation about +Y by `ry`:
`x' = x·cos + z·sin`, `z' = −x·sin + z·cos`. It is identical to Godot's
`Basis(Vector3.UP, ry)` and to `Node3D.rotation.y = ry`. **No sign flip, no axis
swap.** Godot and three.js are both Y-up, −Z-forward, right-handed.

Local axes of a box with yaw `ry`:
* local **+X** in world = `( cos(ry), 0, −sin(ry) )`
* local **+Z** in world = `( sin(ry), 0,  cos(ry) )`

The inverse (world → local) used by `circleBox`, `overlapsXZ`, `roofAt`, `rayBox`,
`findLadder`:
```
lx =  dx*cos(ry) − dz*sin(ry)
lz =  dx*sin(ry) + dz*cos(ry)
```

### 10.2 Primitives

```js
class Mesher {
  constructor() { this.p=[]; this.n=[]; this.c=[]; this.t=[]; this.m=[]; this.tris=0; }
  _tri(ax,ay,az, bx,by,bz, cx,cy,cz, r,g,b, type)   // flat normal from (b-a)×(c-a)
  triV(a,b,c, ca,cb,cc, ma,mb,mc, type)             // per-vertex colour + blend
  tri(a,b,c, col, type)
  quad(a,b,c,d, col, type)                          // a,b,c,d CCW → _tri(a,b,c) + _tri(a,c,d)
  box(cx,cy,cz, hx,hy,hz, ry, col, type, skip = 0)
  cyl(cx,cy,cz, r0,r1, hy, seg, col, type, ry = 0, cap = true)
  corrug(cx,cy,cz, hx,hz, ribs, amp, col, type, ry = 0, tilt = 0)
  seg(ax,ay,az, bx,by,bz, rad, col, type)           // added on the prototype later
}
```

**`box`** — `hx/hy/hz` are HALF-extents. Face order and skip bitmask:
```js
if (!(skip & 4))  this.quad(e, h, g, f, col, type);  // top    +Y
if (!(skip & 8))  this.quad(a, b, c, d, col, type);  // bottom −Y
if (!(skip & 16)) this.quad(d, c, g, h, col, type);  // +Z
if (!(skip & 32)) this.quad(b, a, e, f, col, type);  // −Z
if (!(skip & 1))  this.quad(c, b, f, g, col, type);  // +X
if (!(skip & 2))  this.quad(a, d, h, e, col, type);  // −X
```
with `a…d` the four bottom corners `(∓hx, −hy, ∓hz)` and `e…h` the four top corners.
**`skip` is never passed a non-zero value anywhere in the world build** — every box
is closed. Do not port the parameter unless you want it.

**`cyl`** — a **Y-axis** cylinder/cone, `seg` sides, `r0` bottom radius, `r1` top
radius, `hy` half-height, caps on by default. The 10th parameter `ry` only rotates
the **starting seam angle**; it does **not** re-orient the cylinder (see §10.5).

**`corrug`** — a corrugated sheet in the XZ plane, ribs along local X, `ribs`
segments alternating ±`amp` in Y, `tilt` adds `lx * tilt` to Y (so the sheet is a
sloped plane). Emitted as a **single-sided, open sheet** — the only open surface in
the entire world build.

**`seg`** — an arbitrary-axis square strut of half-width `rad` from A to B, built
from six quads. Up-vector fallback: `if (|dy| > 0.94) up = (1,0,0)`.

**Winding is verified outward.** The reference ships a self-test:
```js
window.__meshTest = () => { … signed volume of each primitive … }
// box(3,4,5, 1,2,3, 0.4) → 48   (expect 2·4·6 = 48)
// cyl(3,4,5, 1,1, 2, 32)  → 12.566 (expect π·1²·4)
// seg(0,0,0, 0,0,-4, 0.5) → 4    (expect 1·1·4)
```
All positive ⇒ outward winding. **Run the same signed-volume test in the Godot bake
and assert positive.** This is the #1 quality bar from the project contract.

**`build(mat)`** sets attributes `position/normal/color/aType/aBlend`, computes a
bounding sphere, and creates a mesh with
`castShadow = true; receiveShadow = true; frustumCulled = false`.
Godot: `ArrayMesh` with `ARRAY_VERTEX/NORMAL/COLOR/CUSTOM0`,
`MeshInstance3D.extra_cull_margin` large (or `custom_aabb`) to mimic
`frustumCulled = false`; terrain overrides to `cast_shadow = OFF`.

### 10.3 Colour helpers

```js
function C3(hex) {                       // cached, returns LINEAR [r,g,b]
  let v = C3CACHE.get(hex);
  if (!v) { _ctmp.setHex(hex).convertSRGBToLinear(); v = [_ctmp.r,_ctmp.g,_ctmp.b]; C3CACHE.set(hex,v); }
  return v;
}
function vary(hex, r, amt = 0.09) {      // consumes exactly 3 rng draws
  const f = 1 + (r() - 0.5) * 2 * amt;
  const c = new THREE.Color(hex);        // sRGB components, three r128 does not manage colour
  c.r = clamp(c.r * f, 0, 1);
  c.g = clamp(c.g * f * (1 + (r() - 0.5) * amt * 0.4), 0, 1);
  c.b = clamp(c.b * f * (1 + (r() - 0.5) * amt * 0.6), 0, 1);
  return c.getHex();
}
```
`vary` works in **sRGB** and returns a hex; `C3` converts to **linear** at emit
time. Draw order is r → g → b — three draws, always, even when `amt` is small.

```gdscript
## Randomised shade of a base sRGB colour. Consumes exactly three rng draws,
## in r/g/b order — the town layout's determinism depends on that count.
static func vary(hex: int, r: XorShift32, amt: float = 0.09) -> int:
	var c: Color = Color.hex(hex | 0xFF000000)   # sRGB components, no conversion
	var f: float = 1.0 + (r.next() - 0.5) * 2.0 * amt
	var cr: float = clampf(c.r * f, 0.0, 1.0)
	var cg: float = clampf(c.g * f * (1.0 + (r.next() - 0.5) * amt * 0.4), 0.0, 1.0)
	var cb: float = clampf(c.b * f * (1.0 + (r.next() - 0.5) * amt * 0.6), 0.0, 1.0)
	return (int(round(cr * 255.0)) << 16) | (int(round(cg * 255.0)) << 8) | int(round(cb * 255.0))
```
`THREE.Color.getHex()` rounds each channel with `Math.round(c * 255)`. Match it or
the palette drifts.

### 10.4 `solid` vs `deco`

```js
function solid(cx,cy,cz, hx,hy,hz, ry, col, type, surf, skip) {
  W.box(cx,cy,cz, hx,hy,hz, ry, col, type, skip || 0);
  addCol(cx,cy,cz, hx,hy,hz, ry, surf === undefined ? type : surf);
}
function deco(cx,cy,cz, hx,hy,hz, ry, col, type, skip) {
  W.box(cx,cy,cz, hx,hy,hz, ry, col, type, skip || 0);
}
```
`solid` = geometry + collider. `deco` = geometry only. Everything drawn with
`W.box`/`W.cyl`/`W.seg`/`W.corrug` directly is non-colliding unless an explicit
`addCol` follows.

### 10.5 Reference defects in the primitives — decide before porting

1. **`Mesher.cyl` cannot lie on its side.** Its 10th argument `ry` is a seam
   rotation, not an orientation. Consequences:
   * `barrel()` "tipped" drums (`chance 0.18`) draw as an upright cylinder but add a
     lying-down collider `addCol(x, y+rad, z, h, rad, rad, r()*3, S.METAL)`.
   * `wreck()` wheels draw as short upright drums (r 0.36, half-height 0.15) but add
     a sideways collider `addCol(px, axleY, pz, 0.16, wheelR, wheelR, ry, S.POLY)`.
   * `plaza` hauler wheels: same mismatch.
   **Recommendation:** give the Godot mesher a real axis parameter, orient the
   visual to match the collider, and note it in the bake log.
2. **`corrug` is an open single-sided sheet** (the warehouse gable roof). Under
   backface culling it vanishes from below. Give it thickness in the bake.
3. **`G.roofs` and `G.tall` are written and never read.** Do not port them.
4. **`bAdobe` computes `const [wx, wz] = L(wu, wv)` and never uses it.** Dead.

---

## 11. Collision — the oriented-box grid

The world has **no physics engine**. Everything collides against a flat array of
yaw-rotated boxes indexed by a 2-D spatial hash. Reproduce this exactly in
GDScript rather than reaching for Jolt bodies: it is one array walk per frame, it
is deterministic, and the movement code below depends on its precise semantics.

### 11.1 Storage
```js
const COL = [];                  // { x,y,z, hx,hy,hz, co,si, surf, ax,az,ay, stamp }
const CELL = 9;                  // metres
const GRID = new Map();          // hashed cell key -> array of indices into COL
const gkey = (i, j) => i * 73856093 ^ j * 19349663;
```
`gkey` is the classic Teschner hash. **GOTCHA:** in JS `^` coerces to int32, so the
key wraps to a signed 32-bit value. In GDScript, mask it:
```gdscript
static func gkey(i: int, j: int) -> int:
	return ((i * 73856093) ^ (j * 19349663)) & 0xFFFFFFFF
```
Any consistent injective-enough key works — only bucket membership matters — but
use a `Dictionary[int, PackedInt32Array]` and keep the cell size at **9 m**.

### 11.2 `addCol`
```js
function addCol(cx, cy, cz, hx, hy, hz, ry, surf) {
  const c = { x:cx, y:cy, z:cz, hx, hy, hz,
              co: Math.cos(ry || 0), si: Math.sin(ry || 0), surf: surf | 0 };
  const idx = COL.length; COL.push(c);
  const ax = Math.abs(c.co) * hx + Math.abs(c.si) * hz;   // conservative AABB
  const az = Math.abs(c.si) * hx + Math.abs(c.co) * hz;
  c.ax = ax; c.az = az; c.ay = hy;
  const i0 = Math.floor((cx - ax) / CELL), i1 = Math.floor((cx + ax) / CELL);
  const j0 = Math.floor((cz - az) / CELL), j1 = Math.floor((cz + az) / CELL);
  for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
    const k = gkey(i, j); let a = GRID.get(k); if (!a) GRID.set(k, a = []); a.push(idx);
  }
  return c;
}
```
`Math.floor` on negatives rounds **down** (−0.3 → −1). GDScript `floori()` does the
same; `int()` truncates toward zero and would be wrong.

### 11.3 `queryCols` — stamped de-duplication
```js
let STAMP = 0;
function queryCols(x, z, r, out) {
  out.length = 0; STAMP++;
  const i0 = Math.floor((x-r)/CELL), i1 = Math.floor((x+r)/CELL);
  const j0 = Math.floor((z-r)/CELL), j1 = Math.floor((z+r)/CELL);
  for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
    const a = GRID.get(gkey(i, j)); if (!a) continue;
    for (let n = 0; n < a.length; n++) {
      const c = COL[a[n]]; if (c.stamp === STAMP) continue; c.stamp = STAMP; out.push(c);
    }
  }
  return out;
}
```
A monotonically increasing `STAMP` per query avoids clearing a visited set. The
`out` array is a single module-level scratch (`_cols`) reused every call — **zero
allocation per frame**, which is exactly what the perf contract wants. In GDScript
use a preallocated `Array[Collider]` and `resize(0)` / `clear()`.

### 11.4 `circleBox` — the XZ penetration test
```js
const _pn = { d: 0, nx: 0, nz: 0 };
function circleBox(px, pz, r, c) {
  const dx = px - c.x, dz = pz - c.z;
  const lx = dx*c.co - dz*c.si, lz = dx*c.si + dz*c.co;
  const clx = clamp(lx, -c.hx, c.hx), clz = clamp(lz, -c.hz, c.hz);
  let ox = lx - clx, oz = lz - clz;
  const d2 = ox*ox + oz*oz;
  if (d2 > r*r) return null;
  if (d2 > 1e-9) { const d = Math.sqrt(d2); _pn.d = r - d; ox /= d; oz /= d; }
  else {                                   // centre inside the rect: push the short way out
    const px1 = c.hx - Math.abs(lx), pz1 = c.hz - Math.abs(lz);
    if (px1 < pz1) { ox = Math.sign(lx) || 1; oz = 0; _pn.d = px1 + r; }
    else           { ox = 0; oz = Math.sign(lz) || 1; _pn.d = pz1 + r; }
  }
  _pn.nx =  ox*c.co + oz*c.si;             // rotate back to world
  _pn.nz = -ox*c.si + oz*c.co;
  return _pn;
}
```
Returns a shared mutable struct — do not cache the pointer. In GDScript return a
small `Vector3(d, nx, nz)` or write into preallocated members.

`Math.sign(0) === 0` hence `|| 1`. Reproduce.

```js
function overlapsXZ(px, pz, r, c) {  // same transform, boolean only
  const dx = px - c.x, dz = pz - c.z;
  const lx = dx*c.co - dz*c.si, lz = dx*c.si + dz*c.co;
  const clx = clamp(lx, -c.hx, c.hx), clz = clamp(lz, -c.hz, c.hz);
  const ox = lx - clx, oz = lz - clz;
  return ox*ox + oz*oz <= r*r;
}
```

### 11.5 `canStand` and `topAt`
```js
// is there room for a body of height h with feet at y, at (x,z)?
function canStand(x, z, y, h, r = MV.radius * 0.92) {   // default r = 0.3128
  if (y < groundH(x, z) - 0.05) return false;
  queryCols(x, z, r + 1.2, _cols);
  for (const c of _cols) {
    if (c.y + c.hy <= y + 0.04 || c.y - c.hy >= y + h - 0.04) continue;
    if (overlapsXZ(x, z, r, c)) return false;
  }
  return true;
}
// highest solid top at a point, within [lo, hi]; null if nothing
function topAt(x, z, lo, hi) {
  let best = null;
  const g = groundH(x, z);
  if (g >= lo && g <= hi) best = g;
  queryCols(x, z, 1.0, _cols);
  for (const c of _cols) {
    const t = c.y + c.hy;
    if (t < lo || t > hi) continue;
    if (!overlapsXZ(x, z, 0.06, c)) continue;
    if (best === null || t > best) best = t;
  }
  return best;
}
```
Constants: vertical slack **0.04**, ground slack **0.05**, query pad **+1.2 m**,
`topAt` query radius **1.0 m**, `topAt` overlap probe radius **0.06 m**.
`topAt` returns `null` for "nothing" — in GDScript return `NAN` or a
`(bool, float)` pair; `-INF` is unsafe because valid tops can be negative.

### 11.6 `rayBox` / `raycastWorld` (shared with the ballistics)
```js
function rayBox(ox, oy, oz, dx, dy, dz, c) {
  const px = ox - c.x, pz = oz - c.z;
  const lx = px*c.co - pz*c.si, lz = px*c.si + pz*c.co;
  const ly = oy - c.y;
  const ux = dx*c.co - dz*c.si, uz = dx*c.si + dz*c.co, uy = dy;
  let t0 = -1e9, t1 = 1e9;
  for (const [o, d, h] of [[lx,ux,c.hx],[ly,uy,c.hy],[lz,uz,c.hz]]) {
    if (Math.abs(d) < 1e-8) { if (o < -h || o > h) return -1; continue; }
    let a = (-h - o)/d, b = (h - o)/d;
    if (a > b) { const t = a; a = b; b = t; }
    if (a > t0) t0 = a; if (b < t1) t1 = b;
    if (t0 > t1) return -1;
  }
  return t0 > 0 ? t0 : (t1 > 0 ? 0 : -1);
}
```
```js
function raycastWorld(org, dir, maxD) {
  let bestT = maxD, surf = S.SAND;
  // 2-D DDA over the broadphase grid, max 90 cells
  let cx = Math.floor(org.x / CELL), cz = Math.floor(org.z / CELL);
  const stepX = dir.x > 0 ? 1 : -1, stepZ = dir.z > 0 ? 1 : -1;
  const tDX = Math.abs(dir.x) < 1e-8 ? 1e9 : Math.abs(CELL / dir.x);
  const tDZ = Math.abs(dir.z) < 1e-8 ? 1e9 : Math.abs(CELL / dir.z);
  let tMX = Math.abs(dir.x) < 1e-8 ? 1e9 : (((dir.x > 0 ? cx+1 : cx) * CELL) - org.x) / dir.x;
  let tMZ = Math.abs(dir.z) < 1e-8 ? 1e9 : (((dir.z > 0 ? cz+1 : cz) * CELL) - org.z) / dir.z;
  let t = 0, guard = 0;
  while (t < bestT && guard++ < 90) {
    const a = GRID.get(gkey(cx, cz));
    if (a) for (let n = 0; n < a.length; n++) {
      const c = COL[a[n]];
      const h = rayBox(org.x, org.y, org.z, dir.x, dir.y, dir.z, c);
      if (h >= 0 && h < bestT) { bestT = h; surf = c.surf; }
    }
    if (tMX < tMZ) { t = tMX; tMX += tDX; cx += stepX; } else { t = tMZ; tMZ += tDZ; cz += stepZ; }
  }
  // terrain: march at 1.4 m then 8 bisection steps
  let prev = org.y - groundH(org.x, org.z);
  const stepLen = 1.4;
  for (let d = stepLen; d < Math.min(bestT, maxD); d += stepLen) {
    const x = org.x + dir.x*d, y = org.y + dir.y*d, z = org.z + dir.z*d;
    const h = y - groundH(x, z);
    if (h <= 0 && prev > 0) {
      let lo = d - stepLen, hi = d;
      for (let k = 0; k < 8; k++) { const m = (lo + hi)/2;
        const hm = (org.y + dir.y*m) - groundH(org.x + dir.x*m, org.z + dir.z*m);
        if (hm <= 0) hi = m; else lo = m; }
      if (hi < bestT) { bestT = hi; surf = surfaceAtGround(org.x + dir.x*hi, org.z + dir.z*hi); }
      break;
    }
    prev = h;
  }
  return { t: bestT, surf, hit: bestT < maxD };
}
```
Constants: DDA guard **90 cells** (= 810 m), terrain march step **1.4 m**,
**8** bisection iterations.

**GOTCHA — the DDA does not de-duplicate.** A collider spanning several cells is
tested once per cell it occupies. Harmless (nearest hit wins) but it is why the
guard is only 90.

**GOTCHA — the DDA visits the origin cell but its `while (t < bestT)` uses `t`, the
distance to the *next* boundary, not the distance travelled through colliders.**
Port literally.

### 11.7 `surfaceAtGround`
```js
function surfaceAtGround(x, z) {
  if (Math.abs(x) < 175 && Math.abs(z) < 205 && roadAt(x, z) > 0.5) return S.ASPHALT;
  return groundNormal(x, z).y < 0.80 ? S.ROCK : S.SAND;
}
```
**GOTCHA:** the z bound here is **205**, but `buildTerrain` uses **210** for the same
test when writing `VR`. A 5 m strip of road is painted but is not asphalt underfoot.
Reference inconsistency — unify to 210 in the port and say so in `balance.md`.

---

## 12. Ladders, walls with holes, stairs

### 12.1 `addLadder(x, z, ry, y0, y1, col)`
```js
function addLadder(x, z, ry, y0, y1, col) {
  const co = Math.cos(ry), si = Math.sin(ry);
  const c = col || 0x5a5049;
  for (const s of [-0.26, 0.26])                                    // two stiles
    W.box(x + s*co, (y0+y1)/2, z - s*si, 0.04, (y1-y0)/2, 0.04, ry, c, S.METAL);
  for (let y = y0 + 0.28; y < y1 - 0.06; y += 0.30)                 // rungs
    W.box(x, y, z, 0.27, 0.025, 0.025, ry, c, S.METAL);
  for (const t of [0.2, 0.8]) {                                     // stand-off brackets
    const y = lerp(y0, y1, t);
    W.box(x - si*0.10, y, z - co*0.10, 0.30, 0.03, 0.12, ry, c, S.METAL);
  }
  LADDERS.push({ x, z, co, si, hx: 0.78, hz: 0.95, y0: y0 - 0.15, y1 });
}
```
**`ry` must be oriented so the ladder's local +Z points AWAY from whatever it is
bolted to.** Get that backwards and the rungs run edge-on to the climber and the
climb volume sits inside the wall. Outward direction in world = `(si, co)`.
Brackets are placed at local `(0, 0, −0.10)`, i.e. into the wall.

Ladder geometry is all `W.box` — **no colliders**. The climb volume is the
`LADDERS` record: half-width **0.78** along local X, depth **−0.45 … +0.95** along
local Z, vertical span `[y0 − 0.15, y1]`. Rung pitch **0.30 m**, stile spacing
**0.52 m**, default colour `0x5a5049`.

### 12.2 `wallWithHoles(ax, az, bx, bz, yBase, h, th, holes, col, type, surf, trim)`
```js
const dx = bx-ax, dz = bz-az, len = Math.hypot(dx, dz);
if (len < 0.01) return;
const ry = Math.atan2(-dz, dx);          // wall runs along local +X
const cxAll = (ax+bx)/2, czAll = (az+bz)/2;
const place = (u0, u1, y0, y1) => {
  if (u1-u0 < 0.02 || y1-y0 < 0.02) return;
  const um = (u0+u1)/2 - len/2;
  solid(cxAll + um*co, (y0+y1)/2, czAll - um*si,
        (u1-u0)/2, (y1-y0)/2, th/2, ry, col, type, surf);
};
const hs = (holes || []).filter(o => o.u1 > 0 && o.u0 < len)
  .map(o => ({ u0: Math.max(0, o.u0), u1: Math.min(len, o.u1),
               y0: yBase + o.y0, y1: yBase + Math.min(h, o.y1) }))
  .sort((a, b) => a.u0 - b.u0);
let cur = 0;
for (const o of hs) {
  if (o.u0 > cur) place(cur, o.u0, yBase, yBase + h);   // pier before the hole
  place(o.u0, o.u1, yBase, o.y0);                       // under the hole
  place(o.u0, o.u1, o.y1, yBase + h);                   // over the hole
  cur = Math.max(cur, o.u1);
}
if (cur < len) place(cur, len, yBase, yBase + h);
```
`holes` entries are `{u0, u1, y0, y1}` with **u measured from `a` along the wall**
and **y measured relative to `yBase`**. `y1` is clamped to `h`, `y0` is not.

**GOTCHA — overlapping holes double-place.** Two holes whose u-ranges overlap each
emit their own under/over slabs, producing z-fighting boxes. The generators avoid
it by checking spacing before pushing windows; keep those checks.

Frames (all `deco`, no colliders), trim colour `tc = trim ?? 0x5c4a36`, type
`S.WOOD`:
```js
const frame = (u0, u1, y0, y1, hy, out) => {
  const um = (u0+u1)/2 - len/2;
  deco(cxAll + um*co, (y0+y1)/2, czAll - um*si, (u1-u0)/2, hy, th/2 + out, ry, tc, S.WOOD);
};
for (const o of hs) {
  const isWin = o.y0 > yBase + 0.25;
  frame(o.u0-0.11, o.u1+0.11, o.y1, o.y1+0.15, 0.075, 0.055);         // lintel
  frame(o.u0-0.11, o.u0,      o.y0, o.y1, (o.y1-o.y0)/2, 0.045);      // jamb L
  frame(o.u1,      o.u1+0.11, o.y0, o.y1, (o.y1-o.y0)/2, 0.045);      // jamb R
  if (isWin) frame(o.u0-0.13, o.u1+0.13, o.y0-0.10, o.y0, 0.05, 0.085); // sill
}
```
Note `frame` takes an explicit `hy` half-height rather than deriving it from
`y0/y1`; the two are consistent in every call site above.

### 12.3 `stairsFixed(x, z, ry, w, run, riseTo, y0, col, type)`
```js
const steps = Math.max(2, Math.round(riseTo / 0.235));
const rise = riseTo / steps, tread = run / steps;
for (let i = 0; i < steps; i++) {
  const u = -run/2 + tread*(i + 0.5);
  const top = y0 + rise*(i+1), bot = y0 - 0.25;
  solid(x + u*co, (top+bot)/2, z - u*si,
        tread/2 + 0.004, (top-bot)/2, w/2, ry, col, type, S.CONCRETE);
}
```
Target riser **0.235 m** (well under `MV.step = 0.58`, so stairs are walked, not
climbed). Each step is a full-height block down to `y0 − 0.25` — no overhangs, no
gaps. The `+0.004` on the tread half-extent overlaps neighbours so there is never a
coplanar seam. **Surface is always forced to `S.CONCRETE`** regardless of `type`.

---

## 13. Building generators

All take `(g, …)` where `g` is `G` and `g.r` is the shared rng.
All return a "building record" pushed to `G.buildings` (except `bContainers`).

### 13.1 `bAdobe(g, x, z, w, d, floors, ry, opts = {})`

```
th   = 0.42                              wall thickness
fh   = opts.fh || rr(r, 3.0, 3.5)        floor height
base = groundH(x, z)
wallC  = vary(pick(r, PAL.adobe), r, 0.10)
trimC  = vary(pick(r, PAL.concrete), r, 0.10)
roofC  = chance(r,0.55) ? vary(pick(r,PAL.adobe), r, 0.13)
                        : vary(pick(r,PAL.concrete), r, 0.13)
frameC = chance(r,0.6)  ? vary(pick(r,PAL.wood), r, 0.14) : vary(0x5c584f, r, 0.14)
hw = w/2, hd = d/2
L(lx,lz) = [x + lx*co + lz*si, z - lx*si + lz*co]
cor = [L(-hw,-hd), L(hw,-hd), L(hw,hd), L(-hw,hd)]
```
Note `L` here takes `(lx, lz)` and returns `[worldX, worldZ]` — the same yaw
convention as §10.1.

**Foundation:** `solid(x, base-0.9, z, hw+0.22, 1.0, hd+0.22, ry, trimC, S.CONCRETE)`.

**`roofY = base + fh * floors`.**

**Per floor `f` in `[0, floors)`**, `y0 = base + f*fh`, for each of the 4 sides `s`:
* `a = cor[s]`, `b = cor[(s+1)%4]`, `len = |b − a|`
* **door**, only on `f === 0` and `s === (opts.doorSide ?? 0)`:
  `dw = min(len - 1.2, rr(r, 1.55, 2.05))`,
  `du = len/2 - dw/2 + (r() - 0.5) * (len * 0.18)`;
  emit `{u0: du, u1: du+dw, y0: 0, y1: 2.45}` if `dw > 1.0`.
* **back door**, `f === 0`, `s === (doorSide + 2) % 4`, `chance(r, 0.62)`:
  `dw = min(len - 1.2, rr(r, 1.4, 1.9))`, centred, `y1 = 2.35`, if `dw > 1.0`.
* **windows:** `nWin = max(0, floor(len / rr(r, 2.6, 4.0)))`; for `i` in `[0,nWin)`:
  `u = (i+0.5)/nWin * len`, `ww = rr(r, 0.7, 1.15)`;
  skip if `holes.some(o => u - ww < o.u1 + 0.5 && u + ww > o.u0 - 0.5)`;
  skip on `chance(r, 0.22)`;
  `sill = rr(r, 0.95, 1.25)`, push `{u0: u-ww/2, u1: u+ww/2, y0: sill, y1: sill + rr(r, 0.95, 1.35)}`.
* `wallWithHoles(a[0], a[1], b[0], b[1], y0, fh, th, holes, wallC, S.CONCRETE, S.CONCRETE, frameC)`

**Floor slab + stair well** (emitted for every `f`, including the top — that slab is
the roof deck; the guarding `if (f < floors)` is vestigial and always true):
```
wellW = min(2.4, w*0.42);  wellD = min(2.4, d*0.42)
yTop  = y0 + fh
wu = hw - wellW/2 - 0.35;  wv = -hd + wellD/2 + 0.35
segs = [ [-hw, hw, -hd, wv-wellD/2],
         [-hw, hw, wv+wellD/2, hd],
         [-hw, wu-wellW/2, wv-wellD/2, wv+wellD/2],
         [wu+wellW/2, hw, wv-wellD/2, wv+wellD/2] ]
slabC = (f === floors-1) ? roofC : trimC
for each [u0,u1,v0,v1] with u1-u0 >= 0.05 and v1-v0 >= 0.05:
  solid(L((u0+u1)/2,(v0+v1)/2), yTop + 0.11, ..., (u1-u0)/2, 0.15, (v1-v0)/2, ry, slabC, S.CONCRETE)
stair: sry = ry + PI/2
       (sx,sz) = L(wu, wv + wellD/2 + (fh*1.15)/2)
       stairsFixed(sx, sz, sry, min(1.1, wellW-0.2), fh*1.15, fh+0.26, y0, trimC, S.CONCRETE)
```

**Parapet:** `par = rr(r, 0.75, 1.15)`; for each side,
`holes = chance(r,0.4) ? [{u0:1.0, u1:1.0 + rr(r,0.8,1.6), y0:0, y1:par}] : []`, then
`wallWithHoles(a, b, roofY + 0.26, par, 0.30, holes, wallC, S.CONCRETE, S.CONCRETE)`
(trim defaults to `0x5c4a36`).

`g.roofs.push({x, z, w, d, ry, y: roofY + 0.26, cor})` — **dead data, do not port.**

**Exterior ladder**, `chance(r, 0.55)`:
```
s = ri(r, 0, 3); a = cor[s]; b = cor[(s+1)%4]; t = rr(r, 0.25, 0.75)
lx = a[0] + (b[0]-a[0])*t;  lz = a[1] + (b[1]-a[1])*t
nrm = atan2(-(b[1]-a[1]), b[0]-a[0]) + PI/2         // outward wall normal angle
addLadder(lx + cos(nrm)*0.32, lz - sin(nrm)*0.32, nrm + PI/2,
          base, roofY + 0.26 + par + 0.30)
```
The `+0.30` above the parapet is mandatory: without it you climb into the parapet
and slide back down.

`roofClutter(g, x, z, w, d, ry, roofY + 0.26, cor)` — see §14.1.

**Awning**, `chance(r, 0.5)`:
```
s = opts.doorSide || 0; a = cor[s]; b = cor[(s+1)%4]
mx,mz = midpoint;  nrm = atan2(-(b[1]-a[1]), b[0]-a[0]) + PI/2
ox = cos(nrm); oz = -sin(nrm);  cC = pick(r, PAL.cloth)
W.box(mx + ox*0.9, base + 2.45, mz + oz*0.9, 1.5, 0.04, 0.95, nrm + PI/2, cC, S.CLOTH)
for sg in [-1, 1]:
  W.cyl(mx + ox*1.75 + sg*(-oz)*1.3, base + 1.2, mz + oz*1.75 + sg*ox*1.3,
        0.05, 0.05, 1.2, 5, 0x5a5049, S.METAL)
```

**Returns** `{ x, z, w, d, ry, roofY: roofY + 0.26, base }`.

### 13.2 `bWarehouse(g, x, z, w, d, ry)`
```
base = groundH(x,z);  h = rr(r, 6.0, 8.2);  hw = w/2, hd = d/2;  th = 0.34
wallC = vary(pick(r, PAL.concrete), r);  tinC = vary(pick(r, PAL.tin), r)
solid(x, base-0.75, z, hw+0.3, 0.8, hd+0.3, ry, vary(0x63605b, r), S.CONCRETE)
doorSide = ri(r, 0, 3)
```
Per side: if `s === doorSide` push `{u0: len/2-2.8, u1: len/2+2.8, y0:0, y1:4.8}`
(a 5.6 × 4.8 m roller door); else if `s === (doorSide+2)%4` and `chance(r,0.7)` push
`{u0: len/2-1.3, u1: len/2+1.3, y0:0, y1:2.6}`.
Clerestory windows: `nw = floor(len / 3.4)`; for each, `u = (i+0.5)/nw*len`, skip if
within 1.2 m of an existing hole, else push `{u0:u-0.65, u1:u+0.65, y0:h-2.1, y1:h-0.9}`.
`wallWithHoles(a, b, base, h, th, holes, wallC, S.CONCRETE, S.CONCRETE, vary(0x4a4c50, r, 0.12))`.

**Gable roof** — `ridge = h + min(hw, hd) * 0.38`:
```js
for (const sgn of [-1, 1]) {
  const slope = (ridge - h) / hw;
  W.corrug(x + sgn*hw/2*co, (h+ridge)/2 + 0.15, z - sgn*hw/2*si,
           hw/2 * Math.hypot(1, slope), hd + 0.35, Math.round(hw*1.6), 0.09,
           tinC, S.TIN, ry, -sgn*slope);
  addCol(x + sgn*hw/2*co, (h+ridge)/2 - 0.1, z - sgn*hw/2*si, hw/2, 0.35, hd, ry, S.TIN);
}
W.box(x, ridge + 0.22, z, 0.24, 0.1, hd + 0.35, ry, tinC, S.TIN);   // ridge cap
```
**GOTCHA — the roof ignores `base`.** `ridge` is `h + …`, an absolute Y, while the
walls run from `base` to `base + h`. In the town pan `base ≈ 0` so the error is
under a metre; on sloped ground the roof detaches. The returned `roofY: h` has the
same bug. **Fix by adding `base` to `h` and `ridge`, and log it in `balance.md`.**

**Catwalk** at `cwY = base + h*0.56`, one per side:
```
ox = -cos(nrm)*0.75, oz = sin(nrm)*0.75;  wry = atan2(-(b[1]-a[1]), b[0]-a[0])
solid(mx+ox, cwY, mz+oz, len/2 - 0.3, 0.07, 0.7, wry, vary(0x5c584f,r), S.METAL, S.METAL)
deco(mx+ox*2.05, cwY+0.52, mz+oz*2.05, len/2-0.3, 0.03, 0.03, wry, 0x4a4c50, S.METAL)   // rail
5 stanchions at t = i/4 along the wall, offset ox*2.05:
  deco(px, cwY+0.26, pz, 0.03, 0.26, 0.03, 0, 0x4a4c50, S.METAL)
```
Ladder: `addLadder(L(-hw+0.55, -hd+2.8), ry + PI/2, base, cwY + 0.95)`.

Interior: `inv = ri(r, 3, 7)` items at `L(rr(r,-hw+1.5,hw-1.5), rr(r,-hd+1.5,hd-1.5))`,
`chance(r,0.4)` → `barrel`, else `bigCrate(…, rr(r,0,3))`.

`g.tall.push({x, z, y: ridge, name: 'depot'})` — dead data.
**Returns** `{ x, z, w, d, ry, roofY: h, base, warehouse: true }`.

### 13.3 `bContainers(g, x, z, ry, n)`
```js
const CW = 3.05, CH = 1.30, CD = 1.22;    // HALF-extents ⇒ 6.10 × 2.60 × 2.44 m
const cols = [0x7a4a2c, 0x5f6448, 0x4a4d52, 0x6a6544, 0x5b4838, 0x6b4028];
let y = base = groundH(x, z);
const stack = ri(r, 1, n || 3);
for (let i = 0; i < stack; i++) {
  const jx = rr(r, -0.3, 0.3) * i, jr = rr(r, -0.05, 0.05) * i;   // drift grows with height
  solid(x + jx, y + CH, z, CW, CH, CD, ry + jr, vary(pick(r, cols), r, 0.13), S.TIN, S.TIN);
  y += CH * 2 + 0.04;
}
if (chance(r, 0.5))
  addLadder(x + (CW+0.12)*Math.cos(ry), z - (CW+0.12)*Math.sin(ry), ry + Math.PI/2, base, y + 0.9);
```
Returns the final `y` (a number), **not** a building record — containers are never
in `G.buildings`, so they are never roof-bridged or chosen as an exfil.

### 13.4 `bRuin(g, x, z, w, d, ry)`
```
base = groundH(x,z);  hw=w/2, hd=d/2;  th = 0.4
wallC = vary(pick(r, PAL.adobe), r, 0.12);  H = rr(r, 3.0, 6.5)
solid(x, base-0.5, z, hw+0.2, 0.6, hd+0.2, ry, vary(0x63605b, r), S.CONCRETE)
```
Per side: `chance(r, 0.28)` → wall gone entirely (`continue`).
Otherwise `segs = max(3, round(len / 1.1))` and for each segment `i`:
```js
const hh = H * clamp(0.25 + fbm2(x*0.3 + s*3 + i*0.7, z*0.3, 3) * 1.5, 0.1, 1.15);
if (hh < 0.4) continue;
solid(px, base + hh/2, pz, len/segs/2, hh/2, th/2, wry, wallC, S.CONCRETE, S.CONCRETE);
```
(the ragged top is a deterministic fbm of the building's own position, not an rng
draw — so it does not consume the stream.)

Rubble ramp: `rn = ri(r, 5, 12)` blocks at angle `r()*TAU`,
`rad = rr(r, 0.3, min(hw,hd)*1.25)`, `s = rr(r,0.3,0.9)`, `hgt = rr(r,0.2,0.75)`,
`solid(px, base + hgt*0.55, pz, s, hgt, s*rr(r,0.6,1.4), r()*3, vary(pick(r,PAL.concrete), r, 0.16), S.CONCRETE, S.CONCRETE)`.

Rebar: `ri(r, 2, 6)` cylinders at a random corner ±0.5 m,
`W.cyl(…, base + rr(r,1.5,3.2), …, 0.025, 0.02, rr(r,0.6,1.4), 4, 0x6b4028, S.METAL, r()*3)`.

**Returns** `{ x, z, w, d, ry, roofY: base + H*0.5, base, ruin: true }`.

### 13.5 `bTower(g, x, z)` — the landmark water tower
```
base = groundH(x,z);  H = rr(r, 13, 19);  legR = rr(r, 2.4, 3.4)
mC = vary(0x4a4c50, r);  tC = vary(0x6a6560, r)
```
**Legs** — 4, at `a = i/4*TAU + PI/4`, tapering from radius `legR` at the base to
`legR*0.42` at the top, in 5 stacked segments:
```js
W.seg(p0, p1, 0.1, mC, S.METAL);
addCol(mid, 0.15, len/2, 0.15, 0, S.METAL);
```
**Bracing rings** at `t = s/5` for `s` in `[1,4]`, radius `lerp(legR, legR*0.42, t)`,
4 boxes per ring: `W.box(mid, yy, mid, len/2, 0.055, 0.055, atan2(-(p1z-p0z), p1x-p0x), mC, S.METAL)`.

**Platform** at `py = base + H`:
`solid(x, py, z, legR*0.72, 0.08, legR*0.72, PI/4, vary(0x5c584f, r), S.METAL, S.METAL)`,
plus 4 rails at `rad = legR*0.72*SQRT2*0.72`, `deco(mid, py+0.5, mid, len/2, 0.03, 0.03, …)`.

**Tank:** `W.cyl(x, py+2.0, z, legR*0.55, legR*0.55, 1.85, 12, tC, S.TIN)` +
`addCol(x, py+2.0, z, legR*0.55, 1.85, legR*0.55, 0, S.TIN)`; cap
`W.cyl(x, py+4.0, z, legR*0.55, 0.1, 0.16, 12, tC, S.TIN)`.

**Ladder:** `addLadder(x + legR*0.99, z, Math.PI/2, base, py + 1.05)` — `ry = π/2`
means outward = `(sin, cos) = (1, 0)` = +X, correctly facing away from the tower.

`g.tall.push(...)` (dead). `POIS.push({x, z, name: 'TOWER', kind: 'poi'})`.
**Returns** `{ x, z, w: legR*2, d: legR*2, ry: 0, roofY: py, base, tower: true }`.

### 13.6 `bMarket(g, x, z, w, d, ry)`
```
rows = max(1, floor(d / 4.2));  n = max(1, floor(w / 3.4))
per stall at (u,v) = ((i+0.5)/n*w - w/2, (j+0.5)/rows*d - d/2):
  b  = groundH(px, pz)
  hh = rr(r, 2.0, 2.5);  sw = rr(r, 1.2, 1.7);  sd = rr(r, 0.8, 1.2)
  4 posts at (±sw, ±sd):
    W.cyl(qx, b + hh/2, qz, 0.055, 0.05, hh/2, 5, 0x5c3f26, S.WOOD)
    addCol(qx, b + hh/2, qz, 0.09, hh/2, 0.09, 0, S.WOOD)
  canopy: cC = vary(pick(r, PAL.cloth), r, 0.14)
    W.box(px, b + hh + 0.06, pz, sw+0.25, 0.035, sd+0.25, ry + rr(r,-0.06,0.06), cC, S.CLOTH)
    addCol(px, b + hh + 0.06, pz, sw+0.25, 0.08, sd+0.25, ry, S.CLOTH)
  table: solid(px, b+0.75, pz, sw*0.85, 0.06, sd*0.7, ry, vary(pick(r,PAL.wood), r), S.WOOD, S.WOOD)
  2 legs at (∓sw*0.8, ∓sd*0.6): deco(qx, b+0.37, qz, 0.05, 0.37, 0.05, 0, 0x5c3f26, S.WOOD)
  chance(r,0.4) → crate(g, px + rr(r,-1,1), b, pz + rr(r,-1,1), r()*3)
  chance(r,0.3) → barrel(g, px + rr(r,-1.5,1.5), b, pz + rr(r,-1.5,1.5))
```
`POIS.push({x, z, name: 'MARKET', kind: 'poi'})` — **once per market**, and markets
are generated both by `buildPlaza` and by the lot loop, so there can be several.
**Returns** `{ x, z, w, d, ry, roofY: base + 2.6, base, market: true }`.

### 13.7 `bCompound(g, x, z, w, d, ry)`
```
base = groundH(x,z);  wallC = vary(pick(r, PAL.concrete), r, 0.12);  gate = ri(r, 0, 3)
per side: holes = (s === gate) ? [{u0: len/2-2.6, u1: len/2+2.6, y0:0, y1:3.4}] : []
          wallWithHoles(a, b, base, rr(r, 2.6, 3.4), 0.34, holes, wallC, S.CONCRETE, S.CONCRETE)
inner shack: bAdobe(g, x + rr(r,-2,2), z + rr(r,-2,2),
                    min(w*0.5, 8), min(d*0.5, 8), 1, ry + rr(r,-0.2,0.2))
ri(r, 2, 5) props at L(rr(r,-hw+1,hw-1), rr(r,-hd+1,hd-1)):
  chance(r,0.5) ? barrel : crate(..., r()*3)
```
**GOTCHA — the inner `bAdobe`'s return value is discarded**, so it is never in
`G.buildings`: it cannot be roof-bridged and cannot be picked as the rooftop exfil,
even though it has a real roof and possibly a ladder.
**Returns** `{ x, z, w, d, ry, roofY: base + 3.4, base, compound: true }`.

Note the compound wall height (`rr(r, 2.6, 3.4)`) is re-rolled per side — four
draws, four different heights.

---

## 14. Prop generators

### 14.1 `roofClutter(g, x, z, w, d, ry, y, cor)`
`n = ri(r, 1, 4)` items at `L(rr(r, -w/2+1, w/2-1), rr(r, -d/2+1, d/2-1))`,
`k = r()` selects:

| `k` | item |
|---|---|
| `< 0.30` | water tank: `W.cyl(px, y+0.75, pz, 0.62, 0.62, 0.75, 9, vary(0x6a6560, r), S.TIN)` + `addCol(px, y+0.75, pz, 0.62, 0.75, 0.62, 0, S.TIN)` |
| `< 0.55` | AC block: `bw = rr(r,0.5,0.9)`, `bh = rr(r,0.4,0.8)`, `solid(px, y+bh, pz, bw, bh, bw*rr(r,0.7,1.3), rr(r,0,3), vary(0x63656a, r), S.METAL)` |
| `< 0.75` | `crate(g, px, y, pz, rr(r, 0, 3))` |
| `< 0.90` | antenna: `W.cyl(px, y+2.2, pz, 0.045, 0.02, 2.2, 5, 0x4a4c50, S.METAL)` + 3 crossbars `W.box(px, y+3.2+a*0.35, pz, 0.42-a*0.1, 0.015, 0.015, a*0.7, 0x4a4c50, S.METAL)` |
| else | `sandbags(g, px, y, pz, rr(r, 0, 6))` |

The antenna mast is **not** collidable (`W.cyl` with no `addCol`) — deliberate, it
would otherwise snag a sprint across the roof.

### 14.2 `crate(g, x, y, z, ry)`
```js
const n = ri(r, 1, 3);
let yy = y;
for (let i = 0; i < n; i++) {
  const s = rr(r, 0.35, 0.55), h = rr(r, 0.3, 0.5);
  const t = chance(r, 0.45) ? S.WOOD : S.METAL;
  solid(x + rr(r,-0.1,0.1), yy + h, z + rr(r,-0.1,0.1), s, h, s*rr(r,0.8,1.2),
        ry + rr(r,-0.3,0.3),
        vary(t === S.WOOD ? pick(r, PAL.wood) : pick(r, PAL.metal), r), t, t);
  yy += h * 2;
}
```

### 14.3 `barrel(g, x, y, z)`
```js
const h = 0.46, rad = 0.30;
const c = chance(r, 0.3) ? 0x7a4a2c : chance(r, 0.5) ? 0x5f6448 : 0x6a6544;
const tipped = chance(r, 0.18);
if (tipped) {
  W.cyl(x, y + rad, z, rad, rad, h, 10, vary(c, r), S.METAL, Math.PI/2);
  addCol(x, y + rad, z, h, rad, rad, r()*3, S.METAL);
} else {
  W.cyl(x, y + h, z, rad, rad, h, 10, vary(c, r), S.METAL);
  W.cyl(x, y + h*0.7, z, rad+0.02, rad+0.02, 0.03, 10, 0x4a4c50, S.METAL);   // rolling hoop
  addCol(x, y + h, z, rad, h, rad, 0, S.METAL);
}
```
Note the colour selection short-circuits: the second `chance` only draws when the
first fails, so the draw count is 1 or 2. **Reproduce the short-circuit.**
"Tipped" is the visual/collider mismatch from §10.5.

### 14.4 `sandbags(g, x, y, z, ry)`
```js
const rows = ri(r, 2, 3), len = ri(r, 3, 5);
for (let j = 0; j < rows; j++) for (let i = 0; i < len - j; i++) {
  const u = (i - (len - j - 1)/2) * 0.46 + (j % 2) * 0.1;
  solid(x + u*co, y + 0.14 + j*0.25, z - u*si, 0.24, 0.13, 0.17,
        ry + rr(r, -0.14, 0.14), vary(0x8f7a52, r, 0.14), S.CLOTH, S.CLOTH);
}
```
A pyramid: each row is one bag shorter, courses offset 0.1 m on odd rows,
bag pitch 0.46 m, course height 0.25 m (bags are 0.26 m tall, so they **overlap**
0.01 m — no gaps).

### 14.5 `bigCrate(g, x, y, z, ry)`
```js
const n = ri(r, 1, 3);
const wd = rr(r, 0.7, 1.2), dp = rr(r, 0.7, 1.2);
let yy = y;
for (let i = 0; i < n; i++) {
  const hgt = rr(r, 0.5, 0.8);
  solid(x, yy + hgt, z, wd, hgt, dp, ry, vary(pick(r, PAL.wood), r), S.WOOD, S.WOOD);
  yy += hgt * 2;
  if (chance(r, 0.4)) break;
}
```
The early `break` still consumes its `chance` draw on the last iteration.

### 14.6 `wreck(g, x, z, ry)` — the derelict truck
```
base = groundH(x,z);  sink = rr(r, 0.02, 0.30);  y0 = base - sink
bodyC = vary(chance(r,0.45) ? 0x5b4838 : chance(r,0.5) ? 0x4a4d52 : 0x6b4028, r, 0.15)
trimC = vary(0x3f4247, r, 0.12)
len = rr(r, 2.3, 3.1);  wid = rr(r, 0.92, 1.15)
wheelR = 0.36;  axleY = y0 + wheelR;  deckY = axleY + 0.31
```
* chassis: `solid(x, axleY+0.20, z, len, 0.11, wid*0.86, ry, trimC, S.METAL, S.METAL)`
* cab at `L(-len*0.42, 0)`: `solid(cx2, deckY+0.42, cz2, len*0.30, 0.42, wid*0.92, ry, bodyC, S.TIN, S.TIN)`
* `chance(r, 0.62)` → cab roof `solid(cx2 + co*0.06, deckY+1.02, cz2 - si*0.06, len*0.24, 0.24, wid*0.80, ry, vary(bodyC, r, 0.1), S.TIN, S.TIN)`
  else → 4 burnt-out pillars at `L(-len*0.42 ± len*0.22, ± wid*0.78)`:
  `deco(px, deckY+1.0, pz, 0.05, 0.34, 0.05, ry, trimC, S.METAL)`
* bed at `L(len*0.30, 0)`: `solid(bx2, deckY+0.10, bz2, len*0.52, 0.10, wid*0.92, ry, vary(bodyC, r, 0.12), S.TIN, S.TIN)`
* side rails, each `chance(r, 0.75)`: at `L(len*0.30, ±wid*0.88)`,
  `solid(px, deckY+0.38, pz, len*0.52, 0.28, 0.06, ry, vary(bodyC, r, 0.12), S.TIN, S.TIN)`
* wheels at `a2 ∈ {−0.62, 0.46}` × `sgn ∈ {−1, 1}`, position `L(len*a2, sgn*wid*0.95)`:
  * `chance(r, 0.22)` → stripped hub `W.cyl(px, axleY, pz, 0.12, 0.12, 0.07, 8, trimC, S.METAL, ry+PI/2)` and `continue`
  * else tyre `W.cyl(px, axleY, pz, wheelR, wheelR, 0.15, 12, vary(0x2b2d30, r, 0.1), S.POLY, ry+PI/2)`,
    hub `W.cyl(px, axleY, pz, wheelR*0.45, wheelR*0.45, 0.16, 8, trimC, S.METAL, ry+PI/2)`,
    `addCol(px, axleY, pz, 0.16, wheelR, wheelR, ry, S.POLY)`
* `chance(r, 0.4)` → open bonnet at `L(-len*0.72, 0)`:
  `solid(px, deckY+0.55, pz, 0.06, 0.42, wid*0.7, ry + rr(r,-0.4,0.4), trimC, S.TIN, S.TIN)`

**The wheels are the §10.5 mismatch**: the `ry + PI/2` on `W.cyl` does nothing, so
they render as upright pancakes while their collider lies on its side.

### 14.7 `deadTree(g, x, z)`
```js
const base = groundH(x, z), h = rr(r, 2.2, 4.4);
W.cyl(x, base + h/2, z, 0.19, 0.09, h/2, 6, vary(0x5c3f26, r, 0.14), S.WOOD);
addCol(x, base + h/2, z, 0.22, h/2, 0.22, 0, S.WOOD);
const n = ri(r, 2, 5);
for (let i = 0; i < n; i++) {
  const a = r()*TAU, len = rr(r, 0.7, 1.8), t = rr(r, 0.55, 0.95);
  const y0 = base + h*t;
  W.seg(x, y0, z, x + Math.cos(a)*len, y0 + rr(r, 0.3, 1.1), z + Math.sin(a)*len,
        0.055, vary(0x4d3323, r), S.WOOD);
}
```
Branches are non-colliding.

### 14.8 `rockCluster(g, x, z)`
```js
const n = ri(r, 3, 8);
for (let i = 0; i < n; i++) {
  const a = r()*TAU, rad = rr(r, 0, 4.5);
  const px = x + Math.cos(a)*rad, pz = z + Math.sin(a)*rad, base = groundH(px, pz);
  const s = rr(r, 0.5, 2.2), hh = s * rr(r, 0.5, 1.1);
  solid(px, base + hh*0.55, pz, s, hh, s*rr(r, 0.6, 1.4), r()*3,
        vary(pick(r, PAL.rock), r, 0.13), S.ROCK, S.ROCK);
}
```
`base + hh*0.55` (not `+hh`) sinks each boulder 45 % of its half-height into the
ground — that is what stops the cluster showing gaps against sloping terrain.

### 14.9 `powerLine(g, pts)`
```js
for (let i = 0; i < pts.length; i++) {
  const [x, z] = pts[i], base = groundH(x, z), h = rr(r, 6.5, 8.5);
  W.cyl(x, base + h/2, z, 0.16, 0.11, h/2, 6, vary(0x5c3f26, r), S.WOOD);
  addCol(x, base + h/2, z, 0.2, h/2, 0.2, 0, S.WOOD);
  W.box(x, base + h - 0.4, z, 1.5, 0.08, 0.08, 0, vary(0x5c3f26, r), S.WOOD);   // crossarm
  if (i > 0) {
    const [px, pz] = pts[i-1], pb = groundH(px, pz) + h - 0.45;
    const seg = 7;
    for (const off of [-1.3, 1.3]) for (let s = 0; s < seg; s++) {
      const t0 = s/seg, t1 = (s+1)/seg;
      const sag = t => 1.4 * Math.sin(t * Math.PI);
      W.seg(lerp(px,x,t0) + off*0.2, pb - sag(t0), lerp(pz,z,t0),
            lerp(px,x,t1) + off*0.2, pb - sag(t1), lerp(pz,z,t1),
            0.022, 0x2f3134, S.METAL);
    }
  }
}
```
Sag amplitude **1.4 m**, `sin(t·π)` profile, 7 segments, two wires **0.52 m** apart
in world X (`off*0.2` = ±0.26).

**GOTCHA — the wire uses the *current* pole's `h` with the *previous* pole's ground
height, and holds a constant Y for both endpoints.** On sloping ground the wire
leaves one crossarm in mid-air. Fix by interpolating between the two crossarm
heights and note it.

The two calls:
```js
powerLine(G, [[-24,-120],[-24,-86],[-26,-52],[-24,-18],[-26,20],[-24,54],[-26,92]]);
powerLine(G, [[-100,42],[-66,40],[-32,42],[26,40],[62,42],[98,40]]);
```

---

## 15. Town layout

### 15.1 State
```js
const G = { r: rng(WORLD_SEED ^ 0xA51F), roofs: [], tall: [], buildings: [] };
const BLOCKS = [];
const PLAZA = { x: 4, z: 6, r: 26 };
const ROADS = [];     // {x0, z0, x1, z1, w}
const LADDERS = [];   // {x, z, co, si, hx, hz, y0, y1}
const POIS = [];      // {x, z, name, kind}
const EXFILS = [];    // {x, z, y, name, r, held}
```

### 15.2 `bsp(rect, depth, out, r, widths)`
```js
function bsp(rect, depth, out, r, widths) {
  const w = rect.x1 - rect.x0, d = rect.z1 - rect.z0;
  const minKeep = 20;
  if (depth <= 0 || (w < 34 && d < 34) || (w < minKeep || d < minKeep)) { out.push(rect); return; }
  const rw = widths[Math.min(widths.length - 1, widths.length - depth)] || 3.6;
  const along = (w > d * 1.08) || (w > d * 0.92 && chance(r, 0.5));
  const t = rr(r, 0.36, 0.64);
  if (along) {
    const cx = rect.x0 + w * t;
    if (cx - rect.x0 < minKeep || rect.x1 - cx < minKeep) { out.push(rect); return; }
    ROADS.push({ x0: cx, z0: rect.z0 - 1, x1: cx, z1: rect.z1 + 1, w: rw });
    bsp({x0: rect.x0, z0: rect.z0, x1: cx - rw/2, z1: rect.z1}, depth-1, out, r, widths);
    bsp({x0: cx + rw/2, z0: rect.z0, x1: rect.x1, z1: rect.z1}, depth-1, out, r, widths);
  } else {
    const cz = rect.z0 + d * t;
    if (cz - rect.z0 < minKeep || rect.z1 - cz < minKeep) { out.push(rect); return; }
    ROADS.push({ x0: rect.x0 - 1, z0: cz, x1: rect.x1 + 1, z1: cz, w: rw });
    bsp({x0: rect.x0, z0: rect.z0, x1: rect.x1, z1: cz - rw/2}, depth-1, out, r, widths);
    bsp({x0: rect.x0, z0: cz + rw/2, x1: rect.x1, z1: rect.z1}, depth-1, out, r, widths);
  }
}
```
`minKeep = 20`, stop when both dimensions `< 34`, split fraction `rr(r, 0.36, 0.64)`.

**GOTCHA — the `widths` index is off by one and `widths[0]` is never used.**
`widths = [8.5, 6.5, 5.0, 4.0, 3.4]` (length 5) with `depth` starting at 4:
`min(4, 5 - depth)` gives 1, 2, 3, 4, 4 for depth 4, 3, 2, 1, 0. So road widths run
6.5 → 5.0 → 4.0 → 3.4 → 3.4 and the 8.5 m width is dead. Keep it bug-compatible or
the whole street hierarchy shifts; document either choice.

**GOTCHA — `chance(r, 0.5)` is only evaluated when `w > d*0.92`**, so the draw count
depends on the rectangle's aspect ratio. Reproduce the short-circuit.

### 15.3 `lots(rect, r, out, minSz)`
```js
function lots(rect, r, out, minSz) {
  const w = rect.x1 - rect.x0, d = rect.z1 - rect.z0;
  if (w < minSz*2 && d < minSz*2) { out.push(rect); return; }
  if (chance(r, 0.16)) { out.push(rect); return; }
  const along = w > d;
  const t = rr(r, 0.38, 0.62);
  const gap = rr(r, 0.6, 1.8);
  … split at cx = rect.x0 + w*t (or cz), bail if either side < minSz,
    recurse with a `gap`-wide alley between the halves …
}
```
Called with `minSz = 9.5`.

### 15.4 `distToRoad` / `roadAt`
```js
function distToRoad(x, z) {
  let best = 1e9;
  for (const rd of ROADS) {
    const dx = rd.x1 - rd.x0, dz = rd.z1 - rd.z0;
    const L2 = dx*dx + dz*dz || 1;
    let t = ((x - rd.x0)*dx + (z - rd.z0)*dz) / L2; t = clamp(t, 0, 1);
    const px = rd.x0 + dx*t, pz = rd.z0 + dz*t;
    const dd = Math.hypot(x - px, z - pz) - rd.w/2;
    if (dd < best) best = dd;
  }
  return best;
}
function roadAt(x, z) { return 1 - smoothstep(-0.4, 2.6, distToRoad(x, z)); }
```
`roadAt` is 1 inside the carriageway, falling to 0 over the 3.0 m band from −0.4 m
to +2.6 m outside the kerb.

**PERF:** `distToRoad` is O(|ROADS|) and `buildTerrain` calls it up to 40401 times.
That is fine in a one-shot bake. **Do not call it at runtime** — `surfaceAtGround`
does, on every footstep and every terrain raycast hit. In the Godot port, bake a
road-mask lookup (e.g. reuse `VR` as a 201×201 float grid sampled with the same
bilinear scheme as `groundH`) and have `surfaceAtGround` read that.

### 15.5 `buildPlaza()`
Centre `cx = PLAZA.x = 4`, `cz = PLAZA.z = 6`, `base = groundH(cx, cz)`, `ry = 0.42`.
```
hull:  solid(cx, base+1.5, cz, 8.5, 1.5, 2.6, ry, vary(0x5b4838, r, 0.1), S.TIN, S.TIN)
deck:  solid(cx, base+3.35, cz-0.3, 7.4, 0.35, 2.3, ry, vary(0x63605b, r), S.TIN, S.TIN)
cab:   at L(-7.0, 0) → solid(hx, base+4.1, hz, 2.0, 1.3, 2.0, ry, vary(0x4a4d52, r), S.METAL, S.METAL)
6 wheels: at L(-6 + i*2.6, (i%2 ? 1 : -1) * 2.75), each chance(r, 0.7):
    W.cyl(wx, base+0.7, wz, 0.72, 0.72, 0.34, 11, 0x2b2d30, S.POLY, ry + PI/2)
    addCol(wx, base+0.7, wz, 0.5, 0.7, 0.72, ry, S.POLY)
loading ramp: 7 steps at L(8.4 + (i/7)*4.2, 0):
    solid(px, base + 3.0*(1-t)*0.5, pz, 0.32, max(0.06, 3.0*(1-t)*0.5), 2.2, ry,
          vary(0x5c584f, r), S.METAL, S.METAL)
signpost at L(0, 8.5), sb = groundH there:
    W.cyl(sx, sb+2.6, sz, 0.13, 0.11, 2.6, 6, vary(0x5c3f26, r), S.WOOD)
    addCol(sx, sb+2.6, sz, 0.18, 2.6, 0.18, 0, S.WOOD)
    6 boards: a = r()*TAU, y = sb + 2.0 + i*0.5, len = rr(r, 0.9, 1.7)
      deco(sx + cos(a)*len*0.5, y, sz + sin(a)*len*0.5, len/2, 0.11, 0.03, -a,
           vary(pick(r, PAL.wood), r), S.WOOD)
5 fire barrels: a = r()*TAU, rad = rr(r, 11, 17) → barrel(G, …)
bMarket(G, cx-13, cz+12, 11, 9, 0.2)
POIS.push({ x: cx, z: cz, name: 'PLAZA', kind: 'poi' })
```
**GOTCHA in the barrel loop:** the reference calls
`barrel(G, cx + cos(a)*rad, groundH(cx + cos(a)*rad, cz + sin(a)*rad), cz + sin(a)*rad)`
— the ground height is sampled at the correct point, but note `cos(a)` and `sin(a)`
are recomputed inline three times each. Same value, no extra draws.

Also `const [rx0, rz0] = L(9.6, 0)` is computed and never used — dead.

### 15.6 `roofAt(x, z)` and `linkRoofs()`
```js
function roofAt(x, z) {
  for (const b of G.buildings) {
    if (!b || b.ruin || b.market || b.tower) continue;
    const dx = x - b.x, dz = z - b.z;
    const co = Math.cos(-b.ry), si = Math.sin(-b.ry);
    const u = dx*co + dz*si, v = -dx*si + dz*co;
    if (Math.abs(u) < b.w/2 - 0.3 && Math.abs(v) < b.d/2 - 0.3) return b;
  }
  return null;
}
```
(Compounds ARE eligible for `roofAt` but are excluded from being a bridge *source*
in `linkRoofs`.)

```js
function linkRoofs() {
  const done = new Set();
  for (const b of G.buildings) {
    if (!b || b.ruin || b.market || b.tower || b.compound) continue;
    for (let dir = 0; dir < 4; dir++) {
      const a = b.ry + dir * Math.PI/2;
      const ox = Math.cos(a), oz = -Math.sin(a);
      const half = (dir % 2 === 0) ? b.w/2 : b.d/2;
      const ex = b.x + ox*half, ez = b.z + oz*half;
      let target = null, gap = 0;
      for (let g2 = 1.6; g2 < 7.5; g2 += 0.5) {          // probe 1.6 … 7.1 m
        const t = roofAt(ex + ox*(g2 + 0.6), ez + oz*(g2 + 0.6));
        if (t && t !== b) { target = t; gap = g2; break; }
      }
      if (!target) continue;
      if (Math.abs(target.roofY - b.roofY) > 1.35) continue;    // too big a step
      const key = [min(idx(b), idx(target)), max(idx(b), idx(target))].join('_');
      if (done.has(key)) continue; done.add(key);
      if (!chance(r, 0.72)) continue;
      const y = Math.max(b.roofY, target.roofY) + 0.08;
      const mx = ex + ox*(gap + 0.6)/2, mz = ez + oz*(gap + 0.6)/2;
      const pry = Math.atan2(-oz, ox);
      const bw = rr(r, 0.45, 0.72);
      solid(mx, y, mz, (gap + 1.7)/2, 0.06, bw, pry, vary(pick(r, PAL.wood), r), S.WOOD, S.WOOD);
      if (chance(r, 0.45)) {
        deco(mx, y + 0.55, mz, (gap + 1.7)/2, 0.025, 0.025, pry, 0x4a4c50, S.METAL);
        for (const s of [-1, 1])
          deco(mx + s*ox*gap*0.4, y + 0.28, mz + s*oz*gap*0.4, 0.025, 0.28, 0.025, 0, 0x4a4c50, S.METAL);
      }
    }
  }
}
```
Constants: probe range **1.6 → 7.5 step 0.5**, probe lead **+0.6 m**, max roof-height
difference **1.35 m**, plank chance **0.72**, plank length `gap + 1.7`, half-width
`rr(r, 0.45, 0.72)`, deck half-thickness **0.06**, rail chance **0.45**.
The `done` set is keyed on the unordered index pair so each link is built once.
`ox = cos(a)`, `oz = -sin(a)` is the local +X of angle `a` — consistent with §10.1.

### 15.7 `layoutTown()`
```js
const T = 118;
ROADS.push({ x0: -8,     z0: -T - 40, x1: -8,    z1: T + 6, w: 11.5 });  // main strip N-S
ROADS.push({ x0: -T - 6, z0: 16,      x1: T + 6, z1: 16,    w:  9.5 });  // cross street
const quads = [
  { x0: -T,   z0: -T,   x1: -12.5, z1: 11.2 },
  { x0: -2.5, z0: -T,   x1:  T,    z1: 11.2 },
  { x0: -T,   z0:  20.8, x1: -12.5, z1: T   },
  { x0: -2.5, z0:  20.8, x1:  T,    z1: T   },
];
const widths = [8.5, 6.5, 5.0, 4.0, 3.4];
for (const q of quads) bsp(q, 4, BLOCKS, r, widths);
buildPlaza();
```
Then per block: `bw`, `bd`, centre `(cx, cz)`.

**Plaza apron** — if `hypot(cx - 4, cz - 6) < 26 + min(bw,bd)*0.4`: place 4 props at
`rr(r, blk.x0, blk.x1) × rr(r, blk.z0, blk.z1)`, skipping any within 11 m of the
plaza centre; `chance(r, 0.5) ? barrel : crate(…, r()*3)`. Then `continue`.

**Big-structure roll** `k = r()`, `dCore = hypot(cx, cz)`:
* `bw > 26 && bd > 22 && k < 0.20` → `bWarehouse(G, cx, cz, bw-3, bd-3, ri(r,0,1) * PI/2)`
* `bw > 24 && bd > 24 && k < 0.30` → `bCompound(G, cx, cz, bw-3, bd-3, 0)`

**Otherwise** `lots(blk, r, L, 9.5)` and per lot:
```
lw = (lot.x1-lot.x0) - rr(r, 1.0, 2.6);   ld = (lot.z1-lot.z0) - rr(r, 1.0, 2.6)
if (lw < 5 || ld < 5) continue
lx = midX + rr(r,-0.6,0.6);  lz = midZ + rr(r,-0.6,0.6)
ry = chance(r, 0.86) ? 0 : rr(r, -0.12, 0.12)
q = r()
```
| `q` | result |
|---|---|
| `< 0.13` | `bRuin(G, lx, lz, lw, ld, ry)` |
| `< 0.21` | container row: `n = max(1, floor(lw/6.4))`, `bContainers(G, lx + (i-(n-1)/2)*2.9, lz, ry + PI/2, 3)` |
| `< 0.27` and `lw > 11 && ld > 9` | `bMarket(G, lx, lz, lw, ld, ry)` |
| `< 0.33` | **yard** (below) |
| else | **house** (below) |

**Yard:** `ri(r, 3, 8)` props at `rr(r, lot.x0+1, lot.x1-1) × rr(r, lot.z0+1, lot.z1-1)`,
`u = r()`: `<0.30` barrel · `<0.55` crate · `<0.72` sandbags · `<0.85` wreck · else bigCrate.
Then `chance(r, 0.5)` → a 7-post fence along `z = lot.z0 + 0.4`:
```js
for (let i = 0; i <= 6; i++) {
  const px = lerp(lot.x0, lot.x1, i/6), pz = lot.z0 + 0.4, b = groundH(px, pz);
  W.cyl(px, b + 0.9, pz, 0.045, 0.045, 0.9, 5, 0x4a4c50, S.METAL);
  addCol(px, b + 0.9, pz, 0.07, 0.9, 0.07, 0, S.METAL);
}
deco((lot.x0+lot.x1)/2, groundH(lot.x0, lot.z0) + 1.72, lot.z0 + 0.4,
     (lot.x1-lot.x0)/2, 0.03, 0.03, 0, 0x4a4c50, S.METAL);   // top rail
```

**House:** floors chosen by distance to the core,
```js
let floors = 1;
const pr = r();
const near = 1 - smoothstep(20, 110, dCore);
if (pr < 0.22 + near*0.44) floors = 2;
if (pr < 0.07 + near*0.28) floors = 3;
if (pr < 0.02 + near*0.10) floors = 4;
if (lw < 7 || ld < 7) floors = Math.min(floors, 2);
const doorSide = Math.abs(lot.z0 - blk.z0) < Math.abs(lot.x0 - blk.x0) ? 0 : 3;
G.buildings.push(bAdobe(G, lx, lz, lw, ld, floors, ry, { doorSide }));
```
At `dCore = 0` the probabilities are 66 % / 35 % / 12 % for ≥2 / ≥3 / 4 floors; at
`dCore ≥ 110` they collapse to 22 % / 7 % / 2 %.

**After the block loop:**
```js
G.buildings.push(bTower(G, -62, -48));
G.buildings.push(bTower(G,  74,  66));
linkRoofs();
```

**Street clutter** — 46 items:
```js
for (let i = 0; i < 46; i++) {
  const t = rr(r, -1, 1);
  const along = chance(r, 0.5);
  const px = along ? -8 + rr(r, -9, 9) : t * T;
  const pz = along ? t * T : 16 + rr(r, -8, 8);
  if (Math.hypot(px - PLAZA.x, pz - PLAZA.z) < 13) continue;
  const b = groundH(px, pz), u = r();
  if      (u < 0.25) barrel(G, px, b, pz);
  else if (u < 0.45) wreck(G, px, pz, r()*3);
  else if (u < 0.62) crate(G, px, b, pz, r()*3);
  else if (u < 0.78) sandbags(G, px, b, pz, r()*3);
  else { W.cyl(px, b + 2.6, pz, 0.08, 0.07, 2.6, 6, 0x4a4c50, S.METAL);
         addCol(px, b + 2.6, pz, 0.11, 2.6, 0.11, 0, S.METAL);
         deco(px + 0.5, b + 5.0, pz, 0.5, 0.06, 0.06, 0, 0x4a4c50, S.METAL); }  // street lamp
}
```
**GOTCHA:** `t` and `along` are drawn *before* the `continue` check, so the skipped
iterations still consume 2 draws. Reproduce the order exactly.

Finally the two `powerLine` calls from §14.9.

---

## 16. The wilds, POIs, exfils

### 16.1 `scatterWilds()`
```js
const r = rng(WORLD_SEED ^ 0x77E5);       // LOCAL stream for placement only
for (let i = 0; i < 260; i++) {
  const a = r()*TAU, rad = 140 + Math.pow(r(), 0.6) * 300;   // 140 … 440 m, biased outward
  const x = Math.cos(a)*rad, z = Math.sin(a)*rad;
  if (Math.abs(x) > 430 || Math.abs(z) > 430) continue;
  const h = groundH(x, z), n = groundNormal(x, z);
  if (n.y < 0.72) continue;                                  // nothing on dune faces
  const u = r();
  if      (u < 0.34) rockCluster(G, x, z);
  else if (u < 0.56) deadTree(G, x, z);
  else if (u < 0.66) wreck(G, x, z, r()*3);
  else if (u < 0.74) { for (let j = 0; j < ri(r, 2, 5); j++)
                         barrel(G, x + rr(r,-3,3), groundH(x + rr(r,-3,3), z), z + rr(r,-3,3)); }
  else if (u < 0.80) bContainers(G, x, z, r()*3, 2);
  else if (u < 0.86) { const a2 = r()*TAU, n2 = ri(r, 5, 14);
                       for (let j = 0; j < n2; j++) {
                         const px = x + Math.cos(a2)*j*2.4, pz = z + Math.sin(a2)*j*2.4;
                         const b = groundH(px, pz);
                         W.cyl(px, b + 0.85, pz, 0.05, 0.05, 0.85, 5, vary(0x5c3f26, r), S.WOOD);
                         addCol(px, b + 0.85, pz, 0.08, 0.85, 0.08, 0, S.WOOD); } }
  else if (u < 0.93) crate(G, x, h, z, r()*3);
  else deadTree(G, x, z);
}
```
**GOTCHA — two rng streams interleave.** `r` here is the wilds stream; every
generator called (`rockCluster`, `deadTree`, `wreck`, `barrel`, `bContainers`,
`crate`, `bAdobe`, `bRuin`) reads `G.r`. But `vary(0x5c3f26, r)` in the fence branch
uses the **local** `r`. Both must advance in exactly this order.

**GOTCHA — the barrel-cluster branch draws `rr(r,-3,3)` three separate times**
(x offset for the placement, x offset again inside `groundH`, z offset), so the
barrel's x position and the x used for its ground height are **different values**.
Faithful port = keep the bug (barrels float/sink slightly); it is one of the things
that makes the wilds read as scattered rather than placed.

**Outlying camps:**
```js
const camps = [[-236, 118], [214, -168], [-176, -244], [262, 262]];
for (const [cx, cz] of camps) {
  const nb = ri(r, 2, 4);
  for (let i = 0; i < nb; i++) {
    const a = r()*TAU, rad = rr(r, 4, 14);
    const x = cx + Math.cos(a)*rad, z = cz + Math.sin(a)*rad;
    if (groundNormal(x, z).y < 0.8) continue;
    if (chance(r, 0.55))      G.buildings.push(bAdobe(G, x, z, rr(r,6,9), rr(r,6,9), 1, r()*TAU));
    else if (chance(r, 0.5))  bContainers(G, x, z, r()*TAU, 2);
    else                      G.buildings.push(bRuin(G, x, z, rr(r,6,10), rr(r,6,10), r()*TAU));
  }
  for (let i = 0; i < 6; i++) {
    const a = r()*TAU, rad = rr(r, 3, 18);
    const x = cx + Math.cos(a)*rad, z = cz + Math.sin(a)*rad;
    chance(r, 0.5) ? barrel(G, x, groundH(x, z), z) : wreck(G, x, z, r()*TAU);
  }
  POIS.push({ x: cx, z: cz, name: 'CAMP', kind: 'poi' });
}
```

**Crash site** — `ax = -300, az = 132`:
```js
for (let i = 0; i < 9; i++) {
  const t = i / 9;
  const px = ax + t*34, pz = az + Math.sin(t*3)*6, b = groundH(px, pz);
  solid(px, b + 1.2 + t*1.6, pz, 2.0, 1.5 - t*0.7, 1.9 - t*0.8, 0.4 + t*0.2,
        vary(0x6a6d73, r, 0.1), S.TIN, S.TIN);
}
for (const s of [-1, 1])
  solid(ax + 8, groundH(ax + 8, az) + 3.4, az + s*9, 9, 0.22, 2.4, s*0.28, 0x63656a, S.TIN, S.TIN);
POIS.push({ x: ax + 16, z: az, name: 'CRASH', kind: 'poi' });   // (-284, 132)
```
The fuselage segments taper and rise along `t`, giving a spine climbing out of the
sand; the two wings are 18 × 4.8 m slabs canted ±0.28 rad.

### 16.2 `POIS` — the complete list
| name | kind | source | count |
|---|---|---|---|
| `PLAZA` | poi | `buildPlaza` | 1, at (4, 6) |
| `MARKET` | poi | every `bMarket` call | ≥1 (plaza market + any lot markets) |
| `TOWER` | poi | every `bTower` call | 2, at (−62, −48) and (74, 66) |
| `CAMP` | poi | `scatterWilds` | 4, at (−236,118) (214,−168) (−176,−244) (262,262) |
| `CRASH` | poi | `scatterWilds` | 1, at (−284, 132) |
| `CULVERT` | exfil | `placeExfils` | 1 |
| `NORTH GATE` | exfil | `placeExfils` | 1 |
| `ROOFTOP LZ` | exfil | `placeExfils` | 1 |

### 16.3 `placeExfils()`
```js
const mk = (x, z, y, name) => {
  EXFILS.push({ x, z, y, name, r: 4.6, held: 0 });
  POIS.push({ x, z, name, kind: 'exfil' });
};
// 1 — down in the wadi
const wz = 196, wx = wadiX(wz);           // wadiX(196) ≈ 196*0.62 - 34 + sin(3.724)*26 + sin(3.3916)*44
mk(wx, wz, groundH(wx, wz), 'CULVERT');
// 2 — north road, out past the last pole
const nz = -236, nx = -8 + Math.sin(nz * 0.008) * 18;
mk(nx, nz, groundH(nx, nz), 'NORTH GATE');
// 3 — the tallest wide roof in town proper
let best = null;
for (const b of G.buildings) {
  if (!b || b.ruin || b.tower || b.market || !b.roofY) continue;
  if (Math.hypot(b.x, b.z) > 105) continue;
  if (Math.min(b.w, b.d) < 11) continue;
  const rise = b.roofY - b.base;
  if (!best || rise > best.rise) best = { b, rise };
}
if (best) mk(best.b.x, best.b.z, best.b.roofY, 'ROOFTOP LZ');
else      mk(40, 40, groundH(40, 40), 'ROOFTOP LZ');
```
Filters: within **105 m** of the origin, `min(w, d) ≥ 11 m` (wide enough to land on),
ranked by `roofY − base`. Warehouses and compounds qualify (a warehouse's `roofY`
carries the §13.2 missing-`base` bug, which flatters it slightly).

**GOTCHA:** `NORTH GATE` uses `-8 + sin(nz*0.008)*18` while `terrainH`'s rim-road
shelf is centred on `-8 - sin(z*0.008)*18`. At `z = -236` those are 15.4 m apart, so
the pad sits off the graded shelf. Reference bug; decide and record.

**Pad furniture**, built for every exfil:
```js
const seg = 16;
for (let i = 0; i < seg; i++) {          // painted ring
  const a0 = i/seg*TAU, a1 = (i+1)/seg*TAU;
  W.seg(e.x + cos(a0)*e.r, e.y + 0.03, e.z + sin(a0)*e.r,
        e.x + cos(a1)*e.r, e.y + 0.03, e.z + sin(a1)*e.r, 0.11, 0xd8822f, S.CONCRETE);
}
for (let i = 0; i < 4; i++) {            // corner posts + flags
  const a = i/4*TAU + 0.4;
  const px = e.x + cos(a)*(e.r + 0.5), pz = e.z + sin(a)*(e.r + 0.5);
  W.cyl(px, e.y + 1.35, pz, 0.07, 0.06, 1.35, 6, 0x4a4c50, S.METAL);
  addCol(px, e.y + 1.35, pz, 0.1, 1.35, 0.1, 0, S.METAL);
  W.box(px, e.y + 2.75, pz, 0.34, 0.24, 0.03, -a, 0xd8822f, S.TIN);
}
barrel(G, e.x + e.r*0.75, e.y, e.z + e.r*0.75);
```
`e.r = 4.6` (the trigger radius AND the ring radius). Accent colour `0xd8822f`.

---

## 17. MOVEMENT

Quake-lineage: separate ground and air controllers, air-strafe acceleration, a
slope-aware slide, an auto-vault, and step-up smoothing.
**All of this is a kinematic controller over §11's box array. Do NOT reimplement it
as a Godot `CharacterBody3D.move_and_slide()` — the feel comes from these exact
resolution rules.** A `Node3D` with hand-rolled integration is the right shape.

### 17.1 `MV` — every tunable, verbatim
```js
const MV = {
  gravity: 21.5,
  walk: 4.35, sprint: 7.5, crouchSpd: 2.15, adsMul: 0.52,
  accel: 13.5, airAccel: 92, airWish: 1.15, friction: 10.5, stopSpeed: 3.0,
  jump: 6.8, step: 0.58, radius: 0.34,
  standH: 1.80, crouchH: 1.12, standEye: 1.66, crouchEye: 0.90,
  slideBoost: 1.30, slideMin: 8.2, slideMax: 19.5, slideFric: 0.85, slideSteer: 4.6,
  coyote: 0.11, jumpBuf: 0.13, maxSpeed: 22,
};
```
`maxSpeed: 22` is declared and **never read** — the only speed cap is `slideMax`
during a slide and the −60 m/s terminal velocity. `adsMul: 0.52` is the ADS
movement multiplier.

```gdscript
@export_group("Movement")
@export var gravity: float = 21.5
@export_range(0.0, 20.0) var walk: float = 4.35
@export_range(0.0, 20.0) var sprint: float = 7.5
@export_range(0.0, 20.0) var crouch_spd: float = 2.15
@export_range(0.0, 1.0) var ads_mul: float = 0.52
@export var accel: float = 13.5
@export var air_accel: float = 92.0
@export var air_wish: float = 1.15
@export var friction: float = 10.5
@export var stop_speed: float = 3.0
@export var jump_vel: float = 6.8
@export_range(0.0, 1.5) var step_height: float = 0.58
@export_range(0.1, 1.0) var radius: float = 0.34
@export var stand_h: float = 1.80
@export var crouch_h: float = 1.12
@export var stand_eye: float = 1.66
@export var crouch_eye: float = 0.90
@export var slide_boost: float = 1.30
@export var slide_min: float = 8.2
@export var slide_max: float = 19.5
@export var slide_fric: float = 0.85
@export var slide_steer: float = 4.6
@export_range(0.0, 0.5) var coyote: float = 0.11
@export_range(0.0, 0.5) var jump_buf: float = 0.13
```

### 17.2 Player state
```js
const P   = new THREE.Vector3();   // FEET position, not centre, not eye
const VEL = new THREE.Vector3();
const PL = {
  yaw: Math.PI, pitch: 0, roll: 0,
  h: MV.standH, eye: MV.standEye, crouchT: 0,
  grounded: false, wasGrounded: false, groundY: 0, groundSurf: S.SAND,
  gnorm: new THREE.Vector3(0, 1, 0),
  coyote: 0, jumpBuf: 0, jumpHeld: false, bumped: false, bumpN: new THREE.Vector3(),
  sliding: false, slideT: 0, slideLock: 0, sprint: false, ads: 0, adsWant: 0,
  stamina: 100, staminaLock: 0, lean: 0, leanWant: 0,
  camY: 0, camYVel: 0, bobT: 0, bobStep: 0, landDip: 0, landVel: 0,
  fov: 78, speed: 0, air: 0, freecam: false, ladder: null, ladderY: 0,
  mantle: null, lastStepSurf: S.SAND, fallStart: 0, exfil: null,
};
```
`P` is the **feet**. Eye height is added only in `updateCamera`.
`PL.groundY`, `PL.camYVel`, `PL.ladderY`, `PL.eye`, `PL.lastStepSurf` are declared
and never used — do not port them.

### 17.3 Input
```js
const KEY = {};                                          // keyed by KeyboardEvent.code
const MOUSE = { dx: 0, dy: 0, down: false, right: false, sens: 0.00185 };
let locked = false;
```
Mouse sensitivity **0.00185 rad per pixel of `movementX`**; accumulated per frame and
zeroed inside `updateMovement`.

Bindings (from the keydown handler and the menu):

| key | action |
|---|---|
| `KeyW/A/S/D` | move |
| `ShiftLeft`/`ShiftRight` | sprint (only with `iz > 0`) |
| `Space` | jump / bhop hold / mantle / ladder up / freecam up |
| `ControlLeft`/`ControlRight`/`KeyC` | crouch, slide when sprinting, freecam down |
| `KeyQ` / `KeyE` | lean left / right |
| `Mouse 2` | ADS |
| `Mouse 1` | fire |
| `KeyR` | reload |
| `Digit1`–`Digit4`, wheel | weapon select / cycle |
| `KeyF` | scavenge new weapon |
| `KeyV` | toggle freecam |
| `KeyH` | toggle HUD |
| `KeyM` | mute · `Minus`/`Equal` volume ∓0.1 |
| `Escape` | release pointer lock |

`e.repeat` events are dropped. On `Space` keydown: `PL.jumpBuf = MV.jumpBuf; PL.jumpHeld = true`.
On blur every key is cleared and `jumpHeld`/`MOUSE.down` reset.

In Godot use `Input.get_axis`/`is_action_pressed` with an `InputMap` and
`Input.MOUSE_MODE_CAPTURED`; feed `InputEventMouseMotion.relative` into
`MOUSE.dx/dy` and zero them each `_physics_process`.

### 17.4 `resolveXZ(dt)` — 3 passes, step-up folded in
```js
function resolveXZ(dt) {
  PL.bumped = false;
  const r = MV.radius;                                   // 0.34
  for (let pass = 0; pass < 3; pass++) {
    let hit = false;
    queryCols(P.x, P.z, r + 1.4, _cols);
    for (const c of _cols) {
      const lo = P.y + 0.02, hi = P.y + PL.h;
      const bLo = c.y - c.hy, bHi = c.y + c.hy;
      if (bHi <= lo || bLo >= hi) continue;              // vertical miss
      const p = circleBox(P.x, P.z, r, c);
      if (!p) continue;
      const rise = bHi - P.y;
      if (rise > 0.001 && rise <= MV.step && (PL.grounded || PL.coyote > 0) &&
          canStand(P.x, P.z, bHi + 0.02, PL.h)) {
        PL.camY -= (bHi + 0.02 - P.y);                   // camera stays put -> smooth stairs
        P.y = bHi + 0.02; PL.grounded = true; PL.groundSurf = c.surf;
        PL.gnorm.set(0, 1, 0); hit = true; continue;
      }
      P.x += p.nx * (p.d + 0.0012); P.z += p.nz * (p.d + 0.0012);
      const vn = VEL.x * p.nx + VEL.z * p.nz;
      if (vn < 0) { VEL.x -= vn * p.nx; VEL.z -= vn * p.nz;
        if (!PL.bumped) { PL.bumped = true; PL.bumpN.set(-p.nx, 0, -p.nz); } }
      hit = true;
    }
    if (!hit) break;
  }
}
```
Key numbers: **3** passes, vertical foot slack **+0.02**, push-out epsilon **0.0012**,
step-up requires `0.001 < rise ≤ 0.58` **and** grounded-or-coyote **and** head room.
`PL.bumpN` is the **inward** normal (into the wall), used by the auto-vault.

`PL.camY -= …` is the stair smoother: the feet snap up instantly, the camera lags
and is damped back to 0 at rate 15 in `postMove`.

### 17.5 `resolveY(dt)`
```js
function resolveY(dt) {
  const r = MV.radius;
  PL.grounded = false;
  const g = groundH(P.x, P.z);
  if (P.y <= g) {
    P.y = g; if (VEL.y < 0) VEL.y = 0;
    PL.grounded = true; PL.groundSurf = surfaceAtGround(P.x, P.z);
    PL.gnorm.copy(groundNormal(P.x, P.z));
  }
  const SKIN = 0.045;                    // without it `grounded` flickers on box tops
  queryCols(P.x, P.z, r + 1.4, _cols);
  for (const c of _cols) {
    const bLo = c.y - c.hy, bHi = c.y + c.hy;
    const pLo = P.y, pHi = P.y + PL.h;
    if (bHi <= pLo - SKIN || bLo >= pHi) continue;
    if (!overlapsXZ(P.x, P.z, r, c)) continue;
    const up = bHi - pLo, down = pHi - bLo;
    if (up <= down) {
      if (up < 0.85) { if (up > 0) P.y = bHi; else P.y = Math.min(P.y, bHi);
        if (VEL.y < 0) VEL.y = 0;
        PL.grounded = true; PL.groundSurf = c.surf; PL.gnorm.set(0, 1, 0); }
    } else if (down < 0.85) {
      P.y = bLo - PL.h; if (VEL.y > 0) VEL.y = 0;   // bonked head
    }
  }
}
```
`SKIN = 0.045` is the contact tolerance — resting exactly on a box top otherwise
toggles `grounded` every other frame, which stutters footsteps and eats jump
inputs. The **0.85 m** guard on both `up` and `down` stops the resolver from
teleporting you through a thick collider.

### 17.6 `snapDown()`
```js
function snapDown() {
  if (PL.grounded || VEL.y > 0.9 || PL.mantle || PL.ladder) return;
  const probe = 0.52;
  const t = topAt(P.x, P.z, P.y - probe, P.y - 0.005);
  if (t !== null) {
    let clear = true;
    queryCols(P.x, P.z, MV.radius + 1.2, _cols);
    for (const c of _cols) { const bH = c.y + c.hy;
      if (Math.abs(bH - t) < 0.02 && overlapsXZ(P.x, P.z, MV.radius, c)) { PL.groundSurf = c.surf; break; } }
    if (clear) {
      PL.camY -= (t - P.y);
      P.y = t; VEL.y = 0; PL.grounded = true;
      if (Math.abs(t - groundH(P.x, P.z)) < 0.02) {
        PL.groundSurf = surfaceAtGround(P.x, P.z); PL.gnorm.copy(groundNormal(P.x, P.z));
      } else PL.gnorm.set(0, 1, 0);
    }
  }
}
```
Probe depth **0.52 m**, upward guard `VEL.y > 0.9`.
**`clear` is initialised `true` and never set false — the loop only sets
`PL.groundSurf`.** Dead branch; keep the behaviour (always snap), drop the variable.

### 17.7 `integrate(dt)` — substepping
```js
function integrate(dt) {
  const sp3 = Math.hypot(VEL.x, VEL.y, VEL.z);
  const steps = clamp(Math.ceil(sp3 * dt / 0.16), 1, 8);
  const sdt = dt / steps;
  for (let i = 0; i < steps; i++) {
    P.x += VEL.x * sdt; P.z += VEL.z * sdt;
    resolveXZ(sdt);
    P.y += VEL.y * sdt;
    resolveY(sdt);
    if (!PL.grounded && PL.wasGrounded && VEL.y <= 0.2 && !PL.ladder) snapDown();
  }
  if (P.y < -80) respawn();
}
```
Substep target **0.16 m of travel**, clamped to **1…8** steps. XZ is resolved before
Y is applied — order matters. Void kill plane at **y < −80**.

### 17.8 `accelerate` / `applyFriction` — Quake, verbatim
```js
function accelerate(wx, wz, wishSpeed, accel, dt) {
  const cur = VEL.x * wx + VEL.z * wz;     // current speed along the wish dir
  const add = wishSpeed - cur;
  if (add <= 0) return;                    // already at/over wish speed: no push
  let a = accel * wishSpeed * dt;
  if (a > add) a = add;
  VEL.x += a * wx; VEL.z += a * wz;
}
function applyFriction(f, dt) {
  const sp = Math.hypot(VEL.x, VEL.z);
  if (sp < 0.02) { VEL.x = 0; VEL.z = 0; return; }
  const ctrl = Math.max(sp, MV.stopSpeed);   // stopSpeed = 3.0
  const ns = Math.max(0, sp - ctrl * f * dt) / sp;
  VEL.x *= ns; VEL.z *= ns;
}
```
`accelerate` is what makes air-strafing work: in the air `wishSpeed = 1.15` so the
`add <= 0` early-out almost never fires when the wish direction is perpendicular to
the velocity, and `accel * wishSpeed * dt = 92 * 1.15 * dt` is added sideways every
frame. Any "fix" that clamps total speed kills bunny-hopping.

```gdscript
## Quake ground/air acceleration. Adds velocity along `wish` only up to
## `wish_speed` measured ALONG that direction — which is why strafing in the air
## adds speed without ever raising the projected speed past the cap.
func accelerate(wx: float, wz: float, wish_speed: float, acc: float, dt: float) -> void:
	var cur: float = vel.x * wx + vel.z * wz
	var add: float = wish_speed - cur
	if add <= 0.0:
		return
	var a: float = minf(acc * wish_speed * dt, add)
	vel.x += a * wx
	vel.z += a * wz
```

### 17.9 The mantle
```js
function tryMantle(auto) {
  if (PL.mantle || PL.ladder || PL.freecam) return false;
  const fx = -Math.sin(PL.yaw), fz = -Math.cos(PL.yaw);
  const maxRise = auto ? 1.32 : 2.05;
  for (const d of [0.42, 0.66, 0.92, 1.18]) {
    const px = P.x + fx*d, pz = P.z + fz*d;
    const t = topAt(px, pz, P.y + 0.18, P.y + maxRise);
    if (t === null) continue;
    // if the "ledge" is just the ground sloping up, walk it instead of vaulting
    if (Math.abs(t - groundH(px, pz)) < 0.07 && (t - P.y) / d < 1.15) continue;
    const lx = px + fx*0.30, lz = pz + fz*0.30;                 // landing point
    if (!canStand(lx, lz, t + 0.05, MV.crouchH + 0.06)) continue;
    const rise = t - P.y;
    PL.mantle = {
      t: 0, dur: clamp(0.19 + rise*0.115, 0.20, 0.42),
      x0: P.x, y0: P.y, z0: P.z, x1: lx, y1: t + 0.02, z1: lz,
      keep: Math.min(Math.hypot(VEL.x, VEL.z), 7.5),
    };
    VEL.set(0, 0, 0);
    PL.sliding = false;
    sfx.mantle(rise);
    return true;
  }
  return false;
}
```
Probe distances **0.42 / 0.66 / 0.92 / 1.18 m**; rise window **+0.18 … +1.32**
(auto) or **+2.05** (manual, i.e. Space); landing pushed **0.30 m** past the probe;
head-room check needs only crouch height **1.18 m** — the stance logic keeps you
ducked up there. Duration `clamp(0.19 + rise*0.115, 0.20, 0.42)` s. Carried speed
capped at **7.5 m/s**.

```js
function stepMantle(dt) {
  const m = PL.mantle; m.t += dt;
  const k = clamp(m.t / m.dur, 0, 1);
  const ky = k < 0.62 ? Math.pow(k / 0.62, 0.62) : 1;            // up first
  const kx = k < 0.30 ? 0 : Math.pow((k - 0.30) / 0.70, 1.35);   // then across
  P.set(lerp(m.x0, m.x1, kx), lerp(m.y0, m.y1, ky), lerp(m.z0, m.z1, kx));
  PL.camY = lerp(PL.camY, -0.10, 1 - Math.exp(-14 * dt));
  if (k >= 1) {
    const fx = -Math.sin(PL.yaw), fz = -Math.cos(PL.yaw);
    const sp = Math.max(2.4, m.keep * 0.62);
    VEL.set(fx*sp, 0.4, fz*sp);
    PL.mantle = null; PL.grounded = true;
  }
}
```
The vertical curve finishes at 62 % of the duration with a `pow(·, 0.62)` ease-out;
the horizontal starts at 30 % with a `pow(·, 1.35)` ease-in. That overlap is what
makes it read as "up and over" rather than a diagonal slide. Exit velocity is
`max(2.4, keep*0.62)` forward plus **0.4 m/s** up. Camera dips to −0.10 at rate 14.

### 17.10 The ladder
```js
function findLadder() {
  let best = null, bd = 1e9;
  for (const L of LADDERS) {
    if (P.y + PL.h < L.y0 - 0.35 || P.y > L.y1 + 0.25) continue;
    const dx = P.x - L.x, dz = P.z - L.z;
    const lx = dx*L.co - dz*L.si, lz = dx*L.si + dz*L.co;
    if (Math.abs(lx) > L.hx || lz < -0.45 || lz > L.hz) continue;   // hx 0.78, hz 0.95
    const d = Math.abs(lx)*0.6 + Math.abs(lz);
    if (d < bd) { bd = d; best = L; }
  }
  return best;
}
function ladderTopOut(L) {
  for (const dir of [-1, 1]) {                    // roof side first, then outward
    const tx = L.x + L.si*0.85*dir, tz = L.z + L.co*0.85*dir;
    const top = topAt(tx, tz, P.y - 0.75, P.y + 1.0);
    if (top === null) continue;
    if (!canStand(tx, tz, top + 0.05, MV.crouchH + 0.06)) continue;
    P.set(tx, top + 0.03, tz); VEL.set(0, 0, 0);
    PL.ladder = null; PL.grounded = true; PL.camY -= 0.12;
    return true;
  }
  return false;
}
```
`LADDERS` is a **linear scan** — there are on the order of a few hundred; at 60 Hz
that is fine, but `findLadder()` is called **twice per frame** (once in
`updateMovement`, once in `updateHUD` for the climb prompt). Cache the result.

The controller (inside `updateMovement`, gravity and friction do not apply):
```js
const outX = L.si, outZ = L.co;                     // ladder's local +Z = away from wall
const pressIn = moving ? -(wx*outX + wz*outZ) : 0;
if (PL.ladder === L || pressIn > 0.12 || KEY.Space) {
  PL.ladder = L; PL.sliding = false; PL.grounded = false; PL.coyote = 0;
  let cl;
  if (KEY.Space)            cl =  1.0;
  else if (pressIn >  0.12) cl =  1.0;     // walk into it, go up (Minecraft rules)
  else if (pressIn < -0.45) cl = -1.0;     // back off, come down
  else                      cl = -0.14;    // hang, sinking slowly
  VEL.y = cl * (cl > 0 ? 3.3 : 3.9);       // up 3.3 m/s, down 3.9 m/s, hang -0.546
  const tx = L.x + outX*0.20, tz = L.z + outZ*0.20;          // stand-off from the rungs
  const perp = ((tx - P.x)*outX + (tz - P.z)*outZ) * 7.0;
  const alongIn = moving ? (wx*L.co - wz*L.si) : 0;          // local +X = (co, -si)
  const along = alongIn * 2.4;                                // shimmy
  VEL.x = outX*perp + L.co*along;
  VEL.z = outZ*perp - L.si*along;
  if (cl > 0 && P.y > L.y1 - 0.75 && ladderTopOut(L)) { postMove(dt, moving); return; }
  if (P.y >= L.y1 + 0.15) PL.ladder = null;
  if (P.y < L.y0 - 0.25 && cl < 0) PL.ladder = null;
  if (PL.jumpBuf > 0 && pressIn <= 0.12) {                    // kick off the wall
    PL.jumpBuf = 0; PL.ladder = null;
    VEL.x = outX*5.0; VEL.z = outZ*5.0; VEL.y = 4.4;
  }
  PL.bobT += dt * Math.abs(cl) * 7.5;
  if (PL.bobT - PL.bobStep > Math.PI) { PL.bobStep = PL.bobT; sfx.step(S.METAL, 0.30); }
  integrate(dt);
  PL.jumpBuf = Math.max(0, PL.jumpBuf - dt);
  postMove(dt, moving);
  return;
}
PL.ladder = null;
```
Constants: attach threshold `pressIn > 0.12`, descend threshold `pressIn < -0.45`,
hang rate `-0.14 × 3.9 = -0.546 m/s`, stand-off **0.20 m** with spring gain **7.0**,
shimmy speed **2.4 m/s**, top-out trigger `P.y > y1 - 0.75`, detach above `y1 + 0.15`
or below `y0 - 0.25`, wall-kick **(5.0 out, 4.4 up)**, climb bob rate **7.5**.

**GOTCHA — `KEY.Space` is checked directly, not `PL.jumpBuf`.** Holding Space
climbs; tapping it while not pressing in kicks off. Both branches read the same key
in the same frame, and the kick branch runs after `VEL` was already set by the climb
branch. Keep the order.

### 17.11 `updateMovement(dt)` — the full order of operations

This function's ordering is the spec. Anything reordered changes the feel.

```
1. PL.wasGrounded = PL.grounded
2. look (only if pointer-locked):
     PL.yaw   -= MOUSE.dx * MOUSE.sens * (PL.ads > 0.5 ? 0.62 : 1)
     PL.pitch -= MOUSE.dy * MOUSE.sens * (PL.ads > 0.5 ? 0.62 : 1)
     PL.pitch  = clamp(PL.pitch, -1.53, 1.53)
   MOUSE.dx = MOUSE.dy = 0        (always, locked or not)
3. if (PL.freecam) { updateFreecam(dt); return; }
4. wish direction:
     ix = D - A;  iz = W - S
     fx = -sin(yaw), fz = -cos(yaw)       // forward
     sx =  cos(yaw), sz = -sin(yaw)       // right
     wx = fx*iz + sx*ix;  wz = fz*iz + sz*ix
     normalise if |w| > 0.0001;  moving = |w| > 0.0001
5. stance:
     wantCrouch = CtrlL || CtrlR || KeyC
     speedNow   = hypot(VEL.x, VEL.z)      // captured BEFORE this frame's accel
     PL.sprint  = Shift && iz > 0 && !wantCrouch && PL.stamina > 1 && PL.ads < 0.4
6. slide entry / maintenance   (see below)
7. crouching = (wantCrouch || sliding) || !canStand(P.x, P.z, P.y + 0.02, standH)
   PL.crouchT = damp(PL.crouchT, crouching ? 1 : 0, sliding ? 22 : 13, dt)
   PL.h = lerp(standH, crouchH, PL.crouchT)
8. if (PL.mantle) { stepMantle(dt); postMove(dt, moving); return; }
9. ladder controller (§17.10) — returns early if attached
10. ground OR air controller (see below)
11. PL.jumpBuf = max(0, PL.jumpBuf - dt)
12. vault triggers (see below)
13. if (PL.mantle) { postMove(dt, moving); return; }   // a vault just started
    integrate(dt)
14. landing detection
15. postMove(dt, moving)
```

Pitch clamp **±1.53 rad** (87.66°). ADS halves look sensitivity to **0.62×** once
`PL.ads > 0.5`.

**Slide (step 6):**
```js
if (wantCrouch && !PL.sliding && PL.grounded && speedNow > 5.0 && PL.slideLock <= 0) {
  PL.sliding = true; PL.slideT = 0; PL.slideLock = 0.30;
  const boost = Math.max(MV.slideMin, Math.min(speedNow * MV.slideBoost, MV.slideMax));
  if (speedNow > 0.01) { VEL.x *= boost/speedNow; VEL.z *= boost/speedNow; }
  PL.stamina = Math.max(0, PL.stamina - 7); PL.staminaLock = 0.5;
  sfx.slide(true);
}
if (PL.sliding) {
  PL.slideT += dt; PL.slideLock -= dt;
  const sp = Math.hypot(VEL.x, VEL.z);
  if (!wantCrouch && PL.slideT > 0.22)          { PL.sliding = false; sfx.slide(false); }
  else if (sp < 2.7 && PL.slideT > 0.28)        { PL.sliding = false; sfx.slide(false); }
  else if (!PL.grounded && PL.air > 0.55)       { PL.sliding = false; sfx.slide(false); }
} else PL.slideLock -= dt;
```
Entry needs **> 5.0 m/s** and `slideLock <= 0`. Boost is
`clamp(speed * 1.30, 8.2, 19.5)` — so entering at 5.1 m/s still snaps you to
**8.2 m/s**. Costs **7 stamina**, locks regen for **0.5 s**, re-entry lock **0.30 s**.
Exits: release crouch after 0.22 s, drop below 2.7 m/s after 0.28 s, or airborne
longer than 0.55 s.

**Ground controller (step 10, `PL.grounded`):**
```js
PL.coyote = MV.coyote; PL.air = 0;
if (PL.sliding) {
  const n = PL.gnorm;
  const gx = -n.x * MV.gravity, gz = -n.z * MV.gravity;     // downhill pull
  const slope = Math.hypot(n.x, n.z);
  VEL.x += gx * 0.92 * dt; VEL.z += gz * 0.92 * dt;
  const uphill = (VEL.x*n.x + VEL.z*n.z) > 0.2;
  applyFriction(MV.slideFric * (uphill ? 3.4 : 1) * (1 - slope*0.55), dt);
  if (moving) accelerate(wx, wz, MV.slideSteer * 0.62, MV.slideSteer, dt);
  const sp = Math.hypot(VEL.x, VEL.z);
  if (sp > MV.slideMax) { VEL.x *= MV.slideMax/sp; VEL.z *= MV.slideMax/sp; }
} else {
  let target = crouching ? MV.crouchSpd : PL.sprint ? MV.sprint : MV.walk;
  if (PL.ads > 0.1 && !PL.sprint) target *= lerp(1, MV.adsMul, PL.ads);
  if (iz < 0) target *= 0.82;                                // backpedal penalty
  if (!(PL.jumpHeld && PL.jumpBuf > 0))                      // no brake on a bhop
    applyFriction(MV.friction * (moving ? 1 : 1.45), dt);
  if (moving) {
    const n = PL.gnorm;                                      // project wish onto the slope
    let px = wx - n.x*(wx*n.x + wz*n.z), pz = wz - n.z*(wx*n.x + wz*n.z);
    const pl = Math.hypot(px, pz) || 1; px /= pl; pz /= pl;
    accelerate(px, pz, target, MV.accel, dt);
  }
}
if (PL.jumpBuf > 0) {
  PL.jumpBuf = 0;
  if (!PL.sliding && tryMantle(false)) { /* a ledge in front wins over a jump */ }
  else {
    VEL.y = MV.jump * (PL.sliding ? 0.92 : 1);
    if (PL.sliding) { PL.sliding = false; sfx.slide(false); PL.slideLock = 0.16; }
    PL.grounded = false; PL.coyote = 0;
    PL.stamina = Math.max(0, PL.stamina - 3.5); PL.staminaLock = 0.30;
    sfx.jump();
  }
}
```
Slide gravity factor **0.92**, uphill friction ×**3.4**, friction scaled by
`(1 - slope*0.55)`, steer wish speed `4.6 * 0.62 = 2.852` at accel 4.6.
Standing friction is **×1.45 when not pressing a direction** — that is the active
brake. Skipping friction while `jumpHeld && jumpBuf > 0` is what makes bunny-hopping
carry speed. Jump costs **3.5 stamina**, locks regen **0.30 s**; slide-jump keeps
**92 %** of jump velocity.

**Air controller (step 10, else):**
```js
PL.air += dt;
PL.coyote -= dt;
if (PL.coyote > 0 && PL.jumpBuf > 0) {
  PL.jumpBuf = 0; VEL.y = MV.jump; PL.coyote = 0;
  PL.stamina = Math.max(0, PL.stamina - 3.5); PL.staminaLock = 0.30; sfx.jump();
}
if (moving) accelerate(wx, wz, MV.airWish, MV.airAccel, dt);   // the strafe trick
VEL.y -= MV.gravity * dt;
if (VEL.y < -60) VEL.y = -60;
```
Terminal velocity **−60 m/s**. Coyote time **0.11 s**, jump buffer **0.13 s**.

**Vault triggers (step 12):**
```js
if (PL.bumped && !PL.mantle) {
  const pressing = moving && (wx*PL.bumpN.x + wz*PL.bumpN.z) > 0.35;
  if (pressing && (PL.grounded || PL.air < 0.5) && speedNow > 2.6) tryMantle(true);
}
if (KEY.Space && !PL.grounded && !PL.mantle && PL.air > 0.05) tryMantle(false);
```
Auto-vault: you must be **pressing into** the wall (dot > 0.35 with the inward
normal), grounded or airborne < 0.5 s, and moving faster than **2.6 m/s** —
using `speedNow`, the speed at the *top* of the frame.
Manual vault: hold Space in the air after **0.05 s**, `maxRise 2.05 m`.

**Landing (step 14):**
```js
if (PL.grounded && !PL.wasGrounded) {
  const fall = PL.fallStart - P.y;
  const impact = clamp(fall / 7, 0, 1);
  PL.landVel -= 0.13 + impact * 0.30;
  sfx.land(PL.groundSurf, 0.35 + impact * 0.75);
  if (fall > 8.5) { flashVig(clamp((fall - 8.5)/9, 0, 0.9)); VEL.x *= 0.55; VEL.z *= 0.55; }
  PL.air = 0;
}
if (!PL.grounded && PL.wasGrounded) PL.fallStart = P.y;
if (PL.grounded) PL.fallStart = P.y;
```
No health system — a hard landing (> **8.5 m**) only flashes the vignette and cuts
horizontal speed to **55 %**.

### 17.12 `postMove(dt, moving)`
```js
const sp = Math.hypot(VEL.x, VEL.z);
// stamina
PL.staminaLock = Math.max(0, PL.staminaLock - dt);
if (PL.sprint && sp > 3.2 && PL.grounded) PL.stamina = Math.max(0, PL.stamina - 13.5*dt);
else if (PL.staminaLock <= 0)             PL.stamina = Math.min(100, PL.stamina + 21*dt);
if (PL.stamina <= 0.5) PL.sprint = false;
// aim
PL.adsWant = (MOUSE.right && !PL.sprint && !PL.sliding && !PL.ladder) ? 1 : 0;
PL.ads = damp(PL.ads, PL.adsWant, 14, dt);
// lean
PL.leanWant = ((KEY.KeyE ? 1 : 0) - (KEY.KeyQ ? 1 : 0)) * (PL.sprint || PL.sliding ? 0 : 1);
if (PL.leanWant !== 0) {                       // do not lean into a wall
  const lx = Math.cos(PL.yaw)*PL.leanWant, lz = -Math.sin(PL.yaw)*PL.leanWant;
  if (!canStand(P.x + lx*0.55, P.z + lz*0.55, P.y + 0.6, 0.6, 0.22)) PL.leanWant = 0;
}
PL.lean = damp(PL.lean, PL.leanWant, 10, dt);
// head bob + footsteps
const bobSpeed = PL.grounded && !PL.sliding ? sp : 0;
PL.bobT += dt * (2.35 + bobSpeed * 0.92);
if (bobSpeed > 1.1) {
  if (PL.bobT - PL.bobStep > Math.PI) {
    PL.bobStep = PL.bobT;
    sfx.step(PL.groundSurf, clamp(0.22 + sp*0.085, 0.2, 1));
  }
} else PL.bobStep = PL.bobT - Math.PI * 0.5;
// camera vertical spring
PL.camY = damp(PL.camY, 0, 15, dt);
PL.landVel += -PL.landDip * 120 * dt - PL.landVel * 13 * dt;
PL.landDip += PL.landVel * dt;

PL.speed = sp;
updateExfil(dt);
```
Stamina: drain **13.5 /s** while sprinting above 3.2 m/s on the ground, regen
**21 /s** once `staminaLock` expires, cap 100, sprint cut at ≤ 0.5.
ADS damp rate **14**, lean damp **10**, lean probe **0.55 m** sideways with a 0.6 m
body and radius **0.22**.
Bob phase advances at `2.35 + speed*0.92` rad/s; a footstep fires every **π** of
phase; when standing still `bobStep` is parked half a step back so the next stride
lands promptly.
Landing dip is a spring: stiffness **120**, damping **13**.
`PL.camY` (the stair/step smoother) damps to 0 at rate **15**.

### 17.13 `updateFreecam(dt)`
```js
const fx = -Math.sin(PL.yaw), fz = -Math.cos(PL.yaw);
const sx =  Math.cos(PL.yaw), sz = -Math.sin(PL.yaw);
const spd = (KEY.ShiftLeft ? 46 : 15) * dt;
const ix = (KEY.KeyD ? 1 : 0) - (KEY.KeyA ? 1 : 0);
const iz = (KEY.KeyW ? 1 : 0) - (KEY.KeyS ? 1 : 0);
const py = Math.sin(PL.pitch), pf = Math.cos(PL.pitch);
P.x += (fx*pf*iz + sx*ix) * spd;
P.z += (fz*pf*iz + sz*ix) * spd;
P.y += (py*iz + ((KEY.Space ? 1 : 0) - (KEY.ControlLeft || KEY.KeyC ? 1 : 0))) * spd;
VEL.set(0, 0, 0); PL.grounded = false; PL.speed = 0;
```
Speeds **15 m/s**, **46 m/s** with Shift. No collision, no gravity. Note `pitch`
here is **inverted relative to the camera**: `py = sin(pitch)` and pitch is negative
when looking down, so `iz = 1` while looking down moves **down**. Correct.

### 17.14 `respawn()` and boot
```js
function respawn() {
  P.set(-9, 0, -104); P.y = groundH(P.x, P.z) + 0.2;
  VEL.set(0, 0, 0); PL.yaw = Math.PI; PL.pitch = -0.02;
}
```
Boot overrides it immediately:
```js
respawn();
P.set(-9, 0, -108); P.y = groundH(P.x, P.z) + 0.1;
PL.yaw = Math.PI; PL.pitch = -0.03;
```
So the **initial** spawn is `(-9, groundH(-9,-108) + 0.1, -108)` facing yaw π
(i.e. **+Z**, looking back down the north road toward town), pitch −0.03.
`respawn()` (used by the void plane and after an extraction) puts you at
`(-9, groundH+0.2, -104)`, pitch −0.02.

---

## 18. The camera rig

```js
function updateCamera(dt) {
  const eye = lerp(MV.standEye, MV.crouchEye, PL.crouchT);      // 1.66 -> 0.90
  const sp = PL.speed;
  const bobAmp = PL.grounded && !PL.sliding ? clamp(sp / MV.sprint, 0, 1.15) : 0;
  const bobY = Math.sin(PL.bobT * 2) * 0.036 * bobAmp;
  const bobX = Math.cos(PL.bobT)     * 0.050 * bobAmp;
  const bobR = Math.cos(PL.bobT)     * 0.011 * bobAmp;

  const sideVel = VEL.x * Math.cos(PL.yaw) - VEL.z * Math.sin(PL.yaw);
  const roll = -sideVel * 0.0042 * (PL.sliding ? 2.6 : 1) - PL.lean * 0.20 + bobR;
  PL.roll = damp(PL.roll, roll, 13, dt);

  const leanOff = PL.lean * 0.46;
  const cx = P.x + Math.cos(PL.yaw) * (leanOff + bobX * 0.5);
  const cz = P.z - Math.sin(PL.yaw) * (leanOff + bobX * 0.5);
  const slideDrop = PL.sliding ? -0.10 : 0;
  camera.position.set(cx, P.y + eye + bobY + PL.camY + PL.landDip + slideDrop, cz);

  _e.set(clamp(PL.pitch + recoil.pitch, -1.56, 1.56) + PL.landDip * 0.5,
         PL.yaw + recoil.yaw,
         PL.roll + recoil.roll * 0.012, 'YXZ');
  camera.quaternion.setFromEuler(_e);

  let fovT = 78;
  if (PL.sprint && sp > 4) fovT += 5.5 * clamp((sp - 4) / 3.5, 0, 1);
  if (PL.sliding)          fovT += 8 + clamp(sp - 8, 0, 10) * 0.85;
  if (!PL.grounded)        fovT += clamp(-VEL.y - 6, 0, 16) * 0.30;
  fovT = lerp(fovT, 52, PL.ads);
  fovT += recoil.fovKick;
  PL.fov = damp(PL.fov, fovT, PL.sliding ? 7 : 9, dt);
  if (Math.abs(camera.fov - PL.fov) > 0.01) { camera.fov = PL.fov; camera.updateProjectionMatrix(); }

  const gf = lerp(58, 44, PL.ads);
  if (Math.abs(gunCam.fov - gf) > 0.01) { gunCam.fov = gf; gunCam.updateProjectionMatrix(); }
}
```

Numbers: bob amplitudes **0.036** vertical (at 2× phase), **0.050** lateral,
**0.011** roll; lean offset **0.46 m** and lean roll **−0.20 rad** at full lean;
strafe roll gain **−0.0042 rad per m/s**, ×**2.6** while sliding; roll damp **13**;
slide camera drop **−0.10 m**.
FOV: base **78**, sprint bonus up to **+5.5** over 4→7.5 m/s, slide bonus
**+8** plus **0.85** per m/s over 8 (capped +8.5), fall bonus **0.30** per m/s of
downward speed past 6 (capped +4.8), then lerped toward **52** by ADS, plus recoil
kick. Damp rate **7** sliding, **9** otherwise. Viewmodel camera FOV **58 → 44**.

### 18.1 Euler order — ports 1:1
three.js `Euler(x, y, z, 'YXZ')` composes **R = Ry · Rx · Rz**. Godot's
`EULER_ORDER_YXZ` (the **default** for `Node3D.rotation_order` and
`Basis.from_euler`) composes the same way. So:
```gdscript
camera.rotation = Vector3(
	clampf(pl.pitch + recoil.pitch, -1.56, 1.56) + pl.land_dip * 0.5,
	pl.yaw + recoil.yaw,
	pl.roll + recoil.roll * 0.012)
```
with `camera.rotation_order` left at its default. Verify the default has not been
changed on the node.

Forward/right vectors used throughout the movement code:
```
forward = (-sin(yaw), 0, -cos(yaw))     # yaw = 0  ->  -Z
right   = ( cos(yaw), 0, -sin(yaw))     # yaw = 0  ->  +X
```
These are exactly what a Y-rotation by `yaw` does to `-Z` and `+X` in Godot. Mouse
right (`dx > 0`) **decreases** yaw.

### 18.2 Recoil spring (owned by GUNS, consumed by the camera)
```js
const recoil = { pitch:0, pitchV:0, yaw:0, yawV:0, kick:0, kickV:0, fovKick:0, roll:0, rollV:0 };
const K = 190, D = 21;
recoil.pitchV += -recoil.pitch * K * dt - recoil.pitchV * D * dt;  recoil.pitch += recoil.pitchV * dt;
recoil.yawV   += -recoil.yaw   * K * dt - recoil.yawV   * D * dt;  recoil.yaw   += recoil.yawV   * dt;
recoil.kickV  += -recoil.kick  * 260 * dt - recoil.kickV * 25 * dt; recoil.kick  += recoil.kickV  * dt;
recoil.rollV  += -recoil.roll  * 200 * dt - recoil.rollV * 22 * dt; recoil.roll  += recoil.rollV  * dt;
recoil.fovKick = damp(recoil.fovKick, 0, 13, dt);
```
Firing also applies a horizontal shove to the body:
`VEL.x -= _fwd.x * kickAmt * 0.012; VEL.z -= _fwd.z * kickAmt * 0.012;`

**GOTCHA — these springs are explicit Euler and are NOT frame-rate independent.**
`K = 190`, `D = 21` with `dt = 1/30` gives `D*dt = 0.7`, still stable; at `dt` above
about 0.05 s (the loop clamps to 0.06) `K*dt² ≈ 0.68` and the spring starts to
overshoot badly. Run the recoil integration on a fixed sub-step (e.g. 1/120 s
accumulator) in the port, or convert to a semi-implicit form.
The same applies to `PL.landVel`/`PL.landDip` in `postMove` (stiffness 120,
damping 13) — safe at the clamped `dt`, but put it on the same fixed sub-step.

---

## 19. Extraction flow

Called from `postMove` every frame.
```js
function updateExfil(dt) {
  let near = null;
  for (const e of EXFILS) {
    if (Math.abs(P.y - e.y) < 3.2 && Math.hypot(P.x - e.x, P.z - e.z) < e.r) { near = e; break; }
  }
  if (near) {
    near.held = Math.min(6, near.held + dt);
    // show the ring, set the label to `${near.name} · hold position`
    // arc dash offset = 263.9 * (1 - near.held / 6)
    if (near.held >= 6 && !PL.extracted) { PL.extracted = true; doExtract(near); }
    if (!PL.exfil) sfx.beep(600);            // one chirp on entering the pad
    PL.exfil = near;
  } else {
    // hide the ring
    for (const e of EXFILS) e.held = Math.max(0, e.held - dt * 2.2);
    PL.exfil = null;
  }
}
```
Trigger: **|Δy| < 3.2 m** and **horizontal distance < e.r = 4.6 m**. First match
wins (`break`) — pads never overlap so it does not matter. Hold time **6 s**, decay
**2.2 × real time** when you step off (so ~2.7 s to lose a full charge).

```js
function doExtract(e) {
  // flash overlay text: `${e.name} · ${WPN.cur.name.toUpperCase()} recovered · ${Math.round(runTime)}s on the ground`
  flash.classList.add('on'); sfx.beep(880); setTimeout(() => sfx.beep(1180), 160);
  setTimeout(() => {
    flash.classList.remove('on'); PL.extracted = false; e.held = 0;
    respawn(); runTime = 0;
  }, 2600);
}
```
Flash holds **2.6 s**, then `respawn()` (to `(-9, groundH+0.2, -104)`) and the run
timer resets. Beeps at **600 Hz** on entry, **880 Hz** then **1180 Hz** (+160 ms) on
success. Extraction is not a game-over — it is a loop.

**Diegetic-UI note for the port:** per the project contract, the ring/timer belongs
in-world, not as screen-space UI. The pad geometry (§16.3) already carries the
orange ring, four posts and four flags — drive an emissive sweep on the painted
ring from `held/6` instead of the SVG arc, and put the name on the flags.

---

## 20. HUD

Everything is `position:fixed` overlay in the reference. In the Godot port only the
compass and the ammo/stamina readouts are candidates for screen space; the rest
should move in-world.

### 20.1 The compass
```js
const PPD = 4.4;                                   // pixels per degree
const CARD = { 0:'N', 45:'NE', 90:'E', 135:'SE', 180:'S', 225:'SW', 270:'W', 315:'NW' };
// track: 3 repeats × 360° in 5° steps; cardinals get a label,
// multiples of 15 get the number, everything else a 1×5 px tick.
tr.style.width = (1080 * PPD) + 'px';
```
Per frame:
```js
const cw = compass.clientWidth;                     // min(560px, 58vw)
let hd = (-PL.yaw * 180 / Math.PI) % 360; if (hd < 0) hd += 360;
comptrack.style.transform = `translateX(${-(hd + 360) * PPD + cw/2}px)`;
```
So **heading in degrees = `(-yaw · 180/π) mod 360`**, and yaw = 0 ⇒ heading 0 = North
= world **−Z**. The track is offset by a full 360° so the middle repeat is always on
screen.

POI markers:
```js
const dx = o.p.x - P.x, dz = o.p.z - P.z;
const d = Math.hypot(dx, dz);
const b = (Math.atan2(dx, -dz) * 180 / Math.PI + 360) % 360;    // bearing, 0 = -Z
let rel = b - hd; if (rel > 180) rel -= 360; if (rel < -180) rel += 360;
const px = cw/2 + rel * PPD;
const drop = Math.abs(rel) > cw/2/PPD - 7            // off the ends of the strip
          || (o.p.kind !== 'exfil' && o.d > 260)     // landmarks only within 260 m
          || shown.some(s => Math.abs(s - px) < 66); // 66 px de-clutter
```
Candidates are sorted with exfils forced first via a `-1e6` bias on the sort key, so
an exfil label always wins a collision against a landmark. Label text is
`(kind === 'exfil' ? '◆ ' : '') + name + ' ' + Math.round(d)`.
Colours: exfil `#d8822f`, poi `#8a9a6b`.

```gdscript
## Compass heading in degrees, 0 = north = world -Z. yaw increases anticlockwise
## when viewed from above, so the sign flips.
static func heading_deg(yaw: float) -> float:
	return fposmod(-yaw * 180.0 / PI, 360.0)

## Bearing from the player to a world point, degrees, 0 = north.
static func bearing_deg(from: Vector3, to: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(to.x - from.x, -(to.z - from.z))), 360.0)
```

### 20.2 Gauges and state text
```js
spdnum.textContent = sp.toFixed(1) + ' m/s';
spdbar.style.width = clamp(sp/17, 0, 1)*100 + '%';
spdbar.style.background = sp > 11 ? '#d8822f' : sp > 7.8 ? '#e6c14f' : '#57a0bb';
stanum.textContent = Math.round(PL.stamina);
stabar.style.width = PL.stamina + '%';
stabar.style.background = PL.stamina < 22 ? '#a03636' : '#8a9a6b';
```
Speed bar full-scale **17 m/s**; thresholds **7.8** (gold) and **11** (orange).
Stamina turns red below **22**.

Movement state string, first match wins:
```
freecam -> 'free camera' · mantle -> 'mantling' · ladder -> 'climbing'
sliding -> 'sliding' · !grounded -> (air > 0.35 ? 'airborne' : '')
sprint && sp > 4 -> 'sprinting' · crouchT > 0.6 -> 'crouched' · else ''
```

### 20.3 Crosshair
```js
const base = clamp(s.spread * 0.12, 2.5, 26);
const g = base * (1 + sp*0.11) * (PL.grounded ? 1 : 1.5) * (1 - PL.ads*0.62) + recoil.kick*3;
// four 7×1.5 px bars at ±g from centre
xh.style.opacity = PL.ads > 0.75 ? 0.12 : 1;
```
Gap in px: weapon spread × 0.12 clamped to [2.5, 26], ×(1 + speed·0.11), ×1.5 in
the air, ×(1 − ads·0.62), plus recoil kick × 3.

### 20.4 Prompt
```js
if (PL.ladder)         ptext = '<k>W</k>climb  <k>SPACE</k>up  <k>S</k>down';
else if (findLadder()) ptext = '<k>W</k>climb';
```
The **second `findLadder()` call per frame**. Cache it (§17.10).

### 20.5 Perf readout
```js
perf.textContent = Math.round(fps) + ' fps · ' + (triCount/1000).toFixed(0) + 'k tris · '
                 + COL.length + ' colliders · ' + pxRatio.toFixed(2) + 'x';
```
Maps onto the project's F3 `DebugHUD`.

### 20.6 Other overlay elements that exist
* `#vig` — radial damage/land vignette, `radial-gradient(ellipse at center, transparent 42%, rgba(120,40,20,.55) 100%)`, opacity set by `flashVig(a)` then reset to 0 after **90 ms**.
* `#toast` — 1.6 s centre-top toast (used only by the volume/mute keys).
* `#wpn` — name, tier chip (colour = tier colour), `cal · mode · rpm rpm · weight kg`, ammo `N / cap`, and a `reloading` / `press R` line.
* `#flash` — the full-screen extraction card.
* `#menu` — the click-to-lock title screen with the keybind grid.
* `#loading` — "generating ash flats…", hidden once the world is built.

---

## 21. Atmosphere

### 21.1 Sky dome
A `SphereGeometry(1200, 32, 20)` with `side: BackSide, depthWrite: false, fog: false`,
`frustumCulled = false`, `renderOrder = -1`, and its position pinned to
`(camera.x, 0, camera.z)` every frame.

```glsl
varying vec3 vD; uniform vec3 uSun;
void main(){
  vec3 d=normalize(vD); float h=d.y;
  vec3 zen=vec3(0.196,0.322,0.478);
  vec3 mid=vec3(0.482,0.576,0.667);
  vec3 hor=vec3(0.831,0.729,0.573);
  vec3 gnd=vec3(0.706,0.604,0.470);
  vec3 c = h>0.0 ? mix(hor, mix(mid,zen,smoothstep(0.18,0.75,h)), smoothstep(0.0,0.30,h))
                 : mix(hor,gnd,smoothstep(0.0,-0.10,h));
  float s=max(dot(d,normalize(uSun)),0.0);
  c += vec3(1.0,0.80,0.52)*pow(s,26.0)*0.28;
  c += vec3(1.0,0.93,0.78)*pow(s,2600.0)*3.0;
  c += vec3(1.0,0.72,0.42)*pow(s,2.5)*0.07;
  float n=sin(d.x*8.0+d.z*5.0)*sin(d.z*7.0-d.x*3.0);
  c += vec3(0.10,0.09,0.075)*smoothstep(0.35,0.95,n)*smoothstep(0.02,0.4,h);
  gl_FragColor=vec4(c,1.0);
}
```
All colours are **linear**, written straight to the framebuffer before tone mapping.
Three sun terms: a wide `pow(s, 2.5) × 0.07` glow, a `pow(s, 26) × 0.28` halo, and a
`pow(s, 2600) × 3.0` disc. Cloud is a two-`sin` product, faded in above the horizon.

**GOTCHA — `smoothstep(0.0, -0.10, h)` has `edge0 > edge1`, which is UNDEFINED in
GLSL.** It happens to work on the drivers this was written against (it evaluates the
same clamped ratio) but Godot's shader compiler and other drivers are free to
produce garbage. **Hand-roll it** (see §2). It is the term that blends the sky down
into the fog colour below the horizon; without it there is a hard seam at the edge
of the ground mesh.

Godot: a `ShaderMaterial` sky (`shader_type sky;`) is the right home; `EYEDIR`
replaces `normalize(vD)`, and there is no dome mesh to position.

### 21.2 Dust
```js
const DUST = { n: 1100, R: 46 };
// spawn: x,z = (random - 0.5) * 92 ; y = pow(random, 2.1) * 13  (grit hugs the ground)
//        phase = random * TAU ; colour = (0.72, 0.61, 0.44) * (0.5 + random*0.5)
// PointsMaterial: size 0.042, vertexColors, transparent, opacity 0.30,
//                 depthWrite false, sizeAttenuation true, fog true
```
```js
let windT = 0, windStr = 1;
function updateDust(dt) {
  windT += dt;
  windStr = 0.75 + Math.sin(windT*0.21)*0.4 + Math.sin(windT*0.083 + 1.3)*0.32;
  const wx = 1.9 * windStr, wz = -1.15 * windStr;
  for each particle i with phase ph:
    x += (wx + Math.sin(windT*1.3 + ph)*0.5) * dt;
    z += (wz + Math.cos(windT*1.1 + ph*1.7)*0.5) * dt;
    y += Math.sin(windT*0.9 + ph*2.3)*0.22*dt - 0.06*dt;      // slow settle
    // toroidal wrap around the camera
    if (x - cx >  R) x -= R*2; else if (x - cx < -R) x += R*2;
    if (z - cz >  R) z -= R*2; else if (z - cz < -R) z += R*2;
    if (y - cy > 13) y -= 17;  else if (y - cy < -4) y += 17;
}
```
1100 points, wrap radius **46 m**, vertical wrap band **−4 … +13 m** relative to the
camera with a **17 m** wrap distance. Wind base `(1.9, 0, -1.15)` scaled by
`windStr ∈ [0.03, 1.47]`.

Godot: a `GPUParticles3D` with a custom process shader, or a `MultiMeshInstance3D`
updated on a worker — but 1100 CPU-updated points per frame is well inside budget
if the buffer is a `PackedVector3Array` written once.

The wind also drives the ambient audio gain:
`0.012 + windStr*0.018 + clamp(PL.speed/60, 0, 0.02)`.

### 21.3 Footstep synthesis — the surface table
The surface id is the only thing that distinguishes footsteps, so the table is part
of the world contract even though the audio is not.
```js
const STEP_P = {
  [S.SAND]:     { f0: 1500, f1: 320, d: 0.085, g: 0.075, click: 0.000, tail: 0.055 },
  [S.ASPHALT]:  { f0: 2400, f1: 380, d: 0.055, g: 0.085, click: 0.020, tail: 0.020 },
  [S.CONCRETE]: { f0: 3000, f1: 420, d: 0.048, g: 0.090, click: 0.026, tail: 0.018 },
  [S.ROCK]:     { f0: 2600, f1: 400, d: 0.055, g: 0.085, click: 0.022, tail: 0.024 },
  [S.METAL]:    { f0: 3600, f1: 620, d: 0.060, g: 0.080, click: 0.030, tail: 0.030 },
  [S.TIN]:      { f0: 3200, f1: 520, d: 0.070, g: 0.078, click: 0.026, tail: 0.036 },
  [S.WOOD]:     { f0: 2000, f1: 300, d: 0.065, g: 0.085, click: 0.018, tail: 0.026 },
  [S.CLOTH]:    { f0: 1100, f1: 260, d: 0.090, g: 0.050, click: 0.000, tail: 0.030 },
  [S.POLY]:     { f0: 2200, f1: 380, d: 0.055, g: 0.070, click: 0.016, tail: 0.018 },
};
```
`f0 → f1` is a lowpass sweep over `d` seconds on white noise, gain `g`, plus an
optional 12 ms 9 kHz→5 kHz click and a 2.2×-length tail. Footsteps alternate pan
±0.22 and are rate-limited to one per **0.09 s**. Playback rate/pitch jitter
`0.88 + random*0.26`, volume jitter `0.82 + random*0.30`.

**Design rule from the reference, worth keeping:** nothing in the audio graph
exceeds **Q 1.4**, and the whole bus runs through a limiter — a high-Q bandpass on
noise is a pitched ring, and at footstep rates it is unbearable.
Landing reuses the same table with `f0 × 0.75`, `f1 × 0.7`, `d × 2.0`, plus a
240→70 Hz thump at gain `0.055 × k`.

---

## 22. Frame loop and adaptive resolution

```js
function frame(now) {
  let dt = (now - last) / 1000; last = now;
  if (dt > 0.06) dt = 0.06;          // hard clamp — everything above assumes it
  if (dt <= 0) return;
  runTime += dt;
  updateMovement(dt);
  updateCamera(dt);
  updateWeapons(dt);
  updateDust(dt);
  updateHUD(dt);
  // sun rig follows the player, sky dome follows in XZ only
  renderer.render(scene, camera);
  renderer.autoClear = false; renderer.clearDepth();
  renderer.render(gunScene, gunCam);
  renderer.autoClear = true;
}
```
**`dt` is clamped to 0.06 s.** Several of the explicit-Euler springs (§18.2) are only
stable because of this. Reproduce the clamp, or move to `_physics_process` at a
fixed 60–120 Hz and drive the camera in `_process` with interpolation.

Adaptive resolution:
```js
const PX_MAX = Math.min(devicePixelRatio, 2), PX_MIN = 0.55;
let pxRatio = PX_MAX, adaptDir = 0;
function adaptResolution() {                       // called every 0.4 s
  if (fps < 45 && pxRatio > PX_MIN)      adaptDir = adaptDir < 0 ? adaptDir - 1 : -1;
  else if (fps > 58 && pxRatio < PX_MAX) adaptDir = adaptDir > 0 ? adaptDir + 1 : 1;
  else                                   adaptDir = 0;
  if (adaptDir <= -3) { pxRatio = Math.max(PX_MIN, pxRatio - 0.15); adaptDir = 0; applyPx(); }
  if (adaptDir >=  8) { pxRatio = Math.min(PX_MAX, pxRatio + 0.10); adaptDir = 0; applyPx(); }
}
```
Drops after **3** consecutive bad samples (1.2 s), climbs back only after **8** good
ones (3.2 s) — asymmetric on purpose so it does not oscillate. Range **0.55 … 2.0**,
step down **0.15**, step up **0.10**, thresholds **45 fps** / **58 fps**.
Maps directly onto Godot's `Viewport.scaling_3d_scale` (or
`GameSettings.render_scale` per the autoload contract).

Reported budget from the reference itself: `triCount = (townVerts + terrainVerts)/3`
and `COL.length` colliders. The terrain alone is 80 000 triangles; the town is the
rest. **One material, two draw calls, ~1500–3000 colliders.**

---

## 23. Complete list of things that will break a naive port

1. **`rng`'s middle shift is signed** (`s >> 17` on an int32). Wrong shift ⇒ a
   completely different world. §1.2.
2. **rng draw counts and order are the world's identity.** `vary()` = 3 draws;
   `barrel()`'s colour picker short-circuits; `bsp`'s `chance` is conditional; the
   street-clutter loop draws before its `continue`. §1.3, §14.3, §15.2, §15.7.
3. **`buildTerrain` must run after `layoutTown`** or `roadAt` sees an empty `ROADS`.
   §1.5.
4. **`groundH` interpolates the wrong quad diagonal** relative to the mesh it is
   supposed to describe. §7.3.
5. **`smoothstep` with `edge0 > edge1`**: fine in JS and in Godot's GDScript, but
   **undefined in GLSL** — and the sky shader relies on it. §2, §21.1.
6. **three.js `FogExp2` is `exp(-(ρd)²)`; Godot's fog is `exp(-ρd)`.** Not the same
   curve. §8.1.
7. **three.js camera `fov` is vertical**; Godot's is vertical only with
   `keep_aspect == KEEP_HEIGHT`. §8.1.
8. **Two cameras with a depth clear between passes.** Godot needs a SubViewport for
   the viewmodel; a 0.006 near plane cannot share the main camera. §8.1.
9. **All mesh colours are converted sRGB→linear at emit time**, but `vary()` mixes
   in sRGB and `THREE.Color.getHex()` rounds. §10.3.
10. **`Mesher.cyl` has no axis parameter** — its `ry` is a seam rotation. Tipped
    barrels, truck wheels and hauler wheels therefore render upright while their
    colliders lie on their side. §10.5.
11. **`Mesher.corrug` is an open, single-sided sheet** (warehouse roof). Under
    Godot's backface culling it disappears from below and violates the no-air-gaps
    rule. Give it thickness in the bake. §10.5.
12. **`bWarehouse`'s roof ignores `base`** — `ridge = h + …` is absolute Y while the
    walls run `base … base + h`. Also the returned `roofY: h`. §13.2.
13. **`bCompound`'s inner `bAdobe` return value is discarded**, so that building is
    invisible to `linkRoofs` and `placeExfils`. §13.7.
14. **`bsp`'s `widths` index is off by one**; `widths[0] = 8.5` is dead. §15.2.
15. **`surfaceAtGround` uses `|z| < 205` but `buildTerrain` uses `|z| < 210`** for the
    same road test. §11.7.
16. **`NORTH GATE` uses `-8 + sin(z·0.008)·18` while `terrainH`'s road shelf is at
    `-8 - sin(z·0.008)·18`.** 15.4 m apart at the pad. §16.3.
17. **`scatterWilds` interleaves two rng streams** and, in the barrel branch, samples
    `groundH` at a *different* x than where the barrel is placed. §16.1.
18. **`powerLine` wires use the current pole's height with the previous pole's ground
    height and hold a constant Y.** §14.9.
19. **`snapDown`'s `clear` flag is never set false** — the guard is dead. §17.6.
20. **`updateMovement` order is the spec.** `speedNow` is captured before this
    frame's acceleration and used by the vault check; friction is skipped while
    `jumpHeld && jumpBuf > 0` (bhop); XZ resolves before Y inside every substep.
    §17.11, §17.7.
21. **`accelerate()` must not clamp total speed.** The air-strafe gain comes from the
    projection onto the wish direction. §17.8.
22. **Recoil and land-dip springs are explicit Euler and frame-rate dependent**;
    they survive only because `dt` is clamped to 0.06. §18.2, §22.
23. **Euler order is YXZ** in both engines and ports 1:1 — but only if
    `Node3D.rotation_order` is left at its default. §18.1.
24. **The yaw convention ports with no flips.** `forward = (-sin y, 0, -cos y)`,
    `right = (cos y, 0, -sin y)`, and the mesher's `P(lx,ly,lz)` is exactly
    `Basis(Vector3.UP, ry)`. Resist the urge to negate anything. §10.1, §18.1.
25. **`findLadder()` is called twice per frame** (movement + HUD prompt) and scans
    every ladder linearly. Cache. §17.10, §20.4.
26. **`distToRoad` is O(|ROADS|) and `surfaceAtGround` calls it at runtime** — on
    every footstep and every terrain raycast hit. Bake a road mask. §15.4.
27. **`topAt` returns `null` for "nothing"**, and valid tops can be negative. Do not
    sentinel with `-INF`. §11.5.
28. **`Math.floor` on negatives** (grid indices, noise cells) rounds down. Use
    `floori()`, never `int()`. §11.2.
29. **`Math.sign(0) === 0`**, hence the `|| 1` fallbacks in `AX` and `circleBox`. §7.1, §11.4.
30. **`queryCols` writes into one shared scratch array** and `circleBox` returns one
    shared struct. Anything that holds a reference across a second call is wrong.
    §11.3, §11.4.
31. **Dead state that must not be ported**: `MAP.half`, `MV.maxSpeed`, `PL.groundY`,
    `PL.camYVel`, `PL.ladderY`, `PL.eye`, `PL.lastStepSurf`, `G.roofs`, `G.tall`,
    `SKY_LOW`, `SKY_HI`, `PAL.sand`, `PAL.rust`, `terrainN`, `Mesher.box`'s `skip`
    parameter, `buildPlaza`'s `[rx0, rz0]`, `bAdobe`'s `[wx, wz]`.

---

## 24. Suggested Godot file layout

| file | contents |
|---|---|
| `res://core/world_noise.gd` | `XorShift32`, `vnoise2`, `fbm2`, `ridged`, `damp` — static, no scene deps |
| `res://core/terrain_field.gd` | `MAP`, `wadi_x`, `MESAS`, `terrain_h`, `AX`/`HG` tables, `ground_h`, `ground_normal`, `surface_at_ground` |
| `res://tools/build_world.gd` | `@tool`, `static func build()` — Mesher, all generators, layout, bakes `res://data/world/terrain.res`, `town.res`, the collider array, `LADDERS`, `POIS`, `EXFILS` |
| `res://data/world/colliders.tres` | baked `Resource` holding the flat collider array + grid |
| `res://art/world_material.gdshader` | §9 ported |
| `res://art/sky.gdshader` | §21.1 ported |
| `res://systems/player/player_controller.gd` | §17 — kinematic, reads the baked collider resource |
| `res://systems/player/player_camera.gd` | §18 |
| `res://demos/ash_flats/ash_flats.tscn` | packed by `build_world.gd` |

The collider array and the terrain height grid must both be **baked resources**, not
rebuilt in `_ready()` — the height grid is 40401 `terrainH` evaluations, each doing
9 fbm calls, and the town build runs thousands of rng draws.
