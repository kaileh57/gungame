# BESTIARY — implementation spec

Source of truth: `reference/bestiary (3).html` (755,066 bytes, 2,500 lines).
Readable JS lives at lines **84–1312** (`BEAST` core), **1315–2015** (`SPECIES` roster),
**2018** (`window.VALIDATION` one-liner), **2020–2497** (viewer, not shipped).
Line 80 is the minified three.js r128 UMD bundle — ignore it.

Everything in this document was transcribed from the source and then **re-executed
headless under node against the real three.js r128 bundle**, so every number below
is a measured output, not an estimate. The validator metric was reverse-engineered
and reproduced to 14 significant digits against `window.VALIDATION` — see §18.

Owner: `res://systems/enemies/`. Bake script: `res://tools/build_enemies.gd`.
Baked output: `res://data/enemies/`.

---

## 0. Porting contract — read this before writing a line

| Concern | three.js reference | Godot 4.7 | Action |
|---|---|---|---|
| Handedness / up | right-handed, +Y up, −Z forward | identical | **no axis flip, no winding flip** |
| Unit | 1 model unit = **1 metre** (unlike the guns, which are 90 mm units) | 1 m | no scaling. Do **not** apply the 0.09 gun scale here. |
| Euler order | `Object3D.rotation` defaults to **`'XYZ'`** = `Rx·Ry·Rz` | `Node3D.rotation_order` defaults to **`EULER_ORDER_YXZ`** | **set `rotation_order = EULER_ORDER_XYZ` on every bone node**, or drive `quaternion` directly. Getting this wrong silently mangles every pose. |
| Explicit `'YXZ'` sites | `solveTurret` `_e2`, `poseDeath` `_eD`, `bone.rotation.setFromQuaternion(q,'YXZ')` | `EULER_ORDER_YXZ` | only these three places are YXZ. Everything else is XYZ. |
| Backfaces | materials are `side: THREE.DoubleSide` | Godot culls backfaces by default | the enemy primitives are closed convex solids (`BoxMesh`/`CylinderMesh`/`SphereMesh`), so DoubleSide is *not* hiding defects here — unlike the gun blob. Keep culling **on**; do not port DoubleSide. |
| Shading | `flatShading: true` on every beast material | `BaseMaterial3D` has no flat-shading flag | bake flat normals into the mesh (duplicate verts per face) or use a shader with `NORMAL = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)))`. |
| Colour space | `new THREE.Color(hex).convertSRGBToLinear()` | `Color(hex)` is already sRGB; Godot converts on upload | pass the hex straight to `albedo_color`; do **not** double-convert. |
| Angles | radians everywhere, no exceptions | radians | no `deg_to_rad` anywhere in this port. |
| Frame rate | poses are **pure functions of (clip, t, take)** except `death`, which is a fixed-step sim at `DT = 1/120` | same | never step animation by `delta`; always evaluate at an absolute clip time. |
| `Quaternion.setFromUnitVectors` 180° case | picks a perpendicular derived from the input vector | `Quaternion(v0, v1)` picks **+Y** when `dot < -1+eps` | differs only when a limb points exactly anti-parallel. Implement three.js's fallback explicitly (§9.3) if you want frame-exact death replays. |
| `Matrix4.lookAt(eye,target,up)` | resulting **+Z** points from target → eye | `Basis.looking_at(t,up)` points **−Z** at target | `lookQ(dir)` ⇒ `Basis.looking_at(-dir, up)`. |

---

## 1. Core scalars and helpers (lines 99–108)

```gdscript
const TAU_C : float = TAU          # Godot's TAU == 2*PI, identical
const G     : float = 9.81

static func clampf3(v: float, a: float, b: float) -> float:
	return maxf(a, minf(b, v))                      # note the reference's arg order
static func lerpf3(a: float, b: float, t: float) -> float:
	return a + (b - a) * t
static func smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)                  # smoothstep, NOT clamped
```

`smooth()` is **never clamped internally** — every caller clamps first
(`smooth(clamp(x,0,1))`). Reproduce that discipline; feeding it t>1 produces
overshoot the reference relies on nowhere.

### 1.1 The RNG — the single nastiest coercion in the file

```js
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}
```

That third step is `>>` (**arithmetic**, sign-extending) not `>>>`. Because the
preceding `s >>>= 0` makes `s` an unsigned value that frequently has bit 31 set,
`s >> 17` sign-extends and fills the top 17 bits with ones. A naive "xorshift32"
port using a logical shift **diverges from the reference at the 4th draw**.

```gdscript
class Rng:
	var s: int = 1
	func _init(seed: int) -> void:
		s = seed & 0xFFFFFFFF
		if s == 0:
			s = 1
	func next() -> float:
		s = (s ^ ((s << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
		# arithmetic >>17 on the int32 reinterpretation:
		var hi: int = 0xFFFF8000 if (s & 0x80000000) != 0 else 0
		s = (s ^ ((s >> 17) | hi)) & 0xFFFFFFFF
		s = (s ^ ((s << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
		return float(s) / 4294967296.0
```

**Test vectors** (must match exactly):

| seed | first six draws |
|---|---|
| 12345 | 0.776938705239, 0.395172696328, 0.655770279467, 0.455104941968, 0.856083941646, 0.940766324056 |
| 1 | 0.000062950188, 0.015739798779, 0.422665603925, 0.815505748847, 0.655159770045, 0.448652910301 |
| 293898594 (= rat, take 0) | 0.584811208304, 0.348880623002, 0.510376841528, 0.923618845409, 0.032611313043, 0.975346250227 |

The wrong (logical-shift) variant with seed 12345 gives
`…, 0.455295676831, 0.167368520750, …` from draw 4 on. Use that as a regression trap.

### 1.2 `hashStr` (material seeding only, line 257)

FNV-1a 32-bit with `Math.imul`:

```gdscript
static func hash_str(t: String) -> int:
	var h: int = 2166136261
	for i in t.length():
		h = (h ^ t.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF      # Math.imul == 32-bit wrapping multiply
	return h if h < 0x80000000 else h - 0x100000000   # imul returns a SIGNED int32
```
Used as `seed = abs(hash_str(id)) % 997 / 997.0` for the per-material noise offset.

---

## 2. MAT — the material table, 18 entries (lines 113–132)

`type` selects the fragment-shader branch: **0** rusted steel · **1** timber ·
**2** polymer · **3** canvas/cloth · **4** flesh · **5** chitin/bone.

| key | type | col | metal | rough | dens (kg/m³) | fill | env | emis | emisI | fx |
|---|---|---|---|---|---|---|---|---|---|---|
| `steel`  | 0 | `#4d4a44` | 0.74 | 0.50 | 7800 | 0.16 | 0.72 | — | — | — |
| `ironox` | 0 | `#6b4a34` | 0.55 | 0.72 | 7500 | 0.15 | 0.55 | — | — | — |
| `gunmet` | 0 | `#33353a` | 0.80 | 0.42 | 7900 | 0.14 | 0.80 | — | — | — |
| `brass`  | 0 | `#8a7238` | 0.85 | 0.38 | 8400 | 0.18 | 0.90 | — | — | — |
| `alum`   | 0 | `#7d8288` | 0.78 | 0.44 | 2700 | 0.20 | 0.78 | — | — | — |
| `timber` | 1 | `#8a5a2b` | 0.04 | 0.82 |  700 | 0.75 | 0.42 | — | — | — |
| `poly`   | 2 | `#26282b` | 0.05 | 0.78 | 1150 | 0.28 | 0.40 | — | — | — |
| `rubber` | 2 | `#141517` | 0.03 | 0.92 | 1150 | 0.22 | 0.22 | — | — | — |
| `canvas` | 3 | `#6b6152` | 0.02 | 0.95 |  700 | 0.13 | 0.30 | — | — | — |
| `hide`   | 3 | `#4a3a2c` | 0.03 | 0.80 |  900 | 0.16 | 0.36 | — | — | — |
| `flesh`  | 4 | `#836158` | 0.02 | 0.62 | 1050 | 0.88 | 0.40 | — | — | — |
| `pallid` | 4 | `#9b8d80` | 0.02 | 0.58 | 1040 | 0.82 | 0.44 | — | — | — |
| `gut`    | 4 | `#5d3a34` | 0.02 | 0.50 | 1030 | 0.88 | 0.50 | — | — | — |
| `chitin` | 5 | `#3a352e` | 0.10 | 0.38 | 1300 | 0.32 | 0.66 | — | — | — |
| `bone`   | 5 | `#b6ac96` | 0.03 | 0.55 | 1900 | 0.55 | 0.44 | — | — | — |
| `glow`   | 2 | `#12140f` | 0.0  | 0.40 | 1200 | 0.20 | 0.30 | `#c8451f` | 2.6 | — |
| `glowc`  | 2 | `#0f1416` | 0.0  | 0.40 | 1200 | 0.20 | 0.30 | `#3fa8c8` | 2.2 | — |
| `flash`  | 2 | `#000000` | 0.0  | 1.0  |    1 | 0.0  | 0.0  | `#ffcf7a` | 5.0 | **true** |

(That is **18** rows. The project brief lists 16 — the 15 surface materials plus
`glow`. The reference adds `glowc` (cyan sensor glow, wasp-only) and `flash`
(muzzle flare). All 18 are live and all 18 are used by the roster except that
`glowc` appears on exactly one part.)

`fx: true` (`flash` only) means:
* the mesh is created at `scale = 0.0001` and only grows during a muzzle pulse;
* `transparent`, `opacity 0.85`, `depthWrite false`;
* it is **excluded from every mass, area, bounds, floor and penetration query**
  (`if (MAT[p.m].fx) continue;` appears in `deriveStats`, `lowestPoint`, and the
  validator). Port that exclusion or your masses and hitboxes will be wrong.

### 2.1 `HARD` — armour-bearing fraction per material (line 134)

```gdscript
const HARD := {
	"steel": 1.0, "ironox": 0.85, "gunmet": 1.0, "alum": 0.62,
	"brass": 0.70, "chitin": 0.45, "bone": 0.30, "poly": 0.22
}
```
Any material not listed contributes 0. This drives the `cover` stat and hence armour.

### 2.2 Material construction (lines 232–256)

