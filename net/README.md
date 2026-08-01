# res://net/ — the networking foundation

Four players. Host authoritative. The host owns the scene. Everything else in
this document falls out of those three sentences.

Read this before you write a line of multiplayer code. It is the contract, and
ten other systems are being written against it at the same time as yours.

---

## The rules, in order of how much trouble ignoring them causes

1. **`NetGame.is_authority()` gates every decision.** True on the host, and true
   always when there is no session. If it is false you are a client: send
   intent, draw what you are told, decide nothing.
2. **Single player must keep working, untouched.** No demo may require a
   network. `is_networked()` is false, `is_authority()` is true, and `players()`
   returns a list of one — you. Write the multiplayer path and the solo path as
   the *same* path wherever `is_authority()` lets you.
3. **Clients never route themselves.** `SceneRouter.go()` refuses them. The host
   goes somewhere and everybody follows.
4. **Joining is only possible while the host is on the title screen.** The
   instant the host commits to a demo the lobby shuts, and a late arrival is
   refused with a sentence saying exactly that.
5. **`SceneRouter` is still the only writer of `get_tree().paused` and
   `Input.mouse_mode`.** Networking did not change that and must not.

---

## The files

| file | what it is |
|---|---|
| `net_game.gd` | autoload `NetGame`. Session, handshake, authority, aim. |
| `net_player.gd` | `NetPlayer` — one person. Also the canonical `MAX_PLAYERS` and the four slot colours. |
| `net_roster.gd` | `NetRoster` — the player list in its wire form and its materialised form. `NetGame` owns one. |
| `net_address.gd` | `NetAddress` — parses what somebody types into a join box. Static, non-blocking, safe to call per keystroke. |
| `net_upnp.gd` | `NetUpnp` — the threaded port forward. |

## The whole API

`NetGame` is an autoload. The other four are `class_name`s you can use anywhere.

### Session

```gdscript
NetGame.host(port := 27015) -> Error   # opens ENet, kicks off UPnP on a thread
NetGame.join(address, port := 27015)   # async; never blocks, never throws
NetGame.leave()                        # safe any time, including when idle
```

`join` takes what a person types: `192.168.1.5`, `192.168.1.5:27015`,
`[::1]:27015`, `localhost`, or a hostname. A port inside the string wins over
the argument. Everything that can go wrong arrives as `join_failed(reason)`
where `reason` is a finished sentence you can put straight on screen.

### Asking where you are

```gdscript
NetGame.is_authority() -> bool   # THE ONE. host, or single-player
NetGame.is_networked() -> bool   # false in pure single-player
NetGame.is_host() -> bool
NetGame.is_lobby_open() -> bool  # hosting AND on the title screen
NetGame.peer_id() -> int         # 1 on the host, 1 in single-player
NetGame.max_players() -> int     # 4
NetGame.status_line() -> String  # one line for a debug overlay
```

### People

```gdscript
NetGame.players() -> Array[NetPlayer]   # slot order, host first, never empty
NetGame.local_player() -> NetPlayer     # never null, same object forever
NetGame.player(id) -> NetPlayer         # or null
NetGame.username = "Kellen"             # sanitised, persisted, pushed live
```

`local_player()` returns the same object for the whole run of the process, so it
is safe in an `@onready`. Every other `NetPlayer` should be re-fetched after a
`players_changed`.

### Scene

```gdscript
NetGame.host_goto("firefight")   # host only; everyone follows
```

`SceneRouter.go("firefight")` on the host does exactly the same thing — the
router announces every route it starts — so use whichever reads better where you
are. On a client both are refused.

### Aim / the laser pointer

```gdscript
NetGame.set_local_aim(hit_position, hit_something)   # once a frame
```

Replicated to everybody at 20 Hz, client → host → everybody, so nobody can move
somebody else's dot. Read it back off any `NetPlayer`:

```gdscript
for p: NetPlayer in NetGame.players():
    if p.is_local or not p.aim_valid:
        continue
    draw_dot_at(p.aim_point, p.color())
```

