class_name WeaponBench
extends Node3D
## The weapon bench, with every control made of steel.
##
## The reference's bench is a second WebGL scene with an HTML card and eight
## buttons. Under the project's diegetic rule none of that survives as pixels, so
## it is a console you shoot: a rotary selector picks the class, a lever scavenges
## a new weapon onto the stand, five caps swap one part each, two more equip it,
## and the stat card is a phosphor placard bolted to the back wall.
##
## What did survive is the behaviour, exactly. A slot swap re-assembles through
## `GunFactory.reroll_slot`, which — like the reference — deliberately does NOT
## re-run `fitOptics`, so the magnification ladder empties and every consumer has
## to go through `GunSpec.zoom_ladder()`. The sight slot still has a 15 % chance
## of taking the optic off entirely. Scavenging still walks the seed by one.
##
## The bench never touches the player. It emits, the demo wires.
##
## FOUR PEOPLE, ONE BENCH. There is exactly one console and it is the host's. A
## client's round flashes a cap and asks; the host decides, rolls, and publishes
## what is on the stand, where the dial is pointing and where the lever is sitting,
## so all four seats are looking at the same console rather than four private ones.
##
## And `equip_requested` carries WHO. A cap is worked by a bullet, and by the time
## the host's copy of that bullet reaches the control `RangeNet.actor()` is already
## the peer id of whoever fired it — so the gun goes to the player who shot the
## button and not to whoever happens to be standing at the bench.

## A new weapon is on the stand. Nothing has been equipped yet.
signal weapon_rolled(spec: GunSpec)
## Put this weapon in a holster slot, for the player whose round worked the cap.
## Slot 1 is only ever asked for a sidearm.
signal equip_requested(slot: int, spec: GunSpec, id: int)
## Stand every target back up and zero the score.
signal reset_requested
## Fresh paper on the board at 25 m.
signal paper_clear_requested

## The five slots the caps swap, keyed by control id.
const SLOTS: Dictionary = {
	&"reroll_receiver": &"receiver",
	&"reroll_barrel": &"barrel",
	&"reroll_grip": &"grip",
	&"reroll_stock": &"stock",
	&"reroll_sight": &"sight",
}
## Stat card rows: label, spec property, the value that fills the bar.
const CARD_ROWS: Array = [
	["DAMAGE", &"damage", 240.0],
	["RANGE", &"effective_range", 900.0],
	["PRECISION", &"precision", 100.0],
	["RECOIL", &"kick", 100.0],
	["HANDLING", &"handling", 100.0],
	["RELIABILITY", &"reliability", 100.0],
]
const RangeNetScript := preload("res://demos/range/range_net.gd")

## Where the bench weapon stands. Model units are 90 mm, so the assembly is
## scaled here and nowhere else.
@export var stand_path: NodePath = NodePath("Stand")
@export var card_path: NodePath = NodePath("CardReadout")
@export var parts_path: NodePath = NodePath("PartsReadout")
## First seed the lever hands out. Every pull adds one, which is the reference's
## `Scavenge` button and the reason two players quoting a seed see the same gun.
@export_range(1, 1000000, 1) var start_seed: int = 4711
@export_range(0.001, 1.0, 0.001) var display_scale: float = 0.09
## Radians per second the stand turns. Slow enough to read, fast enough to see
## the far side without waiting.
@export_range(0.0, 2.0, 0.01) var display_spin: float = 0.32
@export_range(0.0, 0.6, 0.01) var display_tilt: float = 0.11

var _stand: Node3D = null
var _card: DiegeticReadout = null
var _parts: DiegeticReadout = null
var _controls: Dictionary = {}
var _spec: GunSpec = null
var _display: Node3D = null
var _seed: int = 0
var _rand: RandomNumberGenerator = RandomNumberGenerator.new()
var _net: RangeNetScript = null
var _authority: bool = true