```
colour  = sRGB(col or override) * tint          # tint is 1.0 for every species
metal   = MAT.metal
rough   = MAT.rough
envMapIntensity = MAT.env
flatShading = true, side = DoubleSide
emissive = MAT.emis, emissiveIntensity = MAT.emisI   (glow/glowc/flash only)
uSeed   = (abs(hashStr(key|tint|colOverride)) % 997) / 997
```
Materials are cached by `key|tint.toFixed(3)|colOverride`. **One material per
(key, colour-override) pair across the whole bestiary.** Measured: **exactly 19
distinct materials** for all 714 parts — `alum, alum#6d6a5e, bone, brass, canvas,
chitin, flash, flesh, glow, glowc, gunmet, gut, hide, ironox, pallid, poly,
rubber, steel, timber`. (`glowc` is wasp-only; `#6d6a5e` is picker's sign face.)
That satisfies the performance rule; do not instance-per-part.

---

## 3. Primitive geometry (lines 261–291)

Three shapes only. `p.s` ∈ `{'box','cyl','sph'}`.

```gdscript
# box : d = [dx, dy, dz]  (full extents, centred on p.c)
# cyl : r0 = radius at +Y end, r1 = radius at −Y end, h = height, axis = local +Y
# sph : r
```

Tessellation (mirror it so the silhouettes match):

| shape | segments |
|---|---|
| box | 1×1×1 |
| cyl | `p.seg` if given, else `12` when `r0+r1 > 0.22`, else `8`; 1 height segment, **not** capped-open (`openEnded=false`) |
| sph | `12` widthSegs when `r > 0.14` else `8`; heightSegs `max(5, seg >> 1)` ⇒ 6 or 5 |

Geometry is cached by a key built from the rounded dimensions
(`toFixed(4)`), so identical primitives share one mesh. **Do the same in the
bake**: build a `Dictionary[String, ArrayMesh]` and reuse. Measured across the
roster: **714 parts (189 box, 228 cyl, 297 sph) collapse onto 368 unique meshes**,
drawn with 19 materials. Bucket by (mesh, material) and drive each bucket from a
`MultiMeshInstance3D`.

Analytic measures — used for mass, armour coverage and bounds; these are exact,
do not substitute AABB approximations:

```gdscript
static func part_volume(p) -> float:
	match p.s:
		"box": return p.d[0] * p.d[1] * p.d[2]
		"cyl": return PI * p.h / 3.0 * (p.r0 * p.r0 + p.r0 * p.r1 + p.r1 * p.r1)
		_:     return 4.0 / 3.0 * PI * p.r * p.r * p.r

static func part_area(p) -> float:
	match p.s:
		"box": return 2.0 * (p.d[0]*p.d[1] + p.d[1]*p.d[2] + p.d[0]*p.d[2])
		"cyl":
			var sl := sqrt(p.h*p.h + (p.r0-p.r1)*(p.r0-p.r1))     # Math.hypot
			return PI * (p.r0 + p.r1) * sl + PI * (p.r0*p.r0 + p.r1*p.r1)
		_:     return 4.0 * PI * p.r * p.r

static func part_extent(p) -> Vector3:                # half-extents for bounds
	match p.s:
		"box": return Vector3(p.d[0]*0.5, p.d[1]*0.5, p.d[2]*0.5)
		"cyl": var r := maxf(p.r0, p.r1); return Vector3(r, p.h*0.5, r)
		_:     return Vector3(p.r, p.r, p.r)
```

Note `part_area` for a cone frustum includes **both** end caps even when a radius
is 0 (the `PI*r*r` term just vanishes), and the cylinder is treated as a full
frustum — that is what the `cover` stat is calibrated against.

---

## 4. The Rig — bones, parts, and the overlap guarantee (lines 294–330)

```gdscript
class Rig:
	var id: String
	var bones: Array          # [{n, p, o:Vector3, rot:Vector3|null, len:float, r:float}]
	var parts: Array          # [{b, s, c:Vector3, m:String, rot:Vector3, ...}]
	var legs: Array
	var arms: Array
	var by_name: Dictionary
	var tags: Dictionary
	var gait: Dictionary
	var info: Dictionary
	var rho: float = -1.0     # see gotcha G-3
```

### 4.1 `bone(n, parent, off, rot)`
Creates `{n, p: parent|null, o: off.slice() or [0,0,0], rot: rot.slice() or null, len: 0, r: 0}`,
appends to `bones`, registers in `by_name`, returns the **name string**.
Bones are declared parent-before-child; the instantiator relies on that ordering.

### 4.2 `box(b,c,d,m,o)` / `cyl(b,c,r0,r1,h,m,o)` / `sph(b,c,r,m,o)`
`c` is the part centre **in the owning bone's local frame**. `o` is an optional
dict merged over the defaults; the only keys used anywhere in the roster are:

| key | meaning | used by |
|---|---|---|
| `rot` | `[x,y,z]` Euler XYZ, default `[0,0,0]` | ubiquitous |
| `col` | hex colour override for that one part | picker's sign face `#6d6a5e` |
| `seg` | cylinder radial segment override | never used in the roster |
| `rho` | per-part density override | never used in the roster |
| `fxs` | muzzle-flash scale multiplier | the five `flash` spheres |

### 4.3 `link()` — **this is the no-gap guarantee** (lines 315–329)

```gdscript
func link(n, parent, off, length, r0, r1, m, o := {}) -> String:
	bone(n, parent, off)
	var b = by_name[n]; b.len = length; b.r = r0
	var ov0: float = float(o.get("ov0", 0.62)) * r0      # overhang above the pivot
	var ov1: float = float(o.get("ov1", 0.30)) * r1      # overhang below the far end
	var h: float = length + ov0 + ov1
	var cy: float = (ov0 - length - ov1) / 2.0
	cyl(n, Vector3(0, cy, 0), r0, r1, h, m, {"seg": o.get("seg"), "rho": o.get("rho")})
	if o.get("ball", true) != false:
		var br: float = o["ballR"] if o.has("ballR") else maxf(r0 * 1.14, float(o.get("pr", 0.0)) * 1.02)
		sph(n, Vector3.ZERO, br, o.get("ballM", m), {"rho": o.get("rho")})
	return n
```

Why it cannot open a gap, stated precisely — port this reasoning, not just the code:

1. The segment runs down local **−Y** for `len`, but the cylinder spans
   `y ∈ [+ov0, −len−ov1]`. It therefore **overhangs the pivot by `0.62·r0` above
   and the child pivot by `0.30·r1` below**. Neighbouring segments always
   interpenetrate along the bone axis at rest by `ov0(child) + ov1(parent)`.
2. A sphere of radius `ballR` sits at **exactly the joint pivot** (local origin).
   The pivot is the bone's origin, so under *any* local rotation the ball's centre
   is **fixed relative to the parent**. Its overlap with the parent's geometry is
   therefore a rotation-invariant constant. That is the entire trick: the joint
   seam is covered by a solid whose position no rotation can move.
3. Default `ballR = max(r0·1.14, pr·1.02)` guarantees the ball is fatter than the
   segment it caps, so it protrudes through the cylinder wall in every direction.

Empirical proof, from §18: for every humanoid the *global* minimum joint overlap
is exactly `armR · 1.26` — the shoulder ball's radius — and it is **bit-identical
across all 11 clips and 5 death takes**, because that ball never moves relative to
the chest. For `latchdog` the minimum is `0.0393 m`, which is
`bodyH·0.46 − (bodyL·0.30 − bodyL·0.44/2) = 0.1081 − 0.0688`, i.e. the spine
pivot-ball buried inside the pelvis box. Same invariance, same result.

**Rule for all hand-built enemy geometry: every joint gets a sphere centred on
its own pivot, and every segment overhangs both ends.** No exceptions.

### 4.4 `tube(R, bone, pts, r, mat)` (lines 1338–1347)

A polyline of cylinders with balls at every kink — hoses, cables, claws, slings:

```gdscript
static func tube(R, b: String, pts: Array, r: float, mat: String) -> void:
	for p in pts:
		R.sph(b, p, r * 1.06, mat)                       # ball is 6% fatter than the tube
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]; var c: Vector3 = pts[i + 1]
		var d: Vector3 = c - a
		var L: float = d.length()
		if L < 1e-5: continue
		R.cyl(b, (a + c) * 0.5, r, r, L, mat, {"rot": dir_euler(d)})
```

`dir_euler(d)` = the Euler XYZ of the quaternion taking **+Y** onto `normalize(d)`:

```gdscript
static func dir_euler(d: Vector3) -> Vector3:
	var q := Quaternion(Vector3.UP, d.normalized())
	return Basis(q).get_euler(EULER_ORDER_XYZ)
```

The ball-at-every-kink rule is why a tube "can never come apart no matter how it
is routed" — same invariant as `link()`.

---

## 5. `Inst` — instantiating a rig (lines 334–388)

```
root = Group()                 # "rig space": +Y up, +Z forward, y=0 is the ground
for each bone in declaration order:
    node = Object3D(); node.position = b.o; if b.rot: node.rotation = b.rot (XYZ)
    parent = obj[b.p] if b.p else root
for each part:
    local  = compose(p.c, Euler(p.rot,'XYZ'), 1)
    mesh   = Mesh(geoFor(p), material(p.m, tint, p.col)) parented to obj[p.b]
    if MAT[p.m].fx: mesh.scale = 0.0001; push to inst.fx
root.updateMatrixWorld(true)
rest[boneName] = world position of every bone at rest
gait  = solveGait(rig, rest)
for each arm A:  A.L1 = |rest[A.shoulder] − rest[A.elbow]|
                 A.L2 = |rest[A.elbow]   − rest[A.wrist]|
                 limbBones[shoulder|elbow|wrist] = 1
if rig.aim && rig.aim.bone: limbBones[rig.aim.bone] = 1
stats = deriveStats(rig, this, gait)
clip='idle'; phase=0; travel=0
```

`rest` is captured **before any posing**, in rig space with the root at the
origin. `A.L1/L2` are written back onto the rig's arm dicts — the rig object is
mutated by instantiation. In Godot, keep arm/leg records as `RefCounted` objects
owned by the baked resource, and compute `L1/L2` once at bake time.

Viewer seed convention: `seed = 1013 + index * 7919` (index 0…11). Death takes
depend on it, so keep it.

`partMatrices()` returns `obj[bone].global_transform * part.local` for every
part — used by bounds and the validator.

---

## 6. `solveGait` — where walking speed comes from (lines 391–424)

Defaults merged under `rig.gait`:
`{type:'biped', duty:0.60, strideK:1.45, freqK:1.0, lift:0.16, bob:0.022, sway:0.02}`.

Per leg `L` (using the **rest** world positions):

```gdscript
L1 = |hip − knee| ; L2 = |knee − ankle| ; reach = L1 + L2
standY = padR + pastern.len * cos(pastern.a0)      if L.pastern
       = L.sole.h                                  elif L.sole
       = 0                                         else
rx = hip.x * (L.stanceK if set else 1.0) + (L.outX or 0)
rz = hip.z + (L.zOff or 0) + (pastern.len * sin(pastern.a0) * (pastern.dir or 1) if pastern else 0)
rest3   = hypot(rx − hip.x, standY − hip.y, rz − hip.z)     # 3-D hip→foot rest distance
dropMax = (L.dropMax if set else 0.14) * reach
eff     = max(0.25 * reach, rest3 − dropMax)
Emax    = 2 * sqrt(max((0.965 * reach)^2 − eff^2, 0.0025))  # max fore-aft foot travel
```

Legless rigs short-circuit:
```gdscript
if legs.is_empty():
	var hv: float = g.get("hoverSpeed", 3.0)
	g.speed = hv * 0.55 ; g.runSpeed = hv ; g.freq = 1.0 ; g.E = 0.0
	return g          # NOTE: runFreq / runDuty / runE are LEFT UNDEFINED
```

Legged rigs:

```gdscript
reach   = mean(leg.reach)
Emax    = min(leg.Emax)
g.reach = reach
g.hipH  = mean(leg.hipRest.y)
g.standY= mean(leg.standY)
g.freq  = 0.30 * sqrt(9.81 / max(reach, 0.12)) * g.freqK     # pendulum scaling
g.E     = min(g.strideK * g.duty * reach, Emax * 0.90)       # stance travel, metres
g.speed = g.E * g.freq / g.duty                              # stride / contact time
g.EmaxV = Emax
g.dropMax  = min(leg.dropMax)
g.runFreq  = g.freq * 1.42
g.runDuty  = max(0.30, g.duty * 0.56)
g.runE     = min(g.E * 1.45, Emax * 0.94)
g.runSpeed = g.runE * g.runFreq / g.runDuty
```

Walking speed is **derived**, never authored: stride travel divided by contact
time. If you retune a creature, change `strideK`/`duty`/`freqK` and let speed fall
out. Measured results are in §16.

---

## 7. Two-bone IK (lines 436–481)

All IK works in **rig space** = the parent space of `inst.root`, so a wrapper
above the root may translate, rotate and uniformly scale without disturbing the
solve. In Godot: put the rig root under a `Node3D` wrapper and do the maths in the
wrapper's local space (`wrapper.global_transform.affine_inverse() * node.global_transform`).

```gdscript
# ik2: place a 2-link chain from H to T, elbow/knee pushed toward `pole`.
static func ik2(H: Vector3, T: Vector3, L1: float, L2: float, pole: Vector3) -> Dictionary:
	var v: Vector3 = T - H
	var d: float = v.length()
	var lo: float = absf(L1 - L2) + 1e-4
	var hi: float = L1 + L2 - 1e-4
	if d < 1e-6:
		v = Vector3(0, -1, 0); d = 1e-6
	var dc: float = clampf(d, lo, hi)                 # target distance, clamped
	var dir: Vector3 = v / d                          # NOTE: divided by d, not dc
	var a: float = acos(clampf((L1*L1 + dc*dc - L2*L2) / (2.0*L1*dc), -1.0, 1.0))
	var axis: Vector3 = dir.cross(pole)
	if axis.length_squared() < 1e-9: axis = Vector3(1, 0, 0)
	else: axis = axis.normalized()
	var thigh: Vector3 = dir.rotated(axis, a)
	var knee: Vector3  = H + thigh * L1
	var tgt: Vector3   = H + dir * dc
	var shin: Vector3  = (tgt - knee).normalized()
	return {"thigh": thigh, "shin": shin, "knee": knee, "tgt": tgt}
```

Order of operations that a naive port gets wrong: `dir` is normalised by the
**unclamped** `d`, while the cosine rule uses the **clamped** `dc`. Over-extended
targets therefore keep their direction but pull the effective tip to `hi`.

```gdscript
# rig-space position of a node
static func rig_pos(node: Node3D, inv_rig: Transform3D) -> Vector3:
	return inv_rig * node.global_transform.origin

# point a bone's local −Y along dir_rig
static func aim_rig(node: Node3D, dir_rig: Vector3, inv_rig_q: Quaternion) -> void:
	var q1 := Quaternion(Vector3(0, -1, 0), dir_rig)
	var q2 := node.get_parent_node_3d().global_transform.basis.get_rotation_quaternion()
	var q3 := (inv_rig_q * q2).inverse()
	node.quaternion = q3 * q1

# force a bone's rig-space orientation to q_rig
static func orient_rig(node: Node3D, q_rig: Quaternion, inv_rig_q: Quaternion) -> void:
	var q2 := node.get_parent_node_3d().global_transform.basis.get_rotation_quaternion()
	node.quaternion = (inv_rig_q * q2).inverse() * q_rig

static func solve_leg(hip_n, knee_n, H, T, L, inv_q) -> void:
	var pole: Vector3 = Vector3(L.pole[0], L.pole[1], L.pole[2]).normalized()
	var o := ik2(H, T, L.L1, L.L2, pole)
	aim_rig(hip_n,  o.thigh, inv_q); hip_n.force_update_transform()
	aim_rig(knee_n, o.shin,  inv_q); knee_n.force_update_transform()
```

`aimRig` **must** be followed by a world-matrix update before the child is aimed —
the child's solve reads the parent's fresh world quaternion. In Godot,
`force_update_transform()` (or read/compose transforms manually) after each bone.
Skipping it produces a one-frame-lagged limb that visibly detaches at speed.

`solveArm` (lines 577–587) is `ik2` on the arm plus an outright wrist orientation:

```gdscript
static func solve_arm(inst, A, target: Vector3, pole: Vector3, inv_q, hand_q) -> float:
	var H := rig_pos(inst.obj[A.shoulder], inst.inv_rig)
	var d := (target - H).length()
	var o := ik2(H, target, A.L1, A.L2, pole.normalized())
	aim_rig(inst.obj[A.shoulder], o.thigh, inv_q); update()
	aim_rig(inst.obj[A.elbow],    o.shin,  inv_q); update()
	if inst.obj.has(A.wrist) and hand_q != null:
		orient_rig(inst.obj[A.wrist], hand_q, inv_q); update()
	return d / (A.L1 + A.L2)            # reach fraction, >1 means over-extended
```

Setting the wrist outright is what puts a weapon **in** the palm rather than near it.

---

## 8. Clips (lines 488–503)

```gdscript
const CLIPS  : Array[String] = ["idle", "walk", "run", "aim", "attack", "stagger", "death"]
const CLIPLEN := {"idle": 3.4, "walk": 1.0, "run": 1.0, "aim": 9.0,
                  "attack": 1.15, "stagger": 0.85, "death": 1.7}
```

`walk`/`run` lengths of 1.0 are nominal — locomotion is driven by `t * freq`, so
those clips are unbounded in time and the length is only used by the viewer's
scrub bar. `attack`, `stagger` and `death` are one-shot and clamp `t` to the length.

### 8.1 `AIM_PATH` — the aim rehearsal (lines 493–503)

Nine waypoints, in rig space, metres. `fire` gates the muzzle flash.

| # | x | y | z | fire |
|---|---|---|---|---|
| 0 | 0.0 | 1.00 | 9.0 | 1 |
| 1 | 5.5 | 1.30 | 6.0 | 1 |
| 2 | −6.0 | 2.60 | 4.5 | 1 |
| 3 | 2.0 | 0.06 | 2.6 | 1 |
| 4 | −2.5 | 3.60 | 3.0 | 0 |
| 5 | 7.0 | 1.10 | −3.0 | 1 |
| 6 | −5.0 | 0.70 | −5.5 | 1 |
| 7 | 0.0 | 4.20 | 1.6 | 0 |
| 8 | 1.2 | 0.90 | 1.4 | 1 |

```gdscript
static func aim_target_for(inst, clip: String, t: float):
	var S: float = inst.stats.height if inst.stats else 1.7
	if inst.aim_at != null:
		return inst.aim_at                                    # explicit target wins
	if clip == "aim":
		var n := AIM_PATH.size()                              # 9
		var seg := CLIPLEN["aim"] / n                         # 1.0 s per leg
		var i := int(floor(t / seg)) % n
		var u := fposmod(t, seg) / seg
		var a: Vector3 = AIM_PATH[i].p
		var b: Vector3 = AIM_PATH[(i + 1) % n].p
		var k := smooth(clampf((u - 0.62) / 0.34, 0.0, 1.0))   # hold 62%, then move
		return Vector3(lerpf(a.x, b.x, k),
		               lerpf(a.y, b.y, k) * (S / 1.75),        # only Y scales with height
		               lerpf(a.z, b.z, k))
	if clip == "attack":
		if inst.rig.aim: return Vector3(0, S * 0.62, 7.0)
		return Vector3(0, S * 0.45, 1.6)                       # melee: just face it
	return null
```

Only the **Y** component is scaled by `height/1.75`. X and Z are absolute metres.

### 8.2 `firePulse` (lines 561–572)

```gdscript
static func fire_pulse(inst, clip: String, t: float) -> float:
	if clip == "attack":
		return maxf(0.0, 1.0 - absf(t - 0.40) / 0.09)          # single spike at t=0.40
	if clip == "aim":
		var n := 9; var seg := 1.0
		var i := int(floor(t / seg)) % n
		if AIM_PATH[i].fire == 0: return 0.0
		var u := fposmod(t, seg) / seg
		var f := 0.0
		for c in [0.22, 0.40]:                                  # two shots per waypoint
			f = maxf(f, 1.0 - absf(u - c) / 0.035)
		return maxf(0.0, f)
	return 0.0

static func fire_fx(inst, clip: String, t: float) -> void:
	if inst.fx.is_empty(): return
	var f := fire_pulse(inst, clip, t)
	for m in inst.fx:
		m.scale = Vector3.ONE * (0.0001 + f * m.fxs)
```

---

## 9. `poseInst` — the master pose function (lines 759–983)

Signature `poseInst(inst, clip, t, opt)`. `opt.take` selects the death variant.
This function is a **pure write of every bone's local rotation plus the root's
position/rotation**; nothing accumulates. Order matters — reproduce it exactly.

### 9.0 Prologue

```gdscript
var g := inst.gait
var SC: float = g.get("hipH", g.get("hoverH", 1.0))     # body-size scalar
var inv_rig := root_parent.global_transform.affine_inverse()   # identity if no parent
var inv_q   := root_parent.global_basis.get_rotation_quaternion().inverse()
var loco  := clip == "walk" or clip == "run"
var freq  := g.runFreq if clip == "run" else g.freq
var duty  := g.runDuty if clip == "run" else g.duty
var E     := g.runE    if clip == "run" else g.E
var cyc   := t * freq if loco else 0.0
var amp   := 1.0 if loco else 0.0
if clip == "death":
	death_to(inst, t, opt.get("take", inst.death_take))
	fire_fx(inst, clip, t); inst.travel = 0.0; return
```

### 9.1 Clip-level body offsets

```gdscript
var body_y := 0.0; var body_z := 0.0
var body_pitch := 0.0; var body_roll := 0.0; var body_yaw := 0.0; var crouch := 0.0
var atk := 0.0; var stg := 0.0
var br := sin(t * 1.5 * TAU / 3.4) * 0.5 + 0.5                 # breathing 0..1
if clip == "idle":    body_y = sin(t * TAU / 3.4) * 0.012 * SC
if clip == "attack":  atk = clampf(t / 1.15, 0.0, 1.0)
if clip == "stagger": stg = clampf(t / 0.85, 0.0, 1.0)

var melee := inst.rig.aim == null
if atk > 0.0 and melee:
	var w := smooth(atk / 0.34) if atk < 0.34 else 1.0 - smooth(clampf((atk - 0.34) / 0.5, 0, 1))
	var l := -1.0 if atk < 0.34 else 1.0
	body_pitch += 0.16 * w * l
	body_z     += 0.045 * w * l * SC
if stg > 0.0:
	var w := sin(PI * stg) * exp(-stg * 1.2)
	body_pitch -= 0.42 * w
	body_z     -= 0.085 * w * SC
	body_roll  += 0.18 * w
	crouch     += 0.10 * w
```

### 9.2 Aim decomposition — stance / waist / head

```gdscript
var aim_t = aim_target_for(inst, clip, t)
var stance_yaw := 0.0; var waist_yaw := 0.0; var waist_pitch := 0.0
var head_yaw := 0.0; var head_pitch := 0.0; var aiming := 0.0
if aim_t != null:
	aiming = 1.0
	var cx: float = inst.rig.aim.eyeZ if (inst.rig.aim and inst.rig.aim.has("eyeZ")) else 0.0
	var ay := SC * 1.15                                  # notional eye height
	var az := atan2(aim_t.x, aim_t.z - cx)               # azimuth
	var flat := sqrt(aim_t.x*aim_t.x + (aim_t.z-cx)*(aim_t.z-cx))
	var el := atan2(aim_t.y - ay, maxf(flat, 0.05))      # elevation
	var turn: float = inst.rig.tags.turn if inst.rig.tags.has("turn") else (PI if inst.rig.aim else 0.0)
	waist_yaw   = clampf(az, -0.62, 0.62)                # a waist twists ±35.5°
	stance_yaw  = clampf(az - waist_yaw, -turn, turn)    # the feet take the rest
	waist_pitch = clampf(-el * 0.36, -0.34, 0.30)
	head_yaw    = clampf(az - waist_yaw * 0.9, -0.85, 0.85) * 0.55
	head_pitch  = clampf(-el * 0.55, -0.75, 0.65)
	if inst.rig.aim and inst.rig.aim.mode == "turret":
		waist_yaw = 0.0; stance_yaw = 0.0; waist_pitch = 0.0
var aim_blend := 0.0
if aiming > 0.0:
	aim_blend = clampf(t / 0.22, 0.0, 1.0) if clip == "attack" else 1.0
```

### 9.3 Spine, head, neck

```gdscript
var sway   := sin(cyc * TAU) if loco else 0.0
var bounce := sin(cyc * 2.0 * TAU) if loco else 0.0
var lean   := (tags.get("leanRun", 0.0) * (1.0 if clip == "run" else 0.35)) if loco else 0.0
var sp: Array = tags.get("spine", [])
var flexK: float = tags.flex if tags.has("flex") else 1.15
var hunch: float = tags.get("hunch", 0.0) * (1.0 - aim_blend * 0.55)
for i in sp.size():
	var f := float(i + 1) / sp.size()
	var tw := minf(1.0, flexK)                # a long horizontal spine barely twists
	var px := hunch * f + (body_pitch * flexK + lean) * f \
	        + amp * bounce * 0.020 * f + (br * 0.012 * f if clip == "idle" else 0.0) \
	        + waist_pitch * aim_blend * f * tw
	var py := body_yaw * f * 0.6 + amp * sway * 0.045 * f + waist_yaw * aim_blend * f * tw
	var pz := body_roll * f * 0.8 + amp * sway * 0.030 * f
	set_rot(sp[i], px, py, pz)

if tags.head:
	var hp := -hunch * 1.1 - body_pitch * 0.7 + (-bounce * 0.02 if loco else 0.0) \
	        + (sin(t * TAU / 3.4 + 1.1) * 0.05 if (clip == "idle" and aiming == 0.0) else 0.0) \
	        + head_pitch * aim_blend
	var hy := (sin(t * TAU / 5.1) * 0.30 if (clip == "idle" and aiming == 0.0) else 0.0) \
	        + (sway * 0.06 if loco else 0.0) - body_yaw * 0.5 + stg * 0.2 + head_yaw * aim_blend
	set_rot(tags.head, hp, hy, -body_roll * 0.5)

if tags.neck:
	set_rot(tags.neck, tags.get("neckPitch", 0.0) - body_pitch * 0.35, (sway * 0.04 if loco else 0.0), 0.0)
```

Idle head sway uses two incommensurate periods (3.4 s and 5.1 s) so the loop never
visibly repeats.

### 9.4 Arms (procedural pass)

```gdscript
for A in rig.arms:
	var ph: float = A.get("phase", 0.0)
	var s := sin((cyc + ph) * TAU) if loco else 0.0
	var gain := 1.7 if clip == "run" else 1.0
	var sx: float = A.rest[0] + s * A.get("swing", 0.55) * gain * amp
	var sy: float = A.rest[1]
	var sz: float = A.rest[2]
	var ex: float = A.elbowRest + ((0.34 - 0.30 * s) * gain * amp if loco else 0.0)
	if clip == "idle":
		sx += sin(t * TAU / 3.4 + ph * 3.0) * 0.030
		ex += br * 0.05
	if aiming > 0.0 and A.get("carry", false):
		sx = A.carryPose[0]; sy = A.carryPose[1]; sz = A.carryPose[2]; ex = A.carryPose[3]
	if atk > 0.0 and A.get("attack", false) and melee:
		var w := smooth(atk / 0.30) if atk < 0.30 else 1.0 - smooth(clampf((atk - 0.30) / 0.42, 0, 1))
		var l := -1.0 if atk < 0.30 else 1.0
		var k := minf(1.0, w + 0.35)
		sx = lerpf(sx, A.atkPose[0] + (-A.atkWind if l < 0 else 0.0), k)
		sz = lerpf(sz, A.atkPose[2], k)
		ex = lerpf(ex, A.atkPose[3] + (A.atkWind * 0.8 if l < 0 else 0.0), k)
	if stg > 0.0:
		var w := sin(PI * stg)
		sx = lerpf(sx, -0.9, w * 0.8)
		ex = lerpf(ex, 1.3, w * 0.8)
		sz = lerpf(sz, A.rest[2] + 0.5 * A.side, w * 0.7)
	set_rot(A.shoulder, sx, sy, sz)
	set_rot(A.elbow, -maxf(ex, 0.0), 0.0, 0.0)          # elbow only ever flexes
	if A.wrist:
		var wr: Array = A.get("wristRest", [0.0, 0.0, 0.0])
		set_rot(A.wrist, wr[0], wr[1], wr[2] - sz * 0.85)
```

The `atkPose` windup applies `-atkWind` to the shoulder and `+0.8·atkWind` to the
elbow during the first 30 % of the swing, then releases.

### 9.5 Wags and spinners

```gdscript
for W in tags.get("wags", []):                 # tails, booms, sensor heads
	var s := sin(t * TAU * W.f + W.get("ph", 0.0)) * W.a * (1.6 if loco else 1.0)
	node(W.b).rotation = Vector3(W.get("base", 0.0) + (s if W.ax == "x" else 0.0),
	                             s if W.ax == "y" else 0.0,
	                             s if W.ax == "z" else 0.0)
for S in tags.get("spin", []):                 # rotors
	node(S.b).rotation.y = t * S.rate
```

Note the `base` offset is only added on the **x** channel regardless of `ax`.
That is the reference's behaviour; foreman's booms rely on it (`ax:'x'`), and
latchdog's tail uses `ax:'y', base:0`, so nothing breaks — but do not "fix" it.

### 9.6 Hover root placement (legless rigs)

```gdscript
if g.type == "hover":
	var hover_y: float = g.get("hoverH", 1.2) + sin(t*TAU*0.55)*0.05 + sin(t*TAU*1.31 + 1.7)*0.022
	root.position = Vector3(sin(t * TAU * 0.37) * 0.05, hover_y, 0.0)
	root.rotation = Vector3(body_pitch*0.5 + (-0.22 if loco else 0.0),
	                        body_yaw,
	                        body_roll*0.6 + (0.05 if loco else 0.0))
	update()
	if rig.aim and rig.aim.mode == "turret" and aim_t != null: solve_turret(inst, aim_t)
	fire_fx(inst, clip, t)
	inst.travel = (g.runSpeed if clip == "run" else g.speed) if loco else 0.0
	return
```

### 9.7 Legged root placement, including **ballistic flight**

```gdscript
var bob_y := -absf(bounce) * g.bob * 2.0 if loco else 0.0
var flight := 0.0
if loco and not legs.is_empty():
	var t_prev := INF; var t_next := INF; var support := 0
	for L in legs:
		var p := fposmod(cyc + L.get("phase", 0.0), 1.0)
		if p < duty: support += 1
		t_next = minf(t_next, fposmod(1.0 - p, 1.0))
		t_prev = minf(t_prev, fposmod(p - duty, 1.0))
	if support == 0:                                   # airborne: real projectile arc
		var T := t_prev + t_next
		var u := t_prev / T if T > 1e-6 else 0.0
		var secs := T / freq
		flight = (9.81 * secs * secs / 8.0) * sin(PI * u)
var root_y := body_y + bob_y + flight - crouch * (g.hipH * 0.82)
root.position = Vector3(0, root_y, body_z)
root.rotation = Vector3(body_pitch * 0.12,
                        body_yaw + stance_yaw * aim_blend,
                        body_roll * 0.30 + (sway * g.sway if loco else 0.0))
update()
```

The flight term is the exact apex of a ballistic arc of duration `secs`
(`h = g·T²/8`), shaped by `sin(π·u)` so it starts and ends at zero. Runs with
`runDuty < 0.5` on a biped genuinely leave the ground.

### 9.8 Foot targets and the pelvis dip

```gdscript
var T: Array[Vector3] = []; var ROLL: Array[float] = []; var PD: Array = []
var cy := cos(stance_yaw * aim_blend); var sy := sin(stance_yaw * aim_blend)
for i in legs.size():
	var L = legs[i]
	var p := fposmod(cyc + L.get("phase", 0.0), 1.0) if loco else -1.0
	var stance := p >= 0.0 and p < duty
	var swing  := p >= duty
	var u := (p - duty) / (1.0 - duty) if swing else 0.0
	var fz: float = L.rz; var fx: float = L.rx; var lift := 0.0
	if stance:
		fz = L.rz + E * (0.5 - p / duty)                         # foot slides back, linearly
	elif swing:
		fz = L.rz + E * (-0.5 + smooth(u))
		lift = sin(PI * pow(u, 0.86)) * g.lift * (1.35 if clip == "run" else 1.0)
	elif atk > 0.0 and melee and L.get("plant", true) != false:
		fz = L.rz + body_z + (0.06 if i % 2 == 0 else -0.06) * sin(PI * atk) * g.reach
	elif stg > 0.0:
		fz = L.rz + body_z - sin(PI * stg) * g.reach * 0.10 * (1.0 if i % 2 else 0.4)

	var roll := 0.0
	if stance:  roll = lerpf(-0.20, 0.42, p / duty)              # heel-strike → toe-off
	elif swing: roll = lerpf(0.42, -0.20, smooth(u)) - sin(PI * u) * 0.30
	roll *= L.get("rollK", 1.0)
	ROLL.append(roll)

	var rx := fx * cy + fz * sy                                  # rotate stance with the aim
	var rz := -fx * sy + fz * cy
	if L.has("pastern"):                                          # digitigrade / hoofed
		var a := L.pastern.a0 + (L.pastern.a1 - L.pastern.a0) * (p / duty if stance else (1.0 - smooth(u) if swing else 0.0))
		var d := Vector3(0, -cos(a), sin(a) * L.pastern.get("dir", 1)).normalized()
		d = d.rotated(Vector3.UP, stance_yaw * aim_blend)
		PD.append(d)
		T.append(Vector3(rx, L.pastern.padR + lift, rz) - d * L.pastern.len)
	else:
		var fy: float
		if L.has("sole"):                                        # plantigrade boot
			var c := cos(roll); var sn := sin(roll)
			fy = -minf(-L.sole.h*c - L.sole.zb*sn, -L.sole.h*c - L.sole.zf*sn)
		else:
			fy = L.standY
		PD.append(null)
		T.append(Vector3(rx, fy + lift, rz))

# pelvis dip: drop the whole body just enough that no leg over-reaches
var dip := 0.0
for i in legs.size():
	var L = legs[i]
	var H := rig_pos(node(L.hip), inv_rig)
	var Rm := 0.985 * (L.L1 + L.L2)
	var dxz := sqrt(pow(H.x - T[i].x, 2) + pow(H.z - T[i].z, 2))
	if dxz >= Rm:
		dip = maxf(dip, L.dropMax); continue
	var hy := T[i].y + sqrt(Rm*Rm - dxz*dxz)
	if H.y - hy > dip: dip = minf(H.y - hy, L.dropMax)
if dip > 1e-5:
	root.position.y = root_y - dip
	update()

for i in legs.size():
	var L = legs[i]
	solve_leg(node(L.hip), node(L.knee), rig_pos(node(L.hip), inv_rig), T[i], L, inv_q)
	if not node_exists(L.ankle): continue
	if L.has("pastern"):
		orient_rig(node(L.ankle), Quaternion(Vector3(0,-1,0), PD[i]), inv_q)
	else:
		orient_rig(node(L.ankle),
			Quaternion(Basis.from_euler(Vector3(L.get("footBase",0.0) + ROLL[i],
			                                    L.get("footYaw",0.0) + stance_yaw*aim_blend, 0),
			                            EULER_ORDER_XYZ)), inv_q)
	update()
```

`0.985` is the hard limit on leg extension and it is exactly what the validator
reports as `worst.reach` for 10 of the 11 legged species. **The pelvis dips; the
legs do not rest bent.** That is why `humanoid()` uses `bend = 0.985`.

### 9.9 Weapon and hands, then travel

```gdscript
update()
if rig.aim and aim_t != null:      solve_weapon(inst, aim_t, aim_blend)
elif rig.aim:                      solve_weapon(inst, Vector3(0, SC * 1.15, 6.0), 1.0)
fire_fx(inst, clip, t)
inst.travel = (g.runSpeed if clip == "run" else g.speed) if loco else 0.0
```

An armed rig is **always** aim-solved, even at idle, pointing at
`(0, SC·1.15, 6)`. That is what keeps the gun in both hands when standing still.

---

## 10. Exact aim (lines 994–1074)

### 10.1 `aimQuat` — closed-form muzzle-on-target

A weapon is a rigid body pivoting about an anchor with the muzzle **offset** from
that pivot, so pointing the pivot at the target is *not* pointing the muzzle at it.
Solve: find λ such that `|m + λ·f| = |T − anchor|`, then rotate that point onto the
target direction.

```gdscript
static func aim_quat(anchor: Vector3, m: Vector3, f: Vector3, T: Vector3,
                     up_local: Vector3, roll: float) -> Quaternion:
	var dv := T - anchor
	var d := dv.length()
	if d < 1e-5: return Quaternion.IDENTITY
	var mf := m.dot(f)
	var m2 := m.length_squared()
	var lam := -mf + sqrt(maxf(mf*mf - m2 + d*d, 1e-8))
	var uv := m + f * lam
	if uv.length_squared() < 1e-10: uv = f
	uv = uv.normalized(); dv = dv.normalized()
	var out := Quaternion(uv, dv)
	# free roll about the aim axis: bring the weapon's own up as near vertical as possible
	var yv := out * up_local
	var pa := yv - dv * yv.dot(dv)
	var pb := Vector3(0, 1, 0) - dv * dv.y
	if pa.length_squared() > 1e-8 and pb.length_squared() > 1e-8:
		pa = pa.normalized(); pb = pb.normalized()
		var ang := acos(clampf(pa.dot(pb), -1.0, 1.0))
		if pa.cross(pb).dot(dv) < 0.0: ang = -ang
		out = Quaternion(dv, ang) * out             # PRE-multiply
	if roll != 0.0:
		out = out * Quaternion(f.normalized(), roll)  # POST-multiply
	return out
```

`m` is the muzzle offset in the weapon bone's local frame, `f` the weapon's local
forward. The pre-multiply/post-multiply asymmetry is deliberate: the levelling roll
is applied in **rig space** (about the aim axis), the authored `roll` in **weapon
space** (about its own forward). Swapping them tilts the gun wrongly at high
elevation.

### 10.2 `solveTurret` (lines 1019–1035)

Yaw-then-pitch in the mount's own space, clamped, iterated 8 times because the
muzzle offset moves as the head turns:

```gdscript
static func solve_turret(inst, T: Vector3) -> void:
	var a = inst.rig.aim
	var bone := inst.obj[a.yawBone]
	var mount_to_rig := inst.inv_rig * bone.get_parent_node_3d().global_transform
	var tl := mount_to_rig.affine_inverse() * T
	var mL := Vector3(a.muzzle[0], a.muzzle[1], a.muzzle[2])
	for it in 8:
		var uL := bone.quaternion * mL + bone.position
		var dx := tl.x - uL.x; var dy := tl.y - uL.y; var dz := tl.z - uL.z
		var yaw := atan2(dx, dz)
		var pit := atan2(-dy, sqrt(dx*dx + dz*dz))
		bone.quaternion = Quaternion(Basis.from_euler(
			Vector3(clampf(pit, a.pitch[0], a.pitch[1]),
			        clampf(yaw, a.yaw[0], a.yaw[1]), 0.0), EULER_ORDER_YXZ))
	update()
```
**This is one of the three `'YXZ'` sites.**

### 10.3 `solveWeapon` (lines 1038–1074)

```
mode == 'turret'   → solveTurret
mode == 'shoulder' → aimQuat about the gun bone's own rig-space anchor,
                     orientRig the gun, then for each entry in aim.hands:
                       grip point   = gun.local→rig of h.grip
                       hand quat    = gunQuat * Euler(h.hand, 'XYZ')
                       pole         = gunQuat * h.pole, with pole.y clamped ≤ −0.35, normalised
                       solveArm(arm, grip, pole, handQuat)
mode == 'hand'     → wrist is placed on the aim line first, then oriented exactly:
                       dir   = normalize(T − shoulderRigPos)   (fallback +Z)
                       reach = (L1+L2) * (aim.hold or 0.80)
                       tgt   = shoulder + dir*reach
                       tgt.y += (aim.drop or 0) * (L1+L2) * max(0, 1 − |dir.y|*1.4)
                       pole  = (aim.pole[0] or side*0.7, −1, −0.35)
                       solveArm(..., handQ = null)
                       then aimQuat at the resolved wrist position and orientRig the wrist
```

The `pole.y = min(pole.y, −0.35)` clamp on shoulder-mode hands is what stops an
elbow flipping up over the shoulder when the gun points steeply down.

### 10.4 `aimError` (lines 1078–1091)

```gdscript
static func aim_error(inst, T: Vector3) -> float:
	var a = inst.rig.aim
	if a == null or not a.has("fwd"): return 0.0
	var bone: Node3D
	match a.mode:
		"shoulder": bone = inst.obj[a.bone]
		"turret":   bone = inst.obj[a.yawBone]
		_:          bone = inst.obj[inst.rig.arms[a.arm].wrist]
	if bone == null: return 0.0
	var mw := inst.inv_rig * (bone.global_transform * Vector3(a.muzzle[0], a.muzzle[1], a.muzzle[2]))
	var fw := (inst.inv_rig.basis * (bone.global_transform.basis * Vector3(a.fwd[0], a.fwd[1], a.fwd[2]))).normalized()
	var tw := (T - mw).normalized()
	return acos(clampf(fw.dot(tw), -1.0, 1.0))          # radians
```

This is the quantity a downstream accuracy model should sample: the residual
angle between where the muzzle actually points and where it was told to point.
For the ported AI, feed `aim_error` into the hit roll instead of inventing a
spread cone.

---

## 11. Death — a seeded collapse, not a keyframe (lines 597–753)

`DT = 1/120`, `PI_2 = PI/2`. The whole thing is a fixed-step sim replayed from
`t = 0`, so `(seed, take, t)` reproduces a frame exactly.

### 11.1 `deathInit(inst, take)`

```gdscript
var seed_u: int = ((inst.seed * 2654435761) ^ (take * 40503 + 7)) & 0xFFFFFFFF
var r := Rng.new(seed_u)
var nl: int = inst.gait.legs.size()
var s := {
	"take": take, "t": 0.0, "y": 0.0, "vy": 0.0,
	"yaw":   r.next() * TAU,                     # direction of the topple
	"spin":  (r.next() - 0.5) * 3.4,             # residual yaw spin
	"yawSpin": 0.0,
	"theta": 0.03 + r.next() * 0.06,             # initial tip angle
	"omega": 2.3 + r.next() * 3.0,               # initial tip rate
	"buckle": 0.01 + r.next() * 0.09,            # when the knees give
	"bDur":   0.09 + r.next() * 0.15,            # how long they take
	"knee": [], "hip": [], "land": 0.0, "limbs": {},
	"hSeed": r.next(),                           # head loll amount
	"lean":  (r.next() - 0.5) * 1.2,
	"twist": (r.next() - 0.5) * 1.5,
	"settle": 0.010 + 0.012 * inst.gait.get("hipH", 1.0)
}
for i in nl:
	s.knee.append(0.85 + r.next() * 1.15)
	s.hip.append((r.next() - 0.5) * 1.0)
for A in inst.rig.arms:
	s.limbs[A.shoulder] = {"d": Vector3(A.side * 0.25, -1, 0.05).normalized(),
	                       "v": Vector3.ZERO, "k": 55 + r.next() * 70, "c": 6 + r.next() * 4}
	s.limbs[A.elbow]    = {"d": Vector3(A.side * 0.15, -1, 0.15).normalized(),
	                       "v": Vector3.ZERO, "k": 90 + r.next() * 90, "c": 5 + r.next() * 4}
```

**Draw order is load-bearing.** `yaw, spin, theta, omega, buckle, bDur, hSeed,
lean, twist`, then `nl` pairs of `(knee, hip)`, then per-arm `(k_sh, c_sh, k_el,
c_el)`. Any reordering changes every fall.

Note `s.settle` uses `inst.gait.hipH` with an `|| 1` fallback (so hover rigs get 1).

### 11.2 `limbFollow` — damped vector spring

```gdscript
static func limb_follow(st, want: Vector3, dt: float) -> Vector3:
	st.v += (want - st.d) * (st.k * dt)
	st.v *= maxf(0.0, 1.0 - st.c * dt)
	st.d = (st.d + st.v * dt).normalized()
	return st.d
```
Semi-implicit Euler, stable only because `dt` is pinned to 1/120 and `k ≤ 180`.
`k·dt ≤ 1.5` — do **not** run this at variable `delta`.

### 11.3 `clampLimb` — stop a limb spearing through the floor

```gdscript
static func clamp_limb(d: Vector3, origin: Vector3, length: float, floor_y: float) -> Vector3:
	var min_y := (floor_y - origin.y) / maxf(length, 1e-4)
	if d.y < min_y and min_y < 1.0:
		var y := maxf(-1.0, min_y)
		var h := sqrt(maxf(0.0, 1.0 - y*y))
		var hl := sqrt(d.x*d.x + d.z*d.z)
		if hl > 1e-6: d.x = d.x / hl * h; d.z = d.z / hl * h
		else:         d.x = h; d.z = 0.0
		d.y = y
	return d
```
It preserves the horizontal heading and only tilts the limb up.

### 11.4 `deathAdvance` — one 1/120 s step

```gdscript
static func death_advance(inst, s, L: float) -> void:
	var G2 := 9.81 / maxf(L, 0.25)               # angular gravity, scaled by body size
	var w0: float = s.omega
	s.omega += G2 * sin(minf(s.theta, PI/2.0)) * DT * 1.7
	s.theta += s.omega * DT
	if s.theta >= 1.55:                          # hit the ground, bounce back a little
		s.theta = 1.55 - (s.theta - 1.55) * 0.2
		s.omega = -absf(s.omega) * 0.18
	s.omega *= (1.0 - (2.0 + 9.0 * s.land) * DT)
	s.yawSpin += s.spin * DT * 0.35
	s.spin *= (1.0 - (1.4 + 26.0 * s.land) * DT)
	var tip_ax := Vector3(cos(s.yaw), 0, -sin(s.yaw))
	for k in s.limbs:
		var u = s.limbs[k]
		u.d = u.d.rotated(tip_ax, w0 * DT * 1.3).rotated(Vector3(0,-1,0), -s.spin * DT * 0.35).normalized()
		limb_follow(u, Vector3(0, -1, 0), DT)
	s.t += DT
```

Note the limbs are carried by `w0` — the tip rate from **before** this step's
integration, not after.

### 11.5 `poseDeath`

```gdscript
var SC: float = g.get("hipH", g.get("hoverH", 1.0))
var sag := smooth(clampf((s.t - 0.02) / 0.30, 0.0, 1.0))

if g.type == "hover":
	root.position = Vector3(sin(s.yaw) * s.theta * 0.4, s.y, cos(s.yaw) * s.theta * 0.4)
	root.rotation = Vector3(cos(s.yaw)*s.theta*1.5, s.yawSpin*2.2, -sin(s.yaw)*s.theta*1.5)  # YXZ
else:
	# tip about the EDGE OF THE FOOT, not the root, or the body vaults into the air
	var eD := Vector3(cos(s.yaw)*s.theta, s.yawSpin, -sin(s.yaw)*s.theta)       # YXZ
	root.rotation = eD
	var piv := Vector3(sin(s.yaw), 0, cos(s.yaw)) * (0.26 * SC)
	var pv2 := Basis.from_euler(eD, EULER_ORDER_YXZ) * piv
	root.position = Vector3(piv.x - pv2.x, s.y + piv.y - pv2.y, piv.z - pv2.z)
update()

for i in sp.size():                                        # spine sag
	var f := float(i + 1) / sp.size()
	set_rot(sp[i], tags.get("hunch",0.0)*f + sag*(0.30 + 0.45*s.lean)*f,
	               sag * s.twist * 0.45 * f,
	               sag * sin(s.yaw) * 0.45 * f)
if tags.head: set_rot(tags.head, sag*(0.45 + 0.65*s.hSeed), s.twist*0.9*sag, sin(s.yaw*2.0)*0.5*sag)
if tags.neck: set_rot(tags.neck, tags.get("neckPitch",0.0) + 0.45*sag, 0, 0)
for W in tags.get("wags", []):  set_rot(W.b, W.get("base",0.0), 0, 0)   # wags freeze at base
for S in tags.get("spin", []):  node(S.b).rotation.y = s.t * S.rate * maxf(0.0, 1.0 - s.t*1.6)  # rotors spin down

var f := smooth(clampf((s.t - s.buckle) / s.bDur, 0.0, 1.0))
for i in g.legs.size():
	var L = g.legs[i]
	set_rot(L.hip,  -0.08 - 0.55*f + s.hip[i]*f, s.hip[i]*f*0.4, s.hip[i]*f*0.5)
	set_rot(L.knee, s.knee[i]*f, 0, 0)
	if node_exists(L.ankle): set_rot(L.ankle, 0.30*f + (L.pastern.a0 if L.has("pastern") else 0.0), 0, 0)
update()

var floor_y := -0.03 * SC                                   # allow a little sink
for A in rig.arms:
	var su = s.limbs.get(A.shoulder); if su == null: continue
	var eu = s.limbs[A.elbow]
	aim_rig(node(A.shoulder), clamp_limb(su.d, rig_pos(node(A.shoulder), inv_rig), A.L1, floor_y), inv_q); update()
	var ed := clamp_limb(eu.d, rig_pos(node(A.elbow), inv_rig), A.L2 * 1.55, floor_y)   # hand hangs past the wrist
	aim_rig(node(A.elbow), ed, inv_q); update()
	if node_exists(A.wrist):
		orient_rig(node(A.wrist), Quaternion(Vector3(0,-1,0), ed), inv_q); update()

if rig.aim and rig.aim.mode == "shoulder" and node_exists(rig.aim.bone):
	var gp := rig_pos(node(rig.aim.bone), inv_rig)
	var glen: float = Vector3(rig.aim.muzzle[0], rig.aim.muzzle[1], rig.aim.muzzle[2]).length()
	var gd := clamp_limb(Vector3(sin(s.yaw)*0.55, -0.8, cos(s.yaw)*0.55).normalized(), gp, glen, floor_y)
	orient_rig(node(rig.aim.bone), look_q(gd), inv_q); update()
```

`look_q(dir)`: quaternion whose local **+Z** lies along `dir`, up = `(0,1,0)`
except when `|dir.y| > 0.985`, where up becomes `(0,0,∓1)` (sign = `−sign(dir.y)`).
In Godot: `Quaternion(Basis.looking_at(-dir, up))`.

### 11.6 `deathTo(inst, t, take)` — the driver

```gdscript
if s == null or s.take != take or s.t > t + 1e-6:
	s = death_init(inst, take); pose_death(inst, s)
var L: float = inst.gait.get("hipH", inst.gait.get("hoverH", 1.0)) * 1.15
var guard := 0
while s.t < t and guard < 3000:
	guard += 1
	death_advance(inst, s, L)
	pose_death(inst, s)
	# contact judged on TORSO AND LEGS ONLY: an arm flung under the body must not
	# jack the corpse off the floor — it just clips.
	var low := lowest_point(inst, true)            # coreOnly = skip limbBones
	s.vy -= 9.81 * 2.8 * DT                        # 2.8 g: corpses drop fast
	s.y  += s.vy * DT
	if low <= 0.0:
		s.y -= low
		if s.vy < 0.0: s.vy = -s.vy * 0.10         # 10% restitution
		if s.theta > 0.95:                         # feet touching is not landing
			s.land = minf(1.0, s.land + DT * 10.0)
			s.omega *= (1.0 - 24.0 * DT)
	if s.land > 0.1:
		s.y -= s.settle * DT * 4.0 * s.land        # settle into the ground, no gap
pose_death(inst, s)
var low := lowest_point(inst, true)
if low < 0.0: s.y -= low; pose_death(inst, s)
```

The `guard < 3000` cap means a scrub beyond 25 s of sim silently stops advancing.
`lowestPoint(inst, coreOnly=true)` skips every bone in `inst.limbBones`
(shoulders, elbows, wrists, and the weapon bone).

### 11.7 `lowestPoint` (lines 507–530)

Lowest point over all non-`fx` parts in rig space, using exact support functions:

```
sph : c.y − r·scale.x
cyl : min(c.y + ax.y·h/2·sy − r0·sx·k , c.y − ax.y·h/2·sy − r1·sx·k)
      where ax = local +Y in rig space, k = sqrt(max(0, 1 − ax.y²))
box : c.y − (|ay0|·ex + |ay1|·ey + |ay2|·ez)   with ay_i = (world axis i).y
```

---

## 12. `deriveStats` (lines 1100–1146)

```gdscript
var mass := 0.0; var area := 0.0; var hard_area := 0.0
for p in rig.parts:
	var d = MAT[p.m]
	if d.get("fx", false): continue
	var v := part_volume(p); var a := part_area(p)
	var rho: float = p.rho if p.has("rho") else (rig.rho if rig.rho >= 0.0 else d.dens * d.get("fill", 1.0))
	mass += v * rho
	area += a
	hard_area += a * HARD.get(p.m, 0.0)
# boxes/cylinders bound a rounded body and every joint ball double-counts;
# measured against the primitives this over-counts by about a third.
mass *= 0.69
var cover := clampf(hard_area / maxf(area, 1e-6), 0.0, 1.0)

pose_inst(inst, "idle", 0.0)          # measure the STANDING pose, not the rest chain
# world AABB over the 8 corners of every non-fx part's extent box
var box := AABB()
for rec in inst.pmeta: ... expand by (±ex, ±ey, ±ez) transformed by bone.world * rec.local
var height := box.size.y; var width := box.size.x; var depth := box.size.z
var alt := maxf(0.0, box.position.y)                 # hovering units sit off the floor

var hp      := roundi(3.4 * pow(mass, 0.62) * (1.0 + 1.05 * cover) * rig.info.get("hpK", 1.0))
var armour  := roundi(clampf(cover * 80.0 * rig.info.get("armK", 1.0), 0.0, 95.0))
var speed   := g.get("speed", 0.0)
var run     := g.get("runSpeed", speed)
var reach   := rig.info.reach if rig.info.has("reach") else (g.reach * 0.9 if g.has("reach") else 1.0)
var dps     := rig.info.get("dps", 10)
var stagger := clampf(26.0 * log(1.0 + mass) / log(10.0), 2.0, 99.0)     # log10
var detect  := rig.info.get("detect", 40)
var threat  := 0.26 * clampf(26.0 * log10(1.0 + dps),  0.0, 99.0) \
             + 0.24 * clampf(23.0 * log10(1.0 + hp),   0.0, 99.0) \
             + 0.14 * clampf(run * 15.0,               0.0, 99.0) \
             + 0.14 * armour \
             + 0.11 * clampf(detect,                   0.0, 99.0) \
             + 0.11 * clampf(stagger,                  0.0, 99.0)
```

Weights sum to 1.00. `armour` is **not** re-clamped inside the threat sum, but it
is already capped at 95 by its own clamp.

`deriveStats` calls `poseInst(inst,'idle',0)` *during construction*, at which point
`inst.stats` is still null — `aimTargetFor` therefore falls back to `S = 1.7`.
Harmless (idle returns null anyway), but reproduce the ordering or armed rigs
measure a slightly different idle bbox.

### 12.1 TIERS (lines 1153–1161)

```gdscript
const TIERS := [
	{"n": "Vermin",   "c": "#6f6a63", "min": -1},
	{"n": "Common",   "c": "#8a9a6b", "min": 33},
	{"n": "Hardened", "c": "#57a0bb", "min": 40},
	{"n": "Elite",    "c": "#9a79c8", "min": 46},
	{"n": "Warlord",  "c": "#d8822f", "min": 54},
	{"n": "Apex",     "c": "#e6c14f", "min": 63}
]
static func tier_of(threat: float) -> Dictionary:
	var t = TIERS[0]
	for x in TIERS:
		if threat >= x.min: t = x     # ascending scan, last match wins
	return t
```
These are the project's canonical tier colours; they match the ART palette exactly.

---

## 13. `humanoid(R, o)` — the biped builder (lines 1350–1400)

Every parameter, with its default and where it lands:

| param | default | effect |
|---|---|---|
| `hipY` | required | pelvis bone height (m) |
| `footH` | required | boot slab thickness = sole height |
| `footL` | required | boot length (Z) |
| `legR` | required | thigh top radius |
| `hipW` | required | half-distance between hip pivots |
| `pelvH`,`pelvD` | required | pelvis box height/depth |
| `waistW`,`waistD` | required | abdomen box width/depth; also the spine & chest ball radii |
| `absH` | required | abdomen box height |
| `chestW`,`chestH`,`chestD` | required | chest box |
| `neckR`,`neckH` | required | neck radius/length; head ball = `neckR*1.16` |
| `shW` | required | half-distance between shoulder pivots |
| `armU`,`armL` | required | upper-arm / forearm bone lengths |
| `armR` | required | upper-arm top radius |
| `handL` | required | hand box length |
| `bend` | **0.985** | leg rest straightness: `total = (hipY−footH)/bend` |
| `split` | **0.52** | thigh fraction of the total leg |
| `stanceK` | **0.86** | foot X inset relative to the hip |
| `shY` | **0.72** | shoulder height as a fraction of `chestH` |
| `armOut` | **0.11** | shoulder Z-roll outward, times `side` |
| `armPitch` | **−0.06** | shoulder rest pitch |
| `elbowRest` | **0.26** | elbow rest flex |
| `swing` | **0.52** | shoulder swing amplitude when walking |
| `absZ`,`chestZ`,`neckZ` | **0** | never used by any species |
| `m` | required | material map: `torso, abs, leg, boot, arm, hand, skin, shoulder` |

```
drop  = hipY − footH
total = drop / bend
uL    = total * split
lL    = total − uL
```

Bone tree and parts, verbatim:

```
bone pelvis (root)      @ [0, hipY, 0]
  box  pelvis  c=[0, pelvH*0.30, 0]   d=[hipW*2 + legR*2.1, pelvH, pelvD]      m.torso
bone spine  ← pelvis    @ [0, pelvH*0.66, 0]
  sph  spine   c=[0,0,0]              r=waistD*0.56                            m.torso
  box  spine   c=[0, absH*0.40, absZ] d=[waistW, absH, waistD]                 m.abs || m.torso
bone chest  ← spine     @ [0, absH*0.76, 0]
  sph  chest   c=[0,0,0]              r=waistD*0.54                            m.torso
  box  chest   c=[0, chestH*0.42, chestZ] d=[chestW, chestH, chestD]           m.torso
tags.spine = ['spine','chest']

bone neck   ← chest     @ [0, chestH*0.84, neckZ]
  sph  neck    c=[0,0,0]              r=neckR*1.30                             m.skin
  cyl  neck    c=[0, neckH*0.38, 0]   r0=neckR*0.94 r1=neckR*1.06 h=neckH*1.35 m.skin
bone head   ← neck      @ [0, neckH*0.84, 0]
  sph  head    c=[0,0,0]              r=neckR*1.16                             m.skin
tags.head='head'  tags.neck='neck'

for side s in [−1, +1]  (prefix p = 'l' when s<0 else 'r'; ARRAY INDEX 0 = LEFT, 1 = RIGHT)
  link p_hip   ← pelvis @ [s*hipW, 0, 0]  len=uL  r0=legR      r1=legR*0.84  m.leg  ballR=legR*1.20
  link p_knee  ← p_hip  @ [0, −uL, 0]     len=lL  r0=legR*0.86 r1=legR*0.64  m.leg  ballR=legR*0.98
  bone p_ank   ← p_knee @ [0, −lL, 0]
    sph p_ank  c=[0,0,0]  r=legR*0.74                                          m.boot
    box p_ank  c=[0, −footH*0.5, footL*0.22]  d=[legR*2.0, footH, footL]       m.boot
  legs += {hip, knee, ankle, side:s, phase: 0 if s<0 else 0.5,
           pole:[s*0.12, 0, 1], stanceK: o.stanceK||0.86,
           sole:{h: footH, zb: footL*0.22 − footL/2, zf: footL*0.22 + footL/2}}

for side s in [−1, +1]
  link p_sh ← chest @ [s*shW, chestH*shY, 0] len=armU r0=armR      r1=armR*0.86
             m.arm  ballR=armR*1.26  ballM = m.shoulder || m.arm
  link p_el ← p_sh  @ [0, −armU, 0]          len=armL r0=armR*0.86 r1=armR*0.68
             m.arm  ballR=armR*0.99
  bone p_wr ← p_el  @ [0, −armL, 0]
    sph p_wr  c=[0,0,0]                                   r=armR*0.80                       m.hand
    box p_wr  c=[0, −handL*0.40, armR*0.12]  d=[armR*1.24, handL, armR*1.98]                m.hand
    box p_wr  c=[0, −handL*0.72, armR*0.42]  d=[armR*1.10, handL*0.52, armR*0.95] rot=[0.55,0,0]   m.hand
    cyl p_wr  c=[−s*armR*0.58, −handL*0.30, armR*0.34]  r0=armR*0.30 r1=armR*0.24 h=handL*0.66
              rot=[−0.55, 0, s*0.60]                                                        m.hand   (thumb)
  arms += {shoulder, elbow, wrist, side:s, phase: 0 if s<0 else 0.5,
           rest:[armPitch, 0, s*armOut], elbowRest, swing, wristRest:[−0.10, 0, 0]}
```

Returns `{uL, lL, legR}` (unused by every caller).

`armR*1.26` — the shoulder ball — is the tightest joint overlap on every humanoid;
see §18.

---

## 14. `quadruped(R, o)` — the four-legged builder (lines 1403–1442)

| param | default | effect |
|---|---|---|
| `backY` | required | pelvis bone height |
| `bodyL`,`bodyW`,`bodyH` | required | trunk dimensions |
| `chestW`,`chestH` | required | chest box |
| `hipW`,`shW` | required | half-track, rear / front |
| `legR`,`padR` | required | leg radius, foot pad radius |
| `neckY`,`neckL`,`neckR` | required | neck mount height, length, radius |
| `pastern` | required | `{f, h}` — front / hind pastern lengths |
| `ph` | required | `[lf, rf, lh, rh]` gait phases |
| `chestRise` | **0** | extra chest height above the spine |
| `bend` | **0.93** | leg rest straightness (quadrupeds rest visibly bent) |
| `m` | required | `torso, leg, neck?, pad?` |

```
bone pelvis (root) @ [0, backY, −bodyL*0.34]
  box  pelvis c=[0,0,0]  d=[hipW*2 + legR*2.2, bodyH*0.94, bodyL*0.44]   m.torso
bone spine ← pelvis @ [0, bodyH*0.02, bodyL*0.30]
  sph  spine  c=[0,0,0]  r=bodyH*0.46                                    m.torso
  box  spine  c=[0,0,bodyL*0.10]  d=[bodyW*0.92, bodyH*0.90, bodyL*0.36] m.torso
bone chest ← spine @ [0, chestRise, bodyL*0.30]
  sph  chest  c=[0,0,0]  r=bodyH*0.48                                    m.torso
  box  chest  c=[0,0,bodyL*0.10]  d=[chestW, chestH, bodyL*0.40]         m.torso
tags.spine=['spine','chest']   tags.flex = 0.28      # a long horizontal spine barely twists

bone neck ← chest @ [0, neckY, bodyL*0.26]
  sph  neck   c=[0,0,0]  r=neckR*1.25                                    m.neck || m.torso
  cyl  neck   c=[0, −neckL*0.34, neckL*0.30]  r0=neckR r1=neckR*0.94 h=neckL*1.25
              rot=[−1.15, 0, 0]                                          m.neck || m.torso
bone head ← neck @ [0, neckL*0.30, neckL*0.70]
  sph  head   c=[0,0,0]  r=neckR*1.05                                    m.neck || m.torso
tags.head='head'  tags.neck='neck'  tags.neckPitch=0

yPel = backY ; ySpi = yPel + bodyH*0.02 ; yChe = ySpi + chestRise
stF  = padR + pastern.f * cos(0.30)
stH  = padR + pastern.h * cos(0.34)
totF = (yChe − bodyH*0.30 − stF) / bend      # front leg bone budget
totH = (yPel − bodyH*0.30 − stH) / bend      # hind leg bone budget
fU = totF*0.52 ; fL = totF − fU
hU = totH*0.54 ; hL = totH − hU

mk(name, parent, x, z, up, low, r, phase, pole, pastern):
  link name_hip  ← parent   @ [x, −bodyH*0.30, z]  len=up  r0=r      r1=r*0.82  m.leg ballR=r*1.2
  link name_knee ← name_hip @ [0, −up, 0]          len=low r0=r*0.84 r1=r*0.62  m.leg ballR=r*0.96
  bone name_ank  ← name_knee @ [0, −low, 0]
    sph name_ank c=[0,0,0]                      r=r*0.68                        m.leg
    cyl name_ank c=[0,−pastern.len*0.5,0]  r0=r*0.56 r1=r*0.44 h=pastern.len*1.14  m.leg
    sph name_ank c=[0,−pastern.len,0]      r=pastern.padR                       m.pad || m.leg
  legs += {hip, knee, ankle, phase, pole, pastern}     # NOTE: no `side` field

mk('lf','chest', −shW,  bodyL*0.16, fU, fL, legR, ph[0], [0,0,−1], {len:P.f, padR, a0:0.30, a1:0.62, dir:1})
mk('rf','chest',  shW,  bodyL*0.16, fU, fL, legR, ph[1], [0,0,−1], {len:P.f, padR, a0:0.30, a1:0.62, dir:1})
mk('lh','pelvis',−hipW, −bodyL*0.10, hU, hL, legR, ph[2], [0,0, 1], {len:P.h, padR, a0:0.34, a1:0.66, dir:1})
mk('rh','pelvis', hipW, −bodyL*0.10, hU, hL, legR, ph[3], [0,0, 1], {len:P.h, padR, a0:0.34, a1:0.66, dir:1})
```

Front knees point **backward** (`pole = [0,0,−1]`), hind knees **forward**
(`pole = [0,0,+1]`) — the classic quadruped elbow/stifle arrangement. Leg array
order is `lf, rf, lh, rh` and code that reads `i % 2` (attack foot shuffle) depends
on it.

---

## 15. THE ROSTER — twelve species, exhaustively

Class counts: 4 `scav`, 4 `machine`, 4 `mutant`.
Total: **714 welded parts, 207 bones**.
Instantiation seed: `1013 + index*7919`.

### 15.1 `rat` — "Scav Rat" · scav · rusher · 52 parts · 17 bones

> Bottom of the food chain. Comes in threes, dies in threes, and still gets a hatchet into your back if you turn it.

`R.rho = 780`
Materials: `torso:canvas, abs:canvas, leg:canvas, boot:hide, arm:canvas, hand:hide, skin:flesh, shoulder:hide`

```
humanoid o = { hipY:0.855, footH:0.075, footL:0.245, legR:0.062, hipW:0.088,
               pelvH:0.19, pelvD:0.175, waistW:0.255, waistD:0.175, absH:0.20,
               chestW:0.325, chestH:0.30, chestD:0.205, neckR:0.058, neckH:0.085,
               shW:0.152, armU:0.265, armL:0.245, armR:0.046, handL:0.10 }
tags.hunch = 0.145   tags.leanRun = 0.16
```
Extra primitives — gas mask + hood:
```
box head [0, 0.035, 0.022]   [0.165, 0.185, 0.185]  hide
box head [0, −0.012, 0.098]  [0.115, 0.10, 0.055]   rubber
cyl head [0, −0.052, 0.108]  r 0.042/0.046 h 0.075  steel   rot [PI/2.2, 0, 0]
sph head [−0.048, 0.032, 0.086] r 0.033            poly
sph head [ 0.048, 0.032, 0.086] r 0.033            poly
box head [0, 0.098, −0.005]  [0.185, 0.075, 0.205]  canvas
box head [0, 0.045, −0.088]  [0.155, 0.145, 0.075]  canvas
```
Webbing + scrap pauldron:
```
box chest [0, 0.145, 0.098]  [0.30, 0.055, 0.055]   hide
box chest [0.02, 0.075, −0.098] [0.20, 0.20, 0.075] canvas
box l_sh  [−0.022, 0.012, 0] [0.075, 0.115, 0.155]  ironox  rot [0,0,0.2]
box spine [0, 0.02, 0.088]   [0.245, 0.09, 0.045]   hide
```
Hatchet — haft down through the fist, bit **across** the haft (a slab lying flat
against the handle reads as a paddle):
```
cyl r_wr [0, −0.165, 0.015]  r 0.017/0.020 h 0.34   timber
box r_wr [0, −0.300, 0.015]  [0.032, 0.078, 0.058]  steel    # eye
box r_wr [0, −0.300, 0.074]  [0.024, 0.108, 0.082]  steel    # bit
box r_wr [0, −0.300, 0.126]  [0.013, 0.132, 0.036]  steel    # edge
box r_wr [0, −0.298, −0.024] [0.030, 0.062, 0.048]  steel    # poll
```
```
arms[1].attack=true  atkPose=[−1.55, 0, 0.10, 0.35]  atkWind=1.5
arms[0].attack=true  atkPose=[−0.55, 0, −0.35, 0.95] atkWind=0.4
gait = {duty:0.58, strideK:1.55, freqK:1.10, lift:0.115, bob:0.020, sway:0.030}
info = {dps:26, detect:38, reach:1.35, hpK:1.0, armK:0.85}
```

### 15.2 `picker` — "Picker" · scav · brawler · 55 parts · 17 bones

> Wears a road sign as a shield and swings a crowbar like it owes him money. Slow, patient, hard to flank.

`R.rho = 950`
Materials: `torso:canvas, abs:hide, leg:canvas, boot:hide, arm:hide, hand:hide, skin:flesh, shoulder:steel`

```
humanoid o = { hipY:0.925, footH:0.082, footL:0.275, legR:0.075, hipW:0.098,
               pelvH:0.215, pelvD:0.205, waistW:0.30, waistD:0.205, absH:0.215,
               chestW:0.395, chestH:0.335, chestD:0.245, neckR:0.068, neckH:0.085,
               shW:0.182, armU:0.30, armL:0.275, armR:0.056, handL:0.115, armOut:0.14 }
tags.hunch = 0.075   tags.leanRun = 0.12
```
```
box head  [0, 0.02, 0.012]   [0.185, 0.205, 0.205]  flesh
box head  [0, 0.008, 0.098]  [0.135, 0.115, 0.055]  rubber
sph head  [−0.052, 0.048, 0.092] r 0.036            poly
sph head  [ 0.052, 0.048, 0.092] r 0.036            poly
cyl head  [0, 0.128, −0.01]  r 0.115/0.108 h 0.055  steel        # helmet
box head  [0, 0.098, 0.062]  [0.225, 0.038, 0.115]  steel  rot [0.24,0,0]
box chest [0, 0.155, 0.128]  [0.30, 0.225, 0.045]   ironox       # front plate
box chest [0, 0.145, −0.128] [0.275, 0.205, 0.042]  ironox       # back plate
box chest [0, 0.028, 0.135]  [0.245, 0.09, 0.038]   steel
box l_sh  [−0.038, 0.02, 0]  [0.085, 0.155, 0.195]  ironox rot [0,0,0.26]
box r_sh  [ 0.038, 0.02, 0]  [0.085, 0.155, 0.195]  ironox rot [0,0,−0.26]
box spine [0, 0.02, 0]       [0.315, 0.115, 0.225]  hide
# road-sign shield on the left forearm
box l_el  [−0.048, −0.155, 0.055] [0.038, 0.46, 0.40] ironox rot [0,0,0.14]
box l_el  [−0.062, −0.155, 0.055] [0.016, 0.30, 0.26] alum   rot [0,0,0.14]  col '#6d6a5e'
box l_el  [−0.020, −0.155, 0.055] [0.035, 0.155, 0.135] steel
# crowbar: shaft + gooseneck claw curling forward, so the hook reads ACROSS the shaft
cyl r_wr  [0, −0.205, 0.02]  r 0.016/0.016 h 0.42   gunmet
cyl r_wr  [0, −0.408, 0.043] r 0.015/0.014 h 0.075  gunmet rot [−0.85,0,0]
box r_wr  [0, −0.424, 0.092] [0.030, 0.026, 0.080]  gunmet rot [−0.35,0,0]
box r_wr  [0, −0.418, 0.136] [0.030, 0.014, 0.036]  gunmet rot [0.30,0,0]
```
```
arms[1].attack=true  atkPose=[−1.35, 0, 0.15, 0.30]  atkWind=1.35
arms[0].attack=true  atkPose=[−1.05, 0, −0.55, 1.15] atkWind=0.25
arms[0].rest = [−0.62, 0, −0.30]   arms[0].elbowRest = 1.15   arms[0].swing = 0.16   # shield held up
gait = {duty:0.63, strideK:1.30, freqK:0.92, lift:0.105, bob:0.024, sway:0.036}
info = {dps:42, detect:34, reach:1.75, hpK:1.0, armK:1.0}
```

### 15.3 `gasman` — "Gasman" · scav · area denial · 69 parts · 17 bones

> Two stolen welding bottles and a lit torch. Kill him at range or you inherit the fire he was standing in.

`R.rho = 880`
Materials: `torso:rubber, abs:rubber, leg:canvas, boot:rubber, arm:rubber, hand:hide, skin:flesh, shoulder:rubber`

```
humanoid o = { hipY:0.885, footH:0.088, footL:0.285, legR:0.082, hipW:0.10,
               pelvH:0.225, pelvD:0.235, waistW:0.335, waistD:0.245, absH:0.225,
               chestW:0.415, chestH:0.335, chestD:0.285, neckR:0.072, neckH:0.075,
               shW:0.192, armU:0.29, armL:0.265, armR:0.062, handL:0.115, armOut:0.17 }
tags.hunch = 0.10   tags.leanRun = 0.10
```
```
# full-face respirator
box head  [0, 0.015, 0.018]   [0.195, 0.20, 0.205]  rubber
box head  [0, 0.045, 0.098]   [0.155, 0.085, 0.048] poly
cyl head  [−0.078, −0.048, 0.062] r 0.052/0.052 h 0.085 steel rot [0,0,PI/2]
cyl head  [ 0.078, −0.048, 0.062] r 0.052/0.052 h 0.085 steel rot [0,0,PI/2]
sph head  [0, 0.115, −0.02]   r 0.105                rubber
# bottles + RIGID hose to the neck pivot (rigid, so it can never part)
cyl chest [−0.10, 0.115, −0.235] r 0.072/0.072 h 0.46 ironox
cyl chest [ 0.10, 0.115, −0.235] r 0.072/0.072 h 0.46 brass
box chest [0, 0.115, −0.20]   [0.34, 0.30, 0.075]    steel
cyl chest [−0.10, 0.365, −0.235] r 0.032/0.028 h 0.075 brass
cyl chest [ 0.10, 0.365, −0.235] r 0.032/0.028 h 0.075 brass
tube chest r=0.019 rubber  pts=[[−0.10,0.395,−0.235],[−0.145,0.415,−0.165],
                                [−0.115,0.365,−0.055],[−0.045,0.315,0.005],[0,0.282,0.0]]
tube chest r=0.019 rubber  pts=[[ 0.10,0.395,−0.235],[ 0.145,0.405,−0.155],
                                [ 0.118,0.352,−0.05],[ 0.05,0.305,0.005],[0,0.282,0.0]]
box chest [0, 0.09, 0.155]    [0.31, 0.28, 0.055]    hide      # apron
box spine [0, 0.045, 0.13]    [0.345, 0.22, 0.05]    hide      # tank straps
# torch wand, right hand
cyl r_wr  [0, −0.135, 0.05]   r 0.026/0.024 h 0.26   gunmet
cyl r_wr  [0, −0.255, 0.05]   r 0.028/0.034 h 0.09   brass
sph r_wr  [0, −0.325, 0.05]   r 0.055                flash  fxs 3.0
```
```
aim = {mode:'hand', arm:1, hold:0.86, drop:0.02,
       muzzle:[0,−0.325,0.05], fwd:[0,−1,0], up:[0,0,1], roll:0, pole:[0.75,−1,−0.30]}
arms[0].carry = true   arms[0].carryPose = [−0.90, 0, −0.52, 1.35]
gait = {duty:0.66, strideK:1.18, freqK:0.86, lift:0.10, bob:0.026, sway:0.040}
info = {dps:58, detect:30, reach:4.5, hpK:1.05, armK:0.9}
```
The torch fires **down its own −Y** (`fwd:[0,−1,0]`), which is why `aimQuat`'s
generic muzzle solve matters: the flame tip is 0.325 m off the wrist pivot.

### 15.4 `marksman` — "Marksman" · scav · ranged · 69 parts · 18 bones

> Sits in a window for six hours for one shot. The rag strips are not camouflage, they are boredom.

`R.rho = 800`
Materials: `torso:canvas, abs:canvas, leg:canvas, boot:hide, arm:canvas, hand:hide, skin:flesh, shoulder:canvas`

```
humanoid o = { hipY:1.005, footH:0.078, footL:0.275, legR:0.062, hipW:0.092,
               pelvH:0.195, pelvD:0.18, waistW:0.265, waistD:0.185, absH:0.235,
               chestW:0.345, chestH:0.335, chestD:0.215, neckR:0.058, neckH:0.105,
               shW:0.158, armU:0.315, armL:0.29, armR:0.046, handL:0.105 }
tags.hunch = 0.055   tags.leanRun = 0.14
```
```
box head  [0, 0.02, 0.012]   [0.16, 0.19, 0.195]    flesh
box head  [0, 0.048, 0.085]  [0.135, 0.062, 0.075]  gunmet     # goggles
sph head  [−0.048, 0.048, 0.105] r 0.028            poly
sph head  [ 0.048, 0.048, 0.105] r 0.028            poly
box head  [0, 0.058, −0.03]  [0.20, 0.155, 0.215]   canvas     # hood
box head  [0, −0.035, 0.075] [0.135, 0.085, 0.075]  canvas
# rag strips: 5 tabs across the back, i = 0..4, x = −0.13 + i*0.065
box chest [x, 0.075, −0.115] [0.045, 0.30, 0.03]    canvas rot [0.1, 0, (i−2)*0.08]
box l_sh  [−0.03, −0.03, −0.02] [0.06, 0.24, 0.075] canvas rot [0,0,0.12]
box r_sh  [ 0.03, −0.03, −0.02] [0.06, 0.24, 0.075] canvas rot [0,0,−0.12]
box spine [0, 0.05, −0.115]  [0.235, 0.24, 0.075]   canvas
```
Rifle on **its own bone**, butted into the shoulder pocket, so the aim solver
swings the frame about that anchor and both hands are solved onto the grips:
```
bone gun ← chest @ [0.132, chestH*0.54, 0.030]        # chestH = 0.335 → y = 0.1809
box gun [0, 0, 0.055]        [0.056, 0.125, 0.14]     timber   # butt plate
box gun [0, 0.005, 0.20]     [0.050, 0.100, 0.24]     timber   # stock
box gun [0, 0.022, 0.395]    [0.046, 0.078, 0.20]     gunmet   # receiver
box gun [0, −0.085, 0.295]   [0.038, 0.125, 0.060]    timber   rot [0.26,0,0]   # grip
box gun [0, −0.075, 0.395]   [0.032, 0.115, 0.070]    gunmet   rot [−0.16,0,0]  # magazine
box gun [0, 0.014, 0.545]    [0.052, 0.062, 0.235]    timber   # handguard
cyl gun [0, 0.030, 0.700]    r 0.013/0.012 h 0.44     gunmet   rot [PI/2,0,0]   # barrel
cyl gun [0, 0.030, 0.915]    r 0.019/0.018 h 0.055    gunmet   rot [PI/2,0,0]   # muzzle device
box gun [0, 0.072, 0.415]    [0.030, 0.048, 0.075]    gunmet   # scope mount
cyl gun [0, 0.108, 0.425]    r 0.024/0.022 h 0.205    gunmet   rot [PI/2,0,0]   # scope
cyl gun [0, 0.020, 0.560]    r 0.009/0.009 h 0.16     steel    rot [0.45,0,0]   # cleaning rod
sph gun [0, 0.030, 0.985]    r 0.05                   flash  fxs 2.6
# sling: chest → fore-end, welding the frame to the body
tube chest r=0.013 canvas pts=[[0.132, 0.1809, 0.030], [0.06, 0.20, 0.075],
                               [−0.03, 0.10, 0.10], [−0.075, −0.01, 0.075]]
```
```
aim = {mode:'shoulder', bone:'gun', eyeZ:0.05, muzzle:[0,0.030,0.985],
       fwd:[0,0,1], up:[0,1,0],
       hands:[ {arm:1, grip:[ 0.020,−0.038,0.305], hand:[−0.78, 0.10, 0],    pole:[ 0.55,−1,−0.55]},
               {arm:0, grip:[−0.026, 0.052,0.470], hand:[−1.22,−0.16,−0.30], pole:[−0.62,−1,−0.22]} ]}
R.grips = [{hand:'r_wr', weapon:'gun'}, {hand:'l_wr', weapon:'gun'}]   # DEAD DATA — never read
arms[1].carry=true  carryPose=[−0.80, 0, 0.26, 1.50]
arms[0].carry=true  carryPose=[−1.00, 0, −0.40, 1.25]
gait = {duty:0.61, strideK:1.42, freqK:0.98, lift:0.115, bob:0.020, sway:0.028}
info = {dps:74, detect:82, reach:120, hpK:0.92, armK:0.75}
```

### 15.5 `latchdog` — "Latchdog" · machine · hunter · 49 parts · 18 bones

> A warehouse inventory unit with the inventory parts stripped out. Runs down anything that moves and holds it until something worse arrives.

`R.rho = 640`
Materials: `torso:gunmet, leg:alum, neck:gunmet, pad:rubber`

```
quadruped o = { backY:0.62, bodyL:0.86, bodyW:0.28, bodyH:0.235,
                chestW:0.30, chestH:0.255, hipW:0.115, shW:0.115,
                legR:0.045, padR:0.045, neckY:0.06, neckL:0.20, neckR:0.085,
                pastern:{f:0.115, h:0.125}, ph:[0, 0.5, 0.5, 0] }     # diagonal trot
tags.neckPitch = 0.18
```
```
box head  [0, 0.01, 0.075]   [0.155, 0.125, 0.185]  gunmet
box head  [0, 0.045, 0.135]  [0.115, 0.055, 0.075]  poly
sph head  [−0.045, 0.048, 0.155] r 0.028            glow
sph head  [ 0.045, 0.048, 0.155] r 0.028            glow
cyl head  [0, 0.085, 0.02]   r 0.022/0.018 h 0.115  steel  rot [−0.5,0,0]
box head  [0, −0.055, 0.135] [0.10, 0.055, 0.135]   steel  rot [0.18,0,0]   # jaw clamp
box chest [0, 0.125, 0.02]   [0.245, 0.055, 0.335]  alum
box spine [0, 0.125, 0]      [0.215, 0.05, 0.30]    alum
box pelvis[0, 0.115, −0.02]  [0.235, 0.055, 0.315]  alum
cyl chest [−0.155, 0.02, 0.02] r 0.045/0.045 h 0.155 ironox rot [0,0,PI/2]
cyl chest [ 0.155, 0.02, 0.02] r 0.045/0.045 h 0.155 ironox rot [0,0,PI/2]
bone tail ← pelvis @ [0, 0.06, −0.185]
  sph tail [0,0,0] r 0.042                          gunmet
  cyl tail [0, 0.055, −0.115] r 0.022/0.010 h 0.30  gunmet rot [−1.25,0,0]
tags.wags = [{b:'tail', f:1.35, a:0.35, ax:'y', base:0}]
gait = {duty:0.52, strideK:1.30, freqK:1.30, lift:0.085, bob:0.014, sway:0.014}
info = {dps:48, detect:74, reach:1.1, hpK:1.0, armK:1.05}
```
Derived leg geometry (useful for verification): `fU=0.223287, fL=0.206111,
hU=0.224510, hL=0.191249`.

### 15.6 `sentinel` — "Sentinel" · machine · suppression · 49 parts · 17 bones

> Still running the perimeter routine for a company that no longer exists. Will not chase you past the fence line.

`R.rho = 1050`. Built **by hand** (digitigrade biped, not via `humanoid()`).
Materials: `torso:gunmet, leg:alum` (map declared but the calls name materials directly).

```
bone pelvis (root) @ [0, 1.16, 0]
  box pelvis [0, 0.075, 0]     [0.335, 0.235, 0.245]  gunmet
bone spine ← pelvis @ [0, 0.155, 0]
  sph spine  [0,0,0] r 0.125                          gunmet
  box spine  [0, 0.115, 0]     [0.245, 0.235, 0.205]  alum
bone chest ← spine @ [0, 0.215, 0]
  sph chest  [0,0,0] r 0.135                          gunmet
  box chest  [0, 0.155, 0.005] [0.475, 0.34, 0.285]   gunmet
  box chest  [0, 0.145, 0.155] [0.335, 0.245, 0.055]  alum
  box chest  [0, 0.30, −0.145] [0.30, 0.155, 0.115]   ironox
tags.spine = ['spine','chest']
bone neck ← chest @ [0, 0.315, 0.02]
  sph neck   [0,0,0] r 0.075                          gunmet
  cyl neck   [0, 0.045, 0] r 0.055/0.062 h 0.145      steel
bone head ← neck @ [0, 0.105, 0]
  sph head   [0,0,0] r 0.072                          gunmet
  box head   [0, 0.045, 0.03]  [0.245, 0.115, 0.185]  gunmet
  cyl head   [0, 0.045, 0.115] r 0.045/0.045 h 0.075  poly  rot [PI/2,0,0]
  sph head   [0, 0.045, 0.145] r 0.032                glow
  box head   [0, 0.115, −0.02] [0.185, 0.045, 0.145]  alum
tags.head='head'  tags.neck='neck'

SSTAND = 0.055 + 0.20 * cos(0.42)              = 0.238318
STOT   = (1.13 − SSTAND) / 0.95                = 0.938613
SU     = STOT * 0.53                           = 0.497465
SL     = STOT − SU                             = 0.441148
for side s in [−1, +1]:
  link p_hip  ← pelvis @ [s*0.135, −0.03, 0] len=SU r0 0.072 r1 0.062 alum ballR 0.088 ballM gunmet
  link p_knee ← p_hip  @ [0, −SU, 0]         len=SL r0 0.062 r1 0.05  alum ballR 0.075 ballM gunmet
  bone p_ank  ← p_knee @ [0, −SL, 0]
    sph p_ank [0,0,0] r 0.058                        gunmet
    cyl p_ank [0, −0.105, 0] r 0.045/0.038 h 0.24    alum
    sph p_ank [0, −0.20, 0]  r 0.072                 rubber
  # hydraulic ram across the knee, anchored on the THIGH so it cannot part
  cyl p_hip [s*0.062, −SU*0.55, −0.055] r 0.020/0.020 h SU*0.78 steel rot [−0.06,0,0]
  box p_hip [s*0.062, −0.045, −0.055]   [0.045, 0.09, 0.062]    gunmet
  legs += {hip, knee, ankle, side:s, phase: 0 if s<0 else 0.5, pole:[s*0.10, 0, −1],
           pastern:{len:0.20, padR:0.072, a0:0.42, a1:0.72, dir:1}}

link l_sh ← chest @ [−0.255, 0.235, 0] len 0.28 r0 0.062 r1 0.052 alum ballR 0.085 ballM gunmet
link l_el ← l_sh  @ [0, −0.28, 0]      len 0.26 r0 0.052 r1 0.042 alum ballR 0.068 ballM gunmet
bone l_wr ← l_el  @ [0, −0.26, 0]
  sph l_wr [0,0,0] r 0.052                           gunmet
  box l_wr [0, −0.075, 0.02]   [0.075, 0.135, 0.09]  gunmet
  box l_wr [−0.03, −0.155, 0.045] [0.026, 0.115, 0.075] steel rot [0,0,−0.2]
  box l_wr [ 0.03, −0.155, 0.045] [0.026, 0.115, 0.075] steel rot [0,0, 0.2]
link r_sh ← chest @ [0.255, 0.235, 0] len 0.28 r0 0.062 r1 0.052 alum ballR 0.085 ballM gunmet
link r_el ← r_sh  @ [0, −0.28, 0]     len 0.24 r0 0.058 r1 0.05  alum ballR 0.068 ballM gunmet
bone r_wr ← r_el  @ [0, −0.24, 0]
  sph r_wr [0,0,0] r 0.058                           gunmet
  box r_wr [0, −0.085, 0.075]  [0.115, 0.155, 0.30]  gunmet
  cyl r_wr [0, −0.085, 0.285]  r 0.038/0.034 h 0.22  steel  rot [PI/2,0,0]
  cyl r_wr [0, −0.02, 0.135]   r 0.045/0.045 h 0.135 ironox rot [PI/2,0,0]
  sph r_wr [0, −0.085, 0.40]   r 0.075               flash  fxs 2.2

arms = [                                     # REPLACES the array outright
 {shoulder:'l_sh', elbow:'l_el', wrist:'l_wr', side:−1, phase:0,   rest:[−0.05,0,−0.16],
  elbowRest:0.30, swing:0.36, wristRest:[0.10,0,0],
  carry:true, carryPose:[−0.70,0,−0.42,1.05], attack:true, atkPose:[−0.55,0,−0.35,0.85], atkWind:0.3},
 {shoulder:'r_sh', elbow:'r_el', wrist:'r_wr', side: 1, phase:0.5, rest:[−0.05,0, 0.16],
  elbowRest:0.30, swing:0.30, wristRest:[0.10,0,0]}
]
aim = {mode:'hand', arm:1, hold:0.90, drop:0.0, muzzle:[0,−0.085,0.40],
       fwd:[0,0,1], up:[0,1,0], roll:0, pole:[0.65,−1,−0.45]}
tags.hunch = 0.02   tags.leanRun = 0.08
gait = {duty:0.60, strideK:1.22, freqK:0.90, lift:0.145, bob:0.020, sway:0.020}
info = {dps:66, detect:88, reach:45, hpK:1.05, armK:1.15}
```
Note `pole = [s*0.10, 0, −1]` — the sentinel's knees break **backwards**
(digitigrade), unlike every other biped in the roster.

### 15.7 `wasp` — "Wasp" · machine · recon · 37 parts · 10 bones

> Cheap, loud, and always calling someone. Shooting it down is the fastest way to tell the map where you are.

`R.rho = 300`. Legless quadrotor.

```
bone pelvis (root) @ [0, 0, 0]
  sph pelvis [0,0,0] r 0.155                      gunmet
  box pelvis [0, 0.02, 0]    [0.28, 0.155, 0.34]  gunmet
  box pelvis [0, 0.085, −0.02] [0.20, 0.075, 0.245] alum
tags.spine = []           # empty: the spine loop is a no-op
tags.head  = null         # reassigned below

# four ducted rotors; arms = [[−1,1],[1,1],[−1,−1],[1,−1]], i = 0..3
for (sx, sz), i:
  nm = 'arm' + i
  bone nm ← pelvis @ [sx*0.115, 0.055, sz*0.135]
    sph nm [0,0,0] r 0.05                                    gunmet
    cyl nm [sx*0.10, 0.005, sz*0.115] r 0.030/0.026 h 0.30   alum
          rot [sz*0.9, 0, −sx*0.9]
    hx = sx*0.215 ; hz = sz*0.245
    cyl nm [hx, 0.02, hz]   r 0.045/0.042 h 0.075            gunmet
    cyl nm [hx, 0.055, hz]  r 0.175/0.175 h 0.028            poly     # duct ring
  bone nm+'r' ← nm @ [hx, 0.062, hz]
    cyl nm+'r' [0,0,0]      r 0.030/0.026 h 0.045            steel
    box nm+'r' [0, 0.004, 0] [0.315, 0.012, 0.048]           poly     # blade
    box nm+'r' [0, 0.004, 0] [0.048, 0.012, 0.315]           poly     # blade
  tags.spin += {b: nm+'r', rate: 46 + i*3}                   # 46, 49, 52, 55 rad/s

bone head ← pelvis @ [0, −0.115, 0.075]      # sensor ball + gun pod slung under the hull
  sph head [0,0,0]           r 0.088                gunmet
  sph head [0, −0.03, 0.045] r 0.062                poly
  sph head [0, −0.03, 0.085] r 0.032                glowc
  box head [0, −0.055, −0.10] [0.075, 0.075, 0.235] gunmet
  cyl head [0, −0.055, 0.09]  r 0.020/0.018 h 0.24  steel  rot [PI/2,0,0]
  sph head [0, −0.055, 0.215] r 0.055               flash  fxs 1.8
tags.head = 'head'
tags.wags = [{b:'head', f:0.42, a:0.55, ax:'y'}]
aim = {mode:'turret', yawBone:'head', yaw:[−3.15, 3.15], pitch:[−1.30, 1.30],
       eyeZ:0.075, muzzle:[0,−0.055,0.215], fwd:[0,0,1]}
arms = []
gait = {type:'hover', hoverH:0.92, hoverSpeed:4.6}
info = {dps:22, detect:96, reach:30, hpK:0.6, armK:0.7, tilt:−0.34}
```
`info.tilt` is a **display-only** hint (the viewer tilts the model nose-down in the
rack). It has no effect on the rig. `yaw:[−3.15,3.15]` is effectively unlimited;
`pitch:[−1.30,1.30]` is ±74.5°.

### 15.8 `foreman` — "Foreman" · machine · siege · 65 parts · 19 bones

> Site plant that kept working after the site stopped existing. Three tonnes of hydraulics with a grudge and a very slow turn radius. Not a fight you win with rifle rounds.

`R.rho = 1400`
Materials: `torso:ironox, leg:steel, neck:ironox, pad:rubber`

```
quadruped o = { backY:1.72, bodyL:1.90, bodyW:0.86, bodyH:0.68,
                chestW:0.98, chestH:0.78, hipW:0.38, shW:0.42,
                legR:0.145, padR:0.135, neckY:0.235, neckL:0.34, neckR:0.215,
                pastern:{f:0.30, h:0.32}, ph:[0, 0.5, 0.25, 0.75] }     # lateral-sequence walk
tags.neckPitch = 0.32
```
```
box head  [0, 0, 0.135]      [0.46, 0.30, 0.42]     ironox
box head  [0, 0.045, 0.30]   [0.34, 0.155, 0.10]    poly
sph head  [−0.115, 0.05, 0.335] r 0.052             glow
sph head  [ 0.115, 0.05, 0.335] r 0.052             glow
box head  [0, −0.135, 0.245] [0.30, 0.115, 0.245]   steel  rot [0.2,0,0]
cyl head  [0, 0.20, 0.02]    r 0.062/0.045 h 0.24   steel  rot [−0.35,0,0]
box chest [0, 0.40, 0.10]    [0.92, 0.135, 0.86]    steel     # deck plate
box spine [0, 0.38, 0]       [0.80, 0.115, 0.62]    steel
box pelvis[0, 0.36, −0.05]   [0.86, 0.135, 0.72]    steel
cyl spine [−0.30, 0.55, −0.12] r 0.082/0.068 h 0.42 ironox    # stacks
cyl spine [ 0.30, 0.55, −0.12] r 0.082/0.068 h 0.42 ironox
cyl spine [−0.30, 0.75, −0.12] r 0.095/0.080 h 0.10 gunmet
cyl spine [ 0.30, 0.75, −0.12] r 0.095/0.080 h 0.10 gunmet
box spine [0, 0.60, −0.10]   [0.52, 0.34, 0.30]     gunmet
# cage bars, i = 0..3, z = −0.26 + i*0.175
cyl chest [−0.46, 0.20, z]   r 0.026/0.026 h 0.42   gunmet
cyl chest [ 0.46, 0.20, z]   r 0.026/0.026 h 0.42   gunmet
box pelvis[0, 0.10, −0.42]   [0.72, 0.50, 0.26]     gunmet
box pelvis[0, 0.32, −0.34]   [0.78, 0.16, 0.34]     steel
# breaker arm on the front deck
bone boom ← chest @ [0.32, 0.42, 0.24]
  sph boom  [0,0,0] r 0.135                         gunmet
  cyl boom  [0, 0.08, 0.30]  r 0.088/0.075 h 0.72   ironox rot [1.30,0,0]
bone boom2 ← boom @ [0, 0.26, 0.66]
  sph boom2 [0,0,0] r 0.098                         gunmet
  cyl boom2 [0, −0.10, 0.28] r 0.062/0.055 h 0.62   ironox rot [1.70,0,0]
  cyl boom2 [0, −0.20, 0.58] r 0.075/0.055 h 0.34   steel  rot [1.70,0,0]
tags.wags = [{b:'boom',  f:0.30, a:0.16, ax:'x', base:−0.10},
             {b:'boom2', f:0.30, a:0.22, ax:'x', base: 0.24}]
gait = {duty:0.70, strideK:1.05, freqK:0.80, lift:0.18, bob:0.026, sway:0.016}
info = {dps:130, detect:66, reach:3.4, hpK:1.15, armK:1.2}
```
Derived leg geometry: `fU=0.619527, fL=0.571871, hU=0.626701, hL=0.533856`.
Foreman is the only rig whose tightest joint overlap moves with the animation
(the `boom→boom2` elbow), which is why its `minLink` differs between clips.

### 15.9 `husk` — "Husk" · mutant · fodder · 80 parts · 17 bones

> Whatever is left after the dust finishes with a person. Slow, stupid, and there are always more behind it.

`R.rho = 720`
Materials: `torso:pallid, abs:pallid, leg:pallid, boot:hide, arm:pallid, hand:pallid, skin:pallid, shoulder:bone`

```
humanoid o = { hipY:0.835, footH:0.065, footL:0.245, legR:0.052, hipW:0.082,
               pelvH:0.175, pelvD:0.155, waistW:0.205, waistD:0.145, absH:0.215,
               chestW:0.305, chestH:0.295, chestD:0.185, neckR:0.048, neckH:0.10,
               shW:0.142, armU:0.30, armL:0.285, armR:0.038, handL:0.115, armOut:0.08 }
tags.hunch = 0.20   tags.leanRun = 0.10
```
```
box head  [0, 0.008, 0.008]  [0.145, 0.185, 0.185]  pallid
box head  [0, −0.062, 0.075] [0.10, 0.075, 0.075]   pallid   # jaw
sph head  [−0.045, 0.035, 0.078] r 0.022            gut
sph head  [ 0.045, 0.035, 0.078] r 0.022            gut
box head  [0, 0.078, −0.015] [0.115, 0.062, 0.135]  gut      # scalp wound
# exposed ribs, i = 0..3, y = 0.02 + i*0.062
box chest [0, y, 0.098]      [0.245 − i*0.012, 0.026, 0.045] bone
box chest [0, 0.10, 0.105]   [0.038, 0.245, 0.045]  bone     # sternum
box spine [0, 0.10, −0.075]  [0.045, 0.30, 0.062]   bone     # spinal ridge
sph spine [0, 0.06, 0.075]   r 0.088                gut      # herniated gut
box pelvis[0, 0.02, 0]       [0.245, 0.155, 0.185]  canvas   # rag
box l_sh  [−0.018, 0.02, 0]  [0.045, 0.115, 0.115]  bone
# claw hands: for p in [l_wr, r_wr], for i in [−1,0,1]
tube p r=0.010 bone pts=[[i*0.022, −0.075, 0.010],
                         [i*0.030, −0.145, 0.048],
                         [i*0.034, −0.205, 0.062]]
```
```
arms[0].attack=true  atkPose=[−1.65, 0, −0.35, 0.30]  atkWind=1.2
arms[1].attack=true  atkPose=[−1.45, 0,  0.35, 0.45]  atkWind=1.0
arms[0].rest=[−0.32, 0, −0.10]   arms[1].rest=[−0.28, 0, 0.10]
arms[0].elbowRest=0.62           arms[1].elbowRest=0.55
gait = {duty:0.68, strideK:1.05, freqK:0.76, lift:0.075, bob:0.026, sway:0.055}
info = {dps:18, detect:22, reach:1.25, hpK:0.85, armK:0.6}
```
80 parts is the highest count in the roster — the six three-segment claw tubes
alone are 6 × (3 spheres + 2 cylinders) = 30 parts.

### 15.10 `stilt` — "Stilt" · mutant · stalker · 78 parts · 17 bones

> Three metres of bad news that walks quietly and reaches over cover. Aim for the knees, there is nothing else worth hitting.

`R.rho = 690`
Materials: `torso:pallid, abs:pallid, leg:pallid, boot:pallid, arm:pallid, hand:pallid, skin:pallid, shoulder:bone`

```
humanoid o = { hipY:1.72, footH:0.078, footL:0.34, legR:0.076, hipW:0.108,
               pelvH:0.225, pelvD:0.195, waistW:0.255, waistD:0.185, absH:0.335,
               chestW:0.365, chestH:0.345, chestD:0.225, neckR:0.056, neckH:0.185,
               shW:0.168, armU:0.52, armL:0.50, armR:0.054, handL:0.185,
               armOut:0.06, split:0.50 }
tags.hunch = 0.10   tags.leanRun = 0.10
```
```
box head  [0, 0.008, 0.02]   [0.135, 0.225, 0.195]  pallid
box head  [0, −0.082, 0.062] [0.10, 0.125, 0.125]   pallid rot [0.2,0,0]
sph head  [0, 0.075, 0.062]  r 0.030                gut       # single eye
box head  [0, 0.135, −0.02]  [0.098, 0.075, 0.155]  bone
# dorsal spines, i = 0..4
box spine [0, 0.02 + i*0.070, −0.078] [0.048, 0.062, 0.075] bone rot [0.3,0,0]
box chest [0, 0.135, 0.098]  [0.185, 0.235, 0.048]  bone
box l_sh  [−0.022, 0.03, 0]  [0.055, 0.135, 0.115]  bone
box r_sh  [ 0.022, 0.03, 0]  [0.055, 0.135, 0.115]  bone
# claws: for p in [l_wr, r_wr], for i in [−1,0,1]
tube p r=0.010 bone pts=[[i*0.024, −0.085, 0.012],
                         [i*0.032, −0.20,  0.058],
                         [i*0.038, −0.315, 0.082]]
```
```
arms[0].rest=[0.16, 0, −0.06]   arms[1].rest=[0.16, 0, 0.06]    # arms held FORWARD
arms[0].elbowRest=0.30          arms[1].elbowRest=0.30
arms[0].swing=0.34              arms[1].swing=0.34
arms[0].attack=true  atkPose=[−2.05, 0, −0.30, 0.20]  atkWind=0.9
arms[1].attack=true  atkPose=[−2.05, 0,  0.30, 0.20]  atkWind=0.9
gait = {duty:0.64, strideK:1.10, freqK:0.82, lift:0.155, bob:0.030, sway:0.030}
info = {dps:62, detect:58, reach:2.6, hpK:0.95, armK:0.7}
```

### 15.11 `skitter` — "Skitter" · mutant · swarm · 59 parts · 23 bones

> Six legs, no patience. Comes out of drains in numbers and goes for ankles because that is all it can reach.

`R.rho = 520`. Hand-built hexapod.

```
bone pelvis (root) @ [0, 0.40, −0.20]
  sph pelvis [0,0,0]           r 0.155                     chitin
  sph pelvis [0, 0.02, −0.185] r 0.185                     chitin   # abdomen
  box pelvis [0, 0.10, −0.185] [0.22, 0.115, 0.28]         chitin rot [0.2,0,0]
bone spine ← pelvis @ [0, 0.01, 0.185]
  sph spine  [0,0,0] r 0.125                               chitin
  box spine  [0, 0.02, 0.02]   [0.245, 0.155, 0.235]       chitin
bone chest ← spine @ [0, 0.005, 0.185]
  sph chest  [0,0,0] r 0.125                               chitin
  box chest  [0, 0.02, 0.04]   [0.265, 0.145, 0.225]       chitin
  box chest  [0, 0.085, 0.02]  [0.185, 0.062, 0.185]       chitin rot [0.15,0,0]
tags.spine = ['spine','chest']   tags.flex = 0.40
bone neck ← chest @ [0, −0.01, 0.135]
  sph neck   [0,0,0] r 0.085                               chitin
bone head ← neck @ [0, 0, 0.055]
  sph head   [0,0,0] r 0.082                               chitin
  box head   [0, 0, 0.055]     [0.155, 0.098, 0.135]       chitin
  for s in [−1, +1]:
    sph head [s*0.052, 0.035, 0.098] r 0.030               gut     # main eye
    sph head [s*0.026, 0.048, 0.108] r 0.018               gut     # ocellus
    cyl head [s*0.045, −0.03, 0.135] r 0.018/0.006 h 0.155 chitin rot [1.25, 0, s*0.35]  # mandible
tags.head='head'  tags.neck='neck'  tags.neckPitch=0.10

# six splayed legs — tripod gait
rows = [ ['chest',   0.10, 0.40, 0.34, 0.34, 0.0],
         ['spine',   0.00, 0.36, 0.36, 0.36, 0.5],
         ['pelvis', −0.08, 0.40, 0.36, 0.36, 0.0] ]     # [parent, z, out, uL, lL, ph]
for row ri, for s in [−1, +1]:
  nm = ('l' if s<0 else 'r') + ri            # l0 r0 l1 r1 l2 r2
  link nm_hip  ← parent @ [s*0.10, 0.03, z] len=uL r0 0.036 r1 0.028 chitin ballR 0.052
  link nm_knee ← nm_hip @ [0, −uL, 0]       len=lL r0 0.028 r1 0.015 chitin ballR 0.040
  bone nm_ank  ← nm_knee @ [0, −lL, 0]
    sph nm_ank [0,0,0]        r 0.024                      chitin
    cyl nm_ank [0, −0.045, 0] r 0.018/0.010 h 0.10         chitin
    sph nm_ank [0, −0.09, 0]  r 0.024                      chitin
  legs += {hip, knee, ankle, side:s, phase:(ph + (0 if s<0 else 0.5)) mod 1,
           pole:[s*1.0, 1.25, 0], outX: s*out,
           pastern:{len:0.09, padR:0.024, a0:0.10, a1:0.42, dir:1}}
arms = []
gait = {duty:0.46, strideK:1.00, freqK:1.55, lift:0.085, bob:0.012, sway:0.010}
info = {dps:20, detect:44, reach:0.8, hpK:0.8, armK:1.0}
```
Resulting leg phases: `l0=0.0, r0=0.5, l1=0.5, r1=0.0, l2=0.0, r2=0.5` — the two
alternating tripods `{l0, r1, l2}` and `{r0, l1, r2}`. `pole = [s, 1.25, 0]` points
the knees **up and out**, which is what makes it read as an arthropod rather than a
mammal. `outX` splays the foot targets 0.36–0.40 m outboard of the hips.

### 15.12 `gorger` — "Gorger" · mutant · detonator · 52 parts · 17 bones

> Full of something that used to be a person and is now mostly pressure. Do not let it get inside fifteen metres.

`R.rho = 600`
Materials: `torso:gut, abs:gut, leg:flesh, boot:hide, arm:flesh, hand:flesh, skin:flesh, shoulder:flesh`

```
humanoid o = { hipY:0.735, footH:0.088, footL:0.265, legR:0.105, hipW:0.145,
               pelvH:0.245, pelvD:0.315, waistW:0.475, waistD:0.415, absH:0.245,
               chestW:0.50, chestH:0.315, chestD:0.395, neckR:0.088, neckH:0.045,
               shW:0.225, armU:0.245, armL:0.225, armR:0.062, handL:0.115,
               armOut:0.34, split:0.50 }
tags.hunch = 0.05   tags.leanRun = 0.08
```
```
# belly
sph spine [0, 0.055, 0.115]  r 0.245                gut
sph spine [−0.165, 0.005, 0.055] r 0.165            gut
sph spine [ 0.165, 0.005, 0.055] r 0.165            gut
sph spine [0, −0.075, 0.075] r 0.185                gut
sph chest [0, 0.045, 0.145]  r 0.165                gut
# pressure sacs across the shoulders and flank (deliberately asymmetric)
sph chest [−0.185, 0.145, −0.155] r 0.125           gut
sph chest [ 0.165, 0.195, −0.125] r 0.098           gut
sph spine [0, 0.115, −0.215] r 0.135                gut
sph spine [−0.215, 0.135, −0.055] r 0.095           gut
# head sunk into the shoulders
sph head  [0, 0.02, 0.02]    r 0.115                flesh
box head  [0, −0.035, 0.078] [0.135, 0.088, 0.098]  gut
sph head  [−0.048, 0.055, 0.088] r 0.024            gut
sph head  [ 0.048, 0.055, 0.088] r 0.024            gut
box head  [0, 0.075, −0.02]  [0.155, 0.075, 0.145]  hide
box pelvis[0, 0.03, 0]       [0.50, 0.215, 0.375]   canvas
box pelvis[0, 0.115, 0.015]  [0.53, 0.075, 0.40]    hide
```
```
arms[0].rest=[−0.20, 0, −0.42]  arms[1].rest=[−0.20, 0, 0.42]   # arms shoved out by the belly
arms[0].elbowRest=0.75          arms[1].elbowRest=0.75
arms[0].swing=0.28              arms[1].swing=0.28
arms[0].attack=true  atkPose=[−1.85, 0, −0.55, 0.15]  atkWind=0.7
arms[1].attack=true  atkPose=[−1.85, 0,  0.55, 0.15]  atkWind=0.7
gait = {duty:0.70, strideK:0.98, freqK:0.88, lift:0.075, bob:0.030, sway:0.075}
info = {dps:210, detect:30, reach:3.2, hpK:0.9, armK:0.55}
```
Gorger's `cover` is **exactly 0** — no material in its part list appears in `HARD`
— so its armour is 0 regardless of `armK`. Highest `dps` in the roster (it is a
suicide bomber; `dps` is really "detonation damage").

---

## 16. Derived stats — measured, use these as your port's acceptance test

Re-run of `deriveStats` under node against the real bundle. If your Godot port
disagrees by more than rounding, something above is wrong.

| id | parts | bones | legs | arms | mass kg | cover | HP | armour | height m | speed | run | poise | threat | tier |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| rat | 52 | 17 | 2 | 2 | 56.777 | 0.04149 | 43 | 3 | 1.5936 | 1.330 | 3.522 | 45.806 | 35.782 | Common |
| picker | 55 | 17 | 2 | 2 | 118.190 | 0.22696 | 81 | 18 | 1.7456 | 1.040 | 2.819 | 53.982 | 39.724 | Common |
| gasman | 69 | 17 | 2 | 2 | 137.552 | 0.12127 | 85 | 9 | 1.7749 | 0.858 | 2.445 | 55.682 | 38.470 | Common |
| marksman | 69 | 18 | 2 | 2 | 71.188 | 0.04609 | 46 | 3 | 1.8257 | 1.228 | 3.252 | 48.320 | 43.491 | Hardened |
| latchdog | 49 | 18 | 4 | 0 | 57.577 | 0.82528 | 78 | 69 | 0.8663 | 1.032 | 3.684 | 45.961 | 52.493 | Elite |
| sentinel | 49 | 17 | 2 | 2 | 137.946 | 0.82627 | 141 | 76 | 2.1149 | 1.000 | 3.553 | 55.714 | 58.135 | Warlord |
| wasp | 37 | 10 | 0 | 0 | 12.239 | 0.60165 | 16 | 34 | 0.3636 | 2.530 | 4.600 | 29.168 | 44.186 | Hardened |
| foreman | 65 | 19 | 4 | 0 | 2898.594 | 0.89776 | 1064 | 86 | 2.6174 | 0.856 | 3.001 | 90.021 | 66.527 | Apex |
| husk | 80 | 17 | 2 | 2 | 40.503 | 0.03719 | 30 | 2 | 1.5480 | 0.663 | 2.062 | 42.070 | 28.535 | Vermin |
| stilt | 78 | 17 | 2 | 2 | 84.323 | 0.03230 | 52 | 2 | 2.7431 | 1.094 | 3.453 | 50.208 | 41.115 | Hardened |
| skitter | 59 | 23 | 6 | 0 | 39.344 | 0.44619 | 39 | 36 | 0.6073 | 1.224 | 3.865 | 41.750 | 40.371 | Hardened |
| gorger | 52 | 17 | 2 | 2 | 247.592 | 0.00000 | 93 | 0 | 1.5255 | 0.657 | 2.123 | 62.283 | 41.213 | Hardened |

Gait internals:

| id | freq Hz | runFreq | duty | runDuty | E m | runE | g.reach | hipH | standY | Emax | dropMax |
|---|---|---|---|---|---|---|---|---|---|---|---|
| rat | 1.16150 | 1.64933 | 0.58 | 0.3248 | 0.66398 | 0.69349 | 0.79188 | 0.85500 | 0.07500 | 0.73775 | 0.11086 |
| picker | 0.93443 | 1.32689 | 0.63 | 0.3528 | 0.70093 | 0.74948 | 0.85584 | 0.92500 | 0.08200 | 0.79732 | 0.11982 |
| gasman | 0.89835 | 1.27565 | 0.66 | 0.3696 | 0.63016 | 0.70852 | 0.80914 | 0.88500 | 0.08800 | 0.75375 | 0.11328 |
| marksman | 0.94921 | 1.34787 | 0.61 | 0.3416 | 0.78920 | 0.82427 | 0.94112 | 1.00500 | 0.07800 | 0.87689 | 0.13176 |
| latchdog | 1.87909 | 2.66830 | 0.52 | 0.3000 | 0.28566 | 0.41421 | 0.42258 | 0.55185 | 0.15885 | 0.45436 | 0.05821 |
| sentinel | 0.87254 | 1.23900 | 0.60 | 0.3360 | 0.68760 | 0.96356 | 0.93935 | 1.13000 | 0.25462 | 1.02507 | 0.13151 |
| wasp | 1.00000 | — | 0.60 | — | 0.0 | — | — | — | — | — | — |
| foreman | 0.69318 | 0.98432 | 0.70 | 0.3920 | 0.86434 | 1.19493 | 1.17598 | 1.52280 | 0.42914 | 1.27120 | 0.16248 |
| husk | 0.80769 | 1.14691 | 0.68 | 0.3808 | 0.55815 | 0.68463 | 0.78173 | 0.83500 | 0.06500 | 0.72833 | 0.10944 |
| stilt | 0.59676 | 0.84740 | 0.64 | 0.3584 | 1.17357 | 1.46034 | 1.66701 | 1.72000 | 0.07800 | 1.55355 | 0.23338 |
| skitter | 1.73253 | 2.46019 | 0.46 | 0.3000 | 0.32507 | 0.47135 | 0.70667 | 0.43833 | 0.11355 | 1.00104 | 0.09520 |
| gorger | 1.02024 | 1.44875 | 0.70 | 0.3920 | 0.45060 | 0.57443 | 0.65685 | 0.73500 | 0.08800 | 0.61109 | 0.09196 |

Wasp's `runFreq/runDuty/runE` are genuinely **undefined** in the reference (the
legless early return never sets them). Only `speed = hoverSpeed*0.55 = 2.53` and
`runSpeed = hoverSpeed = 4.6` are meaningful. In GDScript, initialise them to 0
and make sure the hover branch never reads them.

