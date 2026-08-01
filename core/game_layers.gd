class_name GameLayers
extends RefCounted
## The project-wide physics layer contract. Mirrors `layer_names/3d_physics/*` in
## project.godot, which only FOUNDATION-A may edit.
##
## Bullets must not test against everything (performance rule): a hitscan ray uses
## `MASK_BULLET`, which deliberately excludes triggers, the viewmodel and the
## player's own body. Enemy limb hitboxes live on their own layer so a body's
## broad collider never eats a shot meant for a limb.

## Static terrain, buildings, roads — everything the world bake emits.
const WORLD: int = 1 << 0
## Loose props: crates, drums, wrecks. Movable or destructible, still shootable.
const PROP: int = 1 << 1
## The player's character body.
const PLAYER: int = 1 << 2
## Enemy character bodies — used for navigation and separation, not for shots.
const ENEMY: int = 1 << 3
## Per-limb enemy hitboxes. Shots resolve here so damage zones stay meaningful.
const ENEMY_HITBOX: int = 1 << 4
## Physical projectiles (grenades, launcher shells) and their proximity probes.
const PROJECTILE: int = 1 << 5
## Interact volumes, ladder volumes, exfil pads. Never blocks movement or shots.
const TRIGGER: int = 1 << 6
## Viewmodel geometry. Rendered by a separate camera and invisible to every query.
const VIEWMODEL: int = 1 << 7

## What a hitscan ray or a pellet is allowed to hit.
const MASK_BULLET: int = WORLD | PROP | ENEMY | ENEMY_HITBOX
## What the player's move-and-slide collides with.
const MASK_PLAYER_MOVE: int = WORLD | PROP
## What an enemy's move-and-slide collides with.
const MASK_ENEMY_MOVE: int = WORLD | PROP | PLAYER | ENEMY
## What the player's interact probe looks for.
const MASK_INTERACT: int = TRIGGER | PROP
## What an explosion's line-of-sight test is occluded by.
const MASK_BLAST_OCCLUDER: int = WORLD | PROP
## What a thrown or fired projectile detonates on.
const MASK_PROJECTILE: int = WORLD | PROP | ENEMY | ENEMY_HITBOX | PLAYER
