# scav_range.html — implementation spec (gun system + shooting range)

Source of truth: `reference/scav_range.html`, 2428 lines. Line 195 is the minified
three.js r13x bundle, line 197 is `<script id="partdata">` (95 parts + 232,134-byte
base64 mesh blob). All readable game code is lines **198–2426**. Every constant below
is transcribed verbatim; every formula was re-derived and then verified by executing
the reference in a browser and dumping golden values (§10).

Line map:

| lines | contents |
|---|---|
| 199–217 | part data decode, `geom()` |
| 219–239 | `rng`, `pick`, `cl`, PREF/NOUN/ROM, `nameFor` |
| 241–259 | `OVL`, `LIM`, `fit()` |
| 261–276 | `MM`, `KNOWN`, `cartridgeName()`, `RPMB` |
| 278–551 | `assemble()` — the whole derivation |
| 553–573 | `TIER_RANK`, `fitOptics()` |
| 574–607 | `randomSel`, `build`, `CLASS_MIX`, `wantedClass`, `rollTyped*`, `rollWeapon` |
| 608–619 | `TIERS`, `tierOf()` |
| 621–711 | gun shader (NOISE/DETAIL/BUMP), `gunMat()` |
| 713–728 | `weaponNode()` |
| 730–876 | `Audio` (procedural weapon voice) |
| 878–900 | renderer, env map |
| 902–1102 | `Bench` |
| 1105–1206 | range world: sky, ground, pad, berms, rocks, markers |
| 1208–1253 | spark particles |
| 1255–1317 | smoke clouds |
| 1319–1349 | decals |
| 1351–1366 | tracers |
| 1368–1441 | projectiles |
| 1443–1542 | targets + range layout |
| 1544–1616 | loadout, muzzle flash, `buildViewmodel()` |
| 1618–1726 | player state, `effSpread`, `spreadDir`, `castValid*`, `fireOnce` |
| 1727–1855 | `resolveHit`, `impact`, `blastAt`, `explode`, `groupReadout` |
| 1857–1906 | `startReload`, `tickWeapon` |
| 1908–2076 | HUD |
| 2078–2215 | `update()` |
| 2216–2301 | scope render, input plumbing |
| 2303–2424 | mode switch, input, boot loop |

---

## 0. Units, axes, and the six things that break a naive port

**Units.** 1 world unit = 1 metre in the range. 1 *model* unit = 90 mm = 0.09 m
(`const MM=90`). Weapon geometry is authored in model units and scaled at instance
time. Ballistics math consumes *millimetres* (`ext[0]*k*MM`), never metres.

**Axes.** three.js and Godot are both right-handed, Y-up, −Z forward. Vertex data,
Euler order `YXZ`, forward/right basis vectors and pitch sign all port with **no flip**.
`_fwd=(-sin(yaw),0,-cos(yaw))` equals Godot's `-basis.z`; `_rgt=(cos(yaw),0,-sin(yaw))`
equals Godot's `basis.x`.

The six real hazards:

1. **`Math.log` is natural log.** Every `Math.log(...)` in `assemble()` is `ln`.
   `Math.log2` appears once (`rawSpread`), `Math.log10` six times. GDScript's `log()`
   is also natural, so `log2(x) → log(x)/0.6931471805599453` and
   `log10(x) → log(x)/2.302585092994046`.
2. **`>>>` vs `>>` inside `rng()`.** The generator uses an *arithmetic* right shift
   (`s^=s>>17`) on a value that has just been coerced to uint32. This is not textbook
   xorshift32 and it is not reproducible with a naive 64-bit shift. See §1.
3. **Order of operations in `assemble()` is load-bearing.** `reload` is computed from
   the **pre-TUNE** `cap`; `cap` is then rewritten by `TUNE.cap`; `reload` is then
   scaled. `spread` is written four times before it is final. Reordering changes stats.
4. **`p.fh` can be exactly `0.0`** (part 70, Serpent stock). `fit()` divides by
   `Math.max(L,1e-6)` and `Math.max(L*k,1e-6)`, producing `err ≈ 13.59` instead of
   `inf`/`NaN`. Reproduce the epsilon guards exactly or you get NaN stats.
5. **`side:THREE.DoubleSide` on every gun material** hides the 55 inverted-winding
   parts. Godot culls backfaces. The mesh repair in the project contract is mandatory —
   do not paper over it with a two-sided material.
6. **Frame-rate dependence.** Decay is written as `x *= Math.pow(k, dt)`, which is
   frame-rate independent and ports directly. But `n.position.lerp(target, 0.16)` and
   `x += (target-x)*0.08` in `Bench.update` and target swing are **per-frame** lerps
   with no `dt` — they are frame-rate dependent in the original. Convert them to
   `1.0 - pow(1.0 - a, dt*60.0)` to preserve the 60 Hz look.

Additional smaller traps are flagged inline as **PORT**.

---

## 1. JS numeric primitives — exact GDScript equivalents

### 1.1 `rng(seed)` — the xorshift the whole system keys off

```js
function rng(seed){let s=seed>>>0||1;return()=>{
  s^=s<<13;s>>>=0;s^=s>>17;s^=s<<5;s>>>=0;return s/4294967296;};}
```

`^`, `<<` and `>>` all coerce through **ToInt32** (signed 32-bit); `>>>=0` coerces to
**ToUint32**. The `s>>17` step therefore sign-extends when `s ≥ 2^31`.

```gdscript
class_name ScavRng
extends RefCounted

var _s: int = 1

static func _i32(x: int) -> int:
	return ((x & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000

func _init(seed: int) -> void:
	_s = seed & 0xFFFFFFFF
	if _s == 0:
		_s = 1

func next() -> float:
	_s = _i32(_s) ^ _i32((_i32(_s) << 13) & 0xFFFFFFFF)
	_s = _s & 0xFFFFFFFF               # s >>>= 0
	_s = _i32(_s) ^ (_i32(_s) >> 17)   # ARITHMETIC shift, sign-extending
	_s = _i32(_s) ^ _i32((_i32(_s) << 5) & 0xFFFFFFFF)
	_s = _s & 0xFFFFFFFF               # s >>>= 0
	return float(_s) / 4294967296.0
```

Verification vectors (must match bit-for-bit):

| seed | first five `next()` |
|---|---|
| 1 | `0.00006295018829405308, 0.015739798778668046, 0.42266560392454267, 0.8155057488474995, 0.6551597700454295` |
| 12345 | `0.776938705239445, 0.3951726963277906, 0.6557702794671059, 0.45510494196787477, 0.8560839416459203` |

### 1.2 Helpers

```js
const pick=(r,a)=>a[Math.floor(r()*a.length)];
const cl=(v,a,b)=>Math.max(a,Math.min(b,v));
```

`cl(v,a,b)` = `clampf(v,a,b)` but note the argument order is `Math.max(a, Math.min(b,v))`
so **if `a > b` the low bound wins** — irrelevant here, all bounds are ordered.

`pick` consumes exactly one `r()` call. Call-order is part of the contract; see §7 and §8.

### 1.3 `Math.round` and `toFixed`

* `Math.round(x)` rounds half toward **+∞** (`Math.round(-0.5) === -0`). GDScript
  `round()` rounds half **away from zero**. Every `Math.round` in `assemble()` is applied
  to a non-negative value except none — so `roundi()` is safe throughout, but do not
  reuse a generic helper on signed data elsewhere.
* `(+x.toFixed(n))` is round-half-away-from-zero **on the stored double**. `1.15` is
  stored as `1.1499999999999999`, so `(1.15).toFixed(1) === "1.1"`. The published
  `zoomLevels` for an iron-sighted gun is therefore `[1.1]`, not `[1.2]`, even though
  `zoom` is `1.15`. Use:

```gdscript
static func to_fixed(x: float, n: int) -> float:
	return float(("%." + str(n) + "f") % x)
```

`printf` rounds half-to-even on the exact double, which agrees with JS `toFixed` on every
value this system produces (all of them are inexact binary fractions). Do **not** use
`snapped()`.

**PORT:** `mass.toFixed(1)` is stored in `stats.weight` as a **string**, used only for
display. `stats.mass` holds the float. Keep both or you will format twice.

---

## 2. Part data contract

`DATA.parts` is 95 objects; `DATA.blob` is 309,512 base64 chars → 232,134 bytes.
`PARTS.forEach((p,i)=>{p.i=i; BY[p.k].push(p)})` — `p.i` is the index into the flat
95-element array and is the identity used by the `cfg` hash. `BY` groups by kind
**preserving flat order**.

| kind | count | flat indices (this order is the `BY` array order — reproduce exactly) |
|---|---|---|
| barrel | 22 | 0,4,8,11,15,20,24,28,33,37,41,45,50,54,59,64,69,74,78,82,86,91 |
| stock | 22 | 1,5,9,12,16,21,25,29,34,38,42,46,51,55,60,65,70,75,79,83,87,92 |
| grip | 20 | 2,6,13,17,22,26,30,39,43,47,52,56,61,66,71,76,80,84,88,93 |
| receiver | 22 | 3,7,10,14,19,23,27,32,36,40,44,49,53,58,63,68,73,77,81,85,90,94 |
| sight | 9 | 18,31,35,48,57,62,67,72,89 |

Total combinations advertised in the bench header:
`22 × 22 × 22 × 20 × (9+1) = 2,129,600`.

### 2.1 Fields

| field | meaning |
|---|---|
| `k` | kind: `barrel`/`stock`/`grip`/`receiver`/`sight` |
| `g` | donor group (20 families, table below) |
| `c` | donor class: `rifle`/`smg`/`shotgun`/`pistol`/`sniper`/`revolver`/`lmg`/`launcher` |
| `qo[3]`,`qs[3]` | dequantisation origin and scale: `pos[a] = qo[a] + int16 * qs[a]` |
| `nv`,`nf` | vertex count, triangle count |
| `vo`,`io` | byte offsets into blob; always `vo + nv*6 == io`, parts packed back to back |
| `ext[3]` | AABB size in model units |
| `cv` | convex-hull volume in model units³ (drives mass, powder, bolt weight) |
| `met`,`wd` | metal hex, timber hex |
| `muz` | barrels only — muzzle-end radius proxy, drives bore |
| `fh`,`fw` | fit height / fit width of this part's mating cut face |
| `s` | receivers only — sockets `{front,rear,bottom,top}`, each `[[x,y,z], height, width]` |

Local-origin conventions (implied by `qo`/`qs`, confirmed by reconstruction):
* **receiver** — centred on X (`x ∈ [-ext0/2, +ext0/2]`), `y=0` is the bore line.
* **barrel** — origin at the breech face, extends to `+X` (`x ∈ [0, ext0]`).
* **stock** — origin at the front (mating) face, extends to `−X` (`x ∈ [-ext0, 0]`).
* **grip** — hangs down: `y ∈ [-ext1, 0]`.
* **sight** — X-centred, sits above `y=0`.

### 2.2 Donor groups (20)

`Blackrifle, Boxgun, Breacher, Broomstick, Chattergun, Handcannon, Kalash, Karabiner,
Longshot, Nineteen, Pumper, Roomsweeper, Screamer, Serpent, Sidearm, Spitter, Stubby,
Sturmgewehr, Tube, Woodsman`

These strings are used verbatim by `nameFor()` and by the bench parts readout.

Class census across all 95 parts: rifle 21, smg 16, sniper 15, pistol 12, revolver 9,
shotgun 9, launcher 8, lmg 5.

### 2.3 The 95 parts

`idx kind group class ext cv fh fw muz met wd`

```
 0 barrel   Kalash      rifle    [3.4404,0.8124,0.4430] 0.78096 0.71031 0.44305 0.26867 #4d4a44 #8a5a2b
 1 stock    Kalash      rifle    [0.2816,0.8059,0.4839] 0.08684 0.80017 0.48392 -       #4d4a44 #8a5a2b
 2 grip     Kalash      rifle    [4.4609,2.0346,0.2824] 1.63098 3.15709 0.26729 -       #4d4a44 #8a5a2b
 3 receiver Kalash      rifle    [4.4694,1.0000,0.4839] 1.97077 -       -       -       #4d4a44 #8a5a2b
 4 barrel   Woodsman    rifle    [9.4185,1.2020,0.3214] 1.36340 0.88949 0.32144 0.33580 #59564e #7a5230
 5 stock    Woodsman    rifle    [5.1577,2.5606,0.5546] 3.87757 0.28184 0.30043 -       #59564e #7a5230
 6 grip     Woodsman    rifle    [7.8487,1.7650,0.4570] 2.65451 7.84871 0.42544 -       #59564e #7a5230
 7 receiver Woodsman    rifle    [7.8487,1.0000,0.5310] 2.26689 -       -       -       #59564e #7a5230
 8 barrel   Tube        launcher [3.4292,1.0510,0.4010] 0.62743 0.83489 0.28883 0.29842 #5f6448 #3f4436
 9 stock    Tube        launcher [2.7073,1.1630,0.6362] 0.98211 0.65702 0.35938 -       #5f6448 #3f4436
10 receiver Tube        launcher [2.8878,1.0000,0.3972] 0.69748 -       -       -       #5f6448 #3f4436
11 barrel   Spitter     smg      [2.2391,0.7113,0.3199] 0.28296 0.62290 0.31987 0.16669 #3a3d42 #2e3033
12 stock    Spitter     smg      [1.2495,1.7445,0.3292] 0.43604 0.47563 0.32925 -       #3a3d42 #2e3033
13 grip     Spitter     smg      [1.5522,2.3997,0.3600] 0.82861 1.45363 0.36000 -       #3a3d42 #2e3033
14 receiver Spitter     smg      [1.8426,1.0000,0.3600] 0.56557 -       -       -       #3a3d42 #2e3033
15 barrel   Pumper      shotgun  [5.3946,0.9499,0.4581] 1.35270 0.49836 0.16469 0.34296 #5a5049 #6b4423
16 stock    Pumper      shotgun  [2.9542,2.0776,0.3970] 1.34261 0.52121 0.27739 -       #5a5049 #6b4423
17 grip     Pumper      shotgun  [1.9755,0.4895,0.2804] 0.10776 1.97549 0.28036 -       #5a5049 #6b4423
18 sight    Pumper      shotgun  [3.5631,0.4523,0.3613] 0.31601 3.56309 0.36000 -       #5a5049 #6b4423
19 receiver Pumper      shotgun  [4.4955,1.0000,0.3600] 1.01592 -       -       -       #5a5049 #6b4423
20 barrel   Kalash      rifle    [3.0717,0.8376,0.3600] 0.49899 0.83609 0.36000 0.21777 #4d4a44 #8a5a2b
21 stock    Kalash      rifle    [2.0737,1.1306,0.1774] 0.24686 0.45037 0.17742 -       #4d4a44 #8a5a2b
22 grip     Kalash      rifle    [2.7400,1.4356,0.1774] 0.45976 1.93406 0.17742 -       #4d4a44 #8a5a2b
23 receiver Kalash      rifle    [2.7649,1.0000,0.3600] 0.62069 -       -       -       #4d4a44 #8a5a2b
24 barrel   Nineteen    pistol   [1.7701,0.7311,0.2953] 0.33052 0.73108 0.29527 0.47022 #63656a #5a3d24
25 stock    Nineteen    pistol   [0.9693,2.4285,0.3600] 0.67979 0.93536 0.36000 -       #63656a #5a3d24
26 grip     Nineteen    pistol   [1.3819,1.4450,0.3600] 0.29672 1.38190 0.36000 -       #63656a #5a3d24
27 receiver Nineteen    pistol   [1.4750,1.0000,0.3600] 0.46008 -       -       -       #63656a #5a3d24
28 barrel   Karabiner   sniper   [8.7110,1.0041,0.2942] 1.41485 0.70563 0.29422 0.20705 #3f4247 #8b6033
29 stock    Karabiner   sniper   [4.7703,2.5615,0.3745] 3.11250 0.15675 0.35775 -       #3f4247 #8b6033
30 grip     Karabiner   sniper   [6.0180,0.9640,0.4062] 1.19057 6.01800 0.40616 -       #3f4247 #8b6033
31 sight    Karabiner   sniper   [6.1161,0.2750,0.4062] 0.34079 6.11606 0.40616 -       #3f4247 #8b6033
32 receiver Karabiner   sniper   [7.2591,1.0000,0.4062] 2.40355 -       -       -       #3f4247 #8b6033
33 barrel   Blackrifle  rifle    [3.2016,0.7525,0.3294] 0.32525 0.56099 0.32939 0.27712 #2f3136 #26282c
34 stock    Blackrifle  rifle    [1.7866,0.9713,0.2358] 0.20993 0.46896 0.18697 -       #2f3136 #26282c
35 sight    Blackrifle  rifle    [0.9939,0.0843,0.1189] 0.00532 0.99391 0.11890 -       #2f3136 #26282c
36 receiver Blackrifle  rifle    [2.6347,1.0000,0.3600] 0.52722 -       -       -       #2f3136 #26282c
37 barrel   Handcannon  revolver [1.4293,1.0524,0.2003] 0.20869 0.71818 0.20026 0.11805 #6e7176 #4a3122
38 stock    Handcannon  revolver [0.7827,1.7177,0.2261] 0.20693 0.44652 0.22612 -       #6e7176 #4a3122
39 grip     Handcannon  revolver [1.1911,0.8766,0.2261] 0.13429 1.19109 0.22612 -       #6e7176 #4a3122
40 receiver Handcannon  revolver [1.1911,1.0000,0.3600] 0.27142 -       -       -       #6e7176 #4a3122
41 barrel   Broomstick  pistol   [4.1038,0.6660,0.3172] 0.47089 0.66596 0.31720 0.45135 #5b4838 #7a5433
42 stock    Broomstick  pistol   [2.2473,4.8154,0.5423] 3.44109 0.83085 0.54233 -       #5b4838 #7a5433
43 grip     Broomstick  pistol   [2.9172,1.8091,0.4743] 2.11227 2.91721 0.47427 -       #5b4838 #7a5433
44 receiver Broomstick  pistol   [3.4198,1.0000,0.5588] 1.46758 -       -       -       #5b4838 #7a5433
45 barrel   Chattergun  lmg      [2.3933,0.6535,0.5725] 0.51804 0.65353 0.35944 0.38060 #4a4d52 #3a3c40
46 stock    Chattergun  lmg      [1.4068,1.7029,0.6788] 0.63955 0.37288 0.67884 -       #4a4d52 #3a3c40
47 grip     Chattergun  lmg      [0.4772,1.1886,0.1665] 0.05352 0.47724 0.10385 -       #4a4d52 #3a3c40
48 sight    Chattergun  lmg      [0.6864,0.4253,0.4839] 0.07617 0.68642 0.48388 -       #4a4d52 #3a3c40
49 receiver Chattergun  lmg      [1.8982,1.0000,0.9789] 0.96853 -       -       -       #4a4d52 #3a3c40
50 barrel   Sidearm     pistol   [2.8291,2.3567,0.5284] 2.32588 0.96795 0.52835 0.70129 #43464a #33353a
51 stock    Sidearm     pistol   [1.5492,4.6004,0.5727] 3.54192 0.87296 0.57270 -       #43464a #33353a
52 grip     Sidearm     pistol   [2.3575,3.6099,0.5556] 3.07345 2.35754 0.52835 -       #43464a #33353a
53 receiver Sidearm     pistol   [2.3575,1.0000,0.5727] 1.24978 -       -       -       #43464a #33353a
54 barrel   Screamer    launcher [4.5002,0.6897,0.3285] 0.48397 0.35290 0.20408 0.21338 #6a6544 #6d4b28
55 stock    Screamer    launcher [4.2859,1.0419,0.6025] 1.25131 0.63552 0.36752 -       #6a6544 #6d4b28
56 grip     Screamer    launcher [1.5458,0.7140,0.2353] 0.12341 1.54576 0.23529 -       #6a6544 #6d4b28
57 sight    Screamer    launcher [0.9546,0.4521,0.0888] 0.02320 0.95464 0.08885 -       #6a6544 #6d4b28
58 receiver Screamer    launcher [1.9286,1.0000,0.3690] 0.43618 -       -       -       #6a6544 #6d4b28
59 barrel   Longshot    sniper   [3.9087,1.0814,0.3600] 0.74927 0.87206 0.36000 0.38250 #3c3f44 #5f4b33
60 stock    Longshot    sniper   [2.1405,1.1794,0.2871] 0.65658 0.26803 0.28713 -       #3c3f44 #5f4b33
61 grip     Longshot    sniper   [2.0347,0.6182,0.3153] 0.16774 1.86284 0.31528 -       #3c3f44 #5f4b33
62 sight    Longshot    sniper   [3.2280,0.2039,0.3600] 0.13641 3.22804 0.36000 -       #3c3f44 #5f4b33
63 receiver Longshot    sniper   [3.2572,1.0000,0.3600] 0.99244 -       -       -       #3c3f44 #5f4b33
64 barrel   Sturmgewehr rifle    [4.3095,1.0446,0.3600] 1.00268 0.74161 0.36000 0.21239 #5a4b3c #6e4c2c
65 stock    Sturmgewehr rifle    [5.5237,2.4295,0.4898] 3.99570 0.94650 0.36000 -       #5a4b3c #6e4c2c
66 grip     Sturmgewehr rifle    [2.1214,4.2264,0.3066] 1.42825 0.95539 0.30660 -       #5a4b3c #6e4c2c
67 sight    Sturmgewehr rifle    [0.7825,0.2929,0.2517] 0.05768 0.78252 0.25171 -       #5a4b3c #6e4c2c
68 receiver Sturmgewehr rifle    [2.1585,1.0000,0.3600] 0.66626 -       -       -       #5a4b3c #6e4c2c
69 barrel   Serpent     revolver [6.5190,1.7337,0.5072] 4.35035 0.64742 0.43704 0.46813 #6a6d73 #4d3323
70 stock    Serpent     revolver [3.5699,5.5403,0.6263] 7.75638 0.00000 0.50719 -       #6a6d73 #4d3323
71 grip     Serpent     revolver [4.8275,3.0005,1.0334] 8.79208 4.82753 1.03339 -       #6a6d73 #4d3323
72 sight    Serpent     revolver [4.4472,0.6944,0.5072] 1.29468 4.44725 0.50719 -       #6a6d73 #4d3323
73 receiver Serpent     revolver [5.4325,1.0000,1.0522] 3.59214 -       -       -       #6a6d73 #4d3323
74 barrel   Breacher    shotgun  [3.0985,0.7814,0.2454] 0.37133 0.78144 0.24535 0.27203 #4a4c50 #5c3f26
75 stock    Breacher    shotgun  [0.4841,0.9149,0.3600] 0.09789 0.84747 0.36000 -       #4a4c50 #5c3f26
76 grip     Breacher    shotgun  [1.9030,1.1382,0.3184] 0.36332 1.90302 0.31840 -       #4a4c50 #5c3f26
77 receiver Breacher    shotgun  [3.7947,1.0000,0.3600] 1.10722 -       -       -       #4a4c50 #5c3f26
78 barrel   Roomsweeper smg      [1.6854,0.9095,0.3600] 0.33170 0.53632 0.36000 0.15671 #35373b #2b2d30
79 stock    Roomsweeper smg      [0.9075,0.9574,0.3243] 0.15128 0.57094 0.32433 -       #35373b #2b2d30
80 grip     Roomsweeper smg      [2.0053,0.8465,0.1868] 0.16976 1.50760 0.18682 -       #35373b #2b2d30
81 receiver Roomsweeper smg      [2.0167,1.0000,0.3600] 0.54125 -       -       -       #35373b #2b2d30
82 barrel   Stubby      smg      [2.6039,0.6219,0.3496] 0.36503 0.59647 0.34961 0.14880 #5c584f #2f3134
83 stock    Stubby      smg      [2.0350,1.2874,0.3328] 0.38841 0.68342 0.33279 -       #5c584f #2f3134
84 grip     Stubby      smg      [2.3476,1.1855,0.1917] 0.29545 1.57490 0.19172 -       #5c584f #2f3134
85 receiver Stubby      smg      [2.3632,0.9724,0.3600] 0.63277 -       -       -       #5c584f #2f3134
86 barrel   Longshot    sniper   [7.1790,0.6748,0.3711] 0.86021 0.67480 0.37114 0.67480 #3c3f44 #5f4b33
87 stock    Longshot    sniper   [3.9314,2.9596,0.3602] 2.33122 0.94039 0.36021 -       #3c3f44 #5f4b33
88 grip     Longshot    sniper   [4.5024,2.6688,0.3012] 2.01247 4.04868 0.30122 -       #3c3f44 #5f4b33
89 sight    Longshot    sniper   [4.3789,1.3936,0.6745] 1.84828 3.94024 0.26353 -       #3c3f44 #5f4b33
90 receiver Longshot    sniper   [5.9825,1.0000,0.4970] 2.04093 -       -       -       #3c3f44 #5f4b33
91 barrel   Boxgun      smg      [1.1636,1.0658,0.4036] 0.25397 0.81887 0.40362 0.12887 #40434a #303236
92 stock    Boxgun      smg      [0.7532,1.5674,0.4036] 0.29966 0.98391 0.40362 -       #40434a #303236
93 grip     Boxgun      smg      [0.8537,1.1788,0.1551] 0.10653 0.85367 0.15507 -       #40434a #303236
94 receiver Boxgun      smg      [0.8537,1.0000,0.4036] 0.27247 -       -       -       #40434a #303236
```