Body extents (`width`, `depth`, `alt` — `alt` is the hover height off the floor):

| id | width | depth | alt |
|---|---|---|---|
| rat | 0.4969 | 0.3663 | 0 |
| picker | 0.7085 | 0.6976 | 0 |
| gasman | 0.7086 | 1.1422 | 0 |
| marksman | 0.5937 | 1.1503 | 0 |
| latchdog | 0.4650 | 1.5338 | 0 |
| sentinel | 0.8059 | 1.1385 | 0 |
| wasp | 1.0100 | 1.1100 | 0.7343 |
| foreman | 1.1880 | 3.2954 | 0 |
| husk | 0.4736 | 0.5718 | 0 |
| stilt | 0.5562 | 0.4302 | 0 |
| skitter | 1.0567 | 1.1393 | 0 |
| gorger | 0.9161 | 0.7187 | 0 |

---

## 17. Distance queries (lines 1168–1300)

These are the collision primitives the validator runs on. They are also exactly
what a Godot port should use for cheap enemy-vs-enemy separation and for a
capsule-free hit query, so port them as static functions, not as physics bodies.

```gdscript
# world-space primitive from a part + its world matrix
static func world_prim(p, M: Transform3D) -> Dictionary:
	var pos := M.origin
	var q := M.basis.get_rotation_quaternion()
	var sc := M.basis.get_scale()
	match p.s:
		"sph": return {"s":"sph", "m":p.m, "c":pos, "r":p.r * sc.x}
		"cyl":
			var ax := q * Vector3.UP
			return {"s":"cyl", "m":p.m,
			        "a": pos + ax * (p.h * 0.5 * sc.y),      # +Y end
			        "b": pos - ax * (p.h * 0.5 * sc.y),      # −Y end
			        "r0": p.r0 * sc.x, "r1": p.r1 * sc.x}
		_:
			return {"s":"box", "m":p.m, "c":pos, "q":q,
			        "e":[p.d[0]*0.5*sc.x, p.d[1]*0.5*sc.y, p.d[2]*0.5*sc.z],
			        "ax":[q*Vector3.RIGHT, q*Vector3.UP, q*Vector3.BACK]}
```

