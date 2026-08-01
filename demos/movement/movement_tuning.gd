class_name MovementTuning
extends RefCounted
## The list of controller knobs the playground puts on a physical desk, and the
## preset banks the master dial selects between.
##
## One table, two readers. `build_movement.gd` walks it to decide how many desks
## to weld and what to stencil on each slider; `MovementConsole` walks the same
## table to wire those sliders to `PlayerController` properties. They cannot drift
## apart, because there is only one of them.
##
## Every row names a real `@export` on `PlayerController`. `verify()` proves that
## at bake time against a live instance, so a renamed export fails the build
## rather than producing a desk of dead sliders.
##
## Ranges are wider than the exports' own `@export_range` on purpose — this is the
## demo where you find out what 4.0 gravity feels like. `DiegeticSlider` clamps to
## the row, and the property setter takes whatever it is given, so the widened end
## of a range is reachable here and nowhere else.

## Row keys. Spelled out rather than positional so a reader is legible.
const KEY_PROP: StringName = &"prop"
## Empty when the property lives on `PlayerController` itself, otherwise the name of the
## controller property holding the object that owns it — `slide` for `PlayerSlide`. The
## slide has thirty dials of its own and they live on a resource rather than bloating the
## controller past its line budget; this is how one table addresses both.
const KEY_HOST: StringName = &"host"
## Unique control id, derived: `prop` at the top level, `host_prop` below it. This is
## what a `DiegeticSlider` is stamped with, so `slide.boost` stays `slide_boost` on the
## bench and every id in the table is still a legal node-name suffix.
const KEY_ID: StringName = &"id"
const KEY_LABEL: StringName = &"label"
const KEY_LOW: StringName = &"low"
const KEY_HIGH: StringName = &"high"
const KEY_STEP: StringName = &"step"
const KEY_FORMAT: StringName = &"format"
const KEY_DESK: StringName = &"desk"

## Desk names, stencilled across the back of each bench. Index is `KEY_DESK`.
const DESK_NAMES: PackedStringArray = ["GROUND", "AIR", "BODY", "SLIDE", "TRAVERSAL", "FEEL"]
## Sliders per desk, and how many ranks they are laid out in. SLIDE carries fourteen in
## two ranks because the slide, the slide-jump and the chain are the deep part of the
## controller and one row of six cannot express them; every other desk is one rank of six
## and its geometry is unchanged. `verify()` checks both numbers against the table.
const DESK_ROWS: PackedInt32Array = [6, 6, 6, 14, 6, 6]
const DESK_RANKS: PackedInt32Array = [1, 1, 1, 2, 1, 1]
## Slider spacing along a desk top, per desk. Tighter on the crowded one — 0.46 leaves
## 4 cm between 42 cm sliders, which reads as a full bank rather than a sparse one.
const DESK_PITCH: PackedFloat32Array = [0.53, 0.53, 0.53, 0.46, 0.53, 0.53]
## Depth between ranks on a multi-rank desk. The slab is 0.84 m deep and a slider's label
## and readout reach 0.13 m either side of it, so 0.40 clears with room at both edges.
const DESK_RANK_GAP: float = 0.40

## Master dial detents. Index 0 is always the shipped controller.
const PRESET_NAMES: PackedStringArray = ["REFERENCE", "FLOAT", "HEAVY", "SPRINT", "LUNAR", "CHAIN"]

## `control_id` of the three controls that are not sliders. They live here rather
## than on `MovementConsole` so the builder can name them without dragging the
## console's dependencies into a headless `--script` run.
const ID_PRESET: StringName = &"preset"
const ID_SLOWMO: StringName = &"slowmo"
const ID_RESET: StringName = &"reset"


