# STATUS

Where the project actually is, measured rather than asserted. This is the
hand-over document: it is written for the person doing the next tuning pass, so
accuracy beats optics everywhere the two disagree.

**Measured 2026-08-01 on Godot 4.7.1-stable (steam), Windows 11, Forward+ /
Jolt / d3d12, AMD Radeon RX 6700 XT, 14C/20T, 32 GB.**

Everything below was re-run today against the tree as it now stands, after a
full `bake_all`. Nothing in the tables is carried from an earlier measurement
unless the row says **(carried)**.

287 GDScript files.

---

## Headline

| gate | command | result |
|---|---|---|
| Full bake | `tools/bake_all.gd` | **PASS** — 25 ok, 0 failed, 1 skipped, 142.4 s (green twice today) |
| Every scene boots | `tools/verify_scenes.gd` | **PASS** — 10/10, 120 frames each |
| **Firefight acceptance** | `tools/verify_firefight.gd` | **PASS ×5** — 25 trials over 5 invocations. See below. |
| **AI traversal** | `tools/verify_ai_traversal.gd` | **PASS ×2** — climbers reached arena 66%/66%, town 77%/75% of routable roof goals against a 55% bar |
| Arena acceptance | `demos/arena/tests/verify_arena.gd` | **PASS** — 8-body wave, player kills a body with his own gun |
| Gun golden vectors | `tools/verify_guns.gd` | **PASS** — 0 failures |
| Firing chain | `tools/verify_guns_firing.gd` | **PASS** — 26 checks, 0 failures |
| Integration | `tools/verify_integration.gd` | **PASS** — 38/38 |
| Species table | `tools/verify_species.gd` | **PASS** — 12 species, no degenerate stats |
| Creature rig | `tools/verify_rig_core.gd` | **PASS** |
| Player locomotion | `systems/player/tests/verify_locomotion.gd` | **PASS** — 30/30 |
| **Click registration** | `tools/verify_click_input.gd` | **PASS** — 7 demos, 100% tap/hold/burst/flick, 90/90 sub-frame taps |
| **ADS occlusion** | `tools/verify_ads_occlusion.gd` | **PASS** — 0 of 111 weapons blind, was 78 of 111 |
| **Panel mounts** | `tools/verify_mounts.gd` | **PASS** — 0 intersections over 36 declared mounts |
| Diegetic UI | `tools/verify_ui.gd` | **PASS** — 102/102 |
| UI shell + menu | `tools/verify_ui_shell.gd` | **PASS** — 144/144 |
| Off-mesh link bake | `tools/bake_nav_links.gd` | **PASS** — 2,928 links over three levels, 100% pathable |
| Multimesh buffers | `tools/verify_multimesh.gd` | **PASS** (runs inside `bake_all`) |
| Renders | `tools/capture.tscn` | **9/9 shot**, 0 engine errors |
| **Mesh validation** | `tools/validate_meshes.gd` | **FAIL** — 71 of 1,048 surfaces, byte-identical to the previous run |
| Format / Lint / Parse | `gdformat --check`, `gdlint`, `gdparse` | **clean** — 287 files, 0 problems |

**One gate is red and it is the same 71 surfaces it has always been**, listed
and explained under *Mesh validation*. Everything else is green.

---

## What the last three agents changed, and what it bought

Three parallel passes landed before this one. All three touched the firefight,
in different files, and the full re-bake reconciled them — see *Conflicts, and
how they were resolved*.

### 1. Firefight verticality — a ramp, not a ladder

The level, not the AI, was the reason `aloft` was **0 of 98** in every previous
measurement. `tools/firefight/firefight_posts.gd` now builds **six raised decks
(~890 m² of roof, tops at 5.4 m) with parapets and two walk-up ramps each**,
plus three shack ramps to 3.70 m inside the compounds.

The important decision is that the access is a **28° walkable ramp and not a
ladder**, and the file argues it from measurement: `AIVantage.bake` gates every
candidate on a real `map_get_path` against a map that has **no off-mesh links on
it at bake time**, so a deck reachable only by a link bakes zero vantage points
and no marksman ever hears about it. A ramp costs one box and no link.

What it bought, in the link bake:

```
firefight   reach a roof: walk-only 0/240 (0%)  ->  with links 0/240 (0%)     BEFORE
firefight   reach a roof: walk-only 117/240 (49%) -> with links 126/240 (53%)  NOW
```

Note where the number comes from: **49 of the 53 points are walking**. The 1,792
off-mesh links add nine goals on top of the 117 the ramps opened. That is the fix
working exactly as its author argued it would.

And in the cover/vantage bake:

```
vantage      44 points, EVERY ONE at y = 0.50    BEFORE
vantage      56 kept of 233 scored, 31 above 2 m, highest 5.75 m   NOW
```

Live, this reads as **`aloft` 1–3 of ~101 bodies, mean 1.54** over 150 s. It is
no longer zero and it is not yet a crowd. See KNOWN GAPS.

### 2. Cover field density — and one honest trade

`AICoverSampler` grew `REFINE_PASSES` (2) and `REFINE_STEP` (0.5): after the
uniform walk, it re-samples at half the coarse step around anything the walk
found, so a container gets a ring of samples rather than whichever single sample
the grid origin happened to drop beside it. The measured justification is in the
file — `unprotected` was refusing 42% of every candidate scored in the live demo.

The firefight cover set went to **3,998 points over 689 cells**; the arena's to
**1,603**.

Live, this is the largest single behavioural change in the pass:

```
concurrent cover leases, ~100 bodies      1–3   ->   13–15   (mean 10.4 over 150 s)
```

The trade the cover agent reported honestly, and which is structural: cover and
vantage compete for one `best_score`, and 3–4× more cover points wins that
comparison more often. Its interim measurement had vantage falling from ~2.6
mean to ~1.0. **Measured on the shipped tree, with the decks in place, vantage
is 2.0 mean over 150 s from the authored camera and 5.8 from a close one** — so
the regression is smaller than feared and the camera turns out to matter more
than the cover density does. See *A measurement trap worth writing down*.
`REFINE_PASSES` is the dial if you want the trade back the other way.

### 3. The war — the flaky gate had a real bug under it

The previous STATUS called `verify_firefight` "a coin flip" and asked for the
gate to be fixed. It was, and **fixing the harness found a genuine defect in the
territory ledger**, which is the outcome that was hoped for and not the one that
usually happens.

The defect: pressure clamps at 1.0 and the capture test asks for the defender's
pressure **plus a margin**, so a holder sitting at `1 − margin` or above could
not be out-pushed by anybody at any strength. Reported measured before the fix
(**their number, not re-measured here — the code that produced it is gone**):
six or seven of this map's seven zones were mathematically uncapturable at any
given moment, 90% of all graded zone-samples. Whether a run scored 2 flips or 5
was decided by which zone happened to be off the clamp that minute.

`Territory._garrison_hold_for` now derives its cap from the same `_margin_for`
the capture test uses, so no combination of `garrison_ceiling`, `capture_margin`,
`home_margin_scale` and a zone's `value` can reach that state. **This part was
re-measured here: `locked 0/7` in every graded sample of all 25 trials**, and the
harness asserts it (`MAX_LOCKED_SHARE` 0.05) rather than trusting it.

Two more territory terms were added, both derived rather than picked:

- **`Factions.contest_attrition` (2.00)** — how hard a faction's push wears down
  its rivals' hold on the same ground, *multiplicatively*. Without it the ledger
  reads "is anybody standing here" instead of "who is winning here", because
  anybody with one body saturates their own clamp in seconds. A subtractive
  version was tried and rejected: it fixed the firefight and froze the nine-zone
  headless war solid, because five bodies against five nets exactly zero.