`penetration(A, B)` returns **positive = overlapping**, negative = separated:

| A | B | method |
|---|---|---|
| sph·sph | | `A.r + B.r − dist(A.c, B.c)` |
| sph·box | | `A.r − dist(A.c, ptBox(A.c, B))` — **note it returns `r` exactly when the centre is inside the box** |
| sph·cyl | `sphCyl` | project the centre on the axis, clamp t∈[0,1], `S.r + cylR(C,t) − dist` |
| cyl·cyl | `cylCyl` | `segClosest`, then `cylR(A,s) + cylR(B,t) − dist(p,q)` |
| cyl·box | `cylBox` | sample the axis at **N = 24** steps, take the **max** of `cylR(C,t) − dist(p, ptBox(p,B))` |
| box·box | `boxBoxSep` | SAT over 6 face axes + 9 cross axes (cross skipped if `lengthSq ≤ 1e-10`), returns the **minimum** overlap; early-outs at ≤ 0 |

```gdscript
static func cyl_r(C, t: float) -> float:        # t = 0 at the a (+Y) end
	return C.r0 + (C.r1 - C.r0) * t

static func pt_box(pt: Vector3, B) -> Vector3:   # closest point on an OBB
	var d := pt - B.c
	var out := B.c
	for i in 3:
		out += B.ax[i] * clampf(d.dot(B.ax[i]), -B.e[i], B.e[i])
	return out
```