## Every knob, in desk order. The order inside a desk is the order along its top.
static func rows() -> Array[Dictionary]:
	return [
		_row(&"walk_speed", "WALK", 0.0, 12.0, 0.05, "%.2f m/s", 0),
		_row(&"sprint_speed", "SPRINT", 0.0, 16.0, 0.05, "%.2f m/s", 0),
		_row(&"crouch_speed", "CROUCH", 0.0, 8.0, 0.05, "%.2f m/s", 0),
		_row(&"ground_accel", "ACCEL", 1.0, 40.0, 0.1, "%.1f", 0),
		_row(&"friction", "FRICTION", 0.0, 25.0, 0.1, "%.1f", 0),
		_row(&"stop_speed", "STOP SPEED", 0.1, 12.0, 0.1, "%.1f", 0),
		_row(&"gravity", "GRAVITY", 3.0, 40.0, 0.1, "%.1f", 1),
		_row(&"jump_velocity", "JUMP", 1.0, 14.0, 0.05, "%.2f m/s", 1),
		_row(&"air_accel", "AIR ACCEL", 1.0, 160.0, 0.5, "%.1f", 1),
		_row(&"air_wish_speed", "AIR WISH", 0.1, 4.0, 0.01, "%.2f", 1),
		_row(&"coyote_time", "COYOTE", 0.0, 0.40, 0.005, "%.3f s", 1),
		_row(&"jump_buffer_time", "JUMP BUFFER", 0.0, 0.40, 0.005, "%.3f s", 1),
		_row(&"step_height", "STEP", 0.0, 1.20, 0.01, "%.2f m", 2),
		_row(&"snap_probe", "SNAP DOWN", 0.0, 1.20, 0.01, "%.2f m", 2),
		_row(&"crouch_height", "CROUCH H", 0.60, 1.60, 0.01, "%.2f m", 2),
		_row(&"stand_eye", "EYE", 1.00, 2.00, 0.01, "%.2f m", 2),
		_row(&"crouch_rate", "DUCK RATE", 1.0, 30.0, 0.5, "%.1f", 2),
		_row(&"ground_skin", "FOOT SKIN", 0.005, 0.200, 0.001, "%.3f m", 2),
		# SLIDE, rank one: the slide itself, in the order it happens.
		_slide(&"entry_speed", "ENTRY", 1.0, 16.0, 0.1, "%.1f m/s"),
		_slide(&"boost", "BOOST", 1.0, 2.5, 0.01, "%.2f x"),
		_slide(&"min_speed", "FLOOR", 1.0, 25.0, 0.1, "%.1f m/s"),
		_slide(&"max_speed", "CEILING", 1.0, 35.0, 0.1, "%.1f m/s"),
		_slide(&"friction", "FRICTION", 0.0, 6.0, 0.01, "%.2f"),
		_slide(&"steer", "STEER", 0.0, 16.0, 0.1, "%.1f"),
		_slide(&"gravity_scale", "PULL", 0.0, 2.0, 0.01, "%.2f x"),
		# SLIDE, rank two: which way the hill pushes you, and the jump out of it.
		_slide(&"downhill_friction", "DOWNHILL", 0.05, 2.0, 0.01, "%.2f x"),
		_slide(&"uphill_friction", "UPHILL", 1.0, 8.0, 0.05, "%.2f x"),
		_slide(&"jump_vertical", "HOP", 0.5, 1.6, 0.01, "%.2f x"),
		_slide(&"jump_lift_gain", "LIFT", 0.0, 1.0, 0.005, "%.3f"),
		_slide(&"jump_boost", "LAUNCH", 0.5, 1.6, 0.01, "%.2f x"),
		_slide(&"jump_air_turn", "AIR TURN", 0.0, 300.0, 1.0, "%.0f d/s"),
		_slide(&"land_conserve", "CHAIN", 0.0, 1.0, 0.01, "%.2f"),
		_row(&"mantle_auto_rise", "AUTO VAULT", 0.20, 3.00, 0.01, "%.2f m", 4),
		_row(&"mantle_manual_rise", "HELD VAULT", 0.20, 4.00, 0.01, "%.2f m", 4),
		_row(&"ladder_climb_speed", "CLIMB", 0.5, 8.0, 0.05, "%.2f m/s", 4),
		_row(&"ladder_descend_speed", "DESCEND", 0.5, 8.0, 0.05, "%.2f m/s", 4),
		_row(&"ladder_kick_out", "KICK OUT", 0.0, 12.0, 0.1, "%.1f m/s", 4),
		_row(&"ladder_kick_up", "KICK UP", 0.0, 12.0, 0.1, "%.1f m/s", 4),
		_row(&"stair_smooth_rate", "STAIR SMOOTH", 1.0, 40.0, 0.5, "%.1f", 5),
		_row(&"bob_idle_rate", "BOB IDLE", 0.0, 8.0, 0.01, "%.2f", 5),
		_row(&"bob_speed_gain", "BOB GAIN", 0.0, 3.0, 0.01, "%.2f", 5),
		_row(&"land_spring_stiffness", "LAND SPRING", 10.0, 300.0, 1.0, "%.0f", 5),
		_row(&"land_spring_damping", "LAND DAMP", 1.0, 40.0, 0.5, "%.1f", 5),
		_row(&"look_scale", "LOOK TRIM", 0.10, 3.00, 0.01, "%.2f x", 5),
	]


