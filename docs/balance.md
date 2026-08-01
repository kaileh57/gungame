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
| effective range, mean | 142.984 m | 151.584 m | +8.600 |
| spread, mean | 83.220 MOA | 43.262 MOA | −39.958 |
| spread, max | 1600.000 MOA | 311.000 MOA | −1289.000 |
| precision, min | 1.000 | 5.000 | +4.000 |
| precision, mean | 42.645 | 46.071 | +3.426 |
| mass, max | 25.649 kg | 12.000 kg | −13.649 |
| rpm, max | 1566 | 1100 | −466 |
| burst DPS, mean | 454.679 | 447.464 | −7.215 |
| magazine, max | 87 | 79 | −8 |
| reload, max | 14.000 s | 13.400 s | −0.600 |
| reload, mean | 4.302 s | 3.805 s | −0.497 |
| reliability, mean | 62.754 | 66.472 | +3.719 |
| score, mean | 63.060 | 64.819 | +1.759 |
| fit error, max | 16.631 | 5.722 | −10.909 |
| Hazard tier | 115 (5.8 %) | 15 (0.8 %) | −100 |
| `blunderbuss` quirk | 278 (13.9 %) | 55 (2.8 %) | −223 |
| `jam-prone` quirk | 195 (9.8 %) | 89 (4.5 %) | −106 |

Nothing was made uniformly better: mean kick rises 41.429 → 41.623 and max
kick, max burst DPS and max sustained DPS are untouched. The bad guns are still
bad. They are no longer *unusable*.

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

## 7. Bolt-driven rate ceiling: none → 1100 rpm

`auto_rpm_ceiling`, §4.9.

Full-auto, machine pistol and 3-round burst take their rate from the bolt, not
the trigger, and the reference's only limit is the 1850 rpm cyclic clamp. A
1566 rpm weapon empties a 20-round magazine in three quarters of a second, which
is a mid-fight cutscene rather than a firefight.

| metric | before | after |
|---|---:|---:|
| rpm, max | 1566 | 1100 |
| rpm, mean | 389.962 | 377.638 |
| burst DPS, mean | 454.679 | 447.457 |
| sustained DPS, mean | 209.831 | 208.644 |

Max burst DPS is unchanged at 2181 — the peak comes from a high-damage
semi-auto, not from rate — so this clips exactly the case it was aimed at.

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
| Cobbled | 706 | 35.3 % |
| Scrap | 653 | 32.6 % |
| Field-Grade | 366 | 18.3 % |
| Gunsmithed | 158 | 7.9 % |
| Warlord-Grade | 88 | 4.4 % |
| Hazard | 15 | 0.8 % |
| Relic | 14 | 0.7 % |

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