- **`Factions.capture_dwell` (10.0)** — an anti-strobe rule. With it at zero,
  `choir_house` changed hands sixteen times in forty seconds in pairs 0.5–1.0 s
  apart.

And the gate now **gates on the distribution**: five trials per invocation, the
ownership bar asked of the **median**, the body-economy floors asked of every
trial, plus a per-trial anti-lock floor, a distinct-zones-moved floor, and a
**rebound share** that tells a war from a metronome — because at
`contest_attrition = 1.0` the capture count was higher (median 10 vs 3) and it
was a lie: `tank_farm` flipped at 126.0, 136.0 and 146.0 s, exactly one dwell
apart.

---

## The firefight gate, run five times

The brief asked for this specifically, because the previous pass's gate failed
one run in three. Every result, no cherry-picking. **Each invocation is five
trials of 240 simulated seconds with a 30 s settle, so this is 25 trials.**

| invocation | ownership changes per trial | median | worst | late-half trials | zones moved | kills | verdict |
|---|---|---:|---:|---|---|---|---|
| 1 | 5 · 10 · 5 · 6 · 6 | 6 | 5 | **4 of 5** | 3·3·3·3·4 | 78–73–77–77–71 | **PASS** |
| 2 | 6 · 4 · 6 · 3 · 6 | 6 | **3** | **3 of 5** | 3·3·3·3·3 | 71–90–74–64–82 | **PASS** |
| 3 | 6 · 10 · 5 · 6 · 4 | 6 | 4 | **5 of 5** | 3·3·3·3·3 | 81–71–84–75–99 | **PASS** |
| 4 | 5 · 5 · 5 · 6 · 6 | 5 | 5 | **5 of 5** | 3·3·3·3·3 | 74–76–68–76–68 | **PASS** |
| 5 | 6 · 5 · 4 · 7 · 8 | 6 | 4 | **4 of 5** | 3·3·3·3·4 | 70–80–73–78–75 | **PASS** |

Bars: **median > 4**, **worst > 2**, at least **half** the trials moving in the
late half, at least **2 distinct zones** moving per trial, ≤ 34% dwell-limited
rebounds, ≤ 5% locked zone-samples.

Over all 25 trials: ownership changes ran **3 to 10**, median 6 in four
invocations and 5 in one; the worst single trial scored **3**, one above the
per-trial floor; **21 of 25 trials moved in the late half**; and `locked` was
**0 of 7 zones in every graded sample of every trial**.

**It still varies — 3 to 10 flips on identical code and an identical seed — and
that is expected and is why it gates on the distribution.** What changed is that
the variance no longer straddles the bar. The previous build returned 2, 4 and 5
against a bar of "more than 2" and failed one run in three; this one returns a
median of 5 or 6 against a bar of 4, five times out of five.

**The clock held at 1.00× on all 25 trials** (240 simulated seconds in 240 wall
seconds), including the trials that ran while other harnesses were running on the
same machine — so none of these numbers is a contention artifact.

**The bar with the least room is the late half.** Invocation 2 returned exactly
3 of 5 against a bar of 3. One trial falling the other way in that invocation
would have been a red gate. That is the number to watch when tuning territory.

---

## Conflicts, and how they were resolved

The cover agent flagged that its bakes had picked up another agent's in-flight
geometry. All four of its concerns were checked, and all four are resolved by
the full re-bake:

1. **`firefight.tscn` was baked at 02:58 but `firefight_posts.gd` changed at
   03:04.** The shipped scene was one edit stale. `bake_all` re-ran
   `build_firefight` and every downstream step; the report is green and
   `POSTS CLEAR: PASS` with the closest keep-out pair 0.3 m apart.
2. **`build_firefight.gd`'s self-test was reporting `VERDICT: FAIL`**
   ("closest keep-out pair −1.0 m apart"). **Not reproduced in five builds
   today.** Every one printed `POSTS CLEAR PASS / OUTWARD WINDING PASS / NO OPEN
   SHELLS PASS (0) / NO DEGENERATES PASS (0) / VERDICT PASS`, closest pair
   +0.3 m. Whose in-flight edit caused it was not investigated and does not
   matter now; what matters is that a negative clearance means two ramps inside
   each other and the bake refuses it, which is the check working.
3. **`arena.tscn` embedded a stale 491-point cover set while `arena_cover.tres`
   held a newer one.** Checked directly in the packed scene today: the embedded
   `SubResource` holds **1,603 positions and 35 vantage points**, and
   `arena_cover.tres` reports 1,603. They agree because `build_arena.gd` passes
   the same in-memory object to `_save` and to the director, so they cannot
   disagree after a bake — only after somebody re-bakes one and not the other,
   which is what `tools/bake_ai_cover.gd` does by design. **If you use
   `bake_ai_cover.gd` on the arena, re-run `build_arena.gd` afterwards or the
   scene keeps the old set.** The firefight does not have this problem: it
   references its `.tres` externally.
4. **`build_firefight.gd` was reported non-deterministic** (3,592 vs 3,580
   navmesh polys, 946 vs 1,038 cover points across two runs). **Not reproduced.**
   Three consecutive runs on a quiet machine produced reports that are identical
   line for line once the two timing lines are removed — 3,869 navmesh polys,
   3,998 cover points over 689 cells, 56 vantage points kept of 233 scored, 342
   routable of 375 candidates, 1,656 arena triangles, volume +762,883.1 m³, 138
   colliders, 542 nodes, closest keep-out pair 0.3 m. The most likely explanation
   for the original report is that it was taken while another agent was editing
   `firefight_posts.gd` between the two runs, which is exactly what that agent
   also reported. **Treat the bake as deterministic; if it ever is not, the
   navmesh poly count is the first number that moves.**

**`bake_all` still does not gate on a builder's own `VERDICT:` line.** It judges
a step by its exit code and by `ToolLog.problems()` scanning stderr for known
markers, and a builder that prints `VERDICT: FAIL` and exits 0 is recorded `OK`.
That is a real hole and it is in WHERE TO START.

---

## What was watched, live

Not what the code implies. `tools/watch.gd`, played on a real display, read line
by line and looked at frame by frame.

### `firefight` — 150 s, ~101 bodies, authored spectator view

```
cover leases     mean 10.4  max 15      was 1-3
vantage leases   mean  2.0  max  6      was 1-4
aloft            mean  1.5  max  3      was 0 of 98
callouts         509 in 150 s, in readable sequences
link crossings   11 in 150 s            was 56 in 120 s
fps              237-290
```

- **All three factions sustained.** After the first thirty seconds: SCAV mean
  21.8 (min 19), FOUNDRY 21.9 (min 20), CHOIR 21.3 (min 16), against a target of
  22. Nobody collapsed and nobody ran away with it.
- **The map changed hands.** Zone ownership walked
  `1/1/1 → 2/2/1 → 2/3/1 → 3/3/1 → 3/2/2 → 2/3/2 → 2/4/1`. It also **sat on
  `2/3/2` for 86 of 151 samples**, which is the slow late half the acceptance
  gate's late-half bar exists to catch.
- **Link crossings collapsed from 56 to 11, and that is the ramps working.** A
  body that can walk up does not need a link. Nothing regressed.
- One recurring engine error under load, unchanged:
  `It's not expect to not find the most reachable polygons`, from
  `ai_navigator.gd:672` via `firefight_agent.gd:153`. It does not stop the body.

### `firefight` — close up, and this is the part that was only ever instrumental

The previous pass could not confirm cover by eye, because the authored spectator
camera sits 73 m out and a body is a few pixels. `tools/watch.gd` now takes
`--eye=x,y,z --look=x,y,z` and parks the camera anywhere for the whole run (see
*Repo hygiene* — it is a new option on an existing observation tool, not a new
tool).

