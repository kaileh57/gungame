extends SceneTree
## Acceptance test for the bestiary roster. Headless, no side effects, no writes.
##
## Builds every species, checks its part and bone counts against the catalogue,
## derives its stats, measures the tightest parent/child joint overlap in the idle
## pose, and prints the whole table so it can be diffed against
## `docs/spec/bestiary.md` §16. Any degenerate stat or any joint whose best
## overlap is not positive fails the run.
##
##   godot --headless --path <project> --script res://tools/verify_species.gd


func _init() -> void:
	var failures: Array[String] = []
	var total_parts: int = 0
	var total_bones: int = 0
	print(
		(
			"id        parts bones legs arms  mass kg   cover     HP  arm  height  "
			+ "speed    run   poise  threat  tier"
		)
	)
	for id in SpeciesTable.IDS:
		var inst: RigInstance = SpeciesTable.instantiate(id)
		var rig: EnemyRig = inst.rig
		var s: EnemyStats = inst.stats
		var want: Dictionary = SpeciesTable.CATALOGUE[id]
		total_parts += rig.parts.size()
		total_bones += rig.bones.size()
		if rig.parts.size() != int(want["parts"]):
			failures.append("%s parts %d != %d" % [id, rig.parts.size(), int(want["parts"])])
		if rig.bones.size() != int(want["bones"]):
			failures.append("%s bones %d != %d" % [id, rig.bones.size(), int(want["bones"])])
		if rig.legs.size() != int(want["legs"]):
			failures.append("%s legs %d != %d" % [id, rig.legs.size(), int(want["legs"])])
		if rig.arms.size() != int(want["arms"]):
			failures.append("%s arms %d != %d" % [id, rig.arms.size(), int(want["arms"])])
		failures.append_array(_check_stats(id, s))
		print(
			(
				"%-9s %5d %5d %4d %4d %9.3f %8.5f %6d %4d %7.4f %6.3f %6.3f %7.3f %7.3f  %s"
				% [
					id,
					rig.parts.size(),
					rig.bones.size(),
					rig.legs.size(),
					rig.arms.size(),
					s.mass,
					s.cover,
					int(s.health),
					int(s.armour),
					s.height,
					s.speed,
					s.run_speed,
					s.stagger,
					s.threat,
					s.tier_name
				]
			)
		)
	print("total parts %d  bones %d" % [total_parts, total_bones])

	print("")
	print("id        freq   runFreq   duty  runDuty      E    runE  reach   hipH  standY")
	for id in SpeciesTable.IDS:
		var g: Dictionary = SpeciesTable.build(id).gait
		print(
			(
				"%-9s %6.5f %8.5f %6.3f %8.4f %6.5f %7.5f %6.5f %6.5f %7.5f"
				% [
					id,
					float(g["freq"]),
					float(g["run_freq"]),
					float(g["duty"]),
					float(g["run_duty"]),
					float(g["e"]),
					float(g["run_e"]),
					float(g.get("reach", 0.0)),
					float(g.get("hip_h", 0.0)),
					float(g.get("stand_y", 0.0))
				]
			)
		)

	print("")
	print("id        width   depth     alt  boxes  head core limb  min extent  min joint")
	for id in SpeciesTable.IDS:
		var inst: RigInstance = SpeciesTable.instantiate(id)
		var boxes: Array[Dictionary] = SpeciesTable.hitboxes(inst)
		var counts: Dictionary = {&"head": 0, &"core": 0, &"limb": 0}
		var min_extent: float = INF
		for b in boxes:
			counts[b["zone"]] = int(counts[b["zone"]]) + 1
			var size: Vector3 = b["size"]
			min_extent = minf(min_extent, minf(size.x, minf(size.y, size.z)))
			if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
				failures.append("%s hitbox on %s is degenerate" % [id, b["bone"]])
		if boxes.is_empty():
			failures.append("%s has no hitboxes" % id)
		var joint: float = _min_joint_overlap(inst)
		if joint <= 0.0:
			failures.append("%s joint gap %.5f m" % [id, joint])
		var s: EnemyStats = inst.stats
		print(
			(
				"%-9s %6.4f %7.4f %7.4f %6d %5d %4d %4d %11.4f %10.5f"
				% [
					id,
					s.width,
					s.depth,
					s.alt,
					boxes.size(),
					int(counts[&"head"]),
					int(counts[&"core"]),
					int(counts[&"limb"]),
					min_extent,
					joint
				]
			)
		)

	print("")
	if failures.is_empty():
		print("PASS — 12 species, no degenerate stats, no open joints.")
	else:
		print("FAIL — %d problem(s):" % failures.size())
		for f in failures:
			print("  " + f)
	quit(0 if failures.is_empty() else 1)


## Every stat that would make a species unusable if it came out wrong.
func _check_stats(id: StringName, s: EnemyStats) -> Array[String]:
	var out: Array[String] = []
	if not is_finite(s.mass) or s.mass <= 0.0:
		out.append("%s mass %f" % [id, s.mass])
	if s.health < 1.0:
		out.append("%s health %f" % [id, s.health])
	if s.armour < 0.0 or s.armour > EnemyStats.ARMOUR_CAP:
		out.append("%s armour %f" % [id, s.armour])
	if s.speed <= 0.0 or s.run_speed < s.speed:
		out.append("%s speed %f / run %f" % [id, s.speed, s.run_speed])
	if s.reach <= 0.0 or s.damage <= 0.0 or s.detect <= 0.0:
		out.append("%s reach/damage/detect %f %f %f" % [id, s.reach, s.damage, s.detect])
	if s.threat <= 0.0 or s.threat > 99.0:
		out.append("%s threat %f" % [id, s.threat])
	if s.height <= 0.0 or s.width <= 0.0 or s.depth <= 0.0:
		out.append("%s bounds %f %f %f" % [id, s.height, s.width, s.depth])
	if s.tier_index != EnemyStats.tier_of(s.threat):
		out.append("%s tier mismatch" % id)
	return out


## Tightest parent/child overlap over the idle pose, in metres. Positive means
## every bone's geometry still interpenetrates its parent's — no seam anywhere.
## Bones whose parent carries no geometry of its own are skipped: the guarantee
## there is transitive through the grandparent.
func _min_joint_overlap(inst: RigInstance) -> float:
	var rig: EnemyRig = inst.rig
	PoseSolver.pose(inst, BeastClips.IDLE, 0.0)
	var by_bone: Array[Array] = []
	by_bone.resize(rig.bones.size())
	for i in rig.bones.size():
		by_bone[i] = []
	var prims: Array[Dictionary] = []
	prims.resize(inst.part_bone.size())
	for i in inst.part_bone.size():
		if inst.part_fx[i] != 0:
			continue
		var m: Transform3D = inst.pose.globals[inst.part_bone[i]] * inst.part_local[i]
		prims[i] = BeastCollide.world_prim(rig.parts[i], m)
		by_bone[inst.part_bone[i]].append(i)

	var worst: float = INF
	for b in rig.bones.size():
		var parent: int = inst.pose.parent_index(b)
		if parent < 0 or by_bone[b].is_empty() or by_bone[parent].is_empty():
			continue
		var best: float = -INF
		for i in by_bone[b]:
			for j in by_bone[parent]:
				best = maxf(best, BeastCollide.penetration(prims[i], prims[j]))
		worst = minf(worst, best)
	return worst