`segClosest(p1,q1,p2,q2)` is the standard Ericson closest-points-on-two-segments
routine with `1e-12` degeneracy epsilons. **Important edge case:** for *parallel or
collinear* segments the determinant is ~0 and the code silently takes `s = 0`
(the `a` end of segment A), then fixes `t` by clamping. Every straight limb chain
hits this branch, so reproduce the branch exactly or your joint-overlap numbers
drift.

```gdscript
static func prim_low_y(o) -> float:              # lowest world Y of a primitive
	match o.s:
		"sph": return o.c.y - o.r
		"cyl":
			var ax := (o.a - o.b).normalized()
			var k := sqrt(maxf(0.0, 1.0 - ax.y * ax.y))
			return minf(o.a.y - o.r0 * k, o.b.y - o.r1 * k)
		_:
			var lo := INF
			for sx in [-1,1]: for sy in [-1,1]: for sz in [-1,1]:
				lo = minf(lo, o.c.y + o.ax[0].y*o.e[0]*sx + o.ax[1].y*o.e[1]*sy + o.ax[2].y*o.e[2]*sz)
			return lo

static func gait_phase(inst, clip: String, t: float) -> Dictionary:
	var g := inst.gait
	var loco := clip == "walk" or clip == "run"
	var freq: float = g.runFreq if clip == "run" else g.freq
	var duty: float = g.runDuty if clip == "run" else g.duty
	var cyc := t * freq if loco else 0.0
	var stance: Array[bool] = []
	for L in g.get("legs", []):
		stance.append(fposmod(cyc + L.get("phase", 0.0), 1.0) < duty if loco else true)
	return {"loco": loco, "freq": freq, "duty": duty, "stance": stance,
	        "support": stance.count(true)}
```

