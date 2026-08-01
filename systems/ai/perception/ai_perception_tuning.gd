class_name AIPerceptionTuning
extends Resource
## Every number perception, memory, the noise bus and the alert machine argue
## about, in one inspectable place.
##
## The species profile answers "how far can this thing see" — that is biology and
## it belongs to the creature. This answers "how twitchy is the whole game" — the
## hysteresis gaps, the dwell times, the decay rates, how loud a rifle is. Those
## are one global feel decision, and having sixteen species resources each carry
## their own copy of the same forty numbers would make tuning that feel a
## sixteen-file edit.
##
## Nothing here is read per frame. Perception and the alert machine copy what they
## need at bind time; the noise bus takes its copy through `apply_to_bus`.

## Where the baked default lives. Built by res://tools/build_ai_tuning.gd.
const DEFAULT_PATH: String = "res://data/ai/perception_tuning.tres"

static var _shared: AIPerceptionTuning = null

@export_group("Sight")
## Raycasts one agent may spend in a single tick, before the director's per-frame
## pool is consulted. Three is enough to acquire in a crowd without any one body
## eating the whole budget.
@export_range(1, 16, 1) var ray_budget_per_tick: int = 3
## How much of the awareness gain still applies at the very rim of the cone. Zero
## makes the cone edge a hard line and reads as a bug; one makes peripheral
## vision as good as looking straight at something.
@export_range(0.0, 1.0, 0.01) var rim_falloff: float = 0.34
## Awareness weight the player carries relative to another agent, so a squad
## fighting each other still turns around when the player walks in.
@export_range(0.5, 4.0, 0.01) var player_threat: float = 1.15
## Ceiling on stored awareness. Above 1.0 so a target that steps behind a crate
## has a little in the bank and does not instantly stop being a target.
@export_range(1.0, 3.0, 0.01) var awareness_ceiling: float = 1.35
## Extra awareness a target earns per unit of noise it is making, capped.
@export_range(0.0, 2.0, 0.01) var motion_draw: float = 0.55
## Cap on that noise term, so a sprinting player is easier to see but not lit up.
@export_range(0.0, 4.0, 0.01) var motion_draw_cap: float = 1.5

@export_group("Hearing")
## Fraction of the distance to a sound that the listener misplaces it by. Twelve
## per cent is roughly how badly a human localises a rifle report in open ground.
@export_range(0.0, 0.6, 0.005) var localisation_error: float = 0.12
## Multiplier from a noise's strength at the ear to awareness granted.
@export_range(0.0, 2.0, 0.01) var heard_awareness_scale: float = 0.9
## Ceiling on the confidence a heard contact can reach. Deliberately below the
## engage threshold: hearing tells you where to look, never what to shoot.
@export_range(0.0, 1.0, 0.01) var heard_confidence_cap: float = 0.85
## Strength at the ear below which a noise is simply not noticed.
@export_range(0.0, 0.5, 0.005) var hearing_floor: float = 0.01

@export_group("Weapon report")
## Muzzle energy, joules, that the reference radius and loudness are quoted at.
## Roughly a mid-power rifle round.
@export_range(50.0, 20000.0, 10.0) var report_reference_energy: float = 1500.0
## Metres at which the reference shot becomes inaudible. Radius scales with the
## square root of energy, which is what inverse-square intensity gives you for a
## fixed hearing threshold.
@export_range(5.0, 400.0, 0.5) var report_reference_radius: float = 60.0
## Hard ceiling on report radius, so a 20 kJ anti-materiel round does not wake the
## entire map.
@export_range(20.0, 600.0, 1.0) var report_radius_max: float = 240.0
## Strength at the source of the reference shot.
@export_range(0.1, 3.0, 0.01) var report_reference_loudness: float = 1.0
## Loudness added per decade of energy above the reference. Loudness is a log
## quantity because ears are, and because the linear version makes a shotgun
## twenty times more alarming than a pistol.
@export_range(0.0, 1.5, 0.01) var report_loudness_per_decade: float = 0.42
## Multiplier applied to a suppressed weapon's report radius and loudness.
@export_range(0.05, 1.0, 0.01) var report_suppressed_scale: float = 0.34
## Two noises of the same kind closer than this, inside the merge window, collapse
## into the loudest. A machine gun would otherwise file ten reports a second.
@export_range(0.0, 8.0, 0.1) var noise_merge_distance: float = 1.6
## Milliseconds over which that merge applies.
@export_range(0.0, 1000.0, 5.0) var noise_merge_window_ms: float = 120.0

