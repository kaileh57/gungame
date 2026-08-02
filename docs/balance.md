# Gun balance — where we left the reference behind, and why

The roll → `GunSpec` pipeline is a verbatim port of `reference/scav_range.html`
as transcribed in `docs/spec/range.md`. `GunTuning.reference_exact()` reproduces
it and passes every golden vector in §10 of that spec. What the game actually
ships is `GunTuning`'s defaults, baked to `res://data/guns/gun_tuning.tres` by
`res://tools/build_gun_tuning.gd` and editable in the inspector.

Every departure below is one exported field, applied at the exact point in
`GunAssembler.assemble()` where the reference's own value would have been read,
so nothing downstream is reordered. Zero (or the reference number) on any field
restores the original behaviour, and the verifier proves it still does.

**Every number on this page is measured, not estimated.** Reproduce it with:

```
godot --headless --path <project> --script res://tools/verify_guns.gd
```

which writes `res://data/gun_balance_report.txt`. All figures below are from
2 000 raw builds per tuning off the same seed sequence, except the archetype
incidence table, which uses 40 000.

---

## The headline

| metric | reference | shipped | delta |
|---|---:|---:|---:|
| effective range, min | 4.000 m | 25.000 m | +21.000 |
| effective range, mean | 142.984 m | 149.535 m | +6.551 |
| spread, mean | 83.220 MOA | 43.981 MOA | −39.240 |
| spread, max | 1600.000 MOA | 318.000 MOA | −1282.000 |
| precision, min | 1.000 | 5.000 | +4.000 |
| precision, mean | 42.645 | 45.788 | +3.143 |
| mass, max | 25.649 kg | 12.000 kg | −13.649 |
| handling, min | 1.000 | 7.000 | +6.000 |
| handling, mean | 53.892 | 49.714 | −4.178 |
| rpm, max | 1566 | 1200 | −366 |
| rpm, mean | 389.962 | 355.829 | −34.133 |
| recoil rise, max | 0.052 rad | 0.075 rad | +0.023 |
| burst DPS, mean | 454.679 | 402.262 | −52.417 |
| magazine, max | 87 | 79 | −8 |
| reload, max | 14.000 s | 13.400 s | −0.600 |
| reload, mean | 4.302 s | 3.805 s | −0.497 |
| reliability, mean | 62.754 | 66.469 | +3.715 |
| score, mean | 63.060 | 64.014 | +0.954 |
| fit error, max | 16.631 | 5.722 | −10.909 |
| Hazard tier | 115 (5.8 %) | 15 (0.8 %) | −100 |
| `blunderbuss` quirk | 278 (13.9 %) | 60 (3.0 %) | −218 |
| `jam-prone` quirk | 195 (9.8 %) | 89 (4.5 %) | −106 |

Nothing was made uniformly better: mean kick rises 41.429 → 41.623 and max
kick is untouched. Mean rpm and mean burst DPS both fall hard, because §14 makes
a semi-auto a deliberate weapon instead of a slow full-auto; that is paid for in
the tier census (Warlord-Grade 88 → 59, Relic 14 → 13 against the pre-§14
shipped balance) and it is the intended price. The bad guns are still bad. They
are no longer *unusable*.

---

## 1. Shot payloads: cone ×15.0 → ×4.0

`shot_spread_multiplier`, `docs/spec/range.md` §4.7.

The reference multiplies the raw cone by 15 for a shot payload. The worked
example in §10.3 lands on **1070 MOA — a 17.8° pattern with a 4 m effective
range**. That is not a shotgun; it is a weapon that cannot hit a target at the
end of the firing pad. Shot payloads are 22.6 % of all builds, so this is one
gun in five.

Measured alone against the reference:

| metric | before | after |
|---|---:|---:|
| spread, mean | 83.220 | 54.095 |
| spread, max | 1600.000 | 1375.000 |
| precision, mean | 42.645 | 44.644 |
| effective range, mean | 142.984 | 147.355 |
| `blunderbuss` quirk | 278 | 116 |
| Scrap tier | 665 | 614 |

×4.0 keeps a shotgun distinctly a spray weapon — it is still by far the widest
cone in the game — while putting the pattern inside a doorway at 15 m.

## 2. Shot payloads: choke cap 0.72 → 0.62

