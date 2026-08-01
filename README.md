# gungame

A Godot 4.7 port of a browser scavenger-shooter prototype: procedurally rolled
guns assembled from 95 baked donor parts, twelve procedurally rigged creatures,
a hand-graded town on a heightfield, and eight demo levels that each put one
system in front of you on its own.

Forward+, Jolt, d3d12. Windows. GDScript only — there is no C#, no GDExtension
and no runtime geometry generation.

---

## Running it

Open the project in Godot **4.7.1-stable** and press F5. The boot scene is
`res://ui/main_menu.tscn`: a workbench with a stencilled plate per demo. Look at
a plate and click it.

Everything the game draws is already on disk. Nothing is generated at load.

---

## The demos

| id | name | what it is |
|---|---|---|
| `range` | SCAV RANGE | Four hundred metres of dirt, twenty-two targets, and a bench that rolls you a new weapon when you shoot the lever. Scoring follows `docs/spec/range.md` §13.2. |
| `bestiary` | BESTIARY | Twelve plinths in three bays, one creature each, all walking the same clip at the same pace so you can compare them. Two control desks; no screen text. |
| `ash_flats` | ASH FLATS | The open level. One dead town on a dry river, patrols, ladders, landing pads with their own gauges. Terrain, town, props, creatures — all instanced as baked. |
| `firefight` | FIREFIGHT | Three factions fight over seven pieces of ground with nobody's thumb on it. You are a camera with no collider; nothing can see you. Fly-to posts and a sim-rate dial. |
| `arena` | ENEMY TEST ARENA | A walled compound with four gates and a control desk you shoot. Put any species in front of any gun. |
| `gunbench` | GUN BENCH | The reading room for the gun system. Roll, filter, hold, strip into five labelled parts, hang on the rack, compare two weapons field by field. |
| `movement` | MOVEMENT BENCH | Ledges, gaps, slopes and a stopwatch, with a console of dials over the locomotion constants. |
| `visuals` | THE FLATS AT DUSK | Nothing to shoot. A settlement under a low sun and a control post from which you change how it looks. |

Demo ids are frozen — `SceneRouter.DEMOS` is the only registry and the menu is
the only caller of `go()`.

---

## Controls

Keyboard/mouse, with a gamepad binding on every action.

| | |
|---|---|
| Move | `W` `A` `S` `D` |
| Jump | `Space` |
| Crouch / slide | `C` |
| Sprint | `Shift` |
| Fire | Left mouse |
| Aim | Right mouse |
| Reload | `R` |
| Interact | `F` |
| Weapon slots | `1` `2` `3` |
| Cycle weapon | Mouse wheel |
| Freecam | `F8` |
| Pause | `Esc` |
| Developer overlay | `F3` |
| Render debug mode | `F4` |
| Debug draw channel | `Ctrl` + `1`…`9` |
| Screenshot | `F12` |

`Ctrl` is required on the debug-draw numbers because bare `1`/`2`/`3` are weapon
selects. It carries nothing else — crouch used to sit on it, which meant every
debug-channel toggle also ducked the player.

UI is diegetic. Apart from the main menu, the pause menu, settings and the F3
overlay, every control in this project is a physical object you look at and press
`F` — or shoot, which routes through the same call.

---

## Re-running the bake

Every mesh, texture, material, navmesh, cover set and demo scene is produced by a
headless builder under `res://tools/` and committed as a `.res` / `.tres` /
`.tscn`. The builders are reproducible; the artifacts are what ships.

```
godot --headless --path <project> --script res://tools/bake_all.gd
```

`bake_all.gd` runs all 25 steps in dependency order, one subprocess each, and
writes `res://data/bake_all_report.txt`. Useful flags after a bare `--`:

```
--list            print the plan and exit
--only=art,vfx    run only these steps
--from=player     start here and run to the end
--skip=ash_flats  run everything but these
--missing-only    skip a step whose outputs are already on disk
--stop-on-fail    abort at the first failure
```

The 95 gun-part meshes are decoded from the reference HTML and repaired once;
`gun_parts` is flagged `missing_only` and is skipped unless the files are gone.
Do not re-bake them casually — the repair pass is expensive and the current
output is the reference for everything downstream.

Adding a new scene means writing a builder, not hand-editing a `.tscn`. Copy the
structure of `res://tools/bake_gun_parts.gd`: build the node tree in code,
`PackedScene.pack(root)`, `ResourceSaver.save(...)`, `quit()`.

### Verification

```
godot --headless --path <project> --script res://tools/verify_scenes.gd
godot --headless --path <project> --script res://tools/validate_meshes.gd
```

`verify_scenes` boots every demo as its own process for 120 frames with the real
autoloads up, then instances every prefab into one live tree; it reads the
console rather than the exit code, because Godot exits 0 after a compile error.
`validate_meshes` walks every baked mesh and reports shells, signed volume,
inverted shells, boundary edges, non-manifold edges, degenerate triangles and
duplicate faces.

The rest of `res://tools/verify_*.gd` are per-system acceptance harnesses (guns,
firing chain, species, rig, UI, AI perception/nav/combat, integration, MultiMesh
population). `res://docs/STATUS.md` records what each of them currently says.

### Style gates

```
gdformat core art systems ui demos tools
gdlint   core art systems ui demos tools
```

Both are clean at HEAD. Config lives in `gdlintrc` (100-column lines,
1000-line file cap, ordered class definitions).

---

## Layout

```
core/        autoloads and the frozen data types — GameSettings, SceneRouter,
             PartLibrary, GunSpec, GunPart, XorShift32, GameLayers
art/         Palette, the three shaders, the 18 materials, scav_world.tscn
systems/
  player/    controller, camera, locomotion, mantle/vault/ladder, view effects
  guns/      GunFactory, assembler, ballistics, fire control, recoil, spread,
             reload, jam, hitscan, projectiles, viewmodel, audio
  enemies/   species table, procedural rig, gait/pose/death solvers, spawner
  ai/        Factions, perception, memory, cover, navigation, squads, scheduler
  vfx/       pooled muzzle flashes, tracers, decals, shells, smoke, explosions
  world/     terrain field, mesher, town layout, prop kits, queries
ui/          main menu, pause, settings, diegetic controls, HUD, F3 overlay
demos/       the eight levels — scripts beside their baked .tscn
data/        every baked artifact, plus the bake and verification reports
tools/       the builders and the verification harnesses; bake-time only
docs/spec/   8,442 lines of transcribed reference spec — range, bestiary, world
reference/   the source HTML prototypes
```

**Autoloads**, in load order: `GameSettings`, `Factions`, `PartLibrary`,
`GunFactory`, `SceneRouter`, `DebugHUD`.

`SceneRouter` is the only writer of `get_tree().paused` and `Input.mouse_mode`.
It consumes the `pause` action and emits `pause_changed`; the pause menu listens.

Gun parts are modelled at 1 unit = 90 mm; a gun is scaled by 0.09 to sit in the
world. Player height is 1.8 m, eye at 1.65 m. Down-range on the shooting range is
`-Z`.

---

## Known state

See `docs/STATUS.md` for the honest per-system table, the open defects and what
a next pass should pick up first. The short version: the bake is green, all nine
scenes load clean headless, and `validate_meshes` reports 71 of 1,048 surfaces
with findings — 66 of them in the frozen gun-part set.