## Class names the dial offers, DERIVED FROM `GunTables.CLASS_MIX` rather than
## written out here. Index 0 means "whatever the world hands out", which is
## `GunTables.wanted_class` and not a uniform draw.
##
## THIS LIST USED TO BE WRONG AND IT MADE EVERY GUN ON THE RANGE A MACHINE GUN.
## It read "Rifle", "SMG", "Pistol", "Revolver", "LMG" — those are RECEIVER classes
## (the `c` field on a part), not ARCHETYPES, and `GunFactory.roll` matches on the
## archetype. Nothing ever matched, so `roll_typed` ran out its 420 attempts and
## returned its fallback: the FIRST raw build, an unweighted geometry draw that
## skews hard to fast autos. The gun bench passed real archetype names and so got
## the `CLASS_MIX`-weighted roll, which is why its guns felt right and these did
## not. Deriving the list means the two benches can never drift apart again.
static func classes() -> PackedStringArray:
	var out := PackedStringArray([""])
	for row: Array in GunTables.CLASS_MIX:
		out.append(String(row[0]))
	return out


func _ready() -> void:
	_seed = start_seed
	_rand.seed = start_seed
	_stand = get_node_or_null(stand_path) as Node3D
	_card = get_node_or_null(card_path) as DiegeticReadout
	_parts = get_node_or_null(parts_path) as DiegeticReadout
	_bind_controls(self)
	_set_enabled(&"equip_sidearm", false)
	_bind_net()
	# The bench is not empty when you walk in. Somebody left a gun on it — and
	# because the opening seed and the dial are the same everywhere, every machine
	# leaves the SAME gun on it, so a client has something on the stand before the
	# host's first packet rather than an empty rig for a round trip.
	if _authority:
		scavenge()
	else:
		_show(GunFactory.roll(_seed, _wanted_class()))
	set_process(display_spin > 0.0)


func _process(delta: float) -> void:
	if _display != null:
		_display.rotate_y(display_spin * delta)


## What is currently on the stand.
func current() -> GunSpec:
	return _spec


## Roll a fresh weapon of the dialled class onto the stand and step the seed.
func scavenge() -> GunSpec:
	if not _authority:
		return _spec
	var spec: GunSpec = GunFactory.roll(_seed, _wanted_class())
	_seed += 1
	if spec == null:
		push_error("WeaponBench: GunFactory returned nothing. Is the part bake present?")
		return null
	_show(spec)
	weapon_rolled.emit(spec)
	_publish()
	return spec


## Swap one slot for a random other part of the same kind, keeping the roll seed
## so the weapon is recognisably the same gun with one different bone in it.
func reroll(kind: StringName) -> GunSpec:
	if not _authority or _spec == null:
		return _spec
	var next: GunSpec = GunFactory.reroll_slot(_spec, kind, _rand)
	if next == null:
		return null
	_show(next)
	weapon_rolled.emit(next)
	_publish()
	return next


## Which class the dial is asking for. Empty means the world's own mix.
func wanted_class() -> String:
	return _wanted_class()


## Where the selector is pointing, as a detent index.
func dial_index() -> int:
	var dial := _controls.get(&"class_dial") as DiegeticDial
	return 0 if dial == null else dial.selected_index()


## Whether the scavenge lever is thrown right now. It springs back on its own, so
## this is only ever true for the half second after somebody pulls it.
func lever_on() -> bool:
	var lever := _controls.get(&"scavenge_lever") as DiegeticLever
	return lever != null and lever.is_on()


## The host's picture of the console. Applied whole: what is on the stand, where
## the selector points and which way the lever is thrown.
func apply_state(spec: GunSpec, dial: int, lever: bool) -> void:
	if _authority:
		return
	var knob := _controls.get(&"class_dial") as DiegeticDial
	if knob != null:
		knob.set_value(float(dial), false)
	var arm := _controls.get(&"scavenge_lever") as DiegeticLever
	if arm != null:
		arm.set_on(lever, false)
	if spec != null:
		_show(spec)


## One control actuated on the host. The value is the state; the flash and the
## clack are what make it read as somebody else's hand on the console.
func apply_control(id: StringName, value: float) -> void:
	if _authority:
		return
	var control := _controls.get(id) as DiegeticControl
	if control == null:
		return
	control.set_value(value, false)
	control.flash()
	_clack(control)