`shot_spread_barrel_cap`, §4.7.

The reference lets a long barrel choke away up to 72 % of the shot cone. With
the cone already cut to ×4.0, keeping that much choke made a long-barrelled slug
gun tighter than a battle rifle for free. Pulling it to 0.62 gives back a little
of what §1 removed, specifically to the guns that were over-rewarded:

| metric | before | after |
|---|---:|---:|
| spread, mean | 83.220 | 84.871 |
| precision, mean | 42.645 | 42.333 |
| effective range, mean | 142.984 | 141.768 |

This is the only departure that makes the average gun *worse*, and that is the
point: §1 and §2 are one change with two halves.

## 3. Shot payloads: effective range decoupled from the cone, capped at 55 m

`shot_range_cap`, §4.12.

The reference computes `range = min(3400 / spread, rangeE)`. For a shot payload
the cone therefore destroys the *damage* range as well as the accuracy — the
§10.3 example gets 4 m, meaning pellets stop hurting at conversational distance.
Chemistry, not pattern, should decide how far buckshot carries. Shipped: take
range from `rangeE` alone and cap it at 55 m, which is roughly where real
buckshot stops being a threat.

| metric | before | after |
|---|---:|---:|
| effective range, mean | 142.984 | 145.889 |
| score, mean | 63.060 | 63.361 |

## 4. Zero-height mating faces: divide-by-epsilon → 0.39 × body height

`zero_fit_height_ratio`, §3, hazard #4.

Part 70 (the Serpent stock) records `fit_height = 0.0`. The reference divides by
a `1e-6` epsilon and lands on `err = 13.59`, which alone drags any gun carrying
it to reliability 1, a 264 MOA cone and tier Hazard. One stock in 22 is a
guaranteed ruined weapon because of a data defect in the donor set.

Shipped: when the recorded mating face is zero, fall back to 0.39 × the part's
own body height — the median `fh / ext.y` across the other 21 stocks.

| metric | before | after |
|---|---:|---:|
| fit error, max | 16.631 | 5.722 |
| spread, mean | 83.220 | 68.666 |
| spread, max | 1600.000 | 1170.000 |
| reliability, mean | 62.754 | 65.448 |
| Hazard tier | 115 | 29 |
| `jam-prone` quirk | 195 | 119 |
| `blunderbuss` quirk | 278 | 220 |

This is the single largest departure, and it is a data repair rather than a
balance opinion. The Serpent stock still fits badly — 0.39 is a guess about a
face nobody measured — it just no longer fits *impossibly*.

## 5. Effective range floor 4 m → 25 m

`min_effective_range`, §4.12.

The reference clamps effective range to `[4, 1800]`. Four metres is inside the
firing pad; a weapon that reaches 4 m is indistinguishable from one that does
not work.

| metric | before | after |
|---|---:|---:|
| effective range, min | 4.000 | 25.000 |
| effective range, mean | 142.984 | 144.707 |

## 6. Mass ceiling 26 kg → 12 kg

`mass_ceiling`, §4.3.

`hand = 132 − 0.062·oal − 5·mass`, so anything past ~26 kg pins handling at its
floor and stops being a weapon a character carries. 12 kg is about the heaviest
thing anyone shoulders.

| metric | before | after |
|---|---:|---:|
| mass, max | 25.649 | 12.000 |
| mass, mean | 5.309 | 5.156 |
| handling, mean | 53.892 | 53.953 |
| kick, mean | 41.429 | 41.623 |
| reliability, mean | 62.754 | 63.214 |
| Hazard tier | 115 | 103 |

This is a tail clamp and the aggregate movement is small — mean handling gains
0.060, and `crew-served` (mass > 8.5 kg) still fires on 13.7 % of builds because
the ceiling clips the tail rather than the shoulder. What it removes is the
25 kg outlier. Note that kick and muzzle rise are impulse over mass, so a
lighter ceiling makes the heaviest guns kick *harder*: mean kick rises 0.194.
That trade is intended. You cannot have a 25 kg gun; if it were 12 kg it would
buck.

## 7. Bolt-driven rate ceiling: none → 1200 rpm

`auto_rpm_ceiling`, §4.9.

