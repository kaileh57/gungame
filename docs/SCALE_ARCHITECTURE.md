# Scaling to the full game

Not a plan for now. A record of what the current multiplayer work must not
foreclose, written while the decisions are still cheap to change.

The reference point is Helldivers 2: four players, host-authoritative,
hundreds of hostiles on screen, missions built from a seed, a persistent meta
layer that outlives any session.

---

## What this project already has that makes it viable

Three things are already in place that most projects have to retrofit painfully.

**A bit-exact deterministic RNG.** `core/xorshift32.gd` reproduces the
reference's stream exactly (verified: seed 1 yields 0.00006295, 0.01573980,
0.42266560, ...). Anything derived from a seed does not need replicating — send
the seed, every client computes the same answer. That covers gun rolls, spread
patterns, VFX variation, prop scatter, enemy personality. **This is the single
largest bandwidth saving available and it is already built.** The rule to hold:
*if it comes from a seed, sync the seed, never the result.*

**A baked-asset pipeline with a live generator underneath it.**
`tools/build_*.gd` bake once to `.res`/`.tscn`, but the generators are still
there — `layoutTown`/`bsp`/`scatterWilds` in the town builder, the terrain field,
the prop kits. That is exactly the shape a seed-driven mission needs: bake the
KIT (props, buildings, terrain chunks, collision), generate the LAYOUT from a
mission seed at load. No geometry streaming, no download, identical worlds on
every client from one integer.

**Host authority already assumed.** The AI, damage and scoring already run in one
place conceptually; the current pass makes that explicit.

---

## The one thing most likely to be built wrong right now

**Per-demo bespoke sync.** Nine agents are each writing their own RPCs for their
own demo. That produces nine sync dialects, and nine is where it stops — it does
not become a game.

Godot's `MultiplayerSynchronizer` is per-node and per-property. It is fine for a
dozen objects and falls over well before the hundreds the target needs. The
firefight agent was told not to use it naively for ~100 bodies; that instruction
needs to become the general rule.

**What replaces it** — a single replication layer, roughly:

- an entity registry with small numeric ids (not node paths, which are strings
  and expensive)
- snapshots at a fixed tick, delta-encoded against the last one each client
  acknowledged
- quantised transforms (position to cm, rotation to a compressed quaternion) —
  a body does not need 32-bit floats
- **interest management**: a client receives only what is relevant to it, by
  distance and visibility. This is what makes a large map affordable, and the
  AI already has a distance/visibility LOD scheduler (`ai_tick_scheduler.gd`)
  whose bucketing is the same shape as replication relevance. Reuse it.
- a separate reliable event channel for discrete things (fired, hit, died,
  button pressed) — those are not state, and sending them as state is waste
- full-state snapshot on join, so drop-in works

The per-demo code should then say *what* is replicated, not *how*.

---

## Session model

Currently: title screen → demo. The target is closer to hub → mission → extract →
hub, with the hub persistent and missions disposable.

The current `SceneRouter` + `NetGame.host_goto()` split is compatible with that
as long as the demo id becomes a *mission descriptor* (id + seed + parameters)
rather than a bare scene path. Worth making that change early — it is a small
edit now and a wide one later.

---

## What is deliberately out of scope, and must stay out of the session layer

Progression, loadouts, unlocks, and anything resembling a persistent war belong
to a backend service, not to peer-to-peer session code. The mistake to avoid is
letting session netcode learn about persistent state; keep the seam clean now
even though there is nothing on the far side of it yet.

---

## Known load-bearing decisions being made in the current pass

| Decision | Consequence if it stands |
|---|---|
| Laser dots replicate the resolved point, not the ray | Correct and cheap. Keep. |
| Host owns scene routing, clients follow | Correct for missions. Keep. |
| `is_authority()` true in single-player | Lets every demo run standalone. Keep — it is also how missions will run solo. |
| Max 4 hard-coded | Matches the target. Fine, but keep it a constant, not a literal. |
| Per-demo RPCs | **Consolidate.** This is the retrofit cost. |
| No host migration | Acceptable now. A host leaving currently ends the session. |

---

## The next architectural pass, when it happens

1. Extract the replication layer from whatever the nine demos ended up doing —
   after they exist, because the demos are better evidence of what needs syncing
   than a guess would be.
2. Turn demo ids into mission descriptors (id + seed + params).
3. Move layout generation from bake-time to load-time-from-seed for the demos
   that want variety, keeping the kit baked.
4. Add drop-in join with a full-state snapshot.
5. Decide host migration: support it, or make a host leaving end the session
   cleanly and say so in the UI.