### Signals

| signal | fires on | means |
|---|---|---|
| `lobby_opened` / `lobby_closed` | host | the door opened / shut |
| `peer_joined(id)` | everyone | somebody entered the roster — spawn their avatar |
| `peer_left(id)` | everyone | somebody left it — free their avatar |
| `players_changed` | everyone | the roster changed in any way — redraw the list |
| `joined` | client | you are in |
| `join_failed(reason)` | client | you are not, and this is why, in words |
| `disconnected(reason)` | client | the host went away; you have been routed home |
| `upnp_finished(ok, message)` | host | the router answered. `ok` false is normal |

`peer_joined` and `peer_left` fire for **every** player including the local one,
on **every** machine including the host. That is deliberate: an avatar spawner
written against those two signals is one piece of code, not two.

---

## NetPlayer

```gdscript
peer_id      int        1 is the host
slot         int        0..3, decides the colour, host holds 0
username     String     sanitised, unique within the session
is_local     bool       true on exactly one, on every machine
aim_point    Vector3    replicated at 20 Hz
aim_valid    bool       false means do not draw their dot
avatar       Node3D     yours to write; ALWAYS is_instance_valid() it
color()      Color      derived from the slot
slot_name()  String     "RED" / "BLUE" / "GOLD" / "SAGE"
is_host()    bool
display_name() String   never empty
```

### The four colours

Slot 0 is the host and is **red**, always. The other three are picked out of
`art/palette.gd` for separation, not for prettiness:

| slot | colour | hex | hue | sat | val |
|---|---|---|---|---|---|
| 0 host | `Palette.TIER_HAZARD` | `#a03636` | 0° | .66 | .63 |
| 1 | `Palette.FACTION_CHOIR` | `#78adc8` | 200° | .40 | .78 |
| 2 | `Palette.GOLD` | `#e6c14f` | 45° | .66 | .90 |
| 3 | `Palette.TIER_COBBLED` | `#8a9a6b` | 80° | .31 | .60 |

The tightest hue gap is gold to sage at 35°, and those two are 0.30 apart in
value — the widest value gap in the set. Nothing is within 45° of the host's
red. Four bodies at forty metres on bleached sand read apart in one glance.

`avatar` is the agreed home for a player's body node. `NetGame` never writes it;
whoever spawns avatars does, and everyone else reads it.

---

## When to RPC, and what clients may do locally

**The host decides. Clients ask, and clients draw.**

Do it **locally, on every machine, no RPC**:

- anything cosmetic — muzzle flash, shell ejection, footstep dust, camera shake,
  hit sparks, the laser dots themselves
- reading `NetGame.players()` to draw nameplates, a scoreboard, a lobby list
- your own view: your camera, your viewmodel, your crosshair, your HUD
- prediction of your own movement, if you build any

Do it **on the host only**, gated with `if NetGame.is_authority()`:

- spawning, despawning, and every AI decision
- damage, death, scoring, ammo, reloads that matter
- target state, wave state, territory, timers of record
- picking up, dropping, and owning anything

Send **client → host** as intent, never as fact:

- "I pressed fire and I was aiming here", not "I killed him"
- "I want to move this way", not "I am at this position"

Send **host → everyone** as state, and prefer:

- `reliable` for anything that happens once — a spawn, a death, a score
- `unreliable_ordered` for anything that is continuously replaced — positions,
  aim, animation state. A dropped packet is fixed by the next one, and re-sending
  a stale position is worse than skipping it.

Put your RPCs on **your own node**, not on `NetGame`. The node path has to be
identical on every machine for Godot to route an RPC to it, which means anything
you RPC on must live at the same place in the tree everywhere — an autoload, or
a node the host spawned and told everyone about.

---

## What NetGame does NOT do, and who has to

It owns **identity, presence, aim, and who is allowed to route**. That is all.
Specifically it does **not** replicate:

- **avatar transforms.** Position and orientation need a higher rate than 20 Hz
  and want interpolation and probably prediction. Whoever builds the capsule
  owns that, and should write into `NetPlayer.avatar` so everyone else can find
  the body.
- **any demo's game state.** Enemies, targets, scores, waves, territory. That is
  each demo's own business, gated on `is_authority()`.
- **input.** Send your own, in whatever shape your system needs.

---

## Two things that will bite you

**A demo instanced as a CHILD is not the routed scene.** `capture.gd` and
`watch.gd` build their own tree; `SceneRouter.current_demo` stays empty and
`NetGame` therefore thinks the host is on the title screen. That is harmless
(nobody hosts from a capture) but do not build on it.

**`net_game.gd` is 939 lines against this project's 1000-line lint ceiling.** New
plumbing goes in a sibling file, not in there. The roster came out into
`net_roster.gd` for exactly this reason.

---

## UPnP

`host()` starts it on a background `Thread`, because `UPNP.discover()` blocks
for seconds and the title screen has to stay alive. It never gates hosting:
**failing UPnP is normal and does not stop anybody hosting.** Plenty of routers
have it switched off on purpose, plenty of connections are behind carrier-grade
NAT where it cannot help, and a LAN game does not need it.

```gdscript
NetGame.upnp_state        # NetUpnp.State — IDLE, WORKING, MAPPED, FAILED
NetGame.upnp_message      # "UDP 27015 forwarded", "UPnP is switched off in the router"
NetGame.external_address  # the WAN address, for somebody joining over the internet
NetGame.lan_address       # this machine's LAN address, for somebody in the building
NetGame.active_port
```

Show the LAN address always and the external address when there is one. Say
plainly when there is not: *"Your router did not open the port. People outside
your network cannot join unless you forward UDP 27015 yourself."*

The mapping is handed back on `leave()` and again on exit.

---

## The handshake, for when it goes wrong

A peer that has connected at the socket level is **not** a player. It sends
`_rq_join(protocol, name)`; the host answers with the roster or with a refusal
and a reason, then closes the socket a quarter second later so the reason has
time to arrive.

Refusals, all of them, all reported through `join_failed`:

- bad address, bad port, un-resolvable hostname — caught by `NetAddress` before
  a socket is opened
- nothing answered — `connection_failed`, or a 10 s deadline
- answered but never let you in — a 5 s deadline after the socket came up,
  which in practice means a different build
- protocol mismatch — `NetGame.PROTOCOL_VERSION` differs; **bump it whenever you
  change the wire format**
- the lobby has started
- the game is full
- you are already in it

The host also drops anything that connects and then says nothing within 6 s.

---

## Running two instances

There are command-line options for this, because there has to be a way to put two
builds in a session without clicking through UI — before the lobby UI exists, and
afterwards from a script.

```
--host              host on the default port
--host=<port>       host on that one
--join=<address>    join, same syntax as the join box
--name=<username>   set the username first
```

Godot only routes what comes after a bare `--` to `OS.get_cmdline_user_args()`,
so put one in. Both argument vectors are searched, so it works either way.

```
godot --path <project> -- --host --name=HOSTY
godot --path <project> -- --join=127.0.0.1 --name=GUESTY
```

Godot is happy with several instances on one box. `NetGame` prints one line to
stdout on every session event, so two headless runs are enough to see the whole
handshake. This is what a good one looks like:

```
NetGame: hosting 192.168.1.100:27015  1/4  lobby open  upnp UDP 27015 forwarded | upnp ok
NetGame: hosting 192.168.1.100:27015  2/4  lobby open  upnp UDP 27015 forwarded | 1 RED HOSTY / 1752050734 BLUE GUESTY
NetGame: guest of 127.0.0.1:27015  2/4 | 1 RED HOSTY / 1752050734 BLUE GUESTY
```

The last two lines are the same roster read off two different machines. That is
the thing to check.

`NetGame.status_line()` is that line without the roster, and is the fastest way
to see what state a build is actually in.