Note that in a non-locomotion clip **every leg counts as stance** — that is what
makes the floor-contact check meaningful for idle/aim/attack/stagger.

---

## 18. `window.VALIDATION` — what it is, and what a GAP looks like

Line 2018 holds a pre-computed report, one entry per species:

```json
{ "id": "rat",
  "clips": { "idle":   {"frames":16, "floating":0, "minLink":0.05795999999999988,
                        "minY":-4.16e-17, "maxY":1.5955614584080489},
             "walk":   {...}, "run": {...}, "aim": {...}, "attack": {...}, "stagger": {...},
             "death#0": {...}, "death#1": {...}, "death#2": {...}, "death#3": {...}, "death#4": {...} },
  "worst": { "gap":0.05795999999999974, "sink":3.15e-16, "hover":3.90e-16, "reach":0.985 } }
```

Frame counts per clip (these define the sampling grid):
`idle 16 · walk 40 · run 40 · aim 72 · attack 24 · stagger 20 · death 24 × 5 takes` =
**308 poses per species, 3,696 across the roster.**

### 18.1 The exact metric definitions (reverse-engineered and verified)

Sampling: `t = i / frames * CLIPLEN[clip]` for `i ∈ [0, frames)` — **not**
`i/(frames−1)`. Death takes are 0…4. Verified to 14 digits.