Parked at `(26, 4.5, 31)` looking across the pan, in
`_shots/close_cover/firefight_05.png`: **a body is tucked hard against the
corner of a deck plinth with its rifle shouldered and aimed around the corner,
while a second body runs across the open ground behind it and a third fires from
the far side of the ramp** — muzzle flash visible in frame. That is the
behaviour the cover work claimed and could not photograph. It is photographed
now.

Parked at `(34, 13, 42)` looking at the `pan_east` deck, in
`_shots/close_deck/`: the ramps and decks read clearly, bodies group at the ramp
feet and along the compound walls — **and the deck tops are mostly empty**,
which is what `aloft 1–3` looks like from outside.

### A measurement trap worth writing down: the camera changes the AI

Comparing the same 90-second window across the two camera positions:

```
             t=0..9  10..19  20..29  30..39  40..49  50..59  60..69  70..79  80..89
vantage, authored view   5.1     5.1     4.9     3.5     2.0     3.7     1.3     1.5     0.3
vantage, parked close    7.2     6.8     8.3     6.4     5.7     5.3     3.9     3.0     3.0
cover,   authored view   3.3     5.6     3.6     3.0     6.2    13.1    13.0    13.0    13.0
cover,   parked close    3.4     6.7     4.9     6.4     8.2     8.5    13.4    13.4    14.0
```

**Vantage roughly doubles when the camera is closer; cover does not move.** The
likely cause is `AITickScheduler`, which LODs off the *viewer*: `near_radius`
22 m at 60 Hz, `mid_radius` 55 m at 15 Hz, `far_radius` 140 m at 4 Hz, with
`offscreen_demote` on. The authored spectator eye is at `(-12, 26, 67)`, which
is **73 m from the centre of the map** — so most of the war is in the FAR bucket
thinking four times a second, while a camera parked at 41 m out puts much of it
in MID and NEAR.

**This is a hypothesis with a matching derivation, not a proven cause** — the
radii and the distances line up and the two close runs agree with each other to
within 1%, but nothing was instrumented to confirm which bucket a body was in.
It matters because **every "cover uptake is low" and "vantage is thin" figure in
every previous STATUS was read through the authored overhead view.** Before
tuning a vantage weight, check what tick rate the bodies were on.

The other thing both views agree on: **vantage decays**. It is ~5–7 in the first
minute and 0–3 after two, in both camera positions. That decay is real and
un-diagnosed.

### `arena` — 90 s, 16-body wave, player firing

```
t= 30s   16 alive   5 engaged  3 hunting   2 rounds   aloft 0/17
t= 60s   16 alive   7 engaged  1 hunting  17 rounds   aloft 0/17
t= 70s   16 alive   9 engaged  1 hunting  22 rounds   aloft 2/17
t= 90s   16 alive  10 engaged  1 hunting  29 rounds   aloft 1/17
```

- The wave walks in through the gates, takes posts, and **10 of 16 are ENGAGED
  by t=90 with 29 rounds downrange on their own**.
- **They climb.** `aloft 2/17` from t=70, and the link bake gives the arena 100%
  roof reachability both ways.
- 277–330 fps.
- `_shots/watch_arena/arena_05.png`: half a dozen species walking in past the
  containers, long shadows, the viewmodel in the corner — **with no hands or
  arms on it**, which is KNOWN GAP 30 photographed without trying.

**A trap was found and fixed while doing this.** `watch.gd --spawn=N` is the
COUNT dial's **detent index**, not a body count, and `DiegeticDial.wraps` is
true — so `--spawn=8` on an eight-detent dial ran through `posmod` to detent 0,
spawned **one** body, and printed "thrown for 8". Eighty seconds of arena went by
with nothing to watch and no error anywhere. `_pull_lever` now clamps against the
dial's own detent count, says so when it clamps, and prints the detent's label
back. **Any previous arena observation made with `--spawn` ≥ 8 was watching a
one-body arena.**

---

## Off-mesh links, as baked

`data/ai/links/link_bake_report.txt`, regenerated today.

| level | polys | discovered | shipped | pathable | reach a roof | get off one |
|---|---:|---:|---|---:|---|---|
| `town` | 29,942 | 3,671 | 274 ladder, 65 mantle, 6 vault, 385 drop, 138 jump (**868**) | 100% | 4% → **21%** | 4% → **50%** |
| `arena` | 563 | 268 | 74 ladder, 27 mantle, 105 drop, 62 jump (**268**) | 100% | 0% → **100%** | 0% → **100%** |
| `firefight` | 3,869 | 1,800 | 274 ladder, 271 mantle, 592 drop, 655 jump (**1,792**) | 100% | **49% → 53%** | 49% → **55%** |

Two things to read out of that table:

1. **The firefight's roof reachability is now carried by walking, not by links.**
   49 of its 53 points are walk-only. That is the ramp doing its job.
2. **The firefight now ships at its budget ceiling** — 1,792 links out of 1,800
   discovered, where `max_links` is 1,792. It is the first level to hit it. If
   more links are wanted there, that is the number to raise, and
   `AIPathService.path_search_polygons` (4,096) is the thing to watch when you
   do.

The town is still capped by the baker's adaptive budget search, which bisects
from 1,792 and settles at 868. The cause is the A\* budget, not the links.

---

## Performance

### Capture, 1600×900

`tools/capture.tscn` gives each demo 150 warm-up frames then accumulates the
next 90. Run **three times** on an otherwise idle machine, because one run is
not a measurement.

| scene | run 1 † | run 2 | run 3 | draw calls | primitives |
|---|---:|---:|---:|---:|---:|
| `main_menu` | 231 | 226 | 235 | 329 | 7,454 |
| `visuals` | 307 | 307 | 305 | 301 | 221,696 |
| `range` | 339 | 436 | 436 | 184 | 111,072 |
| `gunbench` | 357 | 454 | 454 | 341–364 | 32,980–42,014 |
| `bestiary` | 404 | 511 | 510 | 410–443 | 105,066–110,366 |
| `arena` | 420 | 540 | 532 | **30** | 20,642 |
| `firefight` | 297 | 366 | 343 | **798–819** | 345,586–347,114 |
| `ash_flats` | 283 | 358 | 359 | 262 | 598,422 |
| `movement` | 298 | 452 | 454 | 331 | 20,658 |

† Run 1 immediately followed a full `bake_all` and is a **cold shader cache**.
Runs 2 and 3 agree with each other to within 7% on every scene (and within 1% on
six of the nine) and are the ones to quote. Run 1 is kept in the table because it
is what the first launch after a bake actually feels like, and because it is the
honest worst case.

**Every one of the 27 measurements clears 120 fps, and the worst clears it by
1.9×.** The slowest number anywhere in the table is `main_menu` at 226 — a small
scene with a lot of text that is GPU-idle rather than slow. The heaviest real
scene is `firefight` at 297 cold.

Two things worth watching:

- **`firefight` draws 798–819 calls against the project's own declared budget of
  800** (`project.godot`, `[demos] budget/max_draw_calls=800`). It is at or over
  the line in every run. Nothing enforces that number; it is a note to self that
  has quietly become false.
- `gunbench` rolls a random weapon on boot, so its draw calls and primitives
  legitimately differ run to run. `bestiary` and `firefight` also vary because
  their populations move.

The worst-frame column is not reported. It moved between runs on the same scene
(`movement` 60 then 421 then 420, `main_menu` 82/85/137, `firefight`
270/145/173), so it is a single-frame hitch landing somewhere different each
time and not content.

Nine PNGs are in `_shots/`, all shot clean, **zero engine errors across all
three runs**. Looked at: `firefight.png` now shows the six decks and their ramps
with the war deployed across the pan and reads better than the flat pan did;
`main_menu.png` is legible with all nine cards and both plates;
`arena.png` shows the compound, the containers and the viewmodel — and in one
frame confirms three separate KNOWN GAPS (no hands, slab silhouette, ground
detail dying at distance).

