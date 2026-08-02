extends RefCounted
## The reference implementation's published golden builds, transcribed from
## docs/spec/range.md §10.2.
##
## BAKE-TIME ONLY, and DATA ONLY. `tools/verify_guns.gd` preloads this by path and
## compares every field of these nine seeds against what the port derives; a mismatch
## means the derivation drifted and every downstream number in the balance report is
## void. It lives apart from the checker because it is a transcription of somebody
## else's output — the one file in this tool that must never be "fixed" to make a test
## pass. Changing a number here is changing what the port claims to reproduce.
##
## No `class_name`: a `--script` main loop cannot see a global class until the editor
## has rewritten its class cache, and a preload by path needs no cache.

## `seed -> {field: expected}`, transcribed from docs/spec/range.md §10.2.
const GOLD_SEEDS := {
	1:
	{
		"weapon_name": "Coffin Divorce",
		"archetype": "Assault rifle",
		"tier_name": "Field-Grade",
		"caliber": "11.1×62 wildcat",
		"rpm": 292,
		"magazine": 34,
		"damage": 84.0,
		"spread": 22.0,
		"reliability": 78,
		"overall_length": 785,
	},
	2:
	{
		"weapon_name": "Coffin Kalash",
		"archetype": "Assault rifle",
		"tier_name": "Cobbled",
		"caliber": "11.1×62 wildcat",
		"rpm": 292,
		"magazine": 30,
		"damage": 84.0,
		"spread": 26.0,
		"reliability": 75,
		"overall_length": 835,
	},
	3:
	{
		"weapon_name": "The Fair Warning",
		"archetype": "Machine gun",
		"tier_name": "Gunsmithed",
		"caliber": "11.1×62 wildcat",
		"rpm": 328,
		"magazine": 49,
		"damage": 85.0,
		"spread": 9.0,
		"reliability": 78,
		"overall_length": 1398,
	},
	7:
	{
		"weapon_name": "Scabbed Kalash",
		"archetype": "Chopped auto",
		"tier_name": "Cobbled",
		"caliber": "10.5×62 wildcat",
		"rpm": 404,
		"magazine": 23,
		"damage": 73.0,
		"spread": 30.0,
		"reliability": 44,
		"overall_length": 1012,
	},
	42:
	{
		"weapon_name": "Cracked Nailfile",
		"archetype": "Chopped auto",
		"tier_name": "Field-Grade",
		"caliber": "11.4×62 wildcat",
		"rpm": 386,
		"magazine": 35,
		"damage": 72.0,
		"spread": 21.0,
		"reliability": 89,
		"overall_length": 927,
	},
	99:
	{
		"weapon_name": "Kalash-Sidearm",
		"archetype": "Chopped auto",
		"tier_name": "Scrap",
		"caliber": "11.4×62 wildcat",
		"rpm": 404,
		"magazine": 23,
		"damage": 66.0,
		"spread": 42.0,
		"reliability": 48,
		"overall_length": 936,
	},
	1234:
	{
		"weapon_name": "Reclaimed Woodsman",
		"archetype": "Chopped auto",
		"tier_name": "Cobbled",
		"caliber": "6.6×102 wildcat",
		"rpm": 322,
		"magazine": 15,
		"damage": 153.0,
		"spread": 44.0,
		"reliability": 43,
		"overall_length": 1032,
	},
	5000:
	{
		"weapon_name": "The Cough",
		"archetype": "Carbine",
		"tier_name": "Cobbled",
		"caliber": "11.8×27 wildcat",
		"rpm": 218,
		"magazine": 16,
		"damage": 50.0,
		"spread": 7.8,
		"reliability": 67,
		"overall_length": 997,
	},
	77777:
	{
		"weapon_name": "Coffin Migraine",
		"archetype": "Sidearm",
		"tier_name": "Field-Grade",
		"caliber": ".38 Special",
		"rpm": 234,
		"magazine": 23,
		"damage": 66.0,
		"spread": 12.0,
		"reliability": 65,
		"overall_length": 524,
	},
}