**`minLink`** — for every bone that has a parent, take the **maximum** penetration
between any non-`fx` part on that bone and any non-`fx` part on its parent bone;
`minLink` is the **minimum** of those maxima over the whole rig, over every sampled
frame of the clip.

> In words: *"how much does the loosest joint in the body still overlap?"*

```gdscript
static func min_link(inst) -> float:
	var mats := inst.part_matrices()
	var prims := []
	for i in inst.pmeta.size():
		prims.append(null if MAT[inst.pmeta[i].p.m].get("fx", false)
		                  else world_prim(inst.pmeta[i].p, mats[i]))
	var by_bone := {}
	for i in inst.pmeta.size():
		if prims[i] != null:
			by_bone.get_or_add(inst.pmeta[i].bone, []).append(prims[i])
	var worst := INF
	for b in inst.rig.bones:
		if b.p == null: continue
		var kids: Array = by_bone.get(b.n, [])
		var par:  Array = by_bone.get(b.p, [])
		if kids.is_empty() or par.is_empty(): continue
		var best := -INF
		for k in kids:
			for p in par:
				best = maxf(best, penetration(k, p))
		worst = minf(worst, best)          # `floating += 1` when best <= 0
	return worst
```

**`floating`** — the count of parent→child links whose best overlap is **≤ 0**,
i.e. links where the child's geometry does not touch the parent's at all. **A
positive `floating` means a limb has come off the body.** Every entry in the
reference is `0`, across all 3,696 poses.