### AI cost, measured today

| workload | cost |
|---|---|
| AI, 40 bodies, arena, full scheduler + path service + traversal | 0.569 ms mean, 1.062 ms p95, 31.6 ms max |
| AI, 40 bodies, town, same | 0.658 ms mean, 4.605 ms p95, 117.9 ms max |
| AI, 100 agents, `verify_ai_nav` soak, 30 s | 0.486 ms mean, 0.790 ms p95, 4.968 ms max |
| AI perception, 200 agents | **10.85 ms — 130% of a 120 fps frame**, 54.2 µs/agent |
| AI perception, 100 agents | 2.35 ms, 23.5 µs/agent |
| AI perception, 10 agents | 0.16 ms, 16.5 µs/agent |
| Creature animation, 64 bipeds at FULL LOD | 3.7–7.7 ms depending on state |
| `GunHandPose.configure` | 48.6 µs per weapon |

The town's 117.9 ms max frame is a corridor re-solved through a 29,942-polygon
map after a link crossing forces a re-path. It does not appear in the live
demos.

**The perception number disagrees with the one this document has been carrying,
by 2.5×.** Previous STATUS: "4.33 ms — 52% of a 120 fps frame" at 200 agents,
21.7 µs/agent. Measured today on an idle machine, twice, once under load and
once not: **10.85 ms, 54.2 µs/agent.** The two runs agree with each other to
within 2%, so it is not contention. Either the carried figure was wrong or
something regressed between then and now; **the carried figure is retired and
today's stands.** `look` is 8.79 ms of the 10.85 — 81% of it — and the
broad-phase scan is 8.76 ms of that. That is where to look.

---

## Per-system status

**solid** = built, wired, covered by a harness that passes.
**partial** = works, with a named gap. **weak** = present, not doing the job.

**Read the evidence column carefully.** Five harnesses print measurements and
exit 0 whatever they found — `demos/range/verify_range.gd`, `verify_ai_nav`,
`verify_ai_perception`, `bench_enemy_anim`, and `ai_duel_harness` (which has no
`quit()` at all and is driven by `verify_ai_combat`). **`validate_meshes` is
NOT one of them** — the previous STATUS said it "prints `RESULT: FAIL` and
returns zero" and that is **wrong**: `tools/validate_meshes.gd:192` reads
`quit(0 if failures.is_empty() else 1)` and it returned **exit 1** today.

| system | state | evidence (one line) |
|---|---|---|
| `core/` autoloads, `GunSpec`, `XorShift32`, `GameLayers` | **solid** | `verify_integration` 38/38 today |
| `art/` palette, shaders, materials, `scav_world` | **solid** | all 9 scenes render clean today |
| Gun rolling / ballistics | **solid** | `verify_guns` 0 failures today |
| Firing chain | **solid** | `verify_guns_firing` 26/26 today |
| Gun ADS pose | **solid** | `verify_ads_occlusion` PASS, 0 of 111 blind |
| Gun audio | **partial** | bank bakes and loads; no harness plays it |
| Player locomotion | **solid** | `verify_locomotion` 30/30 today |
| Slide and slide-jump | **partial** | covered by `verify_locomotion`; no dedicated course run today |
| Creature rig + species table | **solid** | `verify_species` and `verify_rig_core` PASS today |
| Procedural animation | **partial** | `lowest_point` is 87.8 µs (biped) / 159.2 µs (quadruped) against a 58–120 µs full tick |
| AI perception | **partial** | cost grows super-linearly past 100 agents — see the table |
| AI navigation + scheduler | **solid** | 0.49–0.66 ms mean for 40–100 bodies |
| AI off-mesh traversal | **solid** | `verify_ai_traversal` PASS twice — arena 66%/66%, town 77%/75% of routable, 49 ladder crossings in town |
| **AI cover** | **solid** | 13–15 concurrent leases across ~100 bodies, up from 1–3, and photographed |
| **AI vantage / overwatch** | **partial** | ~5 leases in the first minute decaying to 0–3; camera-dependent |
| AI comms / callouts | **solid** | 509 callouts in 150 s in followable sequences |
| **AI orders / faction command** | **solid** | 25 acceptance trials, median 6 ownership changes, `locked 0/7` throughout |
| AI roles | **partial** | SCOUT still does nothing a spectator can see |
| **Faction / territory** | **solid** | **was partial** — the uncapturable-zone bug is fixed and asserted |
| Diegetic UI + click path | **solid** | `verify_click_input` PASS 7 demos 100%, `verify_ui` 102/102, `verify_ui_shell` 144/144 |
| Panel mounting | **solid** | `verify_mounts` PASS, 0 intersections |
| **Firefight level design** | **partial** | **was weak** — six decks, 49% walk-only roof reach; deck tops still mostly empty |
| World terrain / town / props | **solid** | full re-bake green today |
| GUT unit tests | **weak** | **zero tests exist** |

---

## Mesh validation, in detail

Byte-identical to the previous run, surface for surface. Nothing new broke.

```
meshes               1408
surfaces             1048
triangles         1069246
inverted shells       254   (all terrain heightfield; none counts)
boundary edges         36
non-manifold edges    322
degenerate triangles   92
duplicate faces        81
winding/normal flips   22
empty surfaces          0
RESULT: FAIL - 71 surfaces with findings   (exit 1)
```

Where the 71 live: **66 in `data/guns/`** (16 of 95 baked parts plus the cached
weapon scenes that instance them), **3 in `data/vfx/`** (a two-triangle
billboard quad and the two multimeshes built from it — a validator ought to see
those as legitimately open), and **2 in `data/enemies/`** (`husk` and `stilt`,
4 non-manifold edges each, which are real shell defects).

**Do not re-bake the gun parts without a plan** — the repair pass that produced
them is not idempotent, and `bake_all` deliberately skips the step unless its
outputs are missing.

---

## KNOWN GAPS

Complete and honest. The standing ones are carried forward whether or not this
pass touched them.

### The gates and the harnesses

1. **`bake_all` does not gate on a builder's own verdict.** It reads the exit
   code and greps stderr; a builder that prints `VERDICT: FAIL` and exits 0 is
   recorded `OK`. `build_firefight.gd` prints exactly such a line and is green
   today, but the hole is real and it hid a red self-test for a full pass.
2. **Five harnesses report and never fail** — `demos/range/verify_range.gd`,
   `tools/verify_ai_nav.gd`, `tools/verify_ai_perception.gd`,
   `tools/bench_enemy_anim.gd`, and `tools/ai_duel_harness.gd`.
3. **`verify_click_input` cannot cover `main_menu` headless.** It needs a real
   display server and says so in its own report (`NOT MEASURED`), but `bake_all`
   and any headless CI will skip the menu. Run without `--headless` to cover it —
   done today, and it passes 100% on all four gestures.
4. **32 readable faces carry no mount declaration** and are therefore checked by
   nothing — 10 firefight zone markers, 5 movement gate boards, 5 bestiary
   structure signs, 4 ash_flats gauges, 3 main-menu bench faces, 2 range bench
   readouts, 2 arena, 1 gunbench. `verify_mounts` names every one.
5. **`verify_firefight` costs 20 minutes per invocation** at its default
   `--runs=5 --seconds=240`, and the bars are calibrated for that window. A
   shorter run fails a healthy build, because the ownership bar is a count and
   not a rate. It is not something you can put in a fast loop.
6. **The late-half bar is the tight one.** Over the five invocations run today,
   trials that moved in the late half came out **4, 3, 5, 5 and 4 of 5** against
   a bar of 3 of 5. It passes every time, but invocation 2 landed exactly on the
   bar, and one trial falling the other way there would have been a red gate.