@export_group("Memory")
## Contacts one agent can hold at once. Weakest is evicted to make room.
@export_range(2, 32, 1) var memory_slots: int = 8
## Multiplier on the species' own awareness decay. One global patience dial.
@export_range(0.1, 4.0, 0.01) var awareness_decay_scale: float = 1.0
## Confidence lost per second in a remembered position. Faster than awareness
## decay on purpose — that gap is what turns a chase into a search.
@export_range(0.02, 4.0, 0.01) var confidence_decay: float = 0.55
## Awareness below which a contact is dropped from memory entirely.
@export_range(0.001, 0.3, 0.001) var forget_threshold: float = 0.02
## Seconds of dead reckoning a remembered velocity is worth. Past this the guess
## is confident nonsense, so it stops.
@export_range(0.0, 6.0, 0.05) var extrapolate_seconds: float = 2.0

@export_group("Alertness")
## Awareness that promotes Idle to Suspicious.
@export_range(0.02, 1.0, 0.01) var suspicious_enter: float = 0.30
## Awareness that drops Suspicious back to Idle. The gap is the hysteresis, and
## it is the single thing standing between this machine and a flicker.
@export_range(0.0, 1.0, 0.01) var suspicious_exit: float = 0.14
## Awareness that commits to Engaged. A clean sighting reaches 1.0.
@export_range(0.1, 1.35, 0.01) var engage_enter: float = 0.95
## Seconds without eyes on the target before Engaged concedes it has lost it.
@export_range(0.2, 12.0, 0.05) var lose_grace: float = 2.2
## Seconds spent chasing a ghost before Losing gives up and searches properly.
@export_range(0.5, 30.0, 0.1) var losing_time: float = 5.0
## Seconds of fruitless search before standing down.
@export_range(2.0, 120.0, 0.5) var search_timeout: float = 22.0
## Minimum time served in any state before a transition out of it is considered.
@export_range(0.0, 3.0, 0.01) var min_dwell: float = 0.55
## Seconds Suspicious will stand and stare before it goes and looks.
@export_range(0.0, 6.0, 0.05) var investigate_delay: float = 1.4

@export_group("Search pattern")
## Metres from the last known position that the first search point sits at.
@export_range(0.5, 20.0, 0.1) var search_ring_start: float = 3.0
## How much further out each subsequent point is thrown. The spiral grows with
## the square root of the step, which keeps the swept area growing linearly.
@export_range(0.5, 20.0, 0.1) var search_ring_growth: float = 3.4
## Metres the spiral stops expanding at.
@export_range(4.0, 80.0, 0.5) var search_radius_max: float = 24.0
## Seconds an agent stands at a search point before moving to the next.
@export_range(0.2, 12.0, 0.05) var search_dwell: float = 1.8

@export_group("Target index")
## Metres per cell in the broad-phase grid. Should sit near the median sight
## range divided by four: too small and a long look walks a thousand empty cells,
## too large and every query degenerates to a linear scan.
@export_range(2.0, 40.0, 0.5) var grid_cell_size: float = 16.0
## Rows the index refreshes per budgeted tick. Zero refreshes the whole table.
@export_range(0, 512, 1) var index_rows_per_tick: int = 32


## The one tuning asset, loaded once per process and pushed to the noise bus on
## the way through. Every consumer should take this rather than constructing its
## own, so that a change made in the inspector reaches every agent in the scene.
## Falls back to code defaults if the baked resource is missing, which is what
## makes a freshly cloned repo run before the builders have been executed.
static func shared() -> AIPerceptionTuning:
	if _shared == null:
		if ResourceLoader.exists(DEFAULT_PATH):
			_shared = load(DEFAULT_PATH)
		if _shared == null:
			_shared = AIPerceptionTuning.new()
		_shared.apply_to_bus()
	return _shared


## Push the weapon-report model onto the global bus. Call once, at scene setup.
func apply_to_bus() -> void:
	AINoiseBus.reference_energy = report_reference_energy
	AINoiseBus.reference_radius = report_reference_radius
	AINoiseBus.radius_max = report_radius_max
	AINoiseBus.reference_loudness = report_reference_loudness
	AINoiseBus.loudness_per_decade = report_loudness_per_decade
	AINoiseBus.suppressed_scale = report_suppressed_scale
	AINoiseBus.merge_distance = noise_merge_distance
	AINoiseBus.merge_window_ms = noise_merge_window_ms