func _show(spec: GunSpec) -> void:
	if spec == null:
		return
	_spec = spec
	_write_card(spec)
	_write_parts(spec)
	_set_enabled(&"equip_sidearm", spec.sidearm)
	if _stand == null:
		return
	if _display != null:
		_display.queue_free()
		_display = null
	var node: Node3D = GunFactory.build_node(spec)
	if node == null:
		return
	# The factory hands back model units and the assembly is not centred on its
	# own bore, so the pivot is put through the middle of the mass. A gun that
	# turns about its own trigger guard reads as a gun on a stand; one that turns
	# about the origin reads as a gun on a string.
	var box: AABB = GunFactory.assembly_aabb(spec)
	var pivot := Node3D.new()
	pivot.name = "Spin"
	var inner := Node3D.new()
	inner.name = "Model"
	inner.position = -box.get_center() * display_scale
	inner.scale = Vector3.ONE * display_scale
	inner.add_child(node)
	pivot.add_child(inner)
	pivot.rotation = Vector3(display_tilt, 0.0, 0.0)
	_stand.add_child(pivot)
	_display = pivot


func _write_card(spec: GunSpec) -> void:
	if _card == null:
		return
	_card.accent = spec.tier_color
	_card.set_title(spec.weapon_name.to_upper())
	var lines := PackedStringArray()
	lines.append(
		(
			"%s  %s  ·  %s"
			% [
				String(spec.tier_name).to_upper(),
				String(spec.archetype).to_upper(),
				_cartridge(spec)
			]
		)
	)
	lines.append(
		(
			"%d rnd %s  ·  %.1fs reload  ·  %d rpm"
			% [spec.magazine, _feed_label(spec.feed), spec.reload_time, spec.rpm]
		)
	)
	lines.append("%.1f kg  ·  %d mm  ·  %s" % [spec.mass, spec.overall_length, spec.spread_text])
	lines.append(_terminal(spec))
	_card.set_lines(lines)

	var labels := PackedStringArray()
	var values := PackedFloat32Array()
	var colors := PackedColorArray()
	for row: Array in CARD_ROWS:
		labels.append(String(row[0]))
		var raw: float = float(spec.get(String(row[1])))
		values.append(clampf(raw / float(row[2]), 0.0, 1.0))
		colors.append(_bar_color(float(row[2]), raw))
	_card.set_bars(labels, values, colors)


func _write_parts(spec: GunSpec) -> void:
	if _parts == null:
		return
	_parts.set_title("BILL OF PARTS")
	var lines := PackedStringArray()
	var kinds: PackedStringArray = ["RECEIVER", "BARREL", "STOCK", "GRIP", "SIGHT"]
	var indices := PackedInt32Array(
		[
			spec.receiver_index(),
			spec.barrel_index(),
			spec.stock_index(),
			spec.grip_index(),
			spec.sight_index(),
		]
	)
	for i: int in kinds.size():
		var index: int = indices[i]
		if index < 0:
			lines.append("%-10s iron sights" % kinds[i])
			continue
		var part: GunPart = PartLibrary.part(index)
		if part == null:
			continue
		lines.append(
			"%-10s %s  %s" % [kinds[i], String(part.donor_group), String(part.weapon_class)]
		)
	# Wrapped, not joined — see `GunGrading.quirk_lines`. This panel already carries
	# five part rows, so it is the tightest of the two for height.
	var tags: PackedStringArray = GunGrading.quirk_lines(spec)
	if not tags.is_empty():
		lines.append("")
		lines.append_array(tags)
	lines.append("")
	lines.append("seed %d  ·  fit %.2f" % [spec.roll_seed, spec.fit_error])
	_parts.set_lines(lines)


func _cartridge(spec: GunSpec) -> String:
	if spec.pellets > 1:
		return "%s, %d pellets" % [spec.caliber, spec.pellets]
	return spec.caliber


func _feed_label(feed: StringName) -> String:
	match feed:
		&"box":
			return "box mag"
		&"tube":
			return "tube"
		&"cylinder":
			return "cylinder"
		&"internal":
			return "internal"
		_:
			return "breech"