**`minY` / `maxY`** — over all non-`fx` posed primitives, `min(primLowY)` and
`max(primBounds().max.y)`, in rig space. Reproduced exactly (§18.3).

**`worst.gap`** = min `minLink` across every clip and take.
**`worst.sink`** = `max(0, −lowestY)` of the **stance feet only**, over the six
living clips (death excluded). **`worst.hover`** = `max(lowestY)` of the same set.
Both should be ~1e-16 — feet exactly on the floor.
**`worst.reach`** = max leg extension as a fraction of `L1+L2`, again over living
clips; normally exactly `0.985` (the `Rm` clamp in the dip solver). Hovering rigs
report `0` for all three.

### 18.2 **What a GAP looks like — the number that matters**

* `minLink > 0` ⇒ the joint is sealed. **The smallest value in the whole reference
  bestiary is 0.0391532 m (skitter), i.e. 39.2 mm of solid overlap.**
* `minLink ≤ 0` ⇒ **a visible seam**. Two primitives that should be welded have
  separated. This is the exact failure the project's no-air-gaps directive forbids.
* `floating > 0` ⇒ **a limb has detached entirely.** Ship-blocking.

Per-species worst overlap (all clips, all takes) — treat these as regression
thresholds for the Godot port; **your port must reproduce each to ≤1e-9**:

| id | worst gap (m) | (mm) | where it occurs |
|---|---|---|---|
| rat | 0.05796000000000 | 57.96 | `chest→l_sh` — shoulder ball `armR·1.26` |
| picker | 0.07056000000000 | 70.56 | `chest→l_sh` |
| gasman | 0.07812000000000 | 78.12 | `chest→l_sh` |
| marksman | 0.05796000000000 | 57.96 | `chest→r_sh` |
| latchdog | 0.03930000000000 | 39.30 | `pelvis→spine` — spine ball inside the pelvis box |
| sentinel | 0.06750000000000 | 67.50 | `chest→l_sh` (`ballR 0.085` less the box offset) |
| wasp | 0.05000000000000 | 50.00 | `pelvis→arm0` — rotor-arm ball `r 0.05` inside the hull |
| foreman | 0.12158296871235 | 121.58 | `boom→boom2` — the only pose-varying minimum |
| husk | 0.04788000000000 | 47.88 | `chest→l_sh` |
| stilt | 0.06804000000000 | 68.04 | `chest→l_sh` |
| skitter | 0.03915319750694 | 39.15 | `l1_knee→l1_ank` — smallest in the roster |
| gorger | 0.07812000000000 | 78.12 | `chest→l_sh` |

Why nine of twelve land on the shoulder: `link()` puts a ball of radius
`armR·1.26` **exactly on the shoulder pivot**, and that pivot sits inside the
chest box, so `penetration(sph, box)` returns the radius verbatim and it is
**invariant under every possible arm rotation**. That invariance is the whole
design. Latchdog's is the same trick one bone up: `bodyH·0.46 − (bodyL·0.30 −
bodyL·0.22) = 0.1081 − 0.0688 = 0.0393`.

### 18.3 Reproduction status

The metric above was re-implemented and run against the extracted reference
modules under node. Results:

* `minLink`, all 12 species, all clips: **exact to 14 significant digits**
  (e.g. foreman idle `0.12158342439720` vs reference `0.12158342439720`;
  foreman aim `0.12158296871235` vs `0.12158296871235`).
* `minY` / `maxY`, all species, verified on `idle` and `walk`: **exact**
  (e.g. stilt idle `maxY 2.7440270519`, `minY −6.084e−16`).
* `worst.sink` / `worst.hover` / `worst.reach`: exact for 10 of 11 legged species;
  the two residuals are `foreman.sink 6.661e−16` vs `7.377e−16` (float noise) and
  `latchdog.reach 0.985` vs `0.987982` (latchdog's dip is capped by `dropMax`, so
  one frame over-extends past the 0.985 clamp — see the `dxz >= Rm → continue`
  branch in §9.8).

**The Godot bake must emit the same report.** Write
`res://data/enemies/bestiary_report.txt` with per-species per-clip
`frames / floating / minLink / minY / maxY` and a `worst` block, and fail the bake
loudly if any `minLink ≤ 0` or any `floating > 0`.

---

## 19. Gotchas that will break a naive port

**G-1 · Euler order.** three.js `Object3D.rotation` is XYZ; Godot's `Node3D` is
YXZ. Set `rotation_order = EULER_ORDER_XYZ` on every bone, or write quaternions.
The three exceptions that really are YXZ: `solveTurret`'s clamp euler,
`poseDeath`'s root euler, and the turret's read-back.

**G-2 · The RNG uses an arithmetic right shift.** `s ^= s >> 17` on a value with
bit 31 set sign-extends. A "clean" `>>>` port diverges from draw 4 and every death
animation differs. Test vectors in §1.1.

**G-3 · `R.rho` shadows a method.** `Rig.prototype.rho(v)` is a *method*, and every
species then does `R.rho = 780`, overwriting it with a number. `deriveStats` reads
`rig.rho != null` — for a rig that never assigned it, `rig.rho` would be the
*function*, which is `!= null`, so `mass += v * function` ⇒ **NaN**. Every species
in the roster assigns it, so the bug never fires, but it means the
`d.dens * d.fill` fallback path is **dead code**: material densities never
contribute to mass. Only `R.rho` does. In GDScript use a `float` with `-1.0` as
"unset" and delete the `rho()` method entirely.

**G-4 · `hardMass` is computed and never used** (line 1108). Do not port it.

**G-5 · `R.grips` (marksman) is set and never read.** Dead. Do not port it.

**G-6 · `info.tilt` is viewer-only** (wasp `-0.34`). It rotates the display model
in the rack; it is not part of the rig. Do not bake it into the scene transform.

**G-7 · `fx` parts must be excluded from everything.** Mass, area, coverage,
bounds, floor contact, penetration, `lowestPoint`. Exactly **four** `flash`
spheres exist in the whole roster — gasman (`r_wr`, fxs 3.0), marksman (`gun`,
fxs 2.6), sentinel (`r_wr`, fxs 2.2), wasp (`head`, fxs 1.8). None of the melee
species has one. They sit at scale 1e-4 until `firePulse` inflates them.

**G-8 · `aimRig` needs a world-matrix flush between parent and child.** Godot
defers transform propagation; call `force_update_transform()` (or compose
transforms by hand) after every bone write inside an IK chain. Without it the
forearm solves against last frame's upper arm.

**G-9 · `ik2` normalises by the unclamped distance but solves with the clamped
one.** Do not "simplify" that to one variable.

**G-10 · `smooth()` is unclamped.** Callers clamp. Keep the split.

**G-11 · Locomotion is not a looping animation.** `cyc = t * freq` with `t`
unbounded; foot phase is `fposmod(cyc + phase, 1)`. Never advance a phase
accumulator by `delta` — you will drift, and the validator's frame-exactness is
lost. Feed the pose function absolute time.

**G-12 · `death` is a fixed-step sim with a 3000-iteration guard.** Scrubbing
backwards re-inits. Advancing more than 25 s of sim silently stalls. Cache the
state per instance keyed on `take`.

**G-13 · Hover rigs leave `runFreq`/`runDuty`/`runE` undefined.** In JS those are
`undefined`, which coerces to `NaN` in arithmetic — the hover branch happens to
return before touching them. In GDScript they will be `0.0` and produce a
divide-by-zero if you're careless. Guard on `g.type == "hover"` first.

**G-14 · `wags` only applies `base` to the X channel** regardless of `ax`. Port
the quirk, not the intent.

**G-15 · Arm/leg array order is positional.** `arms[0]` is always **left**
(`side = −1`), `arms[1]` right; legs are `l, r` for bipeds and `lf, rf, lh, rh`
for quadrupeds. `atkPose`/`carryPose` assignments index by number.

**G-16 · Quadruped legs have no `side` field**, so anything reading `L.side`
must default. `poseInst` never does; `deathInit` only reads `A.side` on arms.

**G-17 · `boxBoxSep` returns a *separation*, not a penetration depth, when
negative** — it early-outs on the first separating axis, so the magnitude of a
negative result is meaningless. Only its sign and positive values are usable.

**G-18 · `partArea` counts both frustum caps**, including degenerate ones. The
`cover`/armour numbers in §16 depend on it.

**G-19 · `DoubleSide` is not hiding mesh defects here.** Every enemy primitive is
a closed convex Godot primitive. Do **not** carry the DoubleSide flag over —
that would double the shaded fragments for no benefit and violate the perf budget.

**G-20 · One material per (key, override) — 19 total.** Combine with the geometry
cache (368 unique meshes for 714 parts) and drive the whole bestiary from
`MultiMeshInstance3D` buckets. A per-part `MeshInstance3D` is 714 draw calls for
a single one-of-each encounter, which blows the budget on its own.

**G-21 · `rig.info.reach` is read with `||`, not a null check** (line 1134):
`rig.info.reach || (g.reach ? g.reach*0.9 : 1)`. A `reach` of exactly 0 would fall
through to the gait-derived value. No species does this today; if you retune,
use an explicit sentinel rather than 0.

---

## Appendix A · The surface shader (ART owns this; transcribed for completeness)

Object-space triplanar-free procedural noise injected into three.js's standard
material. `vOP` = object-space position, `vON` = object-space normal, `uType` =
`MAT.type`, `uSeed` = per-material hash.

```glsl
// --- NOISE (prelude) -----------------------------------------------------
float h31(vec3 p){ p=fract(p*0.1031+uSeed*0.137); p+=dot(p,p.yzx+33.33); return fract((p.x+p.y)*p.z); }
float vn(vec3 x){ vec3 i=floor(x), f=fract(x); f=f*f*(3.0-2.0*f);
  return mix(mix(mix(h31(i),h31(i+vec3(1,0,0)),f.x),mix(h31(i+vec3(0,1,0)),h31(i+vec3(1,1,0)),f.x),f.y),
             mix(mix(h31(i+vec3(0,0,1)),h31(i+vec3(1,0,1)),f.x),mix(h31(i+vec3(0,1,1)),h31(i+vec3(1,1,1)),f.x),f.y),f.z); }
float fbm3(vec3 p){ float a=0.5,s=0.0; for(int i=0;i<4;i++){ s+=a*vn(p); p*=2.07; a*=0.5; } return s; }
float fbm2(vec3 p){ float a=0.55,s=0.0; for(int i=0;i<3;i++){ s+=a*vn(p); p*=2.11; a*=0.5; } return s; }
float rdg(vec3 p){ return 1.0-abs(2.0*fbm3(p)-1.0); }

// --- DETAIL (after metalnessmap_fragment) --------------------------------
vec3 P=vOP*3.2; vec3 N=normalize(vON);
float px=length(fwidth(P));
float fade=1.0-smoothstep(0.012,0.075,px);      // kill high-frequency detail at distance
float g=fbm3(P*3.0);
if(uType<0.5){                                   // 0 · pitted, rusting steel
  float rust=smoothstep(0.50,0.84,fbm3(P*1.7+7.3));
  rust*=smoothstep(0.05,0.95,0.66-N.y*0.38);     // rust pools on downward faces
  float scr=smoothstep(0.74,0.96,fbm3(P*vec3(1.2,9.0,9.0)+2.0))*fade;
  float pit=smoothstep(0.80,1.00,fbm3(P*6.5))*fade;
  diffuseColor.rgb*=(0.86+0.28*g);
  diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.150,0.056,0.022)*(0.62+0.95*g),rust*0.66);
  diffuseColor.rgb+=scr*0.055*(1.0-rust);
  roughnessFactor=clamp(roughnessFactor+rust*0.40+pit*0.10-scr*0.10+(g-0.5)*0.12,0.10,1.0);
  metalnessFactor=clamp(metalnessFactor*(1.0-rust*0.80),0.0,1.0);
}else if(uType<1.5){                             // 1 · timber
  float ring=fbm3(P*vec3(0.9,4.0,4.0));
  float grain=pow(sin((P.x*2.0+ring*2.6)*7.0)*0.5+0.5,1.6);
  float blotch=fbm3(P*2.2+11.0);
  diffuseColor.rgb*=mix(0.70,1.16,mix(0.5,grain,fade)*0.66+0.34*blotch);
  float wear=smoothstep(0.62,0.95,fbm3(P*3.2+21.0));
  diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(0.76,0.72,0.68),wear*0.45);
  roughnessFactor=clamp(0.86-grain*0.12*fade+wear*0.06,0.34,1.0);
}else if(uType<2.5){                             // 2 · polymer / rubber
  float sp=fbm3(P*7.0);
  float scuff=smoothstep(0.70,0.96,fbm3(P*vec3(1.6,7.0,7.0)+5.0))*fade;
  diffuseColor.rgb*=(0.92+0.16*sp);
  diffuseColor.rgb+=scuff*0.035;
  roughnessFactor=clamp(0.84+(sp-0.5)*0.14-scuff*0.10,0.34,1.0);
}else if(uType<3.5){                             // 3 · canvas, webbing, hide
  float wu=sin(P.x*46.0)*0.5+0.5, wv=sin(P.y*46.0)*0.5+0.5;
  float weave=mix(wu,wv,0.5)*fade;
  float slub=fbm3(P*9.0);
  float grime=smoothstep(0.35,0.95,fbm3(P*1.4+3.7))*smoothstep(0.6,-0.4,N.y);
  diffuseColor.rgb*=(0.80+0.30*slub)*(0.90+0.20*weave);
  diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.055,0.045,0.036),grime*0.55);
  roughnessFactor=clamp(0.94-weave*0.05+grime*0.05,0.55,1.0);
}else if(uType<4.5){                             // 4 · flesh
  float blotch=fbm3(P*1.6+13.0);
  float vein=smoothstep(0.72,0.99,rdg(P*vec3(2.2,2.6,2.2)+4.0))*fade;
  float bruise=smoothstep(0.55,0.92,fbm3(P*0.9+31.0));
  float pore=fbm3(P*14.0)*fade;
  diffuseColor.rgb*=(0.80+0.34*blotch)*(0.96+0.08*pore);
  diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.230,0.085,0.078),bruise*0.42);
  diffuseColor.rgb=mix(diffuseColor.rgb,vec3(0.330,0.110,0.105),vein*0.50);
  float wet=smoothstep(0.45,0.85,blotch);
  roughnessFactor=clamp(0.70-wet*0.26+bruise*0.06,0.26,1.0);
}else{                                           // 5 · chitin / bone
  float band=pow(sin(P.y*15.0+fbm3(P*2.0)*4.0)*0.5+0.5,2.2)*fade;
  float shell=fbm3(P*2.4+17.0);
  float chip=smoothstep(0.82,0.99,fbm3(P*8.0))*fade;
  diffuseColor.rgb*=(0.74+0.40*shell);
  diffuseColor.rgb+=band*0.045;
  diffuseColor.rgb=mix(diffuseColor.rgb,diffuseColor.rgb*vec3(1.10,1.02,0.88),chip*0.6);
  roughnessFactor=clamp(0.40+band*0.16+shell*0.14-chip*0.12,0.16,1.0);
}

// --- BUMP (after normal_fragment_maps) -----------------------------------
float bsc=9.0, bamt=0.011;
if(uType>3.5&&uType<4.5){ bsc=7.0;  bamt=0.016; }   // flesh
if(uType>4.5){           bsc=12.0; bamt=0.013; }    // chitin
if(uType>2.5&&uType<3.5){ bsc=16.0; bamt=0.012; }   // cloth
float bpx=length(fwidth(vOP))*bsc;
bamt*=1.0-smoothstep(0.05,0.30,bpx);
float hgt=fbm2(vOP*bsc);
vec3 dpx=dFdx(-vViewPosition), dpy=dFdy(-vViewPosition);
float hx=dFdx(hgt), hy=dFdy(hgt);
vec3 rr1=cross(dpy,normal), rr2=cross(normal,dpx);
float det=dot(dpx,rr1);
vec3 grad=(hx*rr1+hy*rr2)/(abs(det)+0.000001);
grad*=min(1.0,6.0/(length(grad)+0.0001));
normal=normalize(normal-bamt*grad);
```

Frequencies are ~10× those in `scav_range.html` because **one model unit is one
metre here**, not 90 mm. The `fade`/`bpx` terms are a hand-rolled mip: detail
dissolves once one pixel spans more than ~0.075 object-space units, which is what
keeps a rack of twelve enemies from shimmering.

Port target: one Godot `ShaderMaterial` with `uType` and `uSeed` as instance
uniforms (`INSTANCE_CUSTOM`), or six pre-specialised shaders. Do **not** create a
material per part.
