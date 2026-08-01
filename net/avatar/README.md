# res://net/avatar/ — how players see each other

Avatars, nameplates and laser cursors. The visual half of multiplayer; `res://net/`
above it is the authoritative half and owns the roster, the socket and the scene.

**If you are a demo, you need one line.** Everything else in this file is here so you
do not have to read the code.

---

## The one line

```gdscript
func _ready() -> void:
    NetPresence.enter(NetPresence.FULL, $Player/Eye)
```

`enter(mode, eye)` — declare how players appear in your demo and where your eye is.
Call it from `_ready`, not `_enter_tree`. The eye may be omitted (`null`), in which case
the viewport's live camera is used every frame, which is what a demo with an F8 freecam
wants.

Single-player demos may call it and it costs almost nothing: the roster is one player
long, no avatars are created, and you get your own aim dot.

### The three modes

| mode | what a remote player looks like | who uses it |
|---|---|---|
| `NetPresence.FULL` | capsule with sunglasses, nameplate, laser dot, collider | range, bestiary, gunbench, movement, ash_flats, visuals |
| `NetPresence.SPHERE` | translucent bubble, nameplate, laser dot | firefight spectators |
| `NetPresence.GHOST` | translucent capsule, **no collider**, laser dot, and a through-walls beacon visible across the whole map | ash_flats race mode |

Switch at any time — `NetPresence.instance().set_mode(NetPresence.GHOST)` — it only
toggles visibility and costs nothing.

---

## What you get to read

```gdscript
var p := NetPresence.instance()

p.aim_point() -> Vector3      # where YOUR aim ray landed, in world space
p.aim_valid() -> bool         # false over open sky
p.dot_of(peer_id) -> Vector3  # where their dot is sitting, smoothed. ZERO if not live
p.hovered_peer() -> int       # whose dot your dot is on, 0 for nobody
p.avatar_of(peer_id) -> PlayerAvatar
p.name_of(peer_id) -> String
p.color_of(peer_id) -> Color
p.local_id() -> int
```

`hovered_peer()` is the hook if you want to do something when two players point at the
same thing. The name-above-the-dot behaviour is already handled.

### Colour

`NetPlayer.SLOT_COLORS` owns the table — the roster assigns slots, so the roster owns
what a slot looks like. `NetColors` is the façade for things that draw:

```gdscript
NetColors.of_slot(slot) -> Color    # straight from NetPlayer
NetColors.slot_name(slot) -> String # "RED", "BLUE", "GOLD", "SAGE"
NetColors.text(color) -> Color      # lifted toward bone; use for small type
NetColors.tint(color) -> Color      # lifted for use as a shell tint MULTIPLIER
```

Host is slot 0 and slot 0 is red. Do not invent a fifth colour.

---

## What you may drive

For whoever ends up owning authoritative movement:

```gdscript
NetPresence.instance().publish(peer_id, {
    "position": Vector3, "yaw": float,   # optional
    "name": String, "color": Color,      # optional; the roster usually wins
    "visible": bool,                     # optional
})
NetPresence.instance().drop(peer_id)     # instant departure; the sweep does it anyway
NetPresence.instance().set_local_body(node)   # what your avatar stands for
```

**The first `publish()` carrying a position for a peer permanently disables this
system's own transform fallback for that peer.** You do not have to turn anything off.

---

## Three things worth knowing

**The dot is a POINT, not a ray.** The owner casts the ray on its own machine and hands
the result to `NetGame.set_local_aim()`, which relays it at 20 Hz. Nobody re-simulates
anybody's aim and nobody can move somebody else's dot.

**A demo with a `CombatReticle` spends zero extra rays.** The reticle already casts the
right ray, against the bullet mask, from the same pixel the click path uses, on every
physics frame — `NetPresence` borrows its answer via the `aim_indicator` group. Demos
without a reticle get one modest cast of their own. The reticle also now publishes
`aim_point()`, `aim_normal()`, `aim_valid()` and `aim_control()`, and the last of those
is the diegetic control under your aim if you want to act on it.

**Position is the one thing this system still sends itself.** `NetGame` replicates the
roster and the aim but not where a body is. Until something does, presence broadcasts
its own position and yaw at 18 Hz over `SceneMultiplayer.send_bytes` — addressed to a
peer rather than to a node path, so a player who has not entered the scene yet is
harmless. Packets carry a magic word and anything without it is ignored.

---

## Collision

`PlayerAvatar` carries an `AnimatableBody3D` on `GameLayers.PLAYER`, on in FULL and
SPHERE and off in GHOST.

**It is inert today.** `GameLayers.MASK_PLAYER_MOVE` is `WORLD | PROP` and does not
include `PLAYER`, so nothing collides with it yet. Adding that bit is a one-line change
to the layer contract and it is deliberately not made here. Remote avatars are likewise
not on `MASK_BULLET`, so they are not shootable.

---

## Rebuilding the art

```
godot --headless --path <project> --script res://tools/build_avatar.gd
```

Writes `res://data/net/` — four meshes, six materials and the two prefabs. It is a step
in `bake_all`. Every shell is audited for negative signed volume, zero boundary edges
and no degenerate triangles, and the bake prints `VERDICT: PASS` or names what failed.

The shaders are source and live here: `laser_dot.gdshader`, `ghost_body.gdshader`,
`beacon.gdshader`. If you edit one, re-run the bake — the materials are baked, not
built at load.

**If you add a mesh to the baker, give it its material BEFORE you save it.** A mesh
saved bare and dressed afterwards is referenced externally by the packed scene, so the
runtime loads the bare copy, renders it white, and every player tint silently does
nothing. That cost one whole build.