## The line that tells you what the round actually does when it gets there —
## whether it is instant, and what it is worth on a head.
func _terminal(spec: GunSpec) -> String:
	if spec.explosive:
		return "lobbed warhead  ·  %.1f m blast" % spec.blast_radius
	var ladder: PackedFloat32Array = spec.zoom_ladder()
	var optic: String = "iron sights"
	if spec.has_optic and not ladder.is_empty():
		optic = "%.1fx optic" % ladder[ladder.size() - 1]
	return (
		"x%.2f head  ·  instant to %d m  ·  %s"
		% [spec.crit_multiplier, int(spec.headshot_range), optic]
	)


func _bar_color(ceiling: float, value: float) -> Color:
	var t: float = clampf(value / ceiling, 0.0, 1.0)
	return UiStyle.WARN.lerp(UiStyle.GOOD, t)


# --- controls ---------------------------------------------------------------


func _bind_net() -> void:
	_net = RangeNetScript.of(self) as RangeNetScript
	if _net == null:
		return
	_authority = _net.is_authority()
	_net.bench_state.connect(apply_state)
	_net.control_state.connect(apply_control)


func _bind_controls(node: Node) -> void:
	for child: Node in node.get_children():
		var control := child as DiegeticControl
		if control != null and control.control_id != &"":
			_controls[control.control_id] = control
			if control is DiegeticLever:
				(control as DiegeticLever).toggled.connect(_on_lever.bind(control))
			else:
				control.pressed.connect(_on_pressed.bind(control))
		_bind_controls(child)


## The lever is a lever, not a switch: throwing it either way scavenges, and it
## springs back to SET a moment later so the next pull reads as a pull.
func _on_lever(_on: bool, control: DiegeticControl) -> void:
	if control.control_id != &"scavenge_lever" or not _authority:
		return
	scavenge()
	if _on:
		var timer: SceneTreeTimer = get_tree().create_timer(0.55, false)
		timer.timeout.connect(_reset_lever.bind(control))


func _reset_lever(control: DiegeticControl) -> void:
	var lever := control as DiegeticLever
	if lever != null and lever.is_on():
		lever.set_on(false, false)
		_publish()


## A cap was knocked in. On the host this runs for every player's round, and
## `RangeNet.actor()` is whoever fired the one being resolved right now — which is
## the whole answer to "who does this gun belong to".
func _on_pressed(control: DiegeticControl) -> void:
	if not _authority:
		return
	var id: StringName = control.control_id
	var who: int = 1 if _net == null else _net.actor()
	if _net != null:
		_net.publish_control(control)
	if SLOTS.has(id):
		reroll(SLOTS[id] as StringName)
		return
	match id:
		&"equip_primary":
			if _spec != null:
				equip_requested.emit(WeaponHolster.PRIMARY_SLOT, _spec, who)
		&"equip_sidearm":
			if _spec != null and _spec.sidearm:
				equip_requested.emit(1, _spec, who)
		&"reset_range":
			reset_requested.emit()
		&"clear_paper":
			paper_clear_requested.emit()
		&"class_dial":
			pass


## Push the whole console: the gun on the stand, the selector and the lever. Sent
## as one because they are one thing to look at, and because a client that missed
## a single control event is corrected by the next publish either way.
func _publish() -> void:
	if _net != null and _authority:
		_net.publish_bench(_spec, dial_index(), lever_on())


## The control's own clack, played where the control is. `DiegeticControl` plays
## this itself when a round actuates it, which only ever happens on the host, so a
## remote actuation would otherwise be a silent one.
func _clack(control: DiegeticControl) -> void:
	var speaker := control.get_node_or_null(^"Sound") as AudioStreamPlayer3D
	if speaker != null and control.sound != null:
		speaker.stream = control.sound
		speaker.play()


func _wanted_class() -> String:
	var dial := _controls.get(&"class_dial") as DiegeticDial
	if dial == null:
		return ""
	var names := classes()
	return names[clampi(dial.selected_index(), 0, names.size() - 1)]


func _set_enabled(id: StringName, on: bool) -> void:
	var control := _controls.get(id) as DiegeticControl
	if control != null:
		control.enabled = on