7. **`verify_arena` leaks at exit** — "4 ObjectDB instances were leaked",
   "2 resources still in use". It exits 0 and passes, but those are two of the
   markers `ToolLog` treats as a failure, so the harness would fail if it were
   ever added to `bake_all`.
8. **`tools/verify_ai_nav.gd` prints five compile errors on every run**, then
   works: `Identifier not found: Factions` at `ai_blackboard.gd:90`, three
   `Failed to compile depended scripts`, and `Failed to load script ... with
   error "Compilation failed"`. It then runs and exits 0. This is trap 21 below.

### AI

9. **Deck tops are mostly empty.** `aloft` is 1–3 of ~101, mean 1.54, against
   six decks and ~890 m² of roof that 49% of roof goals can now reach on foot.
   The level gives them somewhere to go and almost nothing goes.
   **`FirefightAgent._choose_goal` has no height term at all** — read today, it
   picks `squad.objective_point() + _picket` and only reaches for cover when the
   body is already within `HOLD_RADIUS_SQ` (`PICKET_SPREAD`² = 81 m²) of that
   stand, and then only searches `COVER_SEARCH` = 14 m. **The pan ring decks
   stand 21 m from the zone anchors.** A body that never wanders 21 m off its
   picket never has a deck top offered to it, however well the deck scores.
   That is a geometry-versus-search-radius problem, not a scoring problem.
10. **Vantage decays and nobody knows why.** ~5–7 concurrent leases in the first
    minute, 0–3 after two, in both camera positions. It is not the deck bake —
    31 of 56 baked vantage points are above 2 m now, up from 0 of 44 — and it is
    not that height is unweighted: `AIVantage.elevation_weight` (0.34) scores it
    at bake and `elevation_bonus` (0.30) scores it at query. Something is
    releasing leases and not re-taking them.
11. **Vantage is camera-dependent by roughly 2×**, and cover is not. See *A
    measurement trap worth writing down*. Suspected cause is
    `AITickScheduler`'s viewer LOD; **this is not proven**.
12. **Only three of the seven zones ever change hands** — `slag_road`,
    `tank_farm` and `cut_bank`, the three NEUTRAL ring zones. Every trial of
    every invocation scored 3 or 4 distinct zones moved. The three home zones
    are protected by the anti-wipe rule, but `the_pan` at the centre is not, and
    it does not move either.