## Overrides for the preset at `index`, relative to whatever the controller shipped
## with. Index 0 returns nothing, because "REFERENCE" means "the exports as built"
## and the console restores those from the defaults it captured on ready.
static func preset(index: int) -> Dictionary:
	match index:
		1:
			# Long hang time and a loose air controller. Every gap gets easier and
			# every landing gets vaguer; it is the fastest way to feel what gravity
			# is actually buying.
			return {
				&"gravity": 13.0,
				&"jump_velocity": 5.60,
				&"air_accel": 124.0,
				&"air_wish_speed": 1.55,
				&"coyote_time": 0.16,
			}
		2:
			# Weight. Slower to start, slower to stop, shorter in the air, and a
			# landing that visibly costs something.
			return {
				&"gravity": 28.0,
				&"jump_velocity": 7.40,
				&"ground_accel": 9.0,
				&"friction": 14.5,
				&"air_accel": 58.0,
				&"land_spring_stiffness": 170.0,
			}
		3:
			# Everything tuned for the loop timer: quicker off the mark, a slide
			# that carries, and a vault that grabs a full storey.
			return {
				&"sprint_speed": 10.50,
				&"ground_accel": 18.0,
				&"slide_boost": 1.45,
				&"slide_max_speed": 24.0,
				&"slide_friction": 0.55,
				&"mantle_auto_rise": 1.75,
			}
		4:
			# One sixth of a g, near enough. The gap run becomes trivial and the
			# nine-metre drop stops hurting.
			return {
				&"gravity": 5.40,
				&"jump_velocity": 5.00,
				&"air_wish_speed": 2.20,
				&"air_accel": 42.0,
				&"terminal_velocity": -22.0,
			}
		5:
			# Everything the slide-jump has, turned up. Downhill barely rubs, the
			# launch converts hard, landings give almost all of the descent back and
			# the air control is wide enough to pick a roof mid-arc. Flat ground is
			# left punishing on purpose — this is the preset for the slide run, and
			# the point of it is that the line only pays if you keep finding grade.
			return {
				&"slide_downhill_friction": 0.18,
				&"slide_uphill_friction": 3.20,
				&"slide_jump_vertical": 1.08,
				&"slide_jump_lift_gain": 0.28,
				&"slide_jump_boost": 1.16,
				&"slide_jump_air_turn": 150.0,
				&"slide_land_conserve": 0.85,
				&"slide_max_speed": 24.0,
			}
		_:
			return {}


