class_name RagdollBudget
extends RefCounted
## The process-wide census of physics corpses.
##
## Firefight runs about a hundred bodies at 200+ fps and a full ragdoll is orders
## of magnitude more expensive than the pose solver, so the number of them is a
## HARD cap rather than a hope. Every `EnemyBody` asks here before it spends a
## death on physics; the ones that are refused fall back to `DeathPoser`, which is
## the right tool at distance anyway.
##
## A slot is held from the moment the fall starts to the moment the corpse
## settles — NOT until it despawns. A settled ragdoll's bodies are asleep and its
## solver cost is gone, so holding its slot would starve the next death for
## nothing. The nodes themselves are freed when the spawner recycles the actor.
##
## Static state on a `class_name` script, not an autoload: this is one integer
## shared by a system that already exists in every demo, and registering an
## autoload for it would be a project-settings change for no gain.

static var _active: int = 0
static var _peak: int = 0
static var _refused: int = 0


## Take a slot if one is free. `cap` is the caller's own `ragdoll_max_active`, so
## a demo can be stricter than the default without a global setting.
static func claim(cap: int) -> bool:
	if cap <= 0 or _active >= cap:
		_refused += 1
		return false
	_active += 1
	_peak = maxi(_peak, _active)
	return true


## Hand a slot back. Safe to call more than once only if the caller tracks its own
## claim — it does not; `EnemyBody` clears its flag before calling.
static func release() -> void:
	_active = maxi(0, _active - 1)


## Ragdolls solving right now.
static func active() -> int:
	return _active


## The most that were ever solving at once, and how many deaths were sent to the
## cheap poser because the cap was full. Both are read by the arena's stats
## overlay and by `tools/watch.gd`; neither costs anything to keep.
static func peak() -> int:
	return _peak


static func refused() -> int:
	return _refused


## Forget every count. A demo that reloads its level calls this so the previous
## run's peak does not leak into the next one.
static func reset() -> void:
	_active = 0
	_peak = 0
	_refused = 0