Note part **70** has `fh = 0.0` (hazard #4) and part **86** has `muz = 0.67480` which is
the only barrel that produces an explosive launcher on its own (`0.6748*90*0.46 = 27.94 ≥ 25`).

### 2.4 Receiver sockets

`[x,y,z]` is the socket centre in receiver-local model units; `h` is the mating-face
height (measured along **X** for `bottom` and `top`, along **Y** for `front` and `rear`);
`w` is the mating-face width (along Z).

```
idx group        front                              rear                               bottom                              top
 3  Kalash       [ 2.23471,-0.10263,-0.00002] h0.71031 w0.44305 | [-2.23471,-0.20048, 0.00000] h0.80017 w0.48392 | [-0.59745,-0.62055, 0.00000] h3.27452 w0.48392 | [-0.50093, 0.37945, 0.00708] h2.90714 w0.42923
 7  Woodsman     [ 3.92436, 0.04309, 0.02051] h0.96732 w0.32144 | [-3.92436,-0.22114, 0.01909] h0.43886 w0.34126 | [ 0.00000,-0.44057, 0.02051] h7.84871 w0.42544 | [ 0.89741, 0.55943, 0.02176] h6.05390 w0.02692
10  Tube         [ 1.44389,-0.19093, 0.00192] h0.90093 w0.28883 | [-1.44389,-0.00448, 0.00153] h0.65702 w0.35938 | [ 0.79805,-0.64140, 0.02473] h1.29168 w0.05720 | [-0.11575, 0.35860, 0.02269] h2.65629 w0.16245
14  Spitter      [ 0.92131, 0.01099, 0.00000] h0.73327 w0.32925 | [-0.92131,-0.05561, 0.00000] h0.64562 w0.32925 | [-0.10351,-0.62237, 0.00000] h1.47527 w0.36000 | [ 0.00000, 0.26720, 0.00000] h1.84263 w0.32925
19  Pumper       [ 2.24777, 0.14574, 0.00161] h0.50163 w0.16469 | [-2.24777,-0.25579, 0.00170] h0.69531 w0.27739 | [-0.46044,-0.21708, 0.00161] h3.57466 w0.32425 | [ 0.43261, 0.39655, 0.00161] h3.63031 w0.36000
23  Kalash       [ 1.38244,-0.04733, 0.00000] h0.88776 w0.36000 | [-1.38244,-0.15244, 0.00000] h0.45236 w0.17742 | [-0.28547,-0.60345, 0.00000] h1.93406 w0.17742 | [ 0.18434, 0.39655, 0.00000] h2.39619 w0.17742
27  Nineteen     [ 0.73752,-0.02136, 0.00000] h0.73281 w0.29527 | [-0.73752,-0.15507, 0.00000] h0.99899 w0.36000 | [-0.04657,-0.65456, 0.00000] h1.38190 w0.36000 | [ 0.00000, 0.34544, 0.00000] h1.47504 w0.29527
32  Karabiner    [ 3.62957,-0.08210, 0.07799] h0.95731 w0.29422 | [-3.62957,-0.50478, 0.07728] h0.19733 w0.35918 | [ 0.00000,-0.60345, 0.07799] h7.25914 w0.40616 | [ 0.57154, 0.39655, 0.07799] h6.11606 w0.40616
36  Blackrifle   [ 1.31733,-0.12722, 0.00000] h0.56099 w0.32939 | [-1.31733,-0.23119,-0.00027] h0.46896 w0.18697 | [-0.27640,-0.60345,-0.00150] h1.23197 w0.12136 | [-0.25970, 0.39655,-0.00032] h0.99391 w0.11890
40  Handcannon   [ 0.59554,-0.20808, 0.00000] h0.86082 w0.36000 | [-0.59554,-0.27623,-0.00102] h0.72452 w0.22018 | [ 0.00000,-0.63849,-0.00102] h1.19109 w0.22018 | [-0.13029, 0.36151,-0.00188] h0.38478 w0.11329
44  Broomstick   [ 1.70990,-0.13573,-0.00081] h0.66596 w0.31720 | [-1.70990,-0.15648, 0.00000] h0.95196 w0.54233 | [-0.25130,-0.63246, 0.00000] h2.91721 w0.47427 | [-1.06209, 0.36754,-0.00081] h1.29563 w0.42206
49  Chattergun   [ 0.94912,-0.03800, 0.09181] h0.65353 w0.35944 | [-0.94912,-0.10345, 0.13014] h1.00000 w0.71865 | [-0.69351,-0.60345,-0.16978] h0.47724 w0.09276 | [-0.60591, 0.39655, 0.12924] h0.68642 w0.52246
53  Sidearm      [ 1.17877,-0.22230, 0.00000] h1.00000 w0.52835 | [-1.17877,-0.22596, 0.00000] h0.99268 w0.57270 | [ 0.00000,-0.72230, 0.00000] h2.35754 w0.52835 | [ 0.00000, 0.27770,-0.00772] h2.35754 w0.42551
58  Screamer     [ 0.96432,-0.19255, 0.00000] h0.82180 w0.20408 | [-0.96432, 0.05682, 0.00000] h0.63552 w0.36752 | [ 0.19144,-0.60345, 0.06755] h1.54576 w0.23529 | [-0.38126, 0.39655, 0.07418] h1.16612 w0.14836
63  Longshot     [ 1.62862,-0.04221, 0.02415] h0.87752 w0.36000 | [-1.62862,-0.04395, 0.02415] h0.88101 w0.29680 | [-0.52535,-0.60345, 0.02415] h1.86284 w0.31528 | [ 0.01460, 0.39655, 0.02415] h3.22804 w0.36000
68  Sturmgewehr  [ 1.07925,-0.02299, 0.00000] h0.74161 w0.36000 | [-1.07925,-0.12782, 0.00000] h0.95126 w0.36000 | [-0.60155,-0.60345, 0.00000] h0.95539 w0.30660 | [ 0.00000, 0.39655, 0.00000] h2.15850 w0.25171
73  Serpent      [ 2.71626,-0.00041, 0.00000] h0.79392 w0.43704 | [-2.71626,-0.57800, 0.00000] h0.05089 w0.50719 | [-0.30250,-0.60345, 0.00000] h4.82753 w1.05220 | [ 0.49264, 0.39655, 0.00000] h4.44725 w0.50719
77  Breacher     [ 1.89735,-0.02154, 0.00000] h0.73274 w0.24535 | [-1.89735,-0.17788, 0.00000] h0.85113 w0.36000 | [-1.34579,-0.60345, 0.00000] h1.10312 w0.36000 | [ 0.50025, 0.39655, 0.00000] h2.79421 w0.36000
81  Roomsweeper  [ 1.00833,-0.08994, 0.00000] h0.53632 w0.36000 | [-1.00833,-0.08127, 0.00000] h0.57094 w0.32433 | [-0.05974,-0.79580, 0.00000] h1.50760 w0.18682 | [ 0.00000, 0.19994, 0.00000] h2.01667 w0.22645
85  Stubby       [ 1.18161,-0.16153, 0.00000] h0.59647 w0.34961 | [-1.18161,-0.17328, 0.00000] h0.68212 w0.33279 | [-0.00424,-0.80460, 0.00000] h1.57350 w0.19172 | [ 0.00000, 0.16209, 0.00657] h2.36321 w0.20486
90  Longshot     [ 2.99125, 0.00000, 0.00000] h0.67480 w0.37114 | [-2.99125,-0.09045, 0.00000] h1.00000 w0.36021 | [-0.74005,-0.59045, 0.00000] h4.50239 w0.30122 | [-0.58546, 0.40955, 0.00000] h4.81158 w0.26353
94  Boxgun       [ 0.42683,-0.23143, 0.00000] h0.85942 w0.40362 | [-0.42683,-0.16113, 0.00000] h1.00000 w0.40362 | [ 0.00000,-0.66113,-0.00010] h0.85367 w0.15527 | [-0.07950, 0.33887, 0.00000] h0.69467 w0.14544
```

### 2.5 Mesh decode (`geom`, lines 207–217)

```gdscript
# positions: nv*3 SIGNED int16 LE at byte offset vo
# indices:   nf*3 UNSIGNED uint16 LE at byte offset io
for v in nv:
	for a in 3:
		pos[v * 3 + a] = qo[a] + float(blob.decode_s16(vo + (v * 3 + a) * 2)) * qs[a]
```

The reference calls `computeVertexNormals()` (smooth) then renders with
`flatShading:true`, which discards them and uses derivative normals. **Bake flat-shaded
(split vertices, face normals) or a ≤45° smoothing angle** per the project contract.

---

## 3. Part fitting — `OVL`, `LIM`, `fit()`

```js
const OVL={barrel:0.07,stock:0.07,grip:0.15,sight:0.08};
const LIM={barrel:[.50,1.62],stock:[.45,1.80],grip:[.24,1.60],sight:[.34,1.60]};
function fit(kind,p,sock){
  const pos=sock[0].slice(),h=sock[1],w=sock[2],L=p.fh;
  let k=h/Math.max(L,1e-6);
  if(kind==='grip')  k=Math.min(k,1.95/Math.max(p.ext[1],1e-6));
  if(kind==='sight') k=Math.min(k,0.95/Math.max(p.ext[1],1e-6));
  if(kind==='stock') k=Math.min(k,2.10/Math.max(p.ext[1],1e-6),4.0/Math.max(p.ext[0],1e-6));
  if(kind==='barrel')k=Math.min(k,1.85/Math.max(p.ext[1],1e-6));
  k=cl(k,LIM[kind][0],LIM[kind][1]);
  const kz=cl(1+0.85*((w/Math.max(p.fw,1e-6))-1),0.70,1.90);
  const o=OVL[kind];
  if(kind==='barrel')pos[0]-=o;
  if(kind==='stock') pos[0]+=o;
  if(kind==='sight') pos[1]-=o;
  if(kind==='grip'){pos[1]+=o;pos[0]=(pos[0]-h/2)+0.06*h+L*k/2;}
  return{k,kz,pos,err:Math.abs(Math.log(Math.max(h,1e-6)/Math.max(L*k,1e-6)))};
}
```

GDScript:

```gdscript
const OVL := {"barrel": 0.07, "stock": 0.07, "grip": 0.15, "sight": 0.08}
const LIM := {"barrel": Vector2(0.50, 1.62), "stock": Vector2(0.45, 1.80),
	"grip": Vector2(0.24, 1.60), "sight": Vector2(0.34, 1.60)}

static func fit(kind: String, p: GunPart, sock_pos: Vector3, h: float, w: float) -> Dictionary:
	var pos: Vector3 = sock_pos
	var l: float = p.fh
	var k: float = h / maxf(l, 1e-6)
	match kind:
		"grip":   k = minf(k, 1.95 / maxf(p.ext.y, 1e-6))
		"sight":  k = minf(k, 0.95 / maxf(p.ext.y, 1e-6))
		"stock":  k = minf(minf(k, 2.10 / maxf(p.ext.y, 1e-6)), 4.0 / maxf(p.ext.x, 1e-6))
		"barrel": k = minf(k, 1.85 / maxf(p.ext.y, 1e-6))
	var lim: Vector2 = LIM[kind]
	k = clampf(k, lim.x, lim.y)
	var kz: float = clampf(1.0 + 0.85 * ((w / maxf(p.fw, 1e-6)) - 1.0), 0.70, 1.90)
	var o: float = OVL[kind]
	match kind:
		"barrel": pos.x -= o
		"stock":  pos.x += o
		"sight":  pos.y -= o
		"grip":
			pos.y += o
			pos.x = (pos.x - h * 0.5) + 0.06 * h + l * k * 0.5
	return {
		"k": k, "kz": kz, "pos": pos,
		"err": absf(log(maxf(h, 1e-6) / maxf(l * k, 1e-6))),
	}
```

Semantics:

* `k` is the **uniform XY scale**, driven only by matching the part's own cut-face height
  `fh` to the socket height `h`. `kz` is an **extra Z-only** multiplier that closes 85 %
  of the gap between the part's cut width and the socket width, so a bad width match is
  softened rather than fully corrected.
* The per-kind `Math.min` caps are absolute size ceilings in model units: grip body
  ≤ 1.95 tall, sight body ≤ 0.95 tall, stock ≤ 2.10 tall and ≤ 4.0 long, barrel ≤ 1.85
  tall. These beat the socket match — a grip that would have to grow to fill a huge
  socket is capped instead, and eats the `err`.
* `OVL` is the deliberate **interpenetration** distance so joints never gap: barrels are
  pulled 0.07 back into the receiver, stocks pushed 0.07 forward into it, sights dropped
  0.08 into the top rail, grips raised 0.15 into the bottom. **Preserve these — they are
  the only reason the assembly has no air gaps** (project rule #2).
* The grip additionally re-centres along X: its fit face is assumed centred on its own
  local origin, so it is placed at `socket_front_edge + 0.06*h + fit_length/2`, where
  `socket_front_edge = pos.x - h/2`.
* `err` is `|ln(socket_height / achieved_fit_height)|` — 0 for a perfect match, growing
  logarithmically with mismatch. It is summed across barrel + stock + grip + sight into
  the assembly `err`, which then poisons reliability, spread and reload time.

**Worked check (seed 1: receiver 3 / barrel 0 / stock 38 / grip 80):**

| slot | h (socket) | fh | raw k | after cap | after LIM | kz | err |
|---|---|---|---|---|---|---|---|
| barrel 0 (front) | 0.71031 | 0.71031 | 1.00000 | 1.00000 | **1.00000** | 1.00000 | **0.00000** |
| stock 38 (rear) | 0.80017 | 0.44652 | 1.79203 | 1.22257 | **1.22257** | 1.90000 | **0.38239** |
| grip 80 (bottom) | 3.27452 | 1.50760 | 2.17203 | 2.17203 | **1.60000** | 1.90000 | **0.30563** |

Total `err = 0.68802`. Positions: barrel `(2.16471, -0.10263, -0.00002)`,
stock `(-2.16471, -0.20048, 0)`, grip `(-0.83216, -0.47055, 0)`.

**Hazard:** part 70 (Serpent stock) has `fh = 0`. `k` becomes `h/1e-6 = 800170`, is capped
by `2.10/5.5403 = 0.37904`, then *raised* by `LIM.stock[0]` to **0.45**, and
`err = |ln(0.80017/1e-6)| = 13.5926`. Any gun carrying it lands at `rel = 1`,
`spread ≈ 264 MOA`, tier Hazard. That is intended reference behaviour — reproduce it,
epsilons and all, or you get `inf`/`NaN`.

---

## 4. `assemble()` — the derivation, in execution order

`assemble(sel, seed)` where `sel = {receiver, barrel, stock, grip, sight|null}`.
Every step below runs in exactly this order; reordering changes the stats.

### 4.1 Build `used[]` and total `err`

```js
const rec=sel.receiver, s=rec.s;
const used=[{p:rec,k:1,kz:1,pos:[0,0,0]}]; let err=0;
for(const [kind,key] of [['barrel','front'],['stock','rear'],['grip','bottom']]){
  const f=fit(kind,sel[kind],s[key]);
  used.push({p:sel[kind],k:f.k,kz:f.kz,pos:f.pos}); err+=f.err;
}
if(sel.sight){const f=fit('sight',sel.sight,s.top);
  used.push({p:sel.sight,k:f.k,kz:f.kz,pos:f.pos}); err+=f.err;}
```

`used` order is fixed: **receiver, barrel, stock, grip, [sight]**. The receiver is never
scaled (`k=1, kz=1`) and sits at the origin. This order matters for `nameFor()` (§8) and
for the group/class set iteration order.

### 4.2 Dimensions

```js
const hull=u=>u.p.cv*u.k*u.k*u.k*u.kz;      // convex volume after non-uniform scale
const cm3 =v=>v*(MM/10)*(MM/10)*(MM/10);    // model units^3 -> cm^3   (== v*729)

const barLen=bar.p.ext[0]*bar.k*MM;         // mm
const stoLen=sto.p.ext[0]*sto.k*MM;         // mm
const magH  =gri.p.ext[1]*gri.k;            // MODEL UNITS, not mm
const sigLen=sig?sig.p.ext[0]*sig.k:0;      // MODEL UNITS
const recLen=rec.ext[0]*MM;                 // mm  (receiver never scaled)
```

**PORT:** `magH` and `sigLen` stay in model units while `barLen`/`stoLen`/`recLen` are
millimetres. Mixing them silently ruins `feed`, `mode`, `cap` and `zoom`.

Overall length:

```js
let x0=1e9,x1=-1e9;
for(const u of used){const h=u.p.ext[0]*u.k/2;
  const c=u.pos[0]+(u.p.k==='barrel'?h:u.p.k==='stock'?-h:0);
  x0=Math.min(x0,c-h);x1=Math.max(x1,c+h);}
const oaLen=(x1-x0)*MM;                     // mm
```

Each part is an X-interval of half-length `h` centred on `c`. Barrels shift **forward**
by `h` and stocks **backward** by `h` to account for their off-centre local origins;
receiver, grip and sight are centred on `pos.x`.

### 4.3 Mass

```js
const steel=0.0021, timber=0.0009;          // kg per cm^3 of hull volume
const mass=cl(0.35+used.reduce((a,u)=>a+cm3(hull(u))*
    ((u.p.k==='grip'||u.p.k==='stock')?timber:steel),0),0.5,26);
```

```gdscript
var mass: float = 0.35
for u in used:
	var dens: float = 0.0009 if (u.p.k == "grip" or u.p.k == "stock") else 0.0021
	mass += (u.p.cv * u.k * u.k * u.k * u.kz) * 729.0 * dens
mass = clampf(mass, 0.5, 26.0)
```

Seed 1: 3.0171 + 1.1956 + 0.4713 + 0.8668 + 0.35 = **5.900794746439747 kg**.

### 4.4 Cartridge geometry

```js
const caseLen =cl(10+recLen*0.13,16,115);                    // mm
const boreRaw =(bar.p.muz||0.25)*bar.k*MM*0.46;              // mm
const headRec =cl(s.front[1]*MM*0.19,6,42);                  // mm — receiver's cap on case head
const explosive= boreRaw>=25;
const bore    =explosive?cl(boreRaw,25,110):cl(boreRaw,4.5,headRec*0.94);
const caseHead=explosive?bore*1.04:headRec;
const shot    = !explosive && bore>=12.5 && bore/headRec>0.78;
const fillf   = cl(1.15-bore/30,0.35,1.0);
const powder  = Math.pow(caseHead/10,2)*(caseLen/10)*0.30*fillf;   // grams
const burn    = 1-Math.exp(-barLen/240);
const energy  = powder*1250*(0.34+0.66*burn);                      // joules
const projG   = Math.pow(bore,2.85)*0.012;                         // grams
const pellets = shot? cl(Math.round(Math.pow(bore/6.0,2)),2,16):1;
const vel     = cl(Math.sqrt(2*energy/(projG/1000)),150,1500);     // m/s
const impulse = projG/1000*vel + powder*0.75/1000*1500;            // N·s
```

Source rationale, verbatim intent: bore is the barrel's business, and the receiver
normally caps it because the action must close on that case head — but a barrel whose own
bore already clears 25 mm is a launcher tube, and no receiver turns that back into a rifle
round; the chamber just has to accept it.

`(bar.p.muz||0.25)`: every shipped barrel has `muz`, but keep the default. **PORT:** JS
`||` also falls through on `0`, so a `muz` of exactly 0 becomes 0.25.

Seed-1 trace: `recLen=402.246`, `caseLen=62.292`, `boreRaw=11.1229`, `headRec=12.1463`,
`bore=11.1229`, `fillf=0.77924`, `powder=2.14810 g`, `barLen=309.636`, `burn=0.72481`,
`energy=2197.5 J`, `projG=11.508 g`, `vel=617.9`, `impulse=9.5282`.

### 4.5 Cartridge naming

```js
const KNOWN=[[5.7,28,'5.7×28'],[9,19,'9×19'],[9,29,'.38 Special'],[11.4,23,'.45 ACP'],
 [10.9,33,'.44 Magnum'],[9.1,33,'.357 Magnum'],[5.45,39,'5.45×39'],[5.56,45,'5.56×45'],
 [7.62,39,'7.62×39'],[7.62,51,'7.62×51'],[7.92,57,'7.92×57'],[8.6,70,'.338 Lapua'],
 [12.7,99,'.50 BMG'],[18.5,70,'12 gauge'],[15.6,70,'20 gauge'],[20,80,'20 mm'],[40,46,'40 mm HE']];
function cartridgeName(bore,len,shot){
  for(const [b,l,n] of KNOWN)
    if(Math.abs(bore-b)/b<0.09 && Math.abs(len-l)/l<0.13) return n;
  return bore.toFixed(1)+'×'+Math.round(len)+(shot?' shot':' wildcat');
}
```

* Tolerance is **9 % on bore, 13 % on case length**, both relative to the *table* value,
  both strict `<`.
* **First** match in table order wins — `.38 Special` (9 × 29) is tested before
  `.357 Magnum` (9.1 × 33), so a 9.05 × 31 names as `.38 Special`.
* Called with the **unrounded** `bore` and `caseLen`. `stats.bore` / `stats.caseLen` are
  rounded copies; never feed those back in.
* The separator is U+00D7 `×`, not the letter x.

The `RPMB` table on line 276 (`{rifle:1,sniper:1,smg:1,...}`, all 1.0) is **dead code** —
never referenced. Do not port it.

### 4.6 Capacity, feed and fire mode

```js
const roundVol=Math.pow(caseHead/10,2)*(caseLen/10)*1.05;              // cm^3 per round
const magRaw  =cm3(hull(gri))*(0.50+0.50*cl(magH/1.6,0,1.7));
const magUse  =20.5*Math.pow(magRaw,0.40);
let cap=Math.max(1,Math.round(magUse/roundVol));
if(rec.c==='revolver')cap=cl(cap,5,9);
if(explosive)         cap=cl(cap,1,4);
cap=cl(cap,1,200);

const boltKg=cm3(rec.cv)*0.0009;
const cyc   =impulse/Math.max(boltKg*18,0.05);
const feed=(rec.c==='revolver')?'cylinder'
         :(rec.c==='shotgun'&&magH<1.15)?'tube'
         :(explosive)?'breech'
         :(magH>0.85)?'box':'internal';
```

`cyc` is "how badly the impulse outruns the bolt": low `cyc` means light recoil relative
to a heavy bolt, so the action cycles fast and full-auto is possible.

Fire-mode ladder — top to bottom, first hit wins:

```js
let mode;
if(cap<=1)                  mode='Single-shot';
else if(rec.c==='revolver') mode='Double-action';
else if(explosive)          mode='Break-action';
else if(cyc<0.55)           mode=(rec.c==='shotgun')?'Semi-auto':(rec.c==='pistol')?'Machine pistol':'Full-auto';
else if(cyc<0.85)           mode=(rec.c==='shotgun')?'Pump-action':'3-round burst';
else if(cyc<1.35)           mode=(rec.c==='shotgun')?'Pump-action':'Semi-auto';
else                        mode=(rec.c==='shotgun')?'Pump-action':(rec.c==='sniper'||rec.c==='rifle')?'Bolt-action':'Break-action';
if(rec.c==='sniper'&&(mode==='Full-auto'||mode==='3-round burst')&&cyc>0.40)mode='Semi-auto';
const auto=(mode==='Full-auto'||mode==='Machine pistol');
```

```js
const cyclic=Math.round(cl(1500/Math.sqrt(boltKg*impulse),320,1850)/10)*10;   // rpm, snapped to 10
let rpm = (auto||mode==='3-round burst')?cyclic
  : mode==='Semi-auto'    ?Math.round(cl(320-impulse*7,90,320))
  : mode==='Double-action'?110
  : mode==='Pump-action'  ?72
  : mode==='Bolt-action'  ?42
  : mode==='Break-action' ?24
  :                        16;      // Single-shot
let reload = feed==='box'     ?1.05+cap*0.021+magH*0.42
  : feed==='cylinder'?2.3+cap*0.26
  : feed==='tube'    ?0.42*cap+0.70
  : feed==='breech'  ?2.9+bore*0.048
  :                   0.95+cap*0.30;      // internal — stripper clips, one at a time
```

**PORT — order hazard:** `reload` reads the **pre-archetype** `cap`. `cap` is overwritten
by `TUNE.cap` in §4.9 *after* this line, and `reload` is then only multiplied. A tube-fed
36-round gun gets its reload computed from 36 even if the archetype later cuts capacity.

```js
const sidearm = oaLen<=720 && mass<=3.6;                // holster fit
const simVel  = Math.round(vel*0.5);                    // projectile-sim speed, m/s
const hsRange = Math.round(cl((vel-180)*0.10,6,320));   // instant-ray window, metres
```

### 4.7 Provisional spread cone

```js
let rawSpread = 19/(0.55+0.65*Math.log2(1+barLen/170));
if(sig) rawSpread*=0.52-0.05*Math.min(sigLen,3);
if(stoLen>80) rawSpread*=0.74;
rawSpread*=1+0.85*err;
rawSpread*=1+0.9*impulse/Math.max(mass,0.4)/10;
if(shot) rawSpread*=15*(1-cl(barLen/700,0,0.72));
```

Units are **MOA** (arcminutes) throughout. `Math.log2(x)` → `log(x)/0.6931471805599453`.
`0.52-0.05*min(sigLen,3)` bottoms out at 0.37 and can never go negative.

### 4.8 Archetype classification

```js
const rel0=cl(100-(new Set(used.map(u=>u.p.c)).size-1)*6-err*12,10,99);
const optic0=!!sig;
let arch, blastR=0;
if(explosive)                                             arch='Launcher';
else if(pellets>1&&auto)                                  arch='Auto shotgun';
else if(pellets>1&&barLen>560)                            arch='Slug gun';
else if(pellets>1)                                        arch='Shotgun';
else if(auto&&cap>=36&&mass>4.7&&barLen>=330)             arch='Machine gun';
else if(auto&&barLen<320&&(caseLen<42||mass<4.6))         arch='Submachine gun';
else if(auto&&caseLen>60&&barLen>=380)                    arch='Auto battle rifle';
else if((auto||mode==='3-round burst')&&barLen>=300)      arch='Assault rifle';
else if(auto||mode==='3-round burst')                     arch='Chopped auto';
else if(rpm<=145&&rawSpread<11&&caseLen>50&&barLen>=430)  arch='Sniper';
else if(rpm<=145&&rawSpread<14&&barLen>=320)              arch='Marksman carbine';
else if(mode==='Semi-auto'&&caseLen>52&&barLen>=340)      arch='Battle rifle';
else if(cap<=8&&caseHead>13&&barLen>=260)                 arch='Hand cannon';
else if(barLen<250)                                       arch='Snubnose';
else if(sidearm)                                          arch='Sidearm';
else if(caseLen<40)                                       arch='Carbine';
else                                                      arch='Hybrid';
```

`cap` and `rpm` here are still pre-TUNE values.

The 17 `TUNE` rows:

| arch | dmg | rpm | cap | spr | rel |
|---|---|---|---|---|---|
| Launcher | 1.00 | 0.80 | 0.75 | 1.10 | 1.35 |
| Machine gun | 0.95 | 0.80 | 1.30 | 1.20 | 1.35 |
| Submachine gun | 0.82 | 0.86 | 1.15 | 0.92 | 0.85 |
| Assault rifle | 1.05 | 0.68 | 1.05 | 0.92 | 1.00 |
| Auto battle rifle | 1.18 | 0.62 | 0.85 | 1.10 | 1.05 |
| Battle rifle | 1.14 | 1.00 | 0.90 | 0.80 | 1.00 |
| Sniper | 1.34 | 0.85 | 0.70 | 0.50 | 1.10 |
| Marksman carbine | 1.14 | 1.00 | 0.85 | 0.62 | 1.00 |
| Shotgun | 1.12 | 1.00 | 0.85 | 1.15 | 1.05 |
| Auto shotgun | 0.92 | 1.05 | 1.10 | 1.25 | 1.10 |
| Slug gun | 1.30 | 0.90 | 0.75 | 0.55 | 1.05 |
| Hand cannon | 1.22 | 0.90 | 0.85 | 1.05 | 1.00 |
| Sidearm | 1.00 | 0.85 | 0.90 | 1.00 | 0.85 |
| Carbine | 0.95 | 0.80 | 1.05 | 0.95 | 0.95 |
| Chopped auto | 0.92 | 0.92 | 1.05 | 1.30 | 0.85 |
| Snubnose | 0.90 | 1.00 | 0.90 | 1.45 | 0.85 |
| Hybrid | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

### 4.9 Damage, capacity, rpm, reload finalisation

```js
let perProj = shot?1.35*0.5*Math.pow(energy/pellets,0.66):0.5*Math.pow(energy,0.66);
let dmg = perProj*pellets*TUNE.dmg;
if(explosive){
  blastR = cl(1.4+bore*0.098, 3.0, 12.0);                  // metres
  dmg    = cl(120*Math.pow(bore/40,2.15), 90, 900);
  cap    = cl(Math.round(cap*0.5),1,8);
}else{
  cap = Math.max(1,Math.round(cap*TUNE.cap));
}
rpm    = Math.max(8,Math.round(rpm*TUNE.rpm/2)*2);          // forced EVEN
reload = +cl(reload*TUNE.rel
    *(1+Math.max(0,mass-4)*0.055+Math.max(0,oaLen-900)/2400)
    *(1+(100-rel0)/100*0.40),0.75,14).toFixed(1);

const sd  = projG/(bore*bore);                              // sectional-density proxy
const rangeE = explosive? cl(70+bore*4.2,90,620)
                        : 1400*sd*Math.log(Math.max(energy/80,1.02));
```

`dmg` for a shot payload is the **whole payload**: `perProj` is one pellet (with a 1.35
bonus for the shot column) and is multiplied back by `pellets`. At fire time each pellet
carries `st.dmg / st.pellets`.

`Math.round(rpm*TUNE.rpm/2)*2` forces an even rpm; `Math.max(8, ...)` is the floor.

### 4.10 Handling, lethality, crit

```js
const burstDPS=dmg*rpm/60;
const cycleT  =cap/(rpm/60);
const sustDPS =dmg*cap/(cycleT+reload);
const kinds   =new Set(used.map(u=>u.p.c)).size;        // distinct donor CLASSES
const kick    =cl(26*impulse/Math.max(mass,0.5)*(stoLen>80?0.72:1),3,99);
const hand    =cl(132-0.062*oaLen-5.0*mass,1,99);
const noCycle =(mode==='Break-action'||mode==='Single-shot'||mode==='Bolt-action'||mode==='Pump-action');
const crit0   =explosive?1:cl(1.7+vel/1350-(shot?0.55:0)+sd*1.6,1.35,3.4);
const lethal  =cl(38*Math.log10(1+sustDPS),1,99);
const burstR  =cl(30*Math.log10(1+burstDPS),1,99);
const punch   =cl(34*Math.log10(1+dmg*crit0),1,99);
```

`sustDPS` uses the post-TUNE `cap` and `rpm` and the finalised `reload`.

### 4.11 The cone, finalised — `spread` is rewritten four times

```js
const donors=new Set(used.map(u=>u.p.g)).size;          // distinct donor GROUPS
const fitQ=cl(1-(donors-1)/4*0.80-err*0.55,0.05,1);
const LOOSE={'Sniper':0.15,'Marksman carbine':0.22,'Battle rifle':0.40,
  'Assault rifle':0.44,'Auto battle rifle':0.46,'Carbine':0.46,'Machine gun':0.48,
  'Hand cannon':0.50,'Launcher':0.52,'Slug gun':0.55,'Sidearm':0.55,'Hybrid':0.55,
  'Submachine gun':0.58,'Shotgun':0.58,'Chopped auto':0.60,'Snubnose':0.60,
  'Auto shotgun':0.62};
let spread = rawSpread*TUNE.spr*(1+1.9*(LOOSE[arch]||0.5)*Math.pow(1-fitQ,1.30));
if(optic0)spread*=0.86;                                 // real glass earns you something
const FLOOR={'Auto shotgun':120,'Shotgun':90,'Slug gun':22,'Snubnose':20,
  'Chopped auto':16,'Launcher':14,'Submachine gun':11,'Sidearm':9,'Hybrid':9,
  'Hand cannon':8,'Machine gun':7,'Auto battle rifle':7,'Carbine':6,
  'Assault rifle':6,'Battle rifle':4.5,'Marksman carbine':3.0,'Sniper':1.8};
spread=Math.max(spread,(FLOOR[arch]||8)*(0.85+0.45*(1-fitQ)));
if(explosive)spread=Math.max(spread,7);
const grade=cl((0.28*lethal+0.20*punch+0.16*cl(30*Math.log10(1+rangeE),1,99)
               +0.10*(100-kick)+0.08*hand+0.18*rel0-40)/34,0,1);
spread=cl(spread*(2.30-1.40*grade),1.0,1600);
```

`fitQ` is "how well the donors index on each other": 1.0 for one donor and a perfect fit,
floored at 0.05. `grade` is a 0..1 quality judgement made *without reference to the group*,
scaling the final cone between ×2.30 (worst) and ×0.90 (best) — a tight cone is earned,
not rolled.

### 4.12 Everything that falls out of the cone

```js
const range=cl(Math.min(3400/spread,rangeE),4,1800);          // metres
const precision=cl(105-40*Math.log10(1+spread),1,99);
const reach=cl(33*Math.log10(1+range),1,99);
const rel=cl(98-(kinds-1)*6-err*12-Math.max(0,mass-6)*3.5
            -(noCycle?0:Math.max(0,cyc-1.1)*14)-(spread>200?8:0),1,99);
const score=0.14*lethal+0.09*burstR+0.14*punch+0.13*reach+0.24*precision
           +0.05*(100-kick)+0.07*hand+0.14*rel;
const crit=+crit0.toFixed(2);
```

Score weights sum to 1.00. Over 4000 random builds: min 26.04, p10 48.98, median 65.26,
p90 73.42, max 79.36.

### 4.13 Optics zoom

```js
const optic=optic0;
let zoom=optic?cl(1.25+sigLen*0.40,1.25,3.1):1.15;
if(arch==='Sniper')           zoom=cl(zoom*2.2,3.4,9.0);
if(arch==='Marksman carbine') zoom=cl(zoom*1.6,2.6,6.5);
```

`sigLen` is in model units. Iron sights are 1.15× — a slight lean-in, not a scope.

### 4.14 Quirks — derived, never rolled

```js
const q=[];
if(auto&&cyc<0.20)           q.push('runaway');
if(spread>150)               q.push('blunderbuss');
if(explosive)                q.push('explosive');
if(!explosive&&hsRange>=110) q.push('flat-shooting');
if(vel>1150)                 q.push('overbore');
if(dmg>190)                  q.push('hand cannon');
if(rel<32)                   q.push('jam-prone');
if(cap>=60)                  q.push('drum-fed');
if(range>700)                q.push('reach-out');
if(mass>8.5)                 q.push('crew-served');
if(sidearm)                  q.push('sidearm');
const runaway=q.includes('runaway');
```

Push order is display order. `runaway` is the only quirk with mechanical consequences at
fire time (§12.4); it occurs in roughly 0.2 % of random builds (8 / 4000 measured).

### 4.15 Per-weapon deterministic config hash

```js
const cfg=(((rec.i+1)*73856093 ^ (bar.p.i+1)*19349663 ^ (sto.p.i+1)*83492791
          ^ (gri.p.i+1)*2654435761 ^ (sig?(sig.p.i+1)*40503:7919))>>>0)||1;
```

Everything seed-derived below this line keys off `cfg`, not the roll seed, so **the same
five part indices always produce the same name, recoil pattern and tint**. The roll seed
only decides which parts get picked.

**PORT:** JS `^` runs each operand through ToInt32 (mod 2^32). The largest product is
`95*2654435761 = 252,171,397,295 < 2^53`, so the multiplications are exact doubles.
XOR commutes with masking, so GDScript can XOR the exact 64-bit products and mask once:

```gdscript
var cfg: int = ((rec_i + 1) * 73856093) ^ ((bar_i + 1) * 19349663) \
	^ ((sto_i + 1) * 83492791) ^ ((gri_i + 1) * 2654435761) \
	^ (((sig_i + 1) * 40503) if has_sight else 7919)
cfg = cfg & 0xFFFFFFFF
if cfg == 0:
	cfg = 1
```

### 4.16 Recoil pattern

```js
const pr=rng(cfg^0x1f2e3d4c);
const recV=cl(impulse/Math.max(mass,0.6)*0.0032,0.0016,0.052);           // rad/shot, vertical
const recH=recV*cl(0.28+err*0.55+(stoLen>80?0:0.42)+(explosive?0.3:0),0.18,1.35);
const recDrift=+((pr()*2-1)).toFixed(3);      // -1..1, fixed bias direction per weapon
const recPeriod=Math.round(4+pr()*9);         // 4..13 shots per horizontal cycle
const recRand=cl((100-rel)/100*1.15+0.16,0.16,1.3);
const recSettle=cl(0.10+0.24*(mass/6),0.08,0.42);
```

`pr()` is consumed **twice**: drift first, then period. `recV`/`recH`/`recRand`/`recSettle`
use no RNG. `cfg^0x1f2e3d4c` must be masked to 32 bits before it reaches `rng`.

### 4.17 The returned record

```js
const r=rng(cfg^0x5bf03635);
return{seed,cfg,sel,used,rec,name:nameFor(r,[...new Set(used.map(u=>u.p.g))]),
  stats:{...},score,tier:tierOf(score,rel)};
```

Published `stats` fields and their exact forms:

| field | expression |
|---|---|
| `cal` | `cartridgeName(bore,caseLen,shot)` |
| `bore` | `+bore.toFixed(1)` |
| `caseLen` | `Math.round(caseLen)` |
| `mode`,`feed`,`arch` | strings |
| `rpm`,`cyclic`,`cap`,`pellets` | ints |
| `reload` | `+reload.toFixed(1)` (already fixed once) |
| `auto`,`runaway`,`optic`,`explosive`,`sidearm`,`scoped` | bool |
| `vel`,`energy`,`range` | `Math.round(...)` |
| `spread` | `+spread.toFixed(spread<10?1:0)` — MOA |
| `spreadTxt` | `spread<60 ? fixed+"'" : (spread/60).toFixed(1)+'°'` |
| `spreadRad` | `spread*0.000290888` — **uses the unrounded `spread`** |
| `dmg` | `Math.round(dmg)` |
| `burst`,`sust` | `Math.round(burstDPS)`, `Math.round(sustDPS)` |
| `precision`,`reach`,`kick`,`hand`,`rel` | `Math.round(...)` |
| `weight` | `mass.toFixed(1)` — **string**, display only |
| `mass`,`zoom`,`impulse` | raw floats |
| `crit` | `+crit0.toFixed(2)` |
| `blastR` | `+blastR.toFixed(1)` |
| `simVel` | `Math.round(vel*0.5)` |
| `hsRange` | `explosive?0:hsRange` |
| `zoomLevels` | `[]`, filled by `fitOptics` |
| `recV`,`recH`,`recDrift`,`recPeriod`,`recRand`,`recSettle` | raw |
| `barrel` | `Math.round(barLen)` mm |
| `oal` | `Math.round(oaLen)` mm |
| `quirks` | `string[]` |

`1 MOA = 0.000290888 rad` — use this exact literal, not `PI/(180*60)`.

---

## 5. `fitOptics()` — magnification ladder and scope eligibility

```js
const TIER_RANK={'Hazard':0,'Scrap':0,'Cobbled':1,'Field-Grade':1,'Gunsmithed':2,
                 'Warlord-Grade':3,'Relic':4};
function fitOptics(w){
  const s=w.stats, rank=TIER_RANK[w.tier.n]||0;
  let n=1;
  if(s.optic&&s.zoom>=2.4)n++;
  if((s.arch==='Sniper'||s.arch==='Marksman carbine')&&s.optic)n++;
  if(rank>=3&&s.optic)n++;
  n=cl(n,1,4);
  const top=cl(s.zoom*(1+0.55*(n-1))*(1+0.10*rank),s.zoom,14);
  const lv=[];
  for(let i=0;i<n;i++)lv.push(+(s.zoom+(top-s.zoom)*(n===1?0:i/(n-1))).toFixed(1));
  s.zoomLevels=lv;
  s.scoped=!!s.optic&&lv[lv.length-1]>=4.2&&
    (s.arch==='Sniper'||s.arch==='Marksman carbine'||
     (rank>=2&&(s.arch==='Battle rifle'||s.arch==='Auto battle rifle')));
  return w;
}
```

`fitOptics` **mutates `stats` in place** and returns the same weapon. `build()` is
`fitOptics(assemble(randomSel(r),seed))`. `rerollSlot` in the bench calls plain
`assemble()` **without** `fitOptics`, so a bench-rerolled gun keeps `zoomLevels = []` —
`update()` and `cycleZoom()` both fall back to `[st.zoom]` for that case. Reproduce the
fallback (`lv = zoomLevels if not empty else [zoom]`) or bench rerolls crash.

`s.scoped` gates the full circular scope render (§14.4). An iron-sighted or low-power gun
gets a 1.14× "lean-in" FOV instead.

Worked example (Pumper receiver 19 + parts 15/16/17/18, tier Warlord-Grade → rank 3):
`zoom = 2.70212807546259`, `n = 3` (zoom ≥ 2.4, rank ≥ 3), `top = 2.702*2.1*1.3 = 7.376`,
`zoomLevels = [2.7, 5, 7.4]`, `scoped = true` (Battle rifle at rank ≥ 2, top ≥ 4.2).

For iron sights, `zoom = 1.15` and `zoomLevels = [1.1]` — see the `toFixed` note in §1.3.

---

## 6. Tiers

```js
const TIERS=[{n:'Hazard',c:'#a03636',min:-1},{n:'Scrap',c:'#6f6a63',min:0},
 {n:'Cobbled',c:'#8a9a6b',min:62.4},{n:'Field-Grade',c:'#57a0bb',min:69.9},
 {n:'Gunsmithed',c:'#9a79c8',min:73.1},{n:'Warlord-Grade',c:'#d8822f',min:75.1},
 {n:'Relic',c:'#e6c14f',min:77.2}];
function tierOf(score,rel){
  let i=1;for(let k=0;k<TIERS.length;k++)if(TIERS[k].min>=0&&score>=TIERS[k].min)i=k;
  if(rel<14) return score<TIERS[2].min?TIERS[0]:TIERS[Math.min(i,3)];
  if(rel<30) return TIERS[Math.min(i,4)];
  return TIERS[i];
}
```

| # | tier | colour | min score |
|---|---|---|---|
| 0 | Hazard | `#a03636` | −1 (unreachable by score; only via the `rel<14` clamp) |
| 1 | Scrap | `#6f6a63` | 0 |
| 2 | Cobbled | `#8a9a6b` | 62.4 |
| 3 | Field-Grade | `#57a0bb` | 69.9 |
| 4 | Gunsmithed | `#9a79c8` | 73.1 |
| 5 | Warlord-Grade | `#d8822f` | 75.1 |
| 6 | Relic | `#e6c14f` | 77.2 |

The `min:-1` sentinel is *skipped* by the loop (`min>=0` guard) and `i` starts at 1, so
Hazard is only reachable through the reliability clamp.

**The reliability clamp**, verbatim: a gun that eats itself is never a prize, but one that
merely jams a lot is not scrap either — it just cannot climb past the middle of the ladder.

* `rel < 14` **and** `score < 62.4` → **Hazard**.
* `rel < 14` and `score ≥ 62.4` → capped at **Field-Grade** (index 3).
* `rel < 30` → capped at **Gunsmithed** (index 4).
* otherwise → the score band.

Tier distribution over 4000 random builds: Scrap 1350, Cobbled 1257, Field-Grade 682,
Gunsmithed 296, Hazard 254, Warlord-Grade 141, Relic 20.

---

## 7. Rolling: `randomSel`, `build`, `CLASS_MIX`, `wantedClass`, `rollTyped`, `rollWeapon`

```js
function randomSel(r){
  return{receiver:pick(r,BY.receiver),barrel:pick(r,BY.barrel),stock:pick(r,BY.stock),
         grip:pick(r,BY.grip),sight:r()<0.62?pick(r,BY.sight):null};
}
function build(seed){const r=rng(seed);return fitOptics(assemble(randomSel(r),seed));}
```

**RNG call order is a hard contract:** receiver, barrel, stock, grip, sight-gate, and only
then (if the gate passed) the sight index. Six calls maximum, five minimum. 62 % of guns
have a sight.

Verification with `rng(1)` = `[0.00006295, 0.01573980, 0.42266560, 0.81550575, 0.65515977]`:
receiver `BY.receiver[floor(0.00006295*22)=0]` = part 3; barrel `[0]` = part 0;
stock `[floor(0.4226656*22)=9]` = part 38; grip `[floor(0.8155057*20)=16]` = part 80;
sight gate `0.65515977 < 0.62` → false → **null**. Matches the golden build in §10.

```js
const CLASS_MIX=[['Assault rifle',15],['Shotgun',10],['Submachine gun',8],['Sniper',7],
 ['Machine gun',7],['Battle rifle',7],['Marksman carbine',6],['Launcher',6],
 ['Sidearm',6],['Carbine',5],['Hand cannon',5],['Slug gun',5],['Chopped auto',5],
 ['Auto battle rifle',4],['Snubnose',3],['Auto shotgun',1]];
const MIX_TOTAL=CLASS_MIX.reduce((a,c)=>a+c[1],0);        // 100
function wantedClass(u){
  let x=u*MIX_TOTAL;
  for(const [k,wt] of CLASS_MIX){if(x<wt)return k;x-=wt;}
  return 'Assault rifle';
}
```

`MIX_TOTAL = 100`, so the weights are literally percentages. Note **`Hybrid` is not in the
mix** — it is only ever produced as a fallback when `rollTyped` fails to hit the target.

```js
function rollTyped(rand,needSidearm,want){
  let fallback=null;
  for(let i=0;i<420;i++){
    const w=build((rand()*4294967295)>>>0);
    if(needSidearm&&!w.stats.sidearm)continue;
    if(!fallback)fallback=w;
    if(w.stats.arch===want)return w;
  }
  return fallback||build((rand()*4294967295)>>>0);
}
function rollTypedSeeded(baseSeed,want,needSidearm){
  return rollTyped(rng(baseSeed>>>0||1),needSidearm,want);
}
function rollWeapon(needSidearm){
  return rollTyped(Math.random,needSidearm,wantedClass(Math.random()));
}
```

* **420 attempts.** Each attempt consumes one `rand()` and builds a whole weapon (which
  itself consumes five or six `rng()` calls from a *fresh* generator seeded by
  `(rand()*4294967295)>>>0`). This is ~420 full assemblies worst case; in GDScript that is
  a few milliseconds and is fine, but do not call it per-frame.
* `needSidearm` filters *before* the fallback is recorded, so a sidearm request never
  returns a non-sidearm.
* If the loop exhausts, the **first acceptable** weapon is returned regardless of class.
* `(rand()*4294967295)>>>0` — floor via ToUint32, not `Math.round`.

Unweighted archetype distribution (raw `build()`, 4000 samples), for reference when
balancing: Shotgun 630, Chopped auto 558, Submachine gun 434, Snubnose 430, Assault rifle
391, Slug gun 308, Carbine 207, Sidearm 205, Launcher 205, Hybrid 205, Battle rifle 127,
Marksman carbine 92, Machine gun 71, Auto battle rifle 53, Hand cannon 50, Sniper 34.
Sniper is 0.85 % raw and 7 % after `CLASS_MIX` — hence the 420-attempt budget.

Other measured rates: explosive 5.1 %, shot payload 23.5 %, sidearm 27.6 %, auto 23.6 %,
runaway 0.2 %.

Feed distribution: box 57 %, internal 25 %, cylinder 9 %, breech 4.6 %, tube 4.5 %.
Mode distribution: Semi-auto 33 %, Full-auto 19 %, 3-round burst 15 %, Break-action 13 %,
Double-action 9 %, Machine pistol 4.8 %, Pump-action 3.4 %, Bolt-action 3 %,
Single-shot 0.5 %.

---

## 8. Naming

```js
const PREF=['Rusted','Scabbed','Welded','Zip-Tied','Cracked','Bootleg','Coffin','Tetanus','Foundry',
 'Cinder','Bastard','Orphan','Crooked','Reclaimed','Slagged','Hexbolt','Secondhand','Half-Blind',
 'Overbored','Undersprung','Widowed','Grave-Dug','Pig-Iron','Twice-Stolen','Left-Handed'];
const NOUN=['Widow','Preacher','Kettle','Sermon','Cough','Whistle','Kicker','Argument','Divorce',
 'Apology','Grudge','Tantrum','Handshake','Verdict','Nailfile','Debt','Rumour','Migraine','Toothache',
 'Loudmouth','Last Word','Bad News','Fair Warning','Second Opinion','Change of Heart'];
const ROM=['I','II','III','IV','V','VI','VII','VIII','IX','X','XI','XII'];
function nameFor(r,d){
  const a=d[0],b=d[1]||d[0];
  switch(Math.floor(r()*5)){
    case 0:return pick(r,PREF)+' '+a;
    case 1:return a+'-'+b;
    case 2:return 'The '+pick(r,NOUN);
    case 3:return a+' Mk.'+pick(r,ROM);
    default:return pick(r,PREF)+' '+pick(r,NOUN);
  }
}
```

PREF has 25 entries, NOUN 25, ROM 12. `d` is `[...new Set(used.map(u=>u.p.g))]` — the
distinct donor groups **in `used` order** (receiver first). `a` = receiver's group,
`b` = the first different group, falling back to `a`.

RNG consumption per branch: case 0 → 2 calls (selector, PREF); case 1 → **1 call**;
case 2 → 2 (selector, NOUN); case 3 → 2 (selector, ROM); case 4 → 3 (selector, PREF, NOUN).
A GDScript `match` must consume exactly the same number of values.

**PORT:** JS `Set` preserves insertion order and de-duplicates by string identity. Use an
`Array[String]` with an explicit `has()` check, not a Godot `Dictionary` iteration order
assumption.

---

## 9. Building the mesh: `weaponNode()` and materials

```js
function weaponNode(w){
  const inner=new THREE.Group();
  const tint=0.86+0.28*rng((w.cfg||w.seed)^0x9e37)();
  for(const u of w.used){
    const p=u.p;
    const m=new THREE.Mesh(geom(p),gunMat(p.k==='grip'||p.k==='stock'?p.wd:p.met,p.k,tint));
    m.scale.set(u.k,u.k,u.k*u.kz);
    m.position.set(u.pos[0],u.pos[1],u.pos[2]);
    inner.add(m);
  }
  const box=new THREE.Box3().setFromObject(inner);
  ...
  return {inner,size,ctr,box};
}
```

Per-part transform in Godot:

```gdscript
mi.transform = Transform3D(
	Basis().scaled(Vector3(u.k, u.k, u.k * u.kz)),
	u.pos)
```

Grips and stocks use the **timber** colour `p.wd`; barrels, receivers and sights use
`p.met`. `tint` is one multiplier for the whole weapon, `0.86 + 0.28 * rng(cfg^0x9e37)()`
→ range `[0.86, 1.14)`. Mask `cfg^0x9e37` to 32 bits.

Material (`gunMat`, line 688):

```js
const metalish=(kind==='barrel'||kind==='receiver'||kind==='sight');
const type=metalish?0:(isPolymer(hex)?2:1);      // 0 steel, 1 timber, 2 polymer
const c=new THREE.Color(hex).convertSRGBToLinear().multiplyScalar(tint);
if(!metalish)c.lerp(new THREE.Color(0x2a2724).convertSRGBToLinear(),0.15);
metalness: metalish?0.72:0.05
roughness: metalish?0.50:0.82
envMapIntensity: metalish?0.72:0.45
flatShading: true
side: THREE.DoubleSide        // <-- the crutch; do NOT port
```

```js
function isPolymer(hex){
  const c=new THREE.Color(hex); const mx=max(r,g,b), mn=min(r,g,b);
  return (mx-mn)<0.06 && mx<0.30;      // near-neutral and dark
}
```

Shader seed: `seed=(parseInt(hex.slice(1),16)%997)/997 + kind.length*0.11`.

Materials are cached by `hex+kind+tint.toFixed(2)`. Per the project performance rules,
Godot should instead use **one `ShaderMaterial` per `type` (3 total)** and push
`albedo`, `uSeed`, `uType` through `set_instance_shader_parameter` /
`MultiMesh` custom data. Never one material per gun.

The procedural detail shader (lines 622–682) is ART's to port; the numbers are:

* `NOISE`: hash `h31` with `p=fract(p*0.1031+uSeed*0.137)`; `fbm3` = 4 octaves,
  `a=0.5`, lacunarity `2.07`, gain `0.5`; `fbm2` = 3 octaves, `a=0.55`, lacunarity `2.11`.
* Steel (`uType<0.5`): rust mask `smoothstep(0.54,0.84,fbm3(P*1.7+7.3))` modulated by
  `smoothstep(0.05,0.95,0.62-N.y*0.40)` (rust collects on downward faces); streaks
  `smoothstep(0.74,0.96,fbm3(P*vec3(1.2,9,9)+2.0))`; pitting
  `smoothstep(0.80,1.00,fbm3(P*6.5))`. Albedo `*= 0.86+0.28*g`, then
  `mix(albedo, vec3(0.150,0.056,0.022)*(0.62+0.95*g), rust*0.62)`;
  roughness `+rust*0.40+pit*0.10-scr*0.10+(g-0.5)*0.12` clamped `[0.10,1.0]`;
  metalness `*= 1-rust*0.80`.
* Timber (`uType<1.5`): ring `fbm3(P*vec3(0.9,4,4))`,
  `grain=pow(sin((P.x*2+ring*2.6)*7)*0.5+0.5,1.6)`, blotch `fbm3(P*2.2+11)`;
  albedo `*= mix(0.70,1.16, mix(0.5,grain,fade)*0.66+0.34*blotch)`;
  wear `smoothstep(0.62,0.95,fbm3(P*3.2+21))` darkens by `vec3(0.76,0.72,0.68)` at 0.45;
  roughness `0.86-grain*0.12*fade+wear*0.06` clamped `[0.34,1.0]`.
* Polymer (else): `sp=fbm3(P*7)`, scuff `smoothstep(0.70,0.96,fbm3(P*vec3(1.6,7,7)+5))`;
  albedo `*= 0.92+0.16*sp`, `+= scuff*0.035`;
  roughness `0.84+(sp-0.5)*0.14-scuff*0.10` clamped `[0.34,1.0]`.
* `fade = 1.0-smoothstep(0.012,0.075, length(fwidth(P)))` — detail dissolves with
  screen-space derivative, i.e. an automatic distance LOD. Keep it; it is why the guns
  do not shimmer at range.
* `BUMP` derivative-normal block: `bsc = 3.6` for steel / `3.0` otherwise,
  `bamt = 0.010` steel / `0.008` otherwise, faded by
  `1-smoothstep(0.05,0.30, length(fwidth(vOP))*bsc)`, gradient clamped to `6.0/(|grad|)`.

**All of this is per-vertex object-space `P` (`vOP=position`)**, so it must be evaluated in
object space in Godot too (`VERTEX` in `vertex()` passed to `fragment()` via a varying),
not world space, or the pattern swims when the viewmodel moves.

---

## 10. Golden test vectors

Every value below came from executing the reference. A port that matches these is correct.

### 10.1 `build(1)`

```
name        "Coffin Divorce"        (PREF[6] + " " + NOUN[8], nameFor case 4)
tier        Field-Grade             score 70.71991707780789
cfg         3710188260
parts       receiver 3, barrel 0, stock 38, grip 80, no sight
k           1, 1, 1.2225650579262968, 1.6
kz          1, 1, 1.9, 1.9
pos         (0,0,0) (2.16471,-0.10263,-0.00002) (-2.16471,-0.20048,0) (-0.8321588,-0.47055,0)

cal "11.1×62 wildcat"  bore 11.1  caseLen 62   mode Full-auto
rpm 292  cyclic 430  cap 34  feed box  reload 2.7  pellets 1  auto true
vel 618  energy 2198  range 153  spread 22  spreadRad 0.006473800524395552
dmg 84  burst 410  sust 296  precision 50  reach 72  kick 30  hand 54  rel 78
weight "5.9"  mass 5.900794746439747  optic false  zoom 1.15  zoomLevels [1.1]
crit 2.31  arch "Assault rifle"  explosive false  blastR 0
simVel 309  hsRange 44  scoped false
recV 0.005167141412738263   recH 0.003402152582684378
recDrift 0.539  recPeriod 5  recRand 0.4159491800620321  recSettle 0.33603178985758986
barrel 310 mm  oal 785 mm  impulse 9.528200281999123  sidearm false  quirks []
```

### 10.2 Other seeds (abbreviated)

| seed | parts (rec,bar,sto,gri,sig) | name | arch | tier | score | cal | rpm | cap | dmg | spread | rel | oal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2 | 3,0,12,39 | Coffin Kalash | Assault rifle | Cobbled | 69.1700 | 11.1×62 wildcat | 292 | 30 | 84 | 26 | 75 | 835 |
| 3 | 3,4,21,71,35 | The Fair Warning | Machine gun | Gunsmithed | 73.1598 | 11.1×62 wildcat | 328 | 49 | 85 | 9 | 78 | 1398 |
| 7 | 3,8,5,47,72 | Scabbed Kalash | Chopped auto | Cobbled | 62.8950 | 10.5×62 wildcat | 404 | 23 | 73 | 30 | 44 | 1012 |
| 42 | 3,59,87,88 | Cracked Nailfile | Chopped auto | Field-Grade | 72.0204 | 11.4×62 wildcat | 386 | 35 | 72 | 21 | 89 | 927 |
| 99 | 3,50,5,52,57 | Kalash-Sidearm | Chopped auto | Scrap | 61.1831 | 11.4×62 wildcat | 404 | 23 | 66 | 42 | 48 | 936 |
| 1234 | 7,37,87,22,48 | Reclaimed Woodsman | Chopped auto | Cobbled | 63.4235 | 6.6×102 wildcat | 322 | 15 | 153 | 44 | 43 | 1032 |
| 5000 | 27,69,87,17,72 | The Cough | Carbine | Cobbled | 68.6041 | 11.8×27 wildcat | 218 | 16 | 50 | 7.8 | 67 | 997 |
| 77777 | 58,20,79,26,31 | Coffin Migraine | Sidearm | Field-Grade | 71.4262 | .38 Special | 234 | 23 | 66 | 12 | 65 | 524 |

Seed 1234 is `quirks:['flat-shooting','overbore']` (`vel` clamped to 1500, `hsRange` 132).
Seed 77777 is the only sidearm in the set (`oal 524 ≤ 720`, `mass 1.9 ≤ 3.6`).

### 10.3 Hand-picked selections (all with `seed=1` passed to `assemble`)

**Serpent stock hazard** — `{rec 3, bar 0, sto 70, gri 80, no sight}`:
`k=[1,1,0.45,1.6]`, `kz=[1,1,0.961,1.9]`, tier **Hazard**, score 44.937,
`rel 1`, `spread 264` (`spreadTxt "4.4°"`), `precision 8`, `range 13`, `reload 3.4`,
`recRand 1.2985`, quirks `['blunderbuss','jam-prone']`.

**Explosive launcher** — `{rec 90, bar 86, sto 87, gri 88, sig 89}`:
`bore 27.9`, `explosive true`, `caseLen 80`, `mode Break-action`, `rpm 20`, `cap 2`,
`feed breech`, `reload 8.4`, `dmg 90` (clamped floor), `blastR 4.1`, `crit 1`,
`hsRange 0`, `simVel 163`, `range 113`, `spread 30`, `kick 99`, `energy 8467`,
`impulse 59.8286`, `zoom 2.444`, `zoomLevels [2.4,3.8]`, `scoped false`,
quirks `['explosive']`, tier Scrap, score 50.777.

**Shot payload** — `{rec 53, bar 50, sto 51, gri 52, no sight}`:
`bore 16.1`, `shot true`, `pellets 7`, `cal "16.1×38 shot"`, `arch Shotgun`,
`dmg 207` (payload total; 29.57 per pellet), `spread 1070` (`"17.8°"`), `precision 1`,
`range 4`, `crit 1.6`, `kick 76`, quirks `['blunderbuss','hand cannon']`.

**Matched Pumper** — `{rec 19, bar 15, sto 16, gri 17, sig 18}`:
`cal "7.92×57"` (KNOWN match), `bore 8.1`, `caseLen 63`, `arch Battle rifle`,
`mode Semi-auto`, `rpm 286`, `cyclic 830`, `cap 36`, `feed tube`, `reload 14` (clamped),
`spread 3.8` (`"3.8'"`), `precision 78`, `rel 93`, `zoom 2.70212807546259`,
`zoomLevels [2.7,5,7.4]`, `scoped true`, tier Warlord-Grade, score 76.870.

**Matched Boxgun** — `{rec 94, bar 91, sto 92, gri 93, no sight}`:
`cal "5.6×20 wildcat"`, `arch Snubnose`, `cyclic 1850` (clamped), `mode Semi-auto`,
`rpm 298`, `cap 22`, `mass 1.49297622829044`, `oal 243`, `rel 98`, `sidearm true`,
`recRand 0.183`, tier Field-Grade.

### 10.4 `weaponNode` / viewmodel numbers for `build(1)`

```
tint        0.9720909090712666
size        (8.726716277081904, 2.406926690403444, 0.5679858016967774)
centre      (1.2417109770596344, -0.8240216964800271, 0)
box.min     (-3.1216471614813175, -2.027485041681749, -0.2839929008483887)
box.max     ( 5.605069115600586,   0.37944164872169495, 0.2839929008483887)
vmScale     0.04188287878223747
muzZ        0.2547564303347623
adsPos      (0, -0.05272660206952149, -0.3786816044978566)
hipPos      (0.118, -0.08645697221301432, -0.40115356966523774)
slow        false
bench scale 0.315124258963483
```

---

## 11. Loadout and viewmodel

### 11.1 Runtime record

```js
function makeRuntime(w){
  return {w,st:w.stats,ammo:w.stats.cap,voice:Audio.voice(w.stats),
          jammed:false,reloading:0,reloadFor:0,burst:0,next:0,clearing:0,held:false,muzZ:0.3};
}
```

Two slots: `slots=[null,null]`, `active=0`. Slot 1 is the sidearm slot.

```js
function equip(w,slot){
  if(slot===1&&!w.stats.sidearm){feed('too big for a holster');Audio.ui(300);return false;}
  slots[slot]=makeRuntime(w);zoomIdx=0;
  if(Mode.now==='bench')active=slot;
  buildViewmodel();updateSlotHud();
  feed((slot?'sidearm':'primary')+': '+w.name);Audio.ui(slot?1100:1500);
  return true;
}
```

Extra runtime fields added later by other code: `shotN` (shots in the current string),
`shotClock`, `postBurst`, `vmScale`, `adsScale`, `adsPos`, `hipPos`, `slow`.

### 11.2 `buildViewmodel()` — the sight-line solve

```js
const VMBASE=new THREE.Vector3(0.165,-0.185,-0.38);
function buildViewmodel(){
  const {inner,size,box}=weaponNode(rt.w);
  const g=new THREE.Group();
  inner.position.set(0,0.30,0);                 // LIFT
  const s=0.043*cl(8.5/Math.max(size.x,1),0.40,1.10);
  g.scale.setScalar(s);
  g.rotation.set(0.03,Math.PI/2-0.055,0.02);
  g.add(inner);g.position.copy(VMBASE);
  rt.vmScale=s; rt.muzZ=box.max.x*s+0.02;

  const LIFT=0.30, AZ=1.5;
  rt.adsScale=AZ;
  const sa=s*AZ;
  const topY=(box.max.y+LIFT)*sa;
  const rear=-box.min.x*sa;
  const len=(box.max.x-box.min.x)*sa;
  const ctrZ=-(box.min.z+box.max.z)*0.5*sa;
  const dRear=cl(0.125+len*0.105,0.15,0.245);
  rt.adsPos=new THREE.Vector3(ctrZ,-cl(dRear*0.055,0.007,0.016)-topY,-dRear-rear);
  rt.hipPos=new THREE.Vector3(0.118+ctrZ/AZ,-0.058-topY/AZ,
     -cl(0.19+len/AZ*0.22,0.22,0.38)-rear/AZ);
  rt.slow=(60/rt.st.rpm)>0.24;
}
```

Reasoning, from the source: `inner` is lifted 0.30 model units inside `g`, so every extent
has to carry that offset too or the gun straddles the view axis and you stare down its
throat. The butt is then stood off far enough that its rear cross-section reads as a small
shape low in the sight picture, and the whole gun slides sideways so its own centre of
width lands on the view centre. Shouldering also brings the gun physically closer
(`AZ=1.5`), so the viewmodel grows into the pose rather than staying a thin stick you
happen to be looking along.

Note the gun model's **+X is the muzzle direction**; the viewmodel yaws by `π/2 - 0.055`
so +X maps onto camera −Z. In Godot this is `rotate_y(PI*0.5 - 0.055)` on a node whose
child holds the assembled parts, identical maths.

The gun is rendered by a **second camera into a second scene** (`vmScene` / `vmCam`,
FOV 56, near 0.01, far 40) drawn after the world with the depth buffer cleared, so it
never intersects geometry. In Godot: a `SubViewport` with its own `Camera3D` and
`World3D`, composited full-screen; or a second `Camera3D` on a dedicated cull layer with
`Node3D` geometry placed inside a small near-clip shell. **The SubViewport route matches
the reference exactly and is the one to take.**

---

## 12. Firing

### 12.1 Effective spread and cone sampling

```js
let moveMul=1;
function effSpread(rt){
  const tight=rt.st.optic?0.34:0.56;     // shouldering it steadies the gun
  const ads=1-adsT*(1-tight);
  return rt.st.spreadRad*ads*moveMul*(1+bloom);
}
function spreadDir(dir,rad){
  const a=Math.random()*6.2832, r=Math.sqrt(Math.random())*rad;
  const t=Math.abs(dir.y)<0.9?new THREE.Vector3(0,1,0):new THREE.Vector3(1,0,0);
  const u=new THREE.Vector3().crossVectors(dir,t).normalize();
  const v=new THREE.Vector3().crossVectors(dir,u).normalize();
  const tr=Math.tan(r);
  return dir.clone().addScaledVector(u,tr*Math.cos(a)).addScaledVector(v,tr*Math.sin(a)).normalize();
}
```

`effSpread` returns the **full cone angle in radians**. `spreadDir` is called with
`effSpread(rt)/2` — the half-angle. `sqrt(random())` gives a uniform areal distribution
inside the disc (no centre bias). `6.2832` is the literal used, not `TAU`.

```gdscript
func spread_dir(dir: Vector3, rad: float) -> Vector3:
	var a: float = randf() * 6.2832
	var r: float = sqrt(randf()) * rad
	var t: Vector3 = Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	var u: Vector3 = dir.cross(t).normalized()
	var v: Vector3 = dir.cross(u).normalized()
	var tr: float = tan(r)
	return (dir + u * (tr * cos(a)) + v * (tr * sin(a))).normalized()
```

Bloom and stance:

```js
const mv=cl(speed/6.5,0,1.4);
moveMul=1+1.9*mv*mv+(player.onGround?0:1.6);
bloom*=Math.pow(0.055,dt);  if(bloom<0.002)bloom=0;
```

so standing still is 1×, sprinting is up to `1+1.9*1.96 = 4.724×`, and airborne adds a
flat 1.6. `bloom` decays to 5.5 % per second.

### 12.2 Ray casting

```js
const ray=new THREE.Raycaster();ray.far=2000;
function castValid(o,d){
  ray.set(o,d);
  const hits=ray.intersectObjects(hitList,false);
  for(const h of hits){
    if(!h.object.visible)continue;
    let p=h.object,vis=true;
    while(p){if(!p.visible){vis=false;break;}p=p.parent;}
    if(!vis)continue;
    const t=h.object.userData.target;
    if(t&&!t.alive)continue;
    return h;
  }
  return null;
}
```

`castValidFar(from,dir,maxd)` is the same with `ray.far=maxd` and a restore to 2000.

Semantics: **first hit along the ray that is (a) visible up its whole parent chain and
(b) not a downed target**. There is **no penetration model anywhere in this file** —
a round stops at the first valid surface, always. Any "penetration" in the Godot build is
new design, not a port.

Godot equivalent: `PhysicsDirectSpaceState3D.intersect_ray` with
`RayQueryParameters3D.new()`, `collide_with_areas = false`, and a `collision_mask` that
excludes downed targets. Because Godot returns only the closest hit, the "skip downed
targets" rule must be implemented by **disabling the collision shape** when a target goes
down (`t.alive=false`) and re-enabling it on reset — do **not** re-cast in a loop.
Use `intersect_ray` with `exclude` only for the shooter's own body.

Cast range: 2000 m. Tracer end when nothing is hit: `origin + dir*1200`.

### 12.3 `fireOnce()`

```js
function fireOnce(){
  const rt=cur();if(!rt)return;
  const st=rt.st;
  if(rt.jammed){Audio.dry();return;}
  if(rt.ammo<=0){Audio.dry();return;}
  rt.ammo--;
  if(Math.random()<Math.pow(1-st.rel/100,1.8)*0.05){
    rt.jammed=true;Audio.jam();feed('JAM — hold R');updateAmmoHud();return;
  }
  cam.getWorldPosition(_o);cam.getWorldDirection(_d);
  const vp=vmNode?vmNode.position:VMBASE;
  _mz.set(vp.x,vp.y+0.03,vp.z-rt.muzZ);
  vmHolder.localToWorld(_mz);                        // muzzle in world space
  for(let i=0;i<st.pellets;i++){
    const d=spreadDir(_d,effSpread(rt)/2);
    const h=castValid(_o,d);
    let end=_o.clone().addScaledVector(d,1200);
    const perPellet=st.dmg/st.pellets;
    if(h&&h.distance<=st.hsRange){
      end=h.point.clone();
      resolveHit(h,perPellet,h.distance,st);          // inside the instant window
    }else{
      const d0=Math.max(st.hsRange,1.4);
      const start=_o.clone().addScaledVector(d,d0);
      end=start;
      spawnProj(start,d,st.simVel,st,perPellet,d0);
    }
    if(i===0||st.pellets<=5)tracer(_mz,end);
  }
  const k=st.kick/100;
  bloom=Math.min(bloom+(0.30+1.15*k)*(st.auto?1:0.72)*(1-0.45*adsT),3.4);
  shake=Math.min(shake+0.0016+0.0075*k,0.055);shakeT=0.16;
  const n=rt.shotN||0; rt.shotN=n+1; rt.shotClock=0;
  const settle=0.55+0.45*Math.exp(-n*st.recSettle);
  const phase=(n/st.recPeriod)*6.2832;
  const steady=1-0.55*adsT;
  const vKick=st.recV*settle*steady;
  const hKick=(Math.sin(phase)*0.75+st.recDrift*0.55)*st.recH*steady
              +(Math.random()-0.5)*st.recH*st.recRand*steady;
  player.pitch=cl(player.pitch+vKick*0.42,-1.45,1.45);   // permanent: pull it back down
  player.yaw-=hKick*0.42;
  recoilP+=vKick*0.58; recoilY+=hKick*0.58;              // transient, decays
  vmKick=Math.min(vmKick+0.018+0.05*k,0.20); vmKickR=Math.min(vmKickR+0.06+0.24*k,0.9);
  flashT=0.05; flash.intensity=cl(3+st.energy/700,3,20);
  flashSprite.visible=true;flashSprite.material.opacity=1;
  flashSprite.material.rotation=Math.random()*6.2832;
  const fs=cl(0.05+st.energy/9000,0.05,0.34)*(st.pellets>1?1.35:1);
  flashSprite.scale.set(fs,fs,fs);
  Audio.shot(st,rt.voice);
  updateAmmoHud();
}
```

Key behaviours:

* **The jam roll happens after the round is consumed.** `P(jam) = (1 - rel/100)^1.8 * 0.05`.
  At `rel=98` that is 3.6e-5; at `rel=50` it is 0.0144; at `rel=1` it is 0.0492.
* **Hybrid ballistics.** Inside `hsRange` the round is an instant ray. Beyond it, a real
  projectile is spawned *at the edge of the window* (`d0 = max(hsRange, 1.4)`) travelling
  at `simVel` with travel time and drop. The tracer draws to the spawn point in that case,
  which is why long shots look like the tracer stops short — that is correct.
* Tracers draw from the **muzzle** (viewmodel space, transformed to world) but the ray
  originates at the **camera**. Do not unify them; the visual offset is intentional.
* Only the first pellet gets a tracer unless the payload is 5 or fewer.
* **Recoil is split**: 42 % goes permanently into `player.pitch`/`player.yaw` (you must
  pull it back down), 58 % into `recoilP`/`recoilY` which decay at `pow(0.0007, dt)`
  (i.e. to 0.07 % per second — effectively a ~100 ms snap-back).
* `settle = 0.55+0.45*exp(-n*recSettle)` makes the first rounds climb hardest.
* `phase = (n/recPeriod)*6.2832` walks the muzzle sideways on a learnable per-weapon cycle.

### 12.4 `tickWeapon(dt, firing)` — trigger and action

```js
function tickWeapon(dt,firing){
  const rt=cur();if(!rt)return;
  if(rt.clearing>0){
    rt.clearing-=dt;
    if(rt.clearing<=0){rt.jammed=false;feed('cleared');Audio.ui(600);}
    return;
  }
  if(rt.reloading>0){
    rt.reloading-=dt;
    if(rt.reloading<=0){rt.ammo=rt.st.cap;updateAmmoHud();feed('reloaded');}
    return;
  }
  const st=rt.st, interval=60/st.rpm;
  rt.shotClock=(rt.shotClock||0)+dt;
  if(rt.shotClock>Math.max(0.42,interval*2.2))rt.shotN=0;   // pattern resets between strings
  if(rt.next>0)rt.next-=dt;
  if(rt.burst>0){
    if(rt.ammo<=0||rt.jammed){rt.burst=0;}
    else if(rt.next<=0){fireOnce();rt.burst--;rt.next=interval*(rt.burst?1:2.4);}
    return;
  }
  if(firing&&rt.ammo<=0&&!rt.jammed){
    if(rt.reloading<=0){Audio.dry();feed('empty — reloading');startReload();}
    return;
  }
  if(!firing||rt.next>0)return;
  if(st.auto){
    fireOnce();rt.next=interval;
    if(st.runaway&&rt.ammo>0){
      rt.burst=rt.ammo;bloom=Math.max(bloom,1.6);runFlash=1.0;
      feed('sear failed — it will not stop');
    }
  }else if(st.mode==='3-round burst'){
    fireOnce();rt.burst=2;rt.next=interval;rt.postBurst=true;
  }else{
    fireOnce();rt.next=interval;
  }
  rt.held=true;
}
```

* **Every action repeats while the trigger is held**; the action's own cycle rate is the
  only limiter, so a bolt gun still works itself one round at a time at 42 rpm. There is no
  semi-auto "release to fire again" gate. `rt.held` is set but never read as a gate.
* **3-round burst**: fires one immediately, queues 2 more, and the inter-burst gap is
  `interval*2.4`.
* **Runaway**: an auto with `cyc < 0.20` dumps the entire magazine as a queued burst the
  moment the trigger is pulled, and cannot be stopped.
* Firing an empty gun auto-starts the reload.
* `shotN` (the recoil-pattern counter) resets after `max(0.42, interval*2.2)` seconds of
  not firing.

### 12.5 Reload and jam clearing

```js
function startReload(){
  const rt=cur();if(!rt)return;
  if(rt.jammed){if(rt.clearing<=0)rt.clearing=1.2;return;}
  if(rt.reloading>0||rt.ammo>=rt.st.cap)return;
  rt.reloading=rt.reloadFor=rt.st.reload;
  Audio.reloadSeq(rt.st,rt.st.reload);
}
```

`R` does double duty: clears a jam (fixed **1.2 s**, cannot be re-triggered while running)
or starts a reload. Reload is **all-or-nothing** — the magazine is refilled to `cap` at
completion, not incrementally, even for tube and cylinder feeds. Reserve ammo is infinite.

---

## 13. Hit resolution, blast, and the projectile simulation

### 13.1 `resolveHit`

```js
function resolveHit(h,dmgBase,dist,st){
  if(st.explosive){
    const n=h.face?h.face.normal.clone().transformDirection(h.object.matrixWorld):new THREE.Vector3(0,1,0);
    blastAt(h.point.clone().addScaledVector(n,0.25),st.dmg,st.blastR);
    decal(h.point,n,0.55,false);
    return;
  }
  const fall=cl(1-Math.pow(dist/Math.max(st.range,8),1.7)*0.88,0.10,1);
  impact(h,dmgBase*fall,dist,st);
}
```

Damage falloff: full damage at 0 m, `1 - 0.88` = **12 % of damage at exactly `st.range`**,
floored at 10 %. Exponent 1.7 keeps it near-flat for the first half of the range.

### 13.2 `impact` — zones, targets and scoring

```js
function impact(h,dmg,dist,st){
  const t=h.object.userData.target;
  const zone=h.object.userData.zone;
  const crit=(zone==='head');
  if(crit)dmg*=st.crit;
  else if(zone==='core')dmg*=1+(st.crit-1)*0.45;
  const nrm = h.face ? worldNormal(h) : Vector3(0,1,0);
  ...
}
```

`zone==='core'` is never set anywhere in the range — it exists for the enemy port
(45 % of the crit bonus). Keep the branch.

Per target kind:

| kind | on hit | particles | audio | decal | score |
|---|---|---|---|---|---|
| `bottle` | `alive=false`, `node.visible=false`, `down=9` | `spawnP(pt,18,3.6,[0.5,0.9,0.62],0.9)` | `glass`, size 0.1 | — | `t.pts` (30), label `break` |
| `barrel` | `explode(t)` if `hp<=0` | `spawnP(pt, crit?14:6, crit?4.5:2.6, [1,0.7,0.35], 0.5)` | `metal`, 0.3 | `decal(pt,n,0.07,false)` | `round(dmg*0.2)` while alive |
| `paper` | never dies (`hp=1e9`) | — | `paper`, 0.2 | `decal(pt,n,0.05,false)` kept in `t.holes` | `t.pts + ring*2` |
| default (plate/popper/mover) | `hp -= dmg`; `t.v += cl(dmg*0.012,0.05,1.6)*(crit?1.5:1)` | `spawnP(pt, crit?(big?20:12):(big?11:5), crit?6.5:(big?5.5:3), crit?[1,0.92,0.7]:[1,0.82,0.45], crit?0.75:0.55)` where `big = dmg>60` | `steel`, `(t.rad||0.4)*(crit?0.45:1)` | `decal(pt,n,0.05+min(dmg,160)*0.0006,true)` — hot/additive | `round((dmg*0.35+t.pts*0.25)*(crit?1.6:1))` |

On a steel target reaching 0 hp: `alive=false`, `down = (kind==='popper')?6:5`,
`addScore(t.pts, pt, 'DOWN')`, and a second `steel` impact sound at `(t.rad||0.4)*2.4`.

Paper target special handling:

```js
const tag = cur() ? cur().w.name+'#'+cur().w.seed : '?';
if(t.owner!==tag){                       // new gun on the board: fresh paper
  t.owner=tag;t.group.length=0;
  t.holes.forEach(m=>m.visible=false);t.holes.length=0;
  grpEl.textContent='';
}
const lp=t.face.worldToLocal(h.point.clone());
t.group.push([lp.x,lp.y]);
if(t.group.length>60){t.group.shift(); const old=t.holes.shift(); if(old)old.visible=false;}
const ring=Math.max(0,10-Math.round(Math.hypot(lp.x,lp.y)/0.077));
if(ring>=10)headshots++;
addScore(t.pts+ring*2,h.point,ring>=10?'X RING':Math.round(dmg));
groupReadout(t);hitMark(ring>=8,ring>=10);
```

**Ring spacing is 0.077 m in face-local coordinates** (the face plane is 1.15 × 1.15 m,
local range ±0.575). Note the *drawn* texture rings are at `i*34` px of a 512 canvas
(≈0.0764 m apart at 1.15 m width) — close but not identical; scoring uses 0.077 only.
Rolling window of 60 holes.

```js
function groupReadout(t){
  if(t.group.length<3){grpEl.textContent='';return;}
  const g=t.group;let mx=0;
  for(let i=0;i<g.length;i++)for(let j=i+1;j<g.length;j++)
    mx=Math.max(mx,Math.hypot(g[i][0]-g[j][0],g[i][1]-g[j][1]));
  grpEl.textContent='group '+(mx*1000).toFixed(0)+' mm at 25 m · '+g.length+' shots · '+
    (t.owner?t.owner.split('#')[0]:'');
}
```

Extreme-spread (max pairwise distance) in mm, over at most 60 holes → 1770 comparisons
worst case, per hit. Fine, but cache the max incrementally in Godot if it shows up.

Non-target surfaces:

```js
const m=h.object.userData.mat||'metal';
spawnP(h.point, m==='dirt'?9:5, m==='dirt'?2.2:3.2,
  m==='dirt'?[0.45,0.38,0.27]:[0.85,0.8,0.65], 0.7);
decal(h.point,nrm,0.055,false);
Audio.impact(m==='dirt'?'dirt':'metal',dist,0.4);
```

`userData.mat` values in use: `dirt`, `stone`, `metal`, `wood`.

### 13.3 `blastAt` and `explode`

```js
function blastAt(pt,dmg,radius,fromPlayer){
  spawnP(pt,80,13,[1,0.6,0.2],1.5,0.7);
  spawnP(pt,32,5.5,[0.36,0.34,0.31],2.6,0.2);
  puff(pt,26,1.1,0.9,3.2);
  const L=new THREE.PointLight(0xffa040,90,radius*4,2);L.position.copy(pt);scene.add(L);
  setTimeout(()=>scene.remove(L),130);
  const d0=pt.distanceTo(player.pos);
  Audio.impact('boom',d0,1);
  shake=Math.min(shake+cl(0.10*(1-d0/(radius*6)),0,0.09),0.10);shakeT=0.30;
  let hits=0,killed=0;
  targets.forEach(o=>{
    if(!o.alive)return;
    const d=o.node.position.distanceTo(pt);
    if(d>radius)return;
    const f=1-d/radius;
    o.hp-=dmg*f;o.v=(o.v||0)+1.4*f;hits++;
    if(o.hp<=0&&o.kind!=='paper'){
      if(o.kind==='barrel'){setTimeout(()=>{if(o.alive)explode(o);},70+Math.random()*140);}
      else{o.alive=false;o.down=(o.kind==='popper')?6:5;
        o.node.visible=(o.kind!=='bottle');killed++;}
    }
  });
  addScore(Math.round(dmg*0.25+killed*60),pt,killed>1?'MULTI KILL':'BOOM');
  hitMark(killed>0,killed>1);
}
```

**Distance is measured to `o.node.position`, i.e. the target's origin (ground level for
plates/poppers/barrels), not to its centre of mass.** Linear falloff `1 - d/radius`.
Chained barrel detonations are deferred **70–210 ms**.

```js
function explode(t){
  const p=t.node.position.clone();p.y+=0.5;
  t.alive=false;t.down=13;t.node.visible=false;
  spawnP(p,70,12,[1,0.55,0.18],1.4,0.7);
  spawnP(p,28,5,[0.36,0.34,0.31],2.4,0.2);
  puff(p,24,1.0,0.9,3.0);
  const L=new THREE.PointLight(0xffa040,70,30,2);L.position.copy(p);scene.add(L);
  setTimeout(()=>scene.remove(L),120);
  Audio.impact('boom',p.distanceTo(player.pos),1);
  addScore(t.pts*3,p,'BOOM');
  targets.forEach(o=>{
    if(o===t||!o.alive)return;
    const d=o.node.position.distanceTo(t.node.position);
    if(d<9.5){
      o.hp-=200*(1-d/9.5);o.v=(o.v||0)+1.3*(1-d/9.5);
      if(o.hp<=0&&o.kind!=='paper'){
        if(o.kind==='barrel'){setTimeout(()=>{if(o.alive)explode(o);},90+Math.random()*160);}
        else{o.alive=false;o.down=5;o.node.visible=(o.kind!=='bottle');addScore(o.pts,o.node.position,'DOWN');}
      }
    }
  });
}
```

A barrel detonation is a fixed **200 damage over 9.5 m**, linear, independent of what set
it off. Barrel respawn timer is 13 s (vs 5 s / 6 s for plates and poppers).

**PORT:** `setTimeout` chains must become `SceneTreeTimer` / `await get_tree().create_timer(...)`,
and each must re-check `o.alive` on fire (the reference does).

### 13.4 Projectiles

```js
const PGRAV=9.0, PRJMAX=64;
function spawnProj(pos,dir,speed,st,dmg,travelled){
  o.on=true;o.p=pos;o.v=dir*speed;
  o.t=6.0;o.dmg=dmg;o.st=st;o.trav=travelled||0;o.puff=0;
  line.opacity = st.explosive?1.0:0.8;
  line.color   = st.explosive?0xffb060:0xffe0a8;
  const sz=st.explosive?cl(0.34+st.bore*0.016,0.42,1.20):cl(0.030+st.bore*0.0075,0.035,0.12);
  head.scale=sz; head.opacity=st.explosive?1.0:0.75;
  head.color =st.explosive?0xffa552:0xffffff;
  if(st.explosive)puff(pos+dir*14, 12,1.5,0.88,3.0,true);   // launch smoke hung 14 m downrange
}
function stepProj(dt){
  for(const o of prj){
    if(!o.on)continue;
    o.t-=dt;
    const prev=o.p.clone();
    o.v.y-=PGRAV*dt;
    o.p.addScaledVector(o.v,dt);
    const seg=o.p-prev, len=seg.length();
    o.trav+=len;
    if(len>1e-4){
      const h=castValidFar(prev,seg.normalized(),len);
      if(h){resolveHit(h,o.dmg,o.trav,o.st);o.on=false;continue;}
    }
    if(o.t<=0||o.p.y<-3||o.trav>1900){o.on=false;continue;}
    const ex=o.st.explosive;
    o.puff+=len;
    const gap=ex?1.2:9;
    if(o.puff>gap&&(ex||o.st.bore>=8)){
      o.puff=0;
      puff(o.p, ex?3:1, ex?0.34:0.10, ex?0.90:0.34, ex?3.4:0.9, ex);
    }
    const back=Math.min(len*(ex?6.5:2.6)+(ex?2.4:0.4), ex?26:5);
    // line from p - v.normalized()*back  to  p
  }
}
```

* **Gravity is 9.0 m/s², not 9.81.** Explicitly `PGRAV=9.0`.
* `simVel = round(vel*0.5)` — velocity is halved so the arc is readable at range-sized
  distances. This is a deliberate readability cheat; keep it.
* Life 6.0 s, kill below `y = -3`, kill past 1900 m of travel.
* Segment-swept raycast each frame (`castValidFar(prev, dir, len)`), so fast projectiles
  cannot tunnel. **PORT:** in Godot this is a plain `intersect_ray` from `prev` to `p`
  each physics tick — do **not** use a `RigidBody3D`.
* Smoke trail every 1.2 m for rockets, every 9 m for bullets with `bore ≥ 8`.
* Streak length `min(len*k + c, cap)` with `(k,c,cap) = (6.5, 2.4, 26)` explosive,
  `(2.6, 0.4, 5)` otherwise.
* Pool of 64, ring-allocated (`prjHead`); oldest is silently reused.

---

## 14. Player, camera, ADS, zoom, scope

### 14.1 Player state and movement

```js
const player={pos:new THREE.Vector3(0,1.65,8),vel:new THREE.Vector3(),yaw:0,pitch:-0.03,
  onGround:true,bob:0,stepT:0};
const BASEFOV=74;
```

Spawn at `(0, 1.65, 8)` looking down −Z with a −0.03 rad pitch. Eye height 1.65 m.

```js
const sp=((keys['ShiftLeft']||keys['ShiftRight'])?8.6:5.2)*(1-0.55*adsT);
_fwd.set(-Math.sin(player.yaw),0,-Math.cos(player.yaw));
_rgt.set(Math.cos(player.yaw),0,-Math.sin(player.yaw));
// W/ArrowUp +fwd, S/ArrowDown -fwd, D/ArrowRight +rgt, A/ArrowLeft -rgt
if(_wish.lengthSq()>0)_wish.normalize().multiplyScalar(sp);
player.vel.x+=(_wish.x-player.vel.x)*Math.min(1,dt*14);
player.vel.z+=(_wish.z-player.vel.z)*Math.min(1,dt*14);
player.vel.y-=19*dt;
player.pos.addScaledVector(player.vel,dt);
const floor=(Math.abs(player.pos.x)<11&&player.pos.z>-2&&player.pos.z<8)?1.95:1.65;
if(player.pos.y<=floor){player.pos.y=floor;player.vel.y=0;player.onGround=true;}
else player.onGround=false;
player.pos.x=cl(player.pos.x,-38,38);
player.pos.z=cl(player.pos.z,-370,26);
```

| constant | value |
|---|---|
| walk speed | 5.2 m/s |
| sprint speed (Shift) | 8.6 m/s |
| ADS speed multiplier | `1 - 0.55*adsT` |
| horizontal accel | `lerp` factor `min(1, dt*14)` |
| gravity | 19 m/s² |
| jump impulse (Space) | `vel.y = 6.4` |
| eye height | 1.65 m; **1.95 m on the firing pad** (`|x|<11 && -2<z<8`) |
| bounds | x ∈ [−38, 38], z ∈ [−370, 26] |

There is no collision with berms, rocks or targets — only the pad step and the box bounds.

Head bob and footsteps:

```js
if(player.onGround&&speed>0.6){
  player.bob+=dt*speed*1.9;player.stepT-=dt*speed;
  if(player.stepT<=0){player.stepT=1.35;Audio.step();}
}
cam.position.y+=Math.sin(player.bob*2)*0.022*cl(speed/5,0,1.4)+(Math.random()-0.5)*shake;
cam.position.x+=Math.cos(player.bob)*0.013*cl(speed/5,0,1.4)+(Math.random()-0.5)*shake;
cam.rotation.z=(Math.random()-0.5)*shake*0.22;
```

Screen shake: `shakeT>0 ? shakeT-=dt : shake*=pow(0.02,dt)`, so it holds for the shake
window then decays hard. Runaway fire forces `shake >= 0.045`.

**PORT:** the bob offsets are applied *after* `cam.position.copy(player.pos)` — the camera
is not a child of the body. In Godot put the bob on a `Camera3D` that is a child of the
body node, or replicate by writing `global_position` last.

### 14.2 Look and recoil

```js
function look(dx,dy){
  const k=0.0022*Math.tan(cam.fov*Math.PI/360)/Math.tan(BASEFOV*Math.PI/360);
  player.yaw-=dx*k;player.pitch=cl(player.pitch-dy*k,-1.45,1.45);
}
```

Base sensitivity `0.0022 rad per pixel`, **scaled by the FOV ratio** so zoomed aiming is
proportionally slower. Pitch clamp ±1.45 rad (±83.1°). Drag-look (no pointer lock)
multiplies deltas by 1.6.

```js
cam.rotation.order='YXZ';
cam.rotation.y=player.yaw;                       // dead store, overwritten two lines down
cam.rotation.x=player.pitch+recoilP*0.85;
const decay=Math.pow(0.0007,dt);
cam.rotation.y=player.yaw-recoilY*0.75;
recoilP*=decay; recoilY*=decay;
```

Note the transient recoil is applied at 0.85 (pitch) / 0.75 (yaw) of its stored value and
decays by `pow(0.0007, dt)` — 0.07 % remaining after one second, i.e. a ~150 ms visual
snap-back layered on top of the permanent 42 % that went into `player.pitch/yaw`.

### 14.3 ADS blend and FOV

```js
const canAim=!!rtA&&!rtA.jammed&&rtA.reloading<=0;
adsT+=((aiming&&canAim?1:0)-adsT)*Math.min(1,dt*13);
const lv=rtA.st.zoomLevels&&rtA.st.zoomLevels.length?rtA.st.zoomLevels:[rtA.st.zoom];
if(zoomIdx>=lv.length)zoomIdx=lv.length-1;
const z=lv[zoomIdx];
const target=2*Math.atan(Math.tan(BASEFOV*Math.PI/360)/(rtA.st.scoped?1.14:z))*180/Math.PI;
const want=BASEFOV+(target-BASEFOV)*adsT;
cam.fov=want;
const vmWant=56+(52-56)*adsT;      // viewmodel camera 56 -> 52
```

A **scoped** weapon does *not* zoom the main camera — it stays at a 1.14× lean-in, and the
magnification happens inside the scope tube render (§14.4). Unscoped guns zoom the main
camera to the selected level. `adsT` blends at `min(1, dt*13)` (≈77 ms to 63 %).

`aiming = adsHold || adsLock`; RMB or `E` hold, `V` toggles the lock.

```js
function cycleZoom(dir){
  const lv=rt.st.zoomLevels||[rt.st.zoom];
  if(lv.length<2){feed('fixed '+lv[0].toFixed(1)+'× optic');return;}
  zoomIdx=(zoomIdx+(dir>0?1:lv.length-1))%lv.length;
  feed(lv[zoomIdx].toFixed(1)+'× magnification');Audio.ui(1000+zoomIdx*260);
}
```

Mouse wheel down = `dir 1`, wheel up = `dir -1`. `Z` also steps forward.

### 14.4 Scope render

```js
function updateScope(rt,z){
  const on=rt.st.scoped&&adsT>0.55;
  const k=on?cl((adsT-0.55)/0.3,0,1):0;
  scopeEl.style.opacity=k;  crossEl.style.opacity=on?(1-k):1;
  scopeK=k;scopeZ=z;
  if(!on){scopeR=0;return;}
  const R=Math.round(Math.min(innerWidth,innerHeight)*0.335);
  ...
}
```

The scope tube is a **separate render pass into a square render target**, composited back
as a circle so the world outside the glass stays at 1× (both-eyes-open):

```js
if(scopeK>0.5&&scopeR>4){
  const side=Math.max(64,Math.round(scopeR*2));
  // reuse/resize a WebGLRenderTarget(side,side)
  cam.fov=2*Math.atan((side/viewportH)*Math.tan(BASEFOV*Math.PI/360)/scopeZ)*180/Math.PI;
  cam.aspect=1;
  render scene -> scopeRT
  restore fov/aspect
  // full-screen shader quad:
  //   p = vUv*res - res*0.5;  d = length(p)
  //   a = 1 - smoothstep(R-2, R+0.5, d);  discard if a<=0.002
  //   c = texture(map, p/(2R)+0.5).rgb
  //   c *= mix(1.0, 0.40, smoothstep(R*0.72, R, d))     // glass falls off at the rim
  //   out = vec4(c, a*k),  k = cl((scopeK-0.5)/0.35,0,1)
}
```

Scope radius is **33.5 % of the smaller viewport dimension**. The CSS housing shadow is a
radial gradient at `--r` with stops at `r-2px`, `r+1px` (0.82 alpha), `r*1.30` (0.38),
`r*1.66` (0.13), `r*2.10` (0). Reticle: outer ring `r=R-1` stroke 3, four gap crosshair
arms from `±R*0.10` to `±R*0.92` stroke 1.6, mil-dots at `R*0.14*i` for `i=1..5` while
`o < R*0.9` (radius-2 dots on both axes), and a `r=1.6` red centre dot
`rgba(150,30,24,.9)`.

In Godot: a `SubViewport` (square, side = `2*scopeR`) with a duplicate `Camera3D` at
`fov = rad_to_deg(2*atan((side/viewport_h)*tan(deg_to_rad(74)/2)/zoom))`, composited by a
full-screen `CanvasItem` shader with the circle mask above. Reticle is a diegetic overlay
drawn into the same shader or a `TextureRect` — per the project's diegetic-UI rule, prefer
drawing the reticle into the scope shader rather than as screen HUD.

### 14.5 Crosshair (dynamic, mirrors the real cone)

```js
const hpx=innerHeight/2/Math.tan(cam.fov*Math.PI/360);
const r=cl(Math.tan(effSpread(rt)/2)*hpx,3,Math.min(innerWidth,innerHeight)*0.46);
```

Dashed circle at radius `r` (`stroke-dasharray "4 5"`, `rgba(232,228,220,.5)`), 1.5 px
centre dot, four tick marks from `r+2` to `r+8`. This is a *true* projection of the cone,
so it must be recomputed whenever FOV or spread changes.

Action-cycle ring: radius `cl(r+13, 17, min(w,h)*0.47)`, circumference `2πr`, drawn as a
stroke-dashoffset arc rotated −90°.

```js
cycP=(rt.burst>0||rt.next>0)?cl(1-rt.next/Math.max(iv,0.0001),0,1):1;
if(rt.reloading>0||rt.jammed)cycP=0;
```

Colours: ready `rgba(150,214,180,.85)` width 2; cycling `rgba(214,150,60,.95)` width 3;
reloading `rgba(201,162,74,.75)`; jammed `rgba(196,69,63,.9)` width 3 offset 0; runaway
`rgba(226,74,58,.95)` width 4, dashoffset `cycLen*0.62`, spinning at **1500 °/s**.

---

## 15. The range: world, furniture, layout, scoring

`1 world unit = 1 metre`. Down-range is **−Z**. Targets are constructed with a positive
`z` argument and placed at `-z`.

### 15.1 Environment

| element | spec |
|---|---|
| fog | `THREE.Fog(0x8d9aa6, 110, 700)` — linear, near 110 m, far 700 m |
| sky | `SphereGeometry(1400,16,24)`, `BackSide`, unlit, `fog:false`, `depthWrite:false`; vertical gradient stops `#3f5a78` @0, `#8fa1b0` @0.45, `#c3b79c` @0.62, `#8a7c62` @1 |
| camera | FOV 74, near 0.05, far 3000 |
| hemi light | sky `0xa9bcd2`, ground `0x4a3a26`, intensity 0.85 |
| sun | directional `0xfff0d6` intensity 1.30 at `(-60, 90, 40)` |
| bounce | directional `0xc09a6a` intensity 0.30 at `(30, -8, -40)` |
| viewmodel lights | hemi `0xa9bcd2`/`0x4a3a26` 0.70; key `0xfff0d6` 1.15 at `(-2,4,3)`; rim `0x8fb0d8` 0.45 at `(3,1,-3)` |
| tone mapping | ACES filmic, exposure 0.95, sRGB output |

Default material helper: `M(c, r=0.92, m=0.02)` — sRGB colour converted to linear.
`steel() = M('#8a8f96', 0.45, 0.72)`.

Ground and structures:

| object | geometry | position | `mat` |
|---|---|---|---|
| ground | `PlaneGeometry(2400,2400)`, rotated `-π/2` about X, `#6d6047` noise texture repeat 240×240, roughness 0.98 | origin | `dirt` |
| firing pad | `BoxGeometry(22, 0.3, 10)`, `M('#4a4640',0.95)` | `(0, 0.15, 3)` | `stone` |
| 5 posts | `BoxGeometry(0.12,1.1,0.12)`, `M('#3c3833',0.9)` | `(i*4.2, 0.85, -1.6)` for `i=-2..2` | `metal` |
| berm L | `berm(-46,-170,10,440,7)` → `BoxGeometry(10,7,440)` at `(-46, 3.5, -170)` | | `dirt` |
| berm R | `berm( 46,-170,10,440,7)` | | `dirt` |
| backstop | `berm(0,-392,102,12,9)` → `BoxGeometry(102,9,12)` at `(0, 4.5, -392)` | | `dirt` |
| rocks | 64 × `DodecahedronGeometry(1,0)`, `M(i%3?'#6a6152':'#585044',0.98)` | see below | `dirt` |
| distance markers | at 15, 35, 70, 140, 250, 400 m | see below | |

`berm(x,z,w,d,h)` = `BoxGeometry(w,h,d)` at `(x, h/2, z)` with `bermTex` (base `#5c5138`,
repeat 10×5), roughness 0.98.

Rocks:

```js
const a=Math.random()*Math.PI*2, d=16+Math.random()*320;
r.position.set(Math.sin(a)*d*0.5, 0, -Math.abs(Math.cos(a))*d-8);
if(Math.abs(r.position.x)<8) r.position.x += 13*Math.sign(r.position.x||1);
const s=0.25+Math.random()*0.9;  r.scale.set(s, s*0.6, s);
r.rotation.set(Math.random(),Math.random(),Math.random());
```

Note the `-Math.abs(cos)` forces every rock down-range, and the `<8` push keeps the lane
clear. **These are 64 identical meshes with 2 shared materials → one `MultiMeshInstance3D`
per material in Godot** (project performance rule).

`marker(d)`:

```js
post  BoxGeometry(0.16,2.4,0.16), M('#2f2c28',0.9)  at (-8.5, 1.2, -d)   mat 'metal'
sign  PlaneGeometry(1.4,0.7), DoubleSide, canvas 128×64:
      fill '#cabfa8', text bold 40px monospace '#1c1a18' centred, `${d} m` at (64,45)
      at (-8.5, 2.6, -d)   mat 'wood'
```

The sign is `DoubleSide` because you can walk past it. In Godot use a `QuadMesh` with
`cull_mode = disabled` or two back-to-back quads — the latter is preferred (project rule:
no inverted meshes, no relying on two-sidedness).

### 15.2 Target constructors

```js
const targets=[];
function addTarget(o){targets.push(o);scene.add(o.node);
  o.node.traverse(n=>{if(n.isMesh){n.userData.target=o;hitList.push(n);}});return o;}
```

**`plate(x, z, rad, hp)`** — swinging steel disc:

```
node    Group at (x, 0, -z)
ph      = max(0.7, rad*1.4)                            post height
post    BoxGeometry(0.09, ph, 0.09), M('#3a352e',0.9), y = ph/2, mat 'metal'
swing   Group at y = ph
disc    CylinderGeometry(rad, rad, 0.04, 26), steel(), rotated x=π/2, y = rad*0.92
dot     CircleGeometry(rad*0.27, 22), M('#b4432f',0.85), (0, rad*0.92, 0.035), zone 'head'
ring    RingGeometry(rad*0.27, rad*0.31, 24), M('#8f3323',0.85), (0, rad*0.92, 0.036), zone 'head'
record  {kind:'plate', swing, hp, max:hp, alive:true, rad, dist:z,
         pts: round(8 + z*0.55), v:0, ang:0, down:0}
```

**`popper(x, z, hp)`** — hinged silhouette:

```
node    Group at (x, 0, -z);  hinge Group at origin
leg     BoxGeometry(0.1, 0.55, 0.1), M('#3a352e',0.9), y 0.27
body    BoxGeometry(0.44, 0.88, 0.05), steel(), y 0.98
head    BoxGeometry(0.25, 0.27, 0.05), steel(), y 1.55, zone 'head'
band    CircleGeometry(0.10, 18), M('#c25a34',0.85), (0, 1.55, 0.032), zone 'head'
record  {kind:'popper', swing:hinge, rad:0.44, pts: round(16 + z*0.8), down:0}
```

**`bottleRow(z, cnt)`** — 9 bottles at z = 12:

```
rail    BoxGeometry(6.6, 0.12, 0.4), M('#4a4238',0.95) at (0, 1.0, -z), mat 'wood'
legs    BoxGeometry(0.1, 1.0, 0.1), M('#3a352e',0.9) at (±3, 0.5, -z), mat 'wood'
glass   MeshStandardMaterial('#4e7a52', roughness 0.12, metalness 0, transparent, opacity 0.8)
per i   node at (-2.8 + i*(5.6/(cnt-1)), 1.06, -z)
  body  CylinderGeometry(0.055, 0.075, 0.30, 10), y 0.15
  neck  CylinderGeometry(0.028, 0.04,  0.10,  8), y 0.35, zone 'head'
record  {kind:'bottle', hp:1, max:1, rad:0.09, pts:30, down:0}
```

**`mover(z, rad, span, spd)`** — a plate on a rail that tracks left-right:

```
rail    BoxGeometry(span*2+2, 0.1, 0.16), M('#403a32',0.95) at (0, 2.75, -z), mat 'metal'
t       = plate(0, z, rad, 260); then
t.kind='mover'; t.span=span; t.spd=spd; t.phase=Math.random()*6.28;
t.node.position.y = 1.4;  t.pts = round(36 + z*0.9);
motion  t.phase += dt*t.spd;  t.node.position.x = sin(t.phase)*t.span;
```

**`barrel(x, z)`** — explosive drum:

```
body    CylinderGeometry(0.29, 0.29, 0.9, 14), M(rand<0.5?'#7a4b2a':'#5c6b45', 0.85, 0.25), y 0.45
rib     TorusGeometry(0.30, 0.03, 6, 16), M('#3f3a32',0.9,0.3), rot x=π/2, y 0.63
cap     CylinderGeometry(0.13, 0.13, 0.05, 12), M('#c2913a',0.6,0.5), y 0.90, zone 'head'
record  {kind:'barrel', hp:95, max:95, rad:0.32, pts:45, down:0}
```

**`paperTarget(z)`** — the group-measuring target at 25 m:

```
top     BoxGeometry(1.3, 0.06, 0.06), M('#4a4238',0.95), y 2.02, mat 'wood'
legs    BoxGeometry(0.07, 2.02, 0.07), M('#3a352e',0.9) at x ±0.62, y 1.01, mat 'wood'
face    PlaneGeometry(1.15, 1.15), DoubleSide, roughness 0.96, at (0, 1.45, 0.05)
        canvas 512²: fill '#e8e2d2'; stroke '#2a2724';
        for i=6..1: lineWidth = (i===1?5:2), circle r = i*34 at (256,256)
        filled centre dot r=11
record  {kind:'paper', face, hp:1e9, max:1e9, rad:0.58, pts:8, down:0,
         group:[], holes:[], owner:null}
```

### 15.3 Range layout (exact call order — this is the level)

```js
plate(-5.5, 15, 0.30,  60);  plate(0, 15, 0.24,  45);  plate(5.5, 15, 0.30,  60);
popper(-9, 22, 130);         popper(9, 22, 130);
bottleRow(12, 9);
const paper = paperTarget(25);
plate(-7, 35, 0.42, 160);    plate(7, 35, 0.42, 160);
barrel(-13, 30);  barrel(13, 30);  barrel(0, 52);
mover(45, 0.5, 7.5, 1.15);
plate(-11, 70, 0.55, 260);   plate(11, 70, 0.55, 260);
popper(0, 70, 340);
plate(-6, 140, 0.75, 440);   plate(6, 140, 0.75, 440);
barrel(-20, 140);  barrel(20, 140);
plate(0, 250, 1.05,  700);
plate(0, 400, 1.45, 1000);
```

Resulting scoring values: 15 m plates 16 pts, 22 m poppers 34, bottles 30, paper 8 + ring,
35 m plates 27, barrels 45, 45 m mover 77, 70 m plates 47, 70 m popper 72, 140 m plates 85,
250 m plate 146, 400 m plate 228.

### 15.4 Target motion, knock-down and reset (per frame)

```js
for(const t of targets){
  if(t.kind==='mover'&&t.alive){t.phase+=dt*t.spd;t.node.position.x=Math.sin(t.phase)*t.span;}
  if(t.swing){
    if(t.alive){t.v=(t.v||0)*Math.pow(0.05,dt);t.ang=(t.ang||0)+t.v*dt*6;
      t.ang*=Math.pow(0.02,dt);t.swing.rotation.x=cl(t.ang,-0.55,0.55);}
    else t.swing.rotation.x+=(1.35-t.swing.rotation.x)*Math.min(1,dt*7);
  }
  if(!t.alive&&t.down>0){
    t.down-=dt;
    if(t.down<=0){t.alive=true;t.hp=t.max;t.node.visible=true;t.v=0;t.ang=0;
      if(t.swing)t.swing.rotation.x=0;}
  }
}
```

* Live targets swing on an impulse accumulator `t.v` (added by `impact` as
  `cl(dmg*0.012, 0.05, 1.6)*(crit?1.5:1)`), angle clamped ±0.55 rad, both `v` and `ang`
  decaying exponentially per second (5 % and 2 % remaining respectively).
* Downed targets fall to 1.35 rad and stay there.
* **Reset timers**: bottle 9 s, barrel 13 s, popper 6 s, everything else 5 s. On reset the
  target is fully healed, made visible and un-swung. Paper never resets (hp 1e9) — its
  holes clear when a *different weapon* fires at it.

---

## 16. VFX

### 16.1 Spark particles

Single pooled `Points` cloud, `PMAX = 1000`, additive, `size 0.055`, `opacity 0.95`,
`depthWrite false`, `frustumCulled false`. Sprite texture: 32² radial gradient white
1.0 @0, 0.55 @0.4, 0 @1.

```js
function spawnP(p,n,spd,col,life,grav){
  for(let i=0;i<n;i++){
    const k=pHead;pHead=(pHead+1)%PMAX;
    pos[k]=p;
    const a=Math.random()*6.2832, b=Math.acos(2*Math.random()-1), s=spd*(0.35+Math.random());
    vel[k]=( sin(b)*cos(a)*s, |cos(b)|*s*0.9, sin(b)*sin(a)*s );
    base[k]=col; pLife[k]=pMaxL[k]=life*(0.6+Math.random()*0.8);
    pGrav[k]=(grav===undefined)?1:grav;
  }
}
function stepP(dt){
  // vel.y -= 11*grav*dt;  pos += vel*dt
  // floor bounce at y<0.03:  y=0.03; vel.xz*=0.45; vel.y*=-0.28
  // colour = base * (life/maxLife)     -> fades to black, additive so it vanishes
}
```

`Math.acos(2*rand-1)` then `|cos(b)|` makes the hemisphere upward-biased. Particle gravity
is **11 m/s²** times the per-emitter `grav` (default 1; explosions use 0.7 for fire and
0.2 for the slow grey debris).

Call sites (n, speed, colour, life, grav):

| event | call |
|---|---|
| bottle break | `spawnP(pt, 18, 3.6, [0.5,0.9,0.62], 0.9)` |
| barrel hit | `spawnP(pt, crit?14:6, crit?4.5:2.6, [1,0.7,0.35], 0.5)` |
| steel hit | `spawnP(pt, crit?(big?20:12):(big?11:5), crit?6.5:(big?5.5:3), crit?[1,0.92,0.7]:[1,0.82,0.45], crit?0.75:0.55)` |
| dirt hit | `spawnP(pt, 9, 2.2, [0.45,0.38,0.27], 0.7)` |
| metal/stone/wood hit | `spawnP(pt, 5, 3.2, [0.85,0.8,0.65], 0.7)` |
| blast fire | `spawnP(pt, 80, 13, [1,0.6,0.2], 1.5, 0.7)` |
| blast debris | `spawnP(pt, 32, 5.5, [0.36,0.34,0.31], 2.6, 0.2)` |
| barrel explode fire | `spawnP(p, 70, 12, [1,0.55,0.18], 1.4, 0.7)` |
| barrel explode debris | `spawnP(p, 28, 5, [0.36,0.34,0.31], 2.4, 0.2)` |

**PORT:** in Godot this is one `GPUParticles3D` with a `ParticleProcessMaterial` per
colour family, or a `MultiMeshInstance3D` driven from GDScript. The ring-buffer
(`pHead`) semantics — new particles silently steal the oldest slot — must be preserved so
the cost is bounded.

### 16.2 Smoke

Two clouds share one integrator (`smokeCloud(max, size, opacity)`):

| cloud | max | sprite size | opacity | used for |
|---|---|---|---|---|
| `smokeFine` | 420 | 0.62 | 0.50 | muzzle wisps, supersonic bullet trails |
| `smokeHeavy` | 360 | 2.10 | 0.40 | rocket motors |

Sprite texture: 64² radial gradient white 0.88 @0, 0.40 @0.5, 0 @1. `sizeAttenuation true`,
`depthWrite false`, **not** additive.

```js
add(p,n,spread,d,l,rise){
  pos = p + (rand-0.5)*spread on each axis
  vel = ((rand-0.5)*0.7, (rise||0.35)+rand*0.6, (rand-0.5)*0.7)
  dark[k]=d; life[k]=maxL[k]=l*(0.7+rand*0.6);
}
step(dt){
  vel.xz *= Math.pow(0.25,dt);   pos += vel*dt;
  const f=life/maxL, d=dark*f;                 // young = dark, old = haze
  col = HAZE*(1-d) + 0.10*d;      HAZE=[0.62,0.66,0.70]
}
function puff(p,n,spread,dark,life,big){
  if(camPos.distanceToSquared(p) < (big?150:38)) return;   // never born in your face
  (big?smokeHeavy:smokeFine).add(p,n,spread,dark,life, big?0.14:0.35);
}
```

The near-camera cull is **12.25 m for heavy, 6.16 m for fine** (squared distances 150 / 38).
A sprite two metres from the eye covers half the screen, so smoke that would spawn in the
player's face is simply never born. Keep this.

`puff` call sites: rocket launch `puff(pos+dir*14, 12, 1.5, 0.88, 3.0, true)`;
rocket trail `puff(p, 3, 0.34, 0.90, 3.4, true)` every 1.2 m;
bullet trail `puff(p, 1, 0.10, 0.34, 0.9, false)` every 9 m when `bore ≥ 8`;
blast `puff(pt, 26, 1.1, 0.9, 3.2)`; barrel `puff(p, 24, 1.0, 0.9, 3.0)`.

### 16.3 Decals

```js
const DMAX=280, dGeo=new THREE.PlaneGeometry(1,1);
function decal(pt,nrm,size,hot){
  const m=decals[dHead];dHead=(dHead+1)%DMAX;
  m.material=hot?dMatHot:dMatDark;
  m.position.copy(pt).addScaledVector(nrm,0.014);
  m.quaternion.setFromUnitVectors(_zAx,nrm);   // +Z -> surface normal
  m.rotateZ(Math.random()*6.2832);
  m.scale.setScalar(size);m.visible=true;
  return m;
}
```

280-slot ring buffer of unit quads, offset **0.014 m** along the normal, random roll,
`renderOrder 3`, `polygonOffsetFactor -6`.

`holeTex(dark)` — 64², radial gradient:
* dark: `rgba(10,8,7,1)` @0, `rgba(26,22,18,.9)` @0.42, `rgba(40,34,28,0)` @1 — alpha blend.
* hot: `rgba(236,240,246,1)` @0, `rgba(150,158,172,.6)` @0.32, `rgba(140,150,164,0)` @1 —
  **additive** blend (this is the fresh spall on steel).

Sizes: steel `0.05 + min(dmg,160)*0.0006` (hot), barrel 0.07, paper 0.05, world 0.055,
explosive crater 0.55 — all `hot=false` except steel.

**PORT:** Godot's `Decal` node projects a box and is the right tool for surfaces at odd
angles, but 280 `Decal` nodes is too many. Use a pooled `MultiMeshInstance3D` of quads with
`depth_draw_mode = DEPTH_DRAW_DISABLED`, `render_priority` raised, and a small normal
offset — matching the reference exactly.

### 16.4 Tracers

30 pooled two-vertex `Line` segments, colour `0xffe0b0`, additive, `fog:false`,
`depthWrite:false`. Lifetime **0.045 s**, `opacity = cl(t/0.045, 0, 1) * 0.5`.
Drawn muzzle → impact point (or muzzle → projectile spawn point when the shot goes
ballistic, or muzzle → `origin + dir*1200` on a miss).

Godot: `ImmediateMesh` or a pooled `MeshInstance3D` with a stretched quad billboard.
Lines are 1 px in Godot regardless of distance, so a camera-facing quad reads better.

### 16.5 Muzzle flash

```js
const flash=new THREE.PointLight(0xffc880, 0, 10, 2);      // range 10, decay 2
flash.intensity = cl(3 + st.energy/700, 3, 20);            // on fire
flashT = 0.05;
// per frame while flashT>0:  flashT-=dt; flash.intensity*=Math.pow(0.00005,dt);
//   flashSprite.opacity = cl(flashT/0.05,0,1)
const fs = cl(0.05 + st.energy/9000, 0.05, 0.34) * (st.pellets>1 ? 1.35 : 1);
flashSprite.scale = fs;  flashSprite.rotation = Math.random()*6.2832;
```

Flash sprite texture: 64², radial `rgba(255,250,225,1)` @0, `rgba(255,196,110,.85)` @0.25,
`rgba(255,140,50,.28)` @0.6, `rgba(255,120,40,0)` @1, plus **7 random ellipse spikes**
(`rgba(255,220,150,.5)`, `r = 14 + rand*17`, half-width `r*0.5`, half-height 2.2, rotated
to the spike angle). Additive, `depthTest:false`.

The flash light and sprite live in the **viewmodel** scene at
`(base.x, y+0.03, z - muzZ*(1 + (adsScale-1)*adsT))`, so they do not light the world.
**PORT:** that means an explosion of muzzle light on the range is *not* in the reference.
If you want world muzzle light in Godot, that is new design; keep it short-range and
shadow-less per the performance rules.

---

## 17. HUD (and how it maps to the diegetic rule)

The reference HUD is screen-space. Under this project's rules (rule #4) most of it must
become diegetic or move to the F3 overlay. What must survive functionally:

| element | reference | Godot disposition |
|---|---|---|
| dynamic crosshair | SVG circle sized by `tan(effSpread/2)*hpx` | keep — it is a sight picture, not chrome |
| action-cycle ring | SVG arc around the crosshair | keep |
| scope tube + reticle | render-target composite | keep, drawn inside the optic |
| ammo counter | `#ammo`, 44 px magazine count + `of N · reserve ∞`; class `low` when `ammo <= max(1, cap*0.25)`, `empty` at 0 or during runaway | move to the gun (diegetic counter) or F3 |
| reload bar | 190 × 3 px, fill `(1 - reloading/reloadFor)*100 %`, colour `#c9a24a` | fold into the viewmodel animation |
| jam banner | `jam — hold R to clear`, blinking `0.55s steps(2,end)` | keep as a brief on-screen warning |
| hit markers | 4 diagonal ticks, `r0/r1` = 5/12 normal, 6/16 crit; white / `#e6c14f` kill / `#ff6d4a` crit; crit adds a `r=19` ring; 0.3 s `hm` animation | keep |
| damage pops | `.pop`, rise 46 px over 1 s, colours: crit `#ff6d4a` 18 px, `DOWN` `#e6c14f`, `BOOM` `#e07a35`, `break` `#7fc0a8`, else `#e2ddd4` | keep |
| slot list, stat line, feed, score | text overlays, `H` toggles `detail` | F3 debug overlay |

`addScore(n, pt, label)` projects the world point through the camera and only draws the pop
if `v.z < 1 && |v.x| < 1.1 && |v.y| < 1.1`. `hitMark(kill, crit)` is fired on every target
hit; `headshots` increments on `zone==='head'` and on paper `ring >= 10`.

Feed messages (verbatim strings): `too big for a holster`, `primary: <name>`,
`sidearm: <name>`, `JAM — hold R`, `cleared`, `reloaded`, `empty — reloading`,
`sear failed — it will not stop`, `scavenged: <name> [<tier>]`, `sights locked`,
`sights released`, `fixed <z>× optic`, `<z>× magnification`, `stats shown`,
`stats hidden`, `audio off`, `audio on`. Feed holds 6 lines, each for 3.4 s.

Input map:

| key | action |
|---|---|
| `W A S D` / arrows | move |
| `Shift` | sprint |
| `Space` | jump (`vel.y = 6.4`, only when `onGround`) |
| LMB (locked) / `F` | fire |
| RMB / `E` | aim (hold) |
| `V` | toggle aim lock |
| wheel / `Z` | cycle zoom |
| `R` | reload, or hold to clear a jam |
| `1` `2` | select primary / sidearm |
| `Q` | swap slots |
| `G` | scavenge a new gun into the active slot |
| `Tab` | toggle bench ⇄ range |
| `H` | toggle detail stats |
| `M` | mute audio |
| `Esc` (bench) | unfocus |

`blur` clears `firing`, aim and all keys.

---

## 18. The weapon bench

A separate `THREE.Scene` with its own camera (FOV 38, near 0.1, far 300) at `(0,0,camZ)`
always looking at the origin. Lights: hemi `0x93a7bd`/`0x2a2018` 0.38; key `0xfff2e0` 0.95
at `(4,7,6)`; fill `0x6b83a8` 0.55 at `(-6,1,-3)`; rim `0xff8c3c` 0.5 at `(-3,-4,-8)`.
Background `0x0c0d0f`.

### 18.1 Rack layout

```js
let CX=3.05, CY=2.35, TARGET=2.75, rackDist=14, camZ=14;
const N=12;
cols = ar>1.7 ? 4 : (ar>1.0 ? 3 : 2);  rows = Math.ceil(N/cols);
home = ((c-(cols-1)/2)*CX, -(r-(rows-1)/2)*CY, 0);
halfW = cols*CX/2;  halfH = rows*CY/2 + CY*0.48;  t = Math.tan(cam.fov*Math.PI/360);
rackDist = Math.max(halfH/t, halfW/(t*cam.aspect))*1.06 + 1.2;
```

Each weapon is normalised to fit the cell: `s = TARGET / max(size.x, size.y*2.0, 0.001)`,
applied to an outer group; the inner group is offset by `-centre` so the model is centred.
A hidden `BoxGeometry(1,1,1)` picker is scaled to
`(max(size.x*s*1.05, 0.5), max(size.y*s*1.25, 0.95), max(size.z*s*1.6, 0.7))`.

### 18.2 Generation

```js
function generate(seed){
  const mixR=rng((seed*2246822519)>>>0);
  for(let i=0;i<N;i++){
    const base=(seed*1013904223+i*2654435761)>>>0;
    let w=rollTypedSeeded(base,wantedClass(mixR()),false),tries=0;
    while(taken.has(w.name)&&tries++<6)
      w=rollTypedSeeded((base*16807+tries)>>>0,wantedClass(mixR()),false);
    taken.add(w.name);
    ...
  }
}
```

**PORT:** `seed*2246822519` and `seed*1013904223 + i*2654435761` exceed 2^32 and are
truncated by `>>>0`. `base*16807` likewise. In GDScript mask with `& 0xFFFFFFFF` after each
multiply-add. `(seed*1013904223 + i*2654435761)` for seed up to ~10⁶ stays under 2^53 so
the products are exact before masking; guard larger seeds by masking the operands first.

Up to **6 retries** to avoid a duplicate name, and each retry re-rolls the wanted class
(consuming another `mixR()`).

Header text: `${PARTS.length} parts · ${distinct groups} donor firearms · ${combos} combinations`
= `95 parts · 20 donor firearms · 2,129,600 combinations`.

### 18.3 Rack animation (all per-frame lerps — convert to dt-corrected in Godot)

```js
camZ += ((focus<0 ? rackDist : 4.4) - camZ) * 0.12;
// unfocused card:
n.position.lerp(w.home, 0.2);
const sweep = Math.sin(t*0.32 + i*1.7) * 0.40;
n.rotation.y += ((hot===i ? 0.12 : sweep) + 0.30 - n.rotation.y) * 0.08;
n.rotation.x += ((hot===i ? -0.05 : 0.11) - n.rotation.x) * 0.08;
n.position.z += ((hot===i ? 0.5 : 0) - n.position.z) * 0.15;
// focused:
if(!drag) oy += 0.0026;
n.position.lerp((0,0,0), 0.16);
n.rotation.set(ox, oy + 0.42, 0);
```

`t` is `now/1000` (wall clock seconds). Drag sensitivity: yaw `+= dx*0.009`,
pitch `= cl(pitch + dy*0.007, -1.1, 1.1)`.

Labels are HTML positioned by projecting `home - (0, CY*0.40, 0)`; opacity 1 when hovered,
0.62 otherwise, 0 while focused.

### 18.4 Focus, reroll, equip

```js
function rerollSlot(kind){
  const w=weapons[focus], sel=Object.assign({},w.sel);
  if(kind==='sight') sel.sight = Math.random()<0.15 ? null : BY.sight[randIdx];
  else               sel[kind] = BY[kind][randIdx];
  const nw=assemble(sel,w.seed);        // NOTE: no fitOptics()
  nw.idx=focus; nw.home=w.home; nw.label=w.label;
  // preserve the old node's rotation and position, swap the mesh, relabel
}
```

Five swap buttons (`receiver`, `barrel`, `grip`, `stock`, `sight`). The sight button has a
**15 % chance of removing the optic entirely**. Because `fitOptics` is not re-run,
`zoomLevels` stays `[]` — every consumer must fall back to `[stats.zoom]`.

`eq1` equips to slot 0; `eq2` equips to slot 1 and is `disabled` unless
`stats.sidearm`. Seed field: `Scavenge` increments the seed by 1 and regenerates.

### 18.5 The stat card

Six bars, `width = cl(v/max*100, 0, 100) %`:

| row | value | max | colour |
|---|---|---|---|
| Damage | `s.dmg` | 240 | `#c25b3a` |
| Range | `s.range` | 900 | `#6b9e7a` (label `<range> m`) |
| Precision | `s.precision` | 100 | `#5d9bb5` (label `s.spreadTxt`) |
| Recoil | `s.kick` | 100 | `#b58b3a` |
| Handling | `s.hand` | 100 | `#8a9a6b` |
| Reliability | `s.rel` | 100 | `#8c7fb8` |

Header: name, tier chip (tier colour), archetype chip (`#8fa6b8` on `#3d4b57`).
Subtitle: `<cal>[· N pellets] · <mode>` then
`<cap> rnd <feed label> · <reload>s reload · <rpm> rpm · <weight> kg · <oal> mm`
and, if explosive, `blast radius <blastR> m`.
Feed labels: `box → "box mag"`, `tube`, `cylinder`, `internal`, `breech`.
Footer: `<burst> dps burst · <sust> dps sustained · <vel> m/s · <barrel> mm barrel`,
`×<crit> on a head hit · <optic <zoom>× | iron sights>`, then either
`lobbed warhead, drop from the muzzle` or
`instant to <hsRange> m, then <simVel> m/s with drop`.
Then quirk chips, then the parts list: `receiver <g> · barrel <g> / grip <g> · stock <g>[ · sight <g>]`.

---

## 19. Audio — the weapon voice is derived, not sampled

Signal chain: `DynamicsCompressor(threshold −9 dB, knee 14, ratio 3.4, attack 0.004,
release 0.26)` → `WaveShaper(tanh(x*1.9)/tanh(1.9), 1024 points, 2× oversample)` →
`Gain 1.15` → destination. A parallel `Convolver` reverb (2.6 s exponentially decaying
noise, `pow(1-i/len, 2.0) * exp(-t*1.15)`, plus a **berm slapback** impulse of 2.2 at
`t = 0.085 + channel*0.012` ±0.004 s, scaled 0.35) feeds the compressor through a 0.85 gain.

```js
voice(st){
  const e=cl(st.energy/2500,0.12,4.0);
  return {
    crackF: cl(2400/Math.pow(e,0.42),260,3200),
    bodyF : cl(112/Math.pow(e,0.26),28,150),
    subF  : cl(62/Math.pow(e,0.22),20,80),
    tail  : cl(0.34+0.85*Math.log10(1+e*3),0.28,2.1),
    lvl   : cl(0.26+0.34*Math.log10(1+e*4),0.22,0.92),
    mech  : cl(1200+st.cyclic*1.2,900,3400),
    shot  : st.pellets>1,
    big   : cl(e,0.12,4.0)
  };
}
```

Shot layers (all at `t = now`, `L = lvl`, `B = big`):

| layer | spec |
|---|---|
| punch | noise lowpass `bodyF*2.4`, Q 0.6, peak `L*1.75`, attack 0.0009, decay 0.085 |
| sub | sine `subF*2.4 → subF*0.6`, peak `L*1.30`, attack 0.005, decay `0.22+0.14*B` |
| body | triangle `bodyF*2.0 → bodyF*0.5`, peak `L*1.05`, attack 0.004, decay 0.15 |
| crack | noise bandpass `crackF`, Q 0.9, peak `L*0.95`, attack 0.0012, decay 0.075 |
| crack air | at `t+0.004`, highpass `crackF*2.2`, Q 0.4, peak `L*0.30`, attack 0.0008, decay 0.028 |
| shot hiss (payload only) | bandpass 2100, Q 0.5, peak `L*0.55`, attack 0.004, decay 0.20 |
| echo 1 | at `t+0.012` → reverb, lowpass 1200, Q 0.7, peak `L*1.15`, attack 0.008, decay `tail` |
| echo 2 | at `t+0.055` → reverb, lowpass 520, Q 0.6, peak `L*0.55*B`, attack 0.02, decay `tail*1.4` |
| action clatter (auto / semi / burst) | at `t+0.030`, bandpass `mech`, Q 2.2, peak `L*0.26`, attack 0.001, decay 0.034 |

Envelope is `setValueAtTime(0.0001) → exponentialRamp(peak, t+att) → exponentialRamp(0.0001, t+att+dec)`.

Other cues: `dry()` bandpass 3000 Q5 peak 0.16 dec 0.020; `jam()` bandpass 420 Q6 peak 0.28
dec 0.11; `ui(f)` bandpass `f||900` Q4 peak 0.10 dec 0.05; `step()` lowpass 340 peak 0.055
dec 0.075.

`reloadSeq(st, dur)` — a `clack(dt, freq, peak)` is a bandpass Q2.8 at `peak*1.3` plus a
lowpass 260 at `peak*0.9`, both 0.055/0.07 s decay:
* `tube`: `n = min(cap,10)` clacks at `dur*(0.08 + 0.82*i/n)`, freq `1500 + rand*500`,
  peak 0.16; final clack at `dur*0.96`, 900 Hz, 0.22.
* `cylinder`: 0.05 s @700 Hz 0.20; `dur*0.45` @1200 Hz 0.18; `dur*0.9` @520 Hz 0.26.
* everything else: 0.04 s @850 Hz 0.22; `dur*0.55` @620 Hz 0.24; `dur*0.92` @1700 Hz 0.20.

`impact(kind, dist, size)` is delayed by `cl(dist/340, 0, 1.2)` s (**speed of sound**) and
attenuated by `att = cl(1 - dist/420, 0.12, 1)`:
* `steel`: `f = cl(1100/max(size,0.2), 220, 1700)`; lowpass 180 peak `0.26*att` dec 0.10;
  triangle `f` peak `0.30*att` dec 0.70; sine `f*2.71` peak `0.13*att` dec 0.34;
  highpass 3600 peak `0.13*att` dec 0.05; reverb bandpass `f` Q1.2 peak `0.16*att` dec 0.75.
* `glass`: 5 bandpass bursts at `t+i*0.012`, `f = 2600 + rand*3200`, Q6, peak `0.13*att`,
  dec 0.09.
* `boom`: sine 150→22 peak `1.25*att` dec 1.05; sine 70→18 peak `0.95*att` dec 1.5;
  lowpass 520 peak `1.0*att` dec 0.62; bandpass 1800 peak `0.42*att` dec 0.20;
  reverb lowpass 900 peak `0.85*att` dec 2.3 at `t+0.02`.
* default (dirt/paper/metal): lowpass 520 peak `0.20*att` dec 0.11; bandpass 1700 peak
  `0.07*att` dec 0.05.

**PORT:** Godot has no WebAudio graph. Either (a) bake these into `AudioStreamWAV` samples
at bake time with a GDScript synthesiser and select by `energy` bucket, or (b) synthesise
at runtime with `AudioStreamGenerator`. Option (a) fits the "everything is baked" rule:
bucket `e = cl(energy/2500, 0.12, 4.0)` into ~8 bands, bake one shot sample per band per
`shot`/`no-shot`, and pitch-shift within the band. The reverb becomes an
`AudioEffectReverb` bus with the berm slapback as an `AudioEffectDelay` at 85 ms.

---

## 20. Frame loop and mode switching

```js
let last=performance.now();
function loop(now){
  const dt=Math.min((now-last)/1000, 0.05);   last=now;
  if(Mode.now==='range'){Range.update(dt,firing);Range.render();}
  else{Bench.update(now/1000);Bench.render();}
  requestAnimationFrame(loop);
}
```

**`dt` is hard-clamped to 0.05 s (20 fps floor).** Everything downstream — projectile
integration, reload timers, target reset — assumes that clamp. Reproduce it, or a hitch
teleports projectiles.

`Range.render()` order: clear → render world with `cam` → **clear depth** → render
`vmScene` with `vmCam` → optional scope composite. `renderer.autoClear = false`.

Boot:

```js
Bench.generate(1);
Range.equip(rollWeapon(false), 0);
Range.equip(rollWeapon(true),  1);
Range.setActive(0);
resizeAll(); Mode.set('range');
```

---

## 21. Port checklist — what a downstream implementer must get right

1. `ScavRng` with the arithmetic `>>17`; validate against the two vector sets in §1.1.
2. `fit()` epsilon guards (`1e-6`) — part 70 must yield `err = 13.5926`, not `NaN`.
3. `assemble()` statement order, especially `reload`-before-`TUNE.cap` and the four
   successive rewrites of `spread`.
4. `magH` / `sigLen` in **model units**, `barLen` / `stoLen` / `recLen` / `oaLen` /
   `caseLen` / `bore` in **millimetres**.
5. `cfg` masked to 32 bits; `cfg^0x1f2e3d4c` and `cfg^0x5bf03635` masked before seeding.
6. RNG call order in `randomSel` (5–6 calls) and `nameFor` (1–3 calls).
7. `fitOptics` mutates in place and is **skipped** by bench reroll — always fall back to
   `[stats.zoom]` when `zoomLevels` is empty.
8. `1 MOA = 0.000290888 rad`; `spreadRad` uses the **unrounded** spread.
9. `spreadDir` uses `sqrt(random())` for a uniform disc, and is called with the **half**
   angle.
10. Damage falloff floor 0.10, exponent 1.7, coefficient 0.88.
11. No penetration anywhere. First valid hit stops the round.
12. Downed targets are skipped by disabling their collision, not by re-casting.
13. Projectile gravity is **9.0**, particle gravity is **11**, player gravity is **19**.
14. `simVel = round(vel*0.5)` — the deliberate readability halving.
15. `dt` clamped to 0.05 in the loop.
16. Per-frame lerps in the bench and target swing need `1 - pow(1-a, dt*60)`.
17. Every gun material is `DoubleSide` in the reference. Godot must repair winding at bake
    time instead (project rule #2). `OVL` overlaps are the only thing preventing gaps at
    the joints — do not "clean them up".
18. 64 rocks, 280 decals, 1000 sparks, 780 smoke sprites, 30 tracers, 64 projectiles: all
    fixed-size pools. Use `MultiMeshInstance3D` and keep the pools.
19. `explode()` and `blastAt()` measure distance to `node.position` (ground level), not to
    the target's visual centre.
20. Reset timers: bottle 9 s, barrel 13 s, popper 6 s, plate/mover 5 s; paper never.
