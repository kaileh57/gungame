# Gun design direction

The user's model, written down before implementing it. Correct this file first if
any of it is wrong — everything downstream is built from it.

---

## 1. Rate of fire is judged RELATIVE TO THE CLASS, not on an absolute scale

This is the central idea and the current system does not have it at all. Today a
gun's grade comes from a pile of absolute stats, so "fast" is simply good and
"slow" is simply bad everywhere.

It should work like this:

| | slow-firing | somewhat fast-firing |
|---|---|---|
| ordinary gun | **bad** | **good** |
| shotgun | **ok** — that is what a shotgun is | **REALLY good** — rare and exciting |

So the same cyclic rate means different things on different weapons. A pump
shotgun firing slowly is *normal* and should not be graded down for it. An
auto-shotgun is a prize. A rifle that fires slowly is a bad rifle.

Generalise it: every class has an EXPECTED rate band. Grade on where the weapon
sits **within its own class's band**, not on the raw number. Being fast for your
class is what makes a weapon good; being slow for your class is what makes it bad.
Class expectations, roughly — a slug gun and an SMG should not be compared:
  launcher / slug gun / shotgun / revolver / bolt sniper → slow is normal
  rifle / carbine / battle rifle                          → middling is normal
  SMG / machine pistol / machine gun                      → fast is normal

## 2. Nothing currently fires slowly. Fix the floor, not just the ceiling.

Every rolled weapon lands at 322-404 rpm. There is no such thing as a slow gun in
the game right now. Slow weapons must actually exist and be common enough to meet:
they are what makes a fast one feel fast.

## 3. Snipers must be real

- ACTUAL snipers should exist as a recognisable thing, not a label on a rifle.
- **All of them do massive damage.** A sniper that does not hit hard is pointless.
- **About 75% carry a sniper scope.** The rest run irons or a lesser optic, which
  is the interesting minority case, not the default.

## 4. Optics should vary and should suit the weapon

- **Sniper scope: far more common on snipers.** It is currently sprayed around.
- **Iron sights: far more common on shotguns and pistols.** Close-range weapons
  should mostly have close-range sighting.
- More variety in between: different magnifications, and **custom reticles** per
  optic type rather than one crosshair for everything. Enhanced zoom on the high
  end.
- **A fast gun with a sniper scope is funny and should still happen** — it is a
  good roll to stumble on. It just must not also be accurate (see below).

## 5. Spread and recoil are the balance, and both are too low

- **Up the spread generally**, and especially on fast-firing weapons.
- **Up the recoil to match**, so rate of fire is paid for.
- A fast gun with a sniper scope must NOT have no spread. The scope shows you the
  target; the spread and recoil are why you still cannot hit it at range. That
  joke only works if the gun is genuinely bad at long range.
- Spread should be the thing that separates classes at range, not damage alone.

## 6. Sound

Improve the gun audio. Weapons that feel different should SOUND different — rate,
calibre and class should all read in the report. A slug gun and an SMG must not
share a sample with the pitch nudged.

---

## What this replaces

The previous instruction was only "pull the rate band apart" (semi capped at 320
rpm, full-auto floored at 320, so the fastest semi and the slowest auto were the
same rate). That fix is still necessary — it is the prerequisite for any of the
above meaning anything — but it is not sufficient on its own, and grading must
become class-relative rather than absolute.