## Rows belonging to one desk, in top order. Rank order is table order: the first
## `DESK_ROWS[desk] / DESK_RANKS[desk]` rows are the back rank, and so on forward.
static func rows_for_desk(desk: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in rows():
		if int(row[KEY_DESK]) == desk:
			out.append(row)
	return out


## Every row by its control id, so a caller with an id off a slider or out of a preset
## can find the host and property behind it without walking the table.
static func by_id() -> Dictionary:
	var out: Dictionary = {}
	for row: Dictionary in rows():
		out[row[KEY_ID]] = row
	return out


## The object a row's property actually lives on. Returns null when the host property is
## missing, which `verify` reports rather than crashing on.
static func host_of(controller: Object, row: Dictionary) -> Object:
	var host: StringName = row[KEY_HOST]
	if host == &"":
		return controller
	return controller.get(host) as Object


## Bake-time assertion: every row names a real property on a real host, every desk holds
## the count and divides into the ranks the layout promises, every id is unique, and every
## preset override names a row. Returns the problems, empty when sound.
static func verify(controller: Object) -> PackedStringArray:
	var problems := PackedStringArray()
	var counts := PackedInt32Array()
	counts.resize(DESK_NAMES.size())
	counts.fill(0)
	var seen: Dictionary = {}
	for row: Dictionary in rows():
		var id: StringName = row[KEY_ID]
		if seen.has(id):
			problems.append("two rows share the control id '%s'" % id)
		seen[id] = true
		var desk: int = int(row[KEY_DESK])
		if desk < 0 or desk >= DESK_NAMES.size():
			problems.append("row '%s' names desk %d, which does not exist" % [id, desk])
		else:
			counts[desk] += 1
		var host: Object = host_of(controller, row)
		if host == null:
			problems.append("row '%s' names host '%s', which is null" % [id, row[KEY_HOST]])
		elif host.get(row[KEY_PROP]) == null:
			problems.append("row '%s' names no property '%s' on its host" % [id, row[KEY_PROP]])
		if float(row[KEY_LOW]) >= float(row[KEY_HIGH]):
			problems.append("row '%s' has an empty range" % id)
	for i: int in DESK_NAMES.size():
		if counts[i] != DESK_ROWS[i]:
			problems.append(
				(
					"desk %d '%s' carries %d rows, expected %d"
					% [i, DESK_NAMES[i], counts[i], DESK_ROWS[i]]
				)
			)
		elif DESK_RANKS[i] < 1 or counts[i] % DESK_RANKS[i] != 0:
			problems.append(
				(
					"desk %d '%s' cannot split %d rows into %d ranks"
					% [i, DESK_NAMES[i], counts[i], DESK_RANKS[i]]
				)
			)
	# A preset may reach past the desks — LUNAR moves `terminal_velocity`, which has no
	# knob — so an id that is not a row is fine as long as it is a controller property.
	var index: Dictionary = by_id()
	for p: int in range(1, PRESET_NAMES.size()):
		for id: StringName in preset(p):
			if not index.has(id) and controller.get(id) == null:
				problems.append(
					(
						"preset '%s' overrides '%s', which is neither a row nor a property"
						% [PRESET_NAMES[p], id]
					)
				)
	return problems


## A row on the `PlayerSlide` resource. Its control id keeps the `slide_` prefix the
## bench and the presets have always used, so nothing downstream had to be renamed when
## the slide moved off the controller.
static func _slide(
	prop: StringName, label: String, low: float, high: float, step: float, format: String
) -> Dictionary:
	var row: Dictionary = _row(prop, label, low, high, step, format, 3)
	row[KEY_HOST] = &"slide"
	row[KEY_ID] = StringName("slide_%s" % prop)
	return row


static func _row(
	prop: StringName, label: String, low: float, high: float, step: float, format: String, desk: int
) -> Dictionary:
	return {
		KEY_PROP: prop,
		KEY_HOST: &"",
		KEY_ID: prop,
		KEY_LABEL: label,
		KEY_LOW: low,
		KEY_HIGH: high,
		KEY_STEP: step,
		KEY_FORMAT: format,
		KEY_DESK: desk,
	}