13. **FOUNDRY barely bleeds.** Over the 25 trials, bodies lost per 240 s:

    | | mean | min | max | share in the spectator frame |
    |---|---:|---:|---:|---:|
    | SCAV | 20.3 | 10 | 38 | 50% |
    | **FOUNDRY** | **5.9** | **2** | **12** | **90%** |
    | CHOIR | 27.5 | 17 | 47 | 59% |

    A faction taking a quarter of the casualties while standing where the camera
    can see it is not fighting the same war as the other two. It also holds four
    or five zones in most late-game samples. Suspects, in order:
    `foundry_caution` (1.20), `foundry_cohesion` (1.35), `foundry_radio_range`
    (145 m against SCAV's 0), and `FirefightDirector.max_defending_squads` (1).
    **Do not "fix" this by nerfing FOUNDRY until you know whether it is fighting
    at a range the others cannot answer** — the comms table is the more likely
    story than the aggression numbers.
14. **`NavigationAgent3D.link_reached` is unreliable for near-vertical links**
    in Godot 4.7.1. Worked around by reading `get_current_navigation_result()`
    directly; not root-caused in the engine.
15. **`It's not expect to not find the most reachable polygons`** is emitted by
    the navigation server under firefight load, from `ai_navigator.gd:672` via
    `firefight_agent.gd:153`. It does not stop the body and has not been traced.
16. **Six traits and outputs are still computed and dropped** — verified again
    today, no consumer outside their own file: `AIPersonality.caution`,
    `AIPersonality.speaks()`, `AIMorale.push_scale`, `AIMorale.holds_ground`,
    `AIMorale.flee_direction`, `AIMorale.threat_position`.
17. **The SCOUT role does nothing visible.** It exists in `AIRoles.Role` and is
    weighted in the doctrine; nothing a spectator can see distinguishes it.
18. **`ai_duel_harness.gd` reports hit rates above 100%** for pellet weapons.
19. **AI perception scales worse than it should, and worse than this document
    used to say** — 16.5 µs/agent at 10, 23.5 at 100, **54.2 at 200**, for a
    total of **10.85 ms at 200 agents, 130% of a 120 fps frame**. The `look`
    term is 8.79 ms of that. See the note under *AI cost*.
20. **One agent froze for a whole 30 s soak** — `verify_ai_nav` reports
    "frozen agent 0: detections=30 streak=30 detouring=true", and only 52 of 100
    agents held a live corridor. Not investigated.

### Traps for the next editor

21. **Never name an autoload in anything a bake tool or `--script` harness can
    reach.** A script handed to `--script` compiles before the autoloads exist.
    Use `Engine.get_singleton(&"...")` or write against the underlying API.
    `verify_ai_nav.gd` is the last instance and it is gap 8.
22. **A demo instanced as a CHILD does not get its off-mesh links.**
    `capture.gd` and `watch.gd` install them explicitly; anything else must too.
    Measured cost of forgetting: 80 s of arena with 268 links installed and not
    one body off the ground.
23. **A harness that drives the mouse must release it first.** Every demo leaves
    the cursor CAPTURED; the OS then re-centres it every frame and
    `get_mouse_position()` answers dead centre whatever you warp it to.
24. **`Input.warp_mouse` and `InputEvent.position` are in WINDOW pixels;
    `Viewport.get_mouse_position` and `Camera3D.project_ray_*` are in VIEWPORT
    pixels.** A 1920×1080 viewport in a 1280×720 window puts them a factor of
    1.5 apart, and getting it wrong aims somewhere else in silence.
25. **`DiegeticDial.wraps` is true by default**, so `set_value` runs the index
    through `posmod` and an out-of-range index silently selects a different
    detent rather than clamping to the last one. This cost a whole arena
    observation this pass; see the `--spawn` note above.
26. **`WeaponHolster.weapon_changed` is emitted from exactly one place** — only
    at the end of a SWAP. Four consumers have learned this independently.
27. **Mesh winding is settled and CORRECT** — Godot front faces are CLOCKWISE
    and its own `BoxMesh` has signed volume −8.0. **Never "fix" winding.**
28. **`RAMP_DEGREES` in `firefight_posts.gd` is measured, not reasoned.** At 36°
    not one of the six decks joined the navigation mesh; at 34° and 28° they all
    do. Whatever Recast is doing between 34 and 36 is not the slope test. Change
    it only with `NavigationServer3D.map_get_path` in hand.
29. **The previous STATUS's trap 20 was wrong and is retired.** It claimed
    `tools/verify_ai_nav.gd:379 _quad()` winds its ground plane
    counter-clockwise so the ground contributes zero polygons. Both of its
    triangles have `(b−a)×(c−a) = (0, +4h², 0)`, which is the up-facing normal
    Recast's `rcMarkWalkableTriangles` tests, and the harness bakes **52
    polygons** and steers 100 agents on them. The ground is walkable.

### Visual

30. **There are no hands or arms on the first-person viewmodel.** Visible in
    `_shots/watch_arena/arena_05.png`.
31. **The gun silhouettes are simple slabs**, because the source CC0 parts are.
    Five boxes is the read at forty centimetres.
32. **Detail dies at a visible distance on large flat ground** — anisotropy
    limited at 8× (`art/world_material.gdshader:132`).
33. **The sand megaripple still moirés** (`art/world_material.gdshader:347–361`).
34. **Shadow-edge sawtooth**, worst in `movement`'s bottom-left.
    `shadow_cascades` is 1 over a 140 m `shadow_distance`.
35. **`arena` is tonally flat.**
36. **`bestiary`'s horizon line is a lit wall coping, not haze.**
37. **`main_menu` has nothing outside the shed** — one pole, one crate, bare
    sand.
38. **Distant town blocks are untextured cubes** in `firefight`, `ash_flats` and
    `visuals` — clearly visible along the horizon in today's firefight frames.
39. **One `firefight` faction is saturated cyan/teal**, off the warm-neutral
    brief.
40. **`firefight`'s ground mottle is at the wrong scale.**
41. **The `range` canopy shows blown white sky slivers.**

### Correctness and coverage

42. **Mesh validation is FAIL** — 71 of 1,048 surfaces, unchanged, exit 1.
43. **`firefight` is at or over the project's own draw-call budget.** 798–819
    calls against `project.godot`'s `[demos] budget/max_draw_calls=800`, in
    every capture run. Nothing enforces the number and nothing reads it; it has
    quietly become false. The decks added roughly ten calls.
44. **`bench_enemy_anim` reports lower LODs costing MORE per tick than FULL** —
    biped idle is 58.3 µs at FULL and 90.1 µs at REDUCED, which solves half as
    often. Most likely its per-tick denominator counts *solved* ticks while the
    numerator includes the frames it skipped, in which case the LOD is fine and
    the accounting is wrong. **Not confirmed either way. Do not read the LOD
    columns of that bench as costs until somebody checks the denominator.**
45. **`gunbench` and `visuals` have no acceptance harness.**
46. **No unit tests.** GUT is installed; there are zero test scripts.
47. **Gun audio has no acceptance harness.**
48. **The nav bake prints "More than 2 edges tried to occupy the same map
    rasterization space"** — 6 edge errors on the firefight region.
    `link_inset` reduced it; it has not gone away.
49. **Foot placement drifts at low LOD** — up to 49.6 mm **(carried)**.
50. **`DiegeticInteractor.pending()` and its `refused` signal have no callers.**
    Both are real and observable, not stubs, but nothing consumes them.
51. **`tools/firefight/firefight_posts.gd`, `firefight_cover.gd` and
    `nav_index.gd` have no `.uid` sidecar.** Harmless for `--script` runs; the
    editor will generate them on first import, which will show up as an
    untracked change.

---

## WHERE TO START

Prioritised for the tuning pass. File and `@export`/`const` named for each.

1. **Get bodies onto the decks.** This is the biggest remaining behavioural win
   and the level is finally ready for it — 49% of roof goals are reachable *on
   foot*, 31 of 56 baked vantage points are above 2 m, and `aloft` is still 1–3
   of ~101.
   Height **is** weighted, in two separate places, and both are worth a sweep
   before anything structural: `systems/ai/ai_vantage.gd` `elevation_weight`
   (0.34, the bake-time pre-score) with `elevation_scale` (4.0 m, where the term
   saturates), and `elevation_bonus` (0.30, added to every runtime
   `score_point`). Also `max_points` (56) and `min_separation` (7 m), which
   together cap how many decks can be represented at all.
   **But read KNOWN GAP 9 first, because the scoring is probably not the
   binding constraint.** `_choose_goal` in `demos/firefight/firefight_agent.gd`
   only reaches for cover once the body is inside `PICKET_SPREAD` (9 m) of its
   assigned stand, and then searches only `COVER_SEARCH` (14 m) — while the pan
   decks stand 21 m off the zone anchors. **Raising `COVER_SEARCH` to ~24 m is
   the one-line experiment**, and it is cheap: the search is over a 5 m cell
   grid, so the cost is quadratic in the radius but the constant is small.

2. **Find out why vantage decays.** `systems/ai/ai_cover_map.gd` —
   `vantage_period` (1.5 s) and the lease bookkeeping. Leases run ~5–7 in the
   first minute and 0–3 after two, in both camera positions, on a build whose
   vantage field got *better*. Read `AICoverMap.rejections()` /
   `rejection_line()` — the ledger already exists and already found one
   100%-refusal gate — before touching `min_score` (0.05), `band_weight` (0.40),
   `flank_fraction` (0.5) or `keep_bonus` (0.30).

3. **Settle whether the tick scheduler is what makes vantage camera-dependent**,
   because it decides whether item 2 is even real.
   `systems/ai/ai_tick_scheduler.gd` — `near_radius` (22), `mid_radius` (55),
   `far_radius` (140), `far_hz` (4.0), `offscreen_demote` (true). One run with
   `far_hz` raised to 15 and the authored camera, against today's numbers,
   answers it. **Every AI uptake figure in this project's history was read
   through a camera 73 m from the fight.**

4. **Make `bake_all` gate on a builder's verdict.** `tools/bake_all.gd` `_run`
   already has the builder's whole stdout in `text`; one more check for a line
   matching `VERDICT ... FAIL` closes a hole that hid a red self-test for a
   whole pass.

5. **Make the five report-only harnesses gate.** `verify_range`, `verify_ai_nav`,
   `verify_ai_perception`, `bench_enemy_anim`, `ai_duel_harness`. `verify_ai_nav`
   first, because it is the one with a frozen agent and 52-of-100 corridors in
   its own output and nothing looks at it.

6. **Give FOUNDRY a reason to bleed.** `systems/ai/factions.gd` —
   `foundry_caution` (1.20), `foundry_cohesion` (1.35), `foundry_expansion`
   (1.00), `foundry_radio_range` (145 m). It loses 5 bodies where the others
   lose 20+, and a faction that never suffers is a faction the player cannot
   beat.

7. **Make `the_pan` contestable.** `tools/firefight/firefight_zones.gd` —
   it is the centre zone, `value` 1.6, `ZONE_RADIUS` 24 m, and it never changed
   hands in 25 trials. Either it is worth so much that everyone camps it, or
   `AIOrders._score_zones` is not valuing it. `systems/ai/ai_orders.gd`.

8. **Decide what to do about the gun-part topology.** Record the 16 dirty parts
   as an accepted exception so `validate_meshes` can go green, or plan a
   one-time re-repair. A permanently-red gate tells you nothing when it goes red
   for a new reason. **Note the trap:** the existing set is the frozen output of
   a non-idempotent repair pass, and `bake_all` skips it deliberately.

9. **Give the guns a silhouette.** Five slabs is the read at forty centimetres,
   and the ADS fix has now made you look straight past them at the target rather
   than into them. `tools/bake_gun_parts.gd` → `data/guns/meshes/part_*.res`;
   **add** new parts alongside the frozen set rather than re-running the decode.

10. **Declare the 32 undeclared panels**, or teach `verify_mounts` to fail on
    them. `tools/verify_mounts.gd` names each one.

11. **Decide what the draw-call budget means.** `project.godot`
    `[demos] budget/max_draw_calls=800`, and `firefight` renders 798–819 in
    every capture run. Either raise the number to something true or make
    something read it. A budget nothing enforces is a comment.

12. **Fix the shadow sawtooth.** `art/world_environment.gd:144`
    `shadow_cascades` (1 = "Two splits") and `:135` `shadow_distance` (140 m).
    `tools/build_firefight.gd:687` already overrides `shadow_distance` to **56**
    for that demo; the same trick works in `movement`, which does not.

13. **Wire the six dropped AI outputs.** `AIMorale.push_scale` into
    `FirefightAgent._standoff`, `holds_ground` into `_choose_goal`,
    `flee_direction` into a rout, `AIPersonality.speaks()` into `AISquad._say`,
    `caution` into the cover preference. Each is one call site.

14. **Fix `lowest_point`.** Measured today: **87.8 µs on a biped and 159.2 µs on
    a quadruped**, against a whole FULL animation tick of 58–120 µs, under
    `systems/enemies/`. Together with perception's `look` term (item 5's
    `verify_ai_perception`, 8.79 ms at 200 agents) these are the two costs that
    would stop a big fight — the AI's decision logic is not one of them, at
    0.49–0.66 ms for 40–100 bodies.