Full-auto, machine pistol and 3-round burst take their rate from the bolt, not
the trigger, and the reference's only limit is the 1850 rpm cyclic clamp. A
1566 rpm weapon empties a 20-round magazine in three quarters of a second, which
is a mid-fight cutscene rather than a firefight.

Measured alone at 1100 (the value the verifier's ablation row still uses):

| metric | before | after |
|---|---:|---:|
| rpm, max | 1566 | 1100 |
| rpm, mean | 389.962 | 377.638 |
| burst DPS, mean | 454.679 | 447.457 |
| sustained DPS, mean | 209.831 | 208.644 |

Max burst DPS is unchanged at 2181 — the peak comes from a high-damage
semi-auto, not from rate — so this clips exactly the case it was aimed at.

§14 raises the shipped value to 1200. The contrast map there lifts the top of the
mechanical band to ~1540 rpm, and at 1100 a visible share of submachine guns sat
*on* the ceiling rather than under it, which is the same collapse this page is
about, at the other end.

## 8. Magazine ceilings by feed: 60 box / 10 tube / 12 internal

`capacity_box`, `capacity_tube`, `capacity_internal`, §4.6/§4.9.

The reference's only capacity limit is 200, and the archetype multiplier is
applied on top of it. Capacity comes from grip hull volume over round volume,
which happily produces a 36-shell tube magazine and an 87-round box.

Measured alone:

| knob | metric | before | after |
|---|---|---:|---:|
| box → 60 | magazine, max | 87 | 60 |
| box → 60 | magazine, mean | 21.727 | 21.319 |
| tube → 10 | magazine, mean | 21.727 | 21.507 |
| tube → 10 | sustained DPS, mean | 209.831 | 209.351 |
| internal → 12 | magazine, mean | 21.727 | 20.766 |
| internal → 12 | sustained DPS, mean | 209.831 | 206.124 |

## 9. Belt and drum exemptions: 150 machine gun / 32 auto shotgun

`capacity_machine_gun`, `capacity_auto_shotgun`.

These do not clamp; they *protect*. A machine gun's whole identity is the belt,
and the 60-round box ceiling from §8 would take it away. The exemption beats the
feed ceiling, which is why shipped max magazine is **79** rather than 60.

Measured alone against the reference (where nothing is capped) both read "no
measured effect on any tracked metric", which is correct: they only matter in
combination with §8. The auto-shotgun ceiling never binds at all — see §12.

## 10. Reload from the final magazine size, not the pre-archetype one

`reload_uses_final_capacity`, §4.6 PORT note.

The reference computes reload from the capacity it has *before* the archetype
multiplier rewrites it. The §10.3 matched Pumper is the pathological case: a
36-shell tube gives `0.42·36 + 0.70 = 15.8 s`, clamped to the 14 s ceiling — and
it keeps that 14 s even though its archetype and the tube ceiling cut it to a
fraction of 36 rounds. You reload a magazine you do not have.

| metric | before | after |
|---|---:|---:|
| reload, mean | 4.302 | 4.243 |
| `blunderbuss` quirk | 278 | 274 |

Combined with §8 the effect is much larger — shipped mean reload is 3.805 s and
max is 13.400 s, down from 4.302 s and the clamped 14.000 s.

---

## 11. What the shipped roll actually produces

2 000 raw builds, shipped tuning.

| tier | count | share |
|---|---:|---:|
| Scrap | 741 | 37.0 % |
| Cobbled | 732 | 36.6 % |
| Field-Grade | 304 | 15.2 % |
| Gunsmithed | 136 | 6.8 % |
| Warlord-Grade | 59 | 3.0 % |
| Hazard | 15 | 0.8 % |
| Relic | 13 | 0.7 % |

Flags: optic 62.7 %, sidearm 28.4 %, auto 24.0 %, shot payload 22.6 %,
explosive 5.8 %, scoped 3.1 %, runaway 0.3 %. The reference's own measured rates
were 62 %, 27.6 %, 23.6 %, 23.5 %, 5.1 % and 0.2 % — the roll distribution is
unchanged; only the numbers each gun carries moved.

Class-targeted rolls (`GunFactory.roll`) hit the requested archetype **394 / 400
(98.5 %)** at a mean of 37.1 assemblies and a worst case of the full 420-attempt
budget. The holster filter kept 400 / 400.

## 12. Known limitation: Auto shotgun is unreachable

Over 40 000 raw builds the archetype occurs **0 times**, and five consecutive
420-attempt targeted budgets (2 100 assemblies) never produce one. It is
structurally impossible with this part set, not merely rare:

* `Auto shotgun` needs `pellets > 1` and a full-auto action.
* A shotgun-class receiver can never be full-auto — the fire-mode ladder sends
  it to `Semi-auto` at `cyc < 0.55` (§4.6).
* So it needs a non-shotgun receiver carrying a shot payload at `cyc < 0.55`.
  `cyc = impulse / (bolt_kg·18)`, and a shot payload needs `bore ≥ 12.5 mm`,
  which puts impulse well past what the heaviest non-revolver receiver in the
  set (part 32, hull 2.40) can hold under 0.55.

`CLASS_MIX` still asks for it on 1 % of rolls; those fall through to the first
acceptable weapon, which is the reference's documented fallback. Fixing it would
mean rewriting the shotgun branch of the fire-mode ladder, which changes every
shotgun in the game — a far larger distortion than the 1 % it would repair. Its
`TUNE`, `LOOSE`, `FLOOR` and capacity rows are kept because the archetype is
reachable in principle and would otherwise silently misbehave if the part set
ever grows a heavier receiver.

Every other archetype is reachable, with raw incidence over 40 000 builds
ranging from Shotgun at 15.5 % down to Sniper at 0.895 % and Hand cannon at
0.973 %; both of the latter are found by a targeted roll well inside the budget.

## 13. What is deliberately still ugly

* **Handling can still floor at 1.** Not from mass — from length. Overall length
  reaches 1 980 mm, and `−0.062·oal` alone spends 123 of the 132 point budget. A
  two-metre gun should handle terribly; it is left alone.
* **`crew-served` fires on 13.7 % of builds.** Mass over 8.5 kg is common in a
  set assembled from mismatched donors. The quirk is flavour and a handling
  warning, not a defect.
* **Max spread is still 311 MOA (5.2°).** `blunderbuss` at 2.8 % is intended:
  some scavenged guns really are bad.
* **Reliability still bottoms at 1.** A gun assembled from four donor classes
  with a large fit error deserves it. Only the *guaranteed* case — part 70 — was
  repaired, in §4.

## 14. Fire rate: pulling the band apart

`cyclic_floor_rpm`, `cyclic_stroke_power`, `cyclic_fit_penalty`,
`cyclic_pivot_rpm`, `cyclic_contrast`, `archetype_rate_on_cyclic`,
`semi_rate_ceiling`, `semi_recovery_scale`, `auto_rpm_ceiling`. §4.6, §4.9.

The playtest report was *"basically every gun feels the same — all really fast
firing guns with different amounts of ammo."* The fire-mode roll was not the
fault: 31.6 % of builds are semi-auto, 13.4 % break-action, 8.6 % double-action,
and `FireControl.semi_requires_release` genuinely stops a semi repeating on a
held trigger. The fault was that **the rate band had collapsed onto itself.**

The reference sets both edges of that band to the same number:

    cyclic = clamp(1500 / sqrt(bolt_kg · impulse), 320, 1850)   floor   320
    semi   = clamp(320 − impulse · 7,               90,  320)   ceiling 320

so the fastest aimed semi-auto and the slowest self-loading action are the same
weapon in the hand, and the nine golden builds in §10.2 all land between 292 and
404 rpm carrying 66–85 damage. Five changes pull the two apart.

**A semi is priced by recovery, not by momentum.** What paces deliberate single
shots is getting the muzzle back onto the plate, and that is free recoil
*velocity* — `impulse / mass` — not impulse. A 1.4 kg snubnose and a 7 kg battle
rifle can carry identical impulse and do not recover at anything like the same
speed. `rpm = 215 / (1 + v / 3.2)`, floored at 60.

**The bolt has to travel the length of the loaded cartridge.** The reference's
cycle rate knew the carrier's mass but not its stroke, so a 30 mm pistol case and
a 100 mm rifle case cycled the same action at the same rate. `cyclic_stroke_power`
0.75 makes the rifle case 2.4× slower. This is most of what separates an SMG from
a battle rifle.

**A badly mated action loses rate.** `cyclic_fit_penalty` 0.15 per unit of
`fit_error`, floored at 45 % — most of why a Scrap gun used to cycle like a
Gunsmithed one.

**The clamp is replaced by a contrast map.** The three physical terms above span
roughly 120–1900 rpm and the bottom third of that is below anything a self-loader
runs at, so it used to be clamped — and a clamp is a collapse. At
`cyclic_floor_rpm = 470` every one of the 26 Auto battle rifles in a 2 000-build
sample came out at *exactly* 380 rpm and every Machine gun between 424 and 432.
`cyclic = 1140 · (raw / 1140) ^ 0.62` is the same squeeze in log space but
strictly monotone: nothing lands on a limit, and two actions differing by a gram
or a millimetre still differ in rate. The hard floor stays at 360 as a backstop.

**The archetype stops shouting over the geometry.** `TUNE`'s rate multiplier is
smallest exactly where the geometry is already slowest (Auto battle rifle 0.62,
Assault rifle 0.68) and largest where it is already fastest (Auto shotgun 1.05),
so at full strength it drags both ends of the band into the middle. A bolt-driven
rate takes it at `archetype_rate_on_cyclic` = 0.30. A trigger-limited rate still
takes it in full, because there the archetype *is* the shooter's cadence.

Rated rpm per fire mode, 2 000 raw builds, min / mean / max:

| fire mode | n | reference | shipped |
|---|---:|---|---|
| 3-round burst | 318 | 218 / 823 / 1278 | 326 / 837 / 1200 |
| Full-auto | 381 | 254 / 748 / 1566 | 318 / 728 / 1200 |
| Machine pistol | 99 | 368 / 560 / 1410 | 398 / 573 / 1200 |
| Semi-auto | 631 | 126 / 233 / 302 | 82 / 128 / 186 |
| Double-action | 171 | 88 / 106 / 110 | 88 / 106 / 110 |
| Pump-action | 65 | 62 / 70 / 72 | 62 / 70 / 72 |
| Bolt-action | 46 | 38 / 41 / 42 | 38 / 41 / 42 |
| Break-action | 267 | 20 / 22 / 24 | 20 / 22 / 24 |
| Single-shot | 22 | 12 / 12 / 12 | 12 / 12 / 12 |

The reference's semi band (126–302) *overlaps* its full-auto band (254–1566).
The shipped one does not: the fastest semi in the game is 186 rpm and the slowest
self-loader is 318. The fixed manual rates are the reference's and are untouched.

The same table by archetype is where the flatness actually shows. Against the
470-floor build that preceded this pass:

| archetype | 470-floor | shipped |
|---|---|---|
| Submachine gun | 438 / 863 / 1100 | 344 / 938 / 1200 |
| Assault rifle | 394 / 622 / 1066 | 326 / 702 / 1076 |
| Machine gun | 424 / 424 / 432 | 338 / 479 / 574 |
| Auto battle rifle | 380 / 380 / 380 | 318 / 345 / 408 |
| Battle rifle (semi) | 118 / 153 / 176 | 118 / 153 / 176 |

A heavy self-loading battle rifle and an SMG are now 2.7× apart and neither is
sitting on a limit.

Cost, against `reference_exact`: mean rpm 389.962 → 355.829, mean burst DPS
454.679 → 402.262, mean sustained DPS 209.831 → 186.765. Warlord-Grade falls
88 → 59 and Relic 15 → 13 against the pre-§14 shipped balance, because `score`
reads burst DPS. That is the price of a semi-auto being a deliberate weapon and
it is intended.

## 15. Recoil character: shape, not just size

`recoil_character`, `recoil_rise_scale`. §4.16.

The reference has ONE magnitude — `impulse / mass` — with the lateral share a
near-constant, the drift and walk period rolled off `cfg`, and the settle rate a
straight line in mass. Every gun therefore recoils in the same *shape* at a
different size, which is the other half of "they all feel the same". Each of the
six fields now reads a different piece of the geometry:

* **rise** — free recoil velocity, ×1.55 with no stock, ×0.65 when the barrel is
  most of the length and the weight hangs out in front of the hands. Band
  [0.0010, 0.075] rad against the reference's [0.0016, 0.052].
* **lateral share** — a 0.16 floor plus fit error, missing shoulder, cyclic tempo
  and a warhead. A shouldered bolt gun keeps 0.45 of its kick vertical; a
  stockless 1 200 rpm auto goes past 1.0 and walks sideways as hard as it climbs.
* **drift** — geometric magnitude (fit error, missing shoulder) times the
  weapon's own `cfg` signature, `0.45 + 1.10·|roll|`. Mean |roll| is 0.5, so the
  roster's mean drift is exactly the geometry's and only its *spread* is rolled.
  Without that second factor every matched shouldered rifle in the game drifts by
  the same 0.18 and the pattern stops being something you learn per gun.
* **walk period** — shots per horizontal cycle, from the tempo, but the sine only
  means anything on a weapon that fires strings long enough to complete one, so
  the tempo reading owns the field *in proportion to how much tempo there is*.
  At zero tempo the period is the weapon's own rolled one; every break-action is
  no longer handed the same three-shot oscillation it will never live to finish.
* **random** — unreliability plus a missing shoulder.
* **settle** — mass and a shoulder buy a fast settle (one shove, then calm);
  tempo spends it. Band [0.04, 0.95] against the reference's [0.08, 0.42].

Measured over 2 000 builds, mean per fire mode:

| fire mode | rise | lateral | settle | period |
|---|---:|---:|---:|---:|
| Submachine gun (arch) | 0.0045 | 0.0051 | 0.256 | 11.73 |
| Full-auto | 0.0043 | 0.0044 | 0.438 | 10.22 |
| Semi-auto | 0.0065 | 0.0044 | 0.626 | 8.45 |
| Bolt-action | 0.0089 | 0.0040 | 0.594 | 8.28 |
| Break-action | 0.0144 | 0.0117 | 0.598 | 8.46 |
| Single-shot | 0.0435 | 0.0431 | 0.678 | 8.23 |

An SMG climbs a little, walks a lot and never settles; a bolt gun gives one
heavy, straight shove and is calm again by the next round; a stockless
break-action launcher shoves as hard sideways as it does up.

---

## 15. What a tier actually buys

Before this pass, tier was a number on a card. `GunTables.tier_index_for` graded
a weapon and then nothing downstream read the grade — the same Scrap gun that
scored 41 shot exactly like the Field-Grade one that scored 61, minus whatever
its own reliability and spread already said. A Scrap gun that happened to roll
1 044 rpm was not a bad gun; it was a good gun with a bad label.

`GunGrading` is the fix. It derives three quantities and hands every mechanism a
profile keyed off them.

* **`craft`** — workmanship: reliability against joint fit, geometric mean. Pure
  derivation, no tier in it.
* **`rate_stress`** — how far the rated rate outruns what that workmanship can
  carry, `rpm / (80 + 1150·craft^2.2) − 1`, floored at zero. **This is the whole
  answer to the mag-dumping Scrap gun.** A weapon may still roll a high cyclic;
  what it may not do is get it for free.
* **`quality`** — `sqrt(craft · (0.30 + 0.70·rank))`, what the player is holding.
  Every profile below is `0.68 / quality` raised to a power, so Field-Grade is
  1.0 by construction and the exponent reads as "how hard does tier hit this".

Measured over 2 000 raw builds, shipped tuning. `jam/rd` is the per-round
stoppage chance a live weapon actually rolls, after `GunJam.chance_ceiling`;
`clear` is the multiplier on an ordinary stoppage after `grading_clear_ceiling`;
`hard` is the share of stoppages that are the strip-it-down kind; `bloom`,
`ceiling`, `settle`, `sight` and `floor` are the five cone tilts; `floor` is
residual bloom in multiples of the base cone.

| tier | share | quality | jam/rd | wear | hard | clear | bloom | ceil | settle | sight | floor | reload | cycle | fumble | short | misfeed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Hazard | 6.5 % | 0.26 | 14.90 % | 2.21 | 0.37 | 1.60 | 3.29 | 2.35 | 0.35 | 0.28 | 0.197 | 1.82 | 2.17 | 18.7 % | 9.9 % | 2.85 % |
| Scrap | 31.3 % | 0.51 | 2.46 % | 1.25 | 0.20 | 1.36 | 1.54 | 1.32 | 0.70 | 0.51 | 0.088 | 1.22 | 1.31 | 9.5 % | 5.6 % | 1.40 % |
| Cobbled | 36.6 % | 0.60 | 1.94 % | 0.92 | 0.14 | 1.13 | 1.40 | 1.23 | 0.85 | 0.62 | 0.053 | 1.10 | 1.10 | 6.4 % | 4.3 % | 1.04 % |
| Field-Grade | 15.2 % | 0.71 | 0.88 % | 0.57 | 0.09 | 0.96 | 1.12 | 1.10 | 1.06 | 0.73 | 0.022 | 0.97 | 0.98 | 3.1 % | 3.1 % | 0.71 % |
| Gunsmithed | 6.8 % | 0.80 | 0.44 % | 0.27 | 0.05 | 0.83 | 0.94 | 0.97 | 1.21 | 0.84 | 0.007 | 0.90 | 0.90 | 1.6 % | 2.4 % | 0.53 % |
| Warlord-Grade | 3.0 % | 0.87 | 0.22 % | 0.10 | 0.02 | 0.73 | 0.81 | 0.88 | 1.36 | 0.89 | 0.002 | 0.85 | 0.84 | 0.7 % | 1.8 % | 0.38 % |
| Relic | 0.7 % | 0.95 | 0.11 % | 0.03 | 0.01 | 0.67 | 0.70 | 0.78 | 1.49 | 0.98 | 0.000 | 0.80 | 0.79 | 0.1 % | 1.6 % | 0.29 % |

Read across a row and the tier is a sentence. A **Scrap** gun binds once every
41 rounds and more than twice as often across the back half of the magazine; a
fifth of those are teardowns; it opens its group half again as fast per shot,
reaches a third wider before it stops, takes 40 % longer to settle and never
comes back inside 1.09× its own bench group; shouldering it buys half of what
the sights are nominally worth; it reloads 22 % slower and drops the magazine
outright once in eleven; and a fresh magazine can seat up to 5.6 % short with no
warning but the number on the HUD. A **Relic** does none of that: one stoppage
in 900 rounds, almost all of them a tap and a rack, a group that comes back to
the bench figure between shots, and sights worth 98 % of their paper value.

**Hazard is deliberately at the wall.** Its raw per-round product averages 38 %,
which is not a gun. `chance_ceiling = 0.18` is where the line between "this
weapon is a liability" and "this weapon is a cutscene" was drawn, and
`grading_clear_ceiling = 1.60` does the same for the stoppage that follows: an
ordinary Hazard stoppage costs 1.9 s, its worst 4.2 s, its lightest 0.8 s.
Hazard is 6.5 % of rolls and it is content.

### Rate is a thing a well-made gun does

`rate_stress` is fed into five places, so a weapon geared past itself is not
merely slightly worse — it is a different weapon.

| consumer | effect |
|---|---|
| `jam_profile.chance_scale` | `× (1 + 2.6·stress)` |
| `spread_profile.bloom_scale` | `× (1 + 0.9·stress)` |
| `spread_profile.ceiling_scale` | `× (1 + 0.5·stress)` |
| `GunGrading.runs_away` | true above `stress > 0.55` on a gritty automatic |
| `GunGrading.condition` | `craft · (1+stress)^(−1/3)` — pushes the bottom of Scrap into Hazard |

Population mean stress is small by tier (Scrap 0.07, Cobbled 0.17) because most
scrappy weapons are also slow. That is correct, and it is the point: the tax
lands on the specific gun that is both. A Scrap receiver rated 1 044 rpm carries
about 331, so it runs at `stress ≈ 2.15` — it jams at the 18 % ceiling, blooms
three times harder per shot, and if it is automatic it does not stop when you
let go of the trigger.

### Quirks are behaviour

`GunQuirks` holds 28 named traits. Every one carries a modifier bundle that is
folded into the profile the mechanism receives, so a name on the stat card is
always a number that moved. They are drawn once per weapon off `GunSpec.cfg`, so
a given assembly always has the same faults; how many it draws is quality alone
(three below 0.42, two below 0.58, one below 0.84, two virtues above it), and
each is gated on hardware that could plausibly have it. "pts" below are
percentage points added to a probability.

| trait | gate | what it does |
|---|---|---|
| sticky bolt | hand-worked | cycle ×1.42, stoppage clear ×1.18 |
| burred chamber | any | jam ×1.55, teardown share ×1.35 |
| grit in the works | any | jam ×1.30, clear ×1.12, wear +0.70 |
| worn sear | automatic | jam ×1.22, bloom ×1.24, ceiling ×1.16 |
| heat-warped | automatic | wear +0.85, bloom ×1.15 |
| overrun action | `stress > 0.18` | jam ×1.38, ceiling ×1.22, wear +0.60 |
| heavy trigger | any | bloom ×1.16, settle ×0.88 |
| bent feed lips | box/drum | short fill +7 pts, double-feed +2 pts |
| tired spring | box/drum | last-rounds tail +0.90, wear +0.45 |
| stiff spring | box/drum | reload ×1.10, tail +0.40 |
| bent gate | tube | per-shell time ×1.45, fumble +4 pts |
| greasy grip | any | fumble +6 pts, reload ×1.12 |
| cracked stock | any | bloom ×1.28, ADS bloom relief ×0.72 |
| loose optic | has glass | sights worth ×0.62, bloom floor +0.060 |
| canted sights | irons | sights worth ×0.70, bloom floor +0.050 |
| whippy barrel | any | bloom floor +0.050, settle ×0.80 |
| loose choke | shot payload | bloom ×1.30, ceiling ×1.18 |
| muzzle-heavy | ≥ 5.4 kg | settle ×0.82, relief ×1.18, reload ×1.08 |
| broken-in | q ≥ 0.62 | jam ×0.86, clear ×0.90 |
| crisp trigger | q ≥ 0.66 | bloom ×0.88, settle ×1.14 |
| match barrel | q ≥ 0.74 | bloom ×0.80, bloom floor −0.060 |
| tuned sear | automatic, q ≥ 0.72 | settle ×1.20, bloom ×0.88, ceiling ×0.88 |
| hand-fitted | q ≥ 0.78 | jam ×0.68, clear ×0.80, teardown share ×0.55 |
| polished feed | box/drum, q ≥ 0.72 | short −6 pts, double-feed −3 pts, wear −0.50 |
| speed mag | box/drum, q ≥ 0.70 | reload ×0.84, fumble −5 pts |
| slick gate | tube, q ≥ 0.70 | per-shell time ×0.76, fumble −4 pts |
| quick bolt | hand-worked, q ≥ 0.70 | cycle ×0.74 |
| cheek weld | has glass, q ≥ 0.74 | ADS bloom relief ×1.28, sights worth ×1.10 |

The eleven reference quirks (`blunderbuss`, `jam-prone`, `drum-fed` …) are kept
unchanged and are read straight off published numbers the mechanisms already
consume, so they need no bundle: `drum-fed` IS the 60-round stack that
`feed_quality` is already punishing. The derived character tags (`gritty`,
`worn mag`, `wandering zero`, `hard-jamming` …) report the finished profile at
the same threshold the mechanism keys off, traits included, so they describe the
total rather than duplicating it. Nothing on a card is decoration.

Each of the mechanism resources carries an `@export_range` `quirk_strength`
(`GunReload` carries a second, `feed_quirk_strength`, for the magazine): 0 turns
the character layer off without changing which names print, 1 is shipped, 2
makes a fault the defining thing about the weapon.

Over 2 000 builds **0 weapons carry no tag at all**, the mean is 4.43 tags, and
trait incidence runs from `heavy trigger` at 14.6 % down to `slick gate` at
0.1 % — the rare end being traits that need both high quality and unusual
hardware, in that case a tube-fed Warlord.

### What moved to make room for this

| knob | was | now | why |
|---|---:|---:|---|
| `GunJam.chance_ceiling` | 0.34 | 0.18 | 0.34 is a stoppage every third round |
| `GunJam.hard_clear_scale` | 2.70 | 2.20 | with the ceiling below, a Hazard teardown was 8.5 s |
| `GunJam.grading_clear_ceiling` | — | 1.60 | new; `clear_scale` was unbounded |
| `GunGrading.HARD_SHARE` | 0.72 | 0.50 | every Hazard magazine contained a teardown |
| `GunGrading.HARD_MARK` | 0.34 | 0.24 | tracks `HARD_SHARE` so the tag still fires |