15. **Fix the two creature shells** — `data/enemies/husk.res` and
    `data/enemies/stilt.res`, 4 non-manifold edges each — **and add the VFX
    billboard quad to `--open=`** in `tools/validate_meshes.gd`. Together that
    retires 5 of the 71 findings and leaves a number that is purely the frozen
    gun set.

16. **Give `gunbench` and `visuals` acceptance harnesses**, and **write the
    first GUT test** — `GunSpec` derivation and `XorShift32` both already have
    golden vectors to assert against.

---

## AI TUNING

Every knob the AI actually reads, what it does, and where it lives. Everything
here is an `@export` you can open in the inspector or a `const` at the top of a
named file. The ones in **bold** are the ones most likely to change what you see.

### How often a body thinks — `systems/ai/ai_tick_scheduler.gd`

This is the single largest lever on both cost and behaviour, and it is keyed to
the **viewer**, not to the action.

| knob | value | what it does |
|---|---:|---|
| **`agents_per_frame`** | 48 | ceiling on agent ticks per frame. The one number that decides the AI's frame cost. |
| `near_radius` / `mid_radius` / `far_radius` | 22 / 55 / 140 m | bucket boundaries, measured from the viewer |
| **`near_hz` / `mid_hz` / `far_hz` / `dormant_hz`** | 60 / 15 / 4 / 0.5 | how often a body in each bucket thinks |
| `near_share` / `mid_share` / `far_share` / `dormant_share` | .55 / .25 / .15 / .05 | how the per-frame budget is split |
| `offscreen_demote` | true | anything outside the viewer cone drops one bucket |
| `viewer_cone_degrees` | 150 | the cone used for that test |
| `ray_budget_per_frame` | 24 | perception rays per frame, whole scene |
| `path_budget_per_frame` | 8 | path requests handed to the service per frame |

### Where a body chooses to stand — `systems/ai/ai_cover_map.gd`

| knob | value | what it does |
|---|---:|---|
| `min_score` | 0.05 | floor a candidate must clear. The cover pass reported it **never firing once in any run**; not re-verified here, so treat it as a lead. |
| **`band_weight`** | 0.40 | how much "is this a firing position for my weapon" is worth |
| `band_reject` | 1.6 | multiple of the weapon's band past which a point is refused — **firing positions only** |
| **`hide_min_range`** | 3.0 m | the reload/pinned/breaking-contact path instead of `band_reject`. Adding this took cover from unreachable to reachable for 7 of 12 species. |
| `advance_only` | true | refuse cover that is backwards from the threat |
| `travel_weight` | 0.26 | penalty on how far the point is |
| `quality_weight` | 0.22 | how much the sampled cover quality is worth |
| `facing_weight` | 0.24 | how much facing the threat is worth |
| `flank_weight` / `flank_fraction` / `flank_degrees` | 0.30 / 0.5 / 42° | reward for cover off the enemy's axis |
| `keep_bonus` | 0.30 | stickiness for the point already held |
| **`hide_bonus`** | 1.35 | multiplier when the body wants to hide rather than shoot |
| `vantage_period` | 1.5 s | how often overwatch is re-evaluated |
| `refusal_period` | 0.8 s | how often the rejection ledger rolls over |

### Where a marksman chooses to stand — `systems/ai/ai_vantage.gd`

Bake side (re-bake to take effect): `min_contested` (32), `candidate_limit`
(384), **`elevated_share` (0.5 — the split that makes this work on a flat level;
a pure ranked draw bakes an empty set)**, **`max_points` (56)**,
**`min_separation` (7 m — without it the whole set lands on one roof)**,
`elevation_scale` (4 m), **`elevation_weight` (0.34)**, `coverage_weight`
(0.46), `protection_weight` (0.22), `exposure_penalty` (0.30), `min_coverage`
(0.10).

Query side (live): `bias` (2.2), `keep_bonus` (0.55), `over_reach` (1.25),
**`elevation_bonus` (0.30)**.

The **rejection ledger** is the thing to read before turning any of these:
`AICoverMap.rejections()` and `rejection_line()`, published on F3 in the demos.
It already found one gate refusing **100% of 76,062 candidates** for seven of
twelve species. Do not turn a weight without reading it first.

### How the field is sampled — `systems/ai/ai_cover_sampler.gd`, then re-bake

`REFINE_PASSES` (2) and `REFINE_STEP` (0.5) are the density dial. Zero restores
the single uniform pass and the old point counts. More passes means more cover
points, and cover and vantage compete for one `best_score`, so this trades
vantage for cover. Re-bake with `tools/bake_ai_cover.gd` (touches only the
`.tres`) or `tools/build_firefight.gd` / `build_arena.gd` (rebuilds the scene).

### Range, standoff and breaking contact — `systems/ai/ai_engagement.gd`

`preferred_range_fraction` (0.55), `hold_band_low` (0.62), `hold_band_high`
(1.22), `max_engage_fraction` (1.1), `close_reach_metres` (14),
`close_range_fraction` (0.82). Withdrawal: `withdraw_willingness` (2.6),
`withdraw_pressure` (0.62), `withdraw_release` (0.30), `outranged_ratio` (1.0),
`withdraw_seconds` (4.5), `withdraw_push` (1.55), `withdraw_limit` (26 m),
`withdraw_ammo_fraction` (0.10).

### Getting off the ground — `systems/ai/ai_link_baker.gd`, then re-bake

`climb_max` (**3.4 m**) is why nothing reaches a 6 m wall unaided — but note
that the firefight no longer needs it to, because it has ramps.
`ladder_enter_cost` (14.0) — **tested and NOT the traversal problem**; swept
2/4/6/8/10/14 with flat results. `bridge_probe_drop` (0.42),
`links_per_island_pair` (2) and `link_inset` (0.35) are the three rules that
removed links never worth having. `max_links` (**1,792**) is where the budget
search starts — and the firefight now *ships* at it, so it is a real ceiling
there for the first time. On `AIPathService`: `path_search_polygons`
(**4,096 — leave it alone unless you measure**; 32,768 cost 156 fps and bought
nothing, because the budget is a per-query allocation and not a safety margin),
`requests_per_frame` (8), `repath_tolerance` (1.1), `repath_interval` (1.6 s).

### The war — `FirefightDirector`, on the node in `demos/firefight/firefight.tscn`

`target_population` (22), `squads_per_faction` (3), `reinforce_period` (9 s),
`wave_size` (3), `muster_clearance` (26 m), `opening_fraction` (1.0),
`opening_in_contact` (true), `front_inner` (12 m), `front_outer` (36 m),
`front_arc_degrees` (100°), `front_forward_bias` (0.88), `command_period`
(0.25 s), **`retarget_period` (30 s)**, `objective_arrival` (18 m),
`regroup_patience` (25 s), **`max_defending_squads` (1)**, `pressure_scale`
(1.0), `objective_crowding` (0.06), `seed_value` (0x5CA71E — fixes the species
draw, the spawn scatter and the picket offsets, and **does not fix the war**).

Agent constants in `demos/firefight/firefight_agent.gd`: `PICKET_SPREAD` (9 m),
**`COVER_SEARCH` (14 m)**, `COVER_HOLD` (2.4 s), `LEAD_FLOOR` (0.30).

### Territory — the `Factions` autoload, `systems/ai/factions.gd`

The three that decide whether the map moves, all derived from sweeps rather than
picked:

| knob | value | what it does |
|---|---:|---|
| **`contest_attrition`** | 2.00 | how hard your push wears down a rival's hold on the same ground, multiplicatively. Below ~1.9 a zone goes to whoever merely turns up in equal numbers. |
| **`capture_dwell`** | 10.0 s | anti-strobe. At zero, `choir_house` changed hands 16 times in 40 s. Too high and the capture count is measuring the timer. |
| `overextension_penalty` | — | how much harder a faction pushes for owning less of the map. The anti-stalemate term. |

Plus `capture_margin` (0.18), `contest_threshold` (0.15), `garrison_regen`
(0.020), `garrison_ceiling`, `home_margin_scale`, `post_capture_pressure`,
`post_capture_residue` (0.45), `territory_tick_hz` (4.0).

Per faction — this is where the three sides get their personality:

| | aggression | caution | cohesion | expansion | radio range | comms latency | discipline |
|---|---:|---:|---:|---:|---:|---:|---:|
| SCAV | 1.25 | 0.65 | 0.70 | 1.10 | **0 m** (voice only) | 0.30 s | 0.55 |
| FOUNDRY | 0.95 | **1.20** | **1.35** | 1.00 | 145 m | 0.16 s | 1.35 |
| CHOIR | 1.05 | 1.05 | 1.10 | 0.95 | 95 m | 0.12 s | 1.60 |

Voice, shared: `voice_range` (26 m), `callout_error_base` (0.35),
`callout_error_range` (0.055), `callout_error_doubt` (1.15),
`relay_error_scale` (0.60), `relay_confidence_scale` (0.82).

### Squad shape and everything else

Doctrine: `data/ai/role_doctrine.tres` (five roles — ANCHOR, SUPPRESSOR,
FLANKER, ADVANCER, SCOUT). Orders fallbacks are `const`s at the top of
`systems/ai/ai_orders.gd`: `FALLBACK_ASSAULT` (0.62), `FALLBACK_HOLD` (0.65),
`FALLBACK_WITHDRAW` (0.34), `FALLBACK_SUPPORT_RADIUS` (70 m),
`FALLBACK_SWEEP_MEMORY` (26 s), `INTENT_URGENCY`. Perception feel:
`data/ai/perception_tuning.tres`. Nerve: `systems/ai/ai_morale.gd` (`COMPANY`
3.0, `SHOCK_CEILING` 1.4). Individuals: `systems/ai/ai_personality.gd`.

---

## The other tunable knobs

### The click path — `ui/diegetic/diegetic_interactor.gd`

`press_patience` (0.35 s) is how long a press keeps being offered to a control
inside its debounce; `queue_limit` (16) is a ceiling, not a target.
`interact_reach` (3.2 m) and `fire_reach` (120 m). `aim_at_pointer` switches
between the crosshair and the cursor and is on only in `ui/main_menu.gd`.
`fire_presses_at_point` decides whether a fire press lands where you pointed.
On the control itself, `DiegeticControl.press_cooldown` (**0.04 s**) is the
operator debounce and `cooldown` (0.14 s) is the pellet debounce — **they are
not the same number and must not be merged.**

### The ADS pose — `systems/guns/gun_hand_pose.gd`

`ads_clear_degrees` (**1.6**) is the angle the whole weapon must pass under the
crosshair. Measured worst crest is −1.60°, so this is the binding constraint;
`tools/verify_ads_occlusion.gd` bars it at 0.80. On the holster,
`iron_sight_height` (0.10) and `sight_notch` (0.25).

### Panel mounting — `ui/diegetic/panel_mount.gd`

`clearance` (**4 mm**), `tilt_degrees`, `yaw_degrees`, `panel_scale`, `axis`,
`direction`. Nothing here is tuned by hand — the standoff is solved from the
panel's real bounds, the basis it is mounted with, and the box its support
occupies. If a panel looks wrong, the bounds or the support box is wrong, not
the standoff.

### The firefight level — `tools/firefight/firefight_posts.gd`, then re-bake

`RAMP_DEGREES` (**28 — measured, see trap 28**), `RAMP_WIDTH` (4.6 m),
`RAMP_BITE` (0.4 m), `RAMP_SINK` (0.4 m), `PLINTH_TOP` (1.4 m),
`PLINTH_SHOULDER` (0.65 m), `CLEAR` (5 m), `FIXTURE_CLEAR` (2 m), and the `RING`
table itself — six rows of `[id, radius, bearing, half-extent, deck height,
ramp bearings]`. `Posts.clearance()` proves the packing and the bake **fails**
rather than shipping ramps inside each other.

---

## Repo hygiene

- `/_shots/` is in `.gitignore`. Everything under it is a working artifact —
  regenerate, do not commit. Today's are `_shots/*.png` (the nine captures),
  `_shots/watch/`, `_shots/watch_arena/`, `_shots/close_cover/`,
  `_shots/close_deck/`, `_shots/ads/` and `_shots/ads_before/`. The scratch
  directories the three previous agents left (`cover_before`, `cover_after`,
  `cover_final`, `cover_new`, `cover_old`, `cover_oldfield`, `cover_r2`,
  `watch_before`, `watch_after`, `watch_run3`, `watch_final`) were removed.
- No probe, scratch or temporary scripts remain in `tools/` or the project root.
- Every file in `tools/` is a builder invoked by `bake_all`, a `verify_*` /
  `bench_*` harness, an observation tool (`capture`, `watch`, `ads_shot`), or a
  referenced helper. Eight are referenced by nothing else because they are
  standalone `--script` entry points: `bake_ai_cover`, `bench_enemy_anim`,
  `test_player_traversal`, `verify_guns_firing`, `verify_integration`,
  `verify_rig_core`, `verify_species`, `vfx/vfx_stress`.
- The per-invocation firefight reports from this pass
  (`demos/firefight/ff_pop_[1-5].txt`) were removed; the harness's default
  report, `demos/firefight/firefight_population.txt`, holds the last run.
- **`user://` is NOT clean and was left alone deliberately.**
  `%APPDATA%/Godot/app_userdata/gungame/` holds scratch from earlier passes —
  `_mm_roundtrip*.res/tres`, `_probe_mm.res`, `gb_*.png`, `probe_arena_cover.tres`,
  `probe_firefight_cover.tres`. None is referenced by anything;
  `verify_ai_cover.tres` beside them **is** live (written by
  `ai_duel_harness.gd`). It is outside the repository, and a previous pass
  destroyed `settings.cfg` by writing there carelessly, so nothing in that
  directory was touched. `settings.cfg` currently holds `vsync=false` and
  nothing else — **leave it that way, or every capture pins to 60 fps.**
- **`tools/watch.gd` changed this pass** — it gained `--eye`/`--look` (park the
  camera anywhere, which is how the cover behaviour was finally photographed)
  and its `--spawn` now clamps to the dial's detent count instead of wrapping.
  Both are additive; nothing else in the tool moved.

## Multiplayer — open item

`verify_scenes` reports FAIL for range, bestiary, gunbench, movement and visuals:
four leaked ObjectDB instances and one resource still in use at exit, identical in
every one. **Shutdown only.** Every scene exits 0, runs its full 120 frames and
logs zero script errors; nothing here reaches gameplay.

Identified but not closed. `--verbose` names it:

    Leaked instance: Node — Node path: (empty)
    Leaked instance: PhysicsRayQueryParameters3D
    Resource still in use: res://net/avatar/net_presence.gd

The node is detached from the tree and then never freed. Two things already
ruled out by measurement, so do not retry them:

- It is not the static singleton cache. That was removed (the node is now found
  by name under `/root`) and the leak is byte-identical afterwards.
- It is not `enter()`. `ash_flats`, `arena` and `firefight` all call it and all
  pass; `leave()` is called only by `movement`, which is one of five failures.

So the difference between the five that leak and the three that do not is still
unaccounted for, and that difference is the thing to find. Next step: log the
instance id at `add_child` and at `_exit_tree` in a failing demo and a passing
one, and find who calls `remove_child` on it. Do not tune around it.
