extends RefCounted
## Reads a headless Godot run's console output and decides whether it went wrong.
##
## Shared by `bake_all.gd` and `verify_scenes.gd`, because the rule is the same
## for both and it is not obvious: **the exit code does not tell you.** Godot
## exits 0 after a script compile error, after a failed `ResourceLoader.load`,
## and after pushing a hundred `push_error`s. The only reliable signal is the
## text, so this is where the text is judged.
##
## Kept deliberately narrow. Every pattern below is something that means an
## artifact is wrong or missing; the exit-time RID and ObjectDB leak reports are
## matched too, because a builder that orphans a node tree is a real defect and
## the whole point of an integration gate is that it does not learn to ignore
## things.

## Substrings that condemn a line. Lower-cased before matching.
const MARKERS: PackedStringArray = [
	"script error",
	"parse error",
	"compile error",
	"failed to load",
	"cannot open file",
	"resource file not found",
	"no loader found",
	"invalid call",
	"invalid access",
	"nonexistent function",
	"can't create file",
	"were leaked at exit",
	"resources still in use at exit",
	"instances were leaked",
	"scene_load_error",
	"failed instantiating",
	"is not a valid scene",
	'condition "',
]

## Cap on how many problem lines are worth reporting from one run. Past this the
## run is comprehensively broken and the tail is noise.
const MAX_HITS: int = 30


## Every line of `text` that means something went wrong, in order, deduplicated.
static func problems(text: String) -> PackedStringArray:
	var hits: PackedStringArray = []
	var seen: Dictionary = {}
	for raw: String in text.split("\n", false):
		var line: String = raw.strip_edges()
		if line.is_empty() or seen.has(line):
			continue
		var lower: String = line.to_lower()
		for m: String in MARKERS:
			if lower.contains(m):
				seen[line] = true
				hits.push_back(line)
				break
		if hits.size() >= MAX_HITS:
			break
	return hits


## The last `count` non-blank lines, for when a run failed without saying why.
static func tail(text: String, count: int) -> PackedStringArray:
	var all: PackedStringArray = text.split("\n", false)
	var kept: PackedStringArray = []
	for i: int in range(maxi(0, all.size() - count), all.size()):
		var line: String = all[i].strip_edges()
		if not line.is_empty():
			kept.push_back(line)
	return kept


## Joins `OS.execute`'s output array, which is one entry per read chunk and not
## one per line, into a single searchable string.
static func joined(out: Array) -> String:
	var chunks: PackedStringArray = []
	for v: Variant in out:
		chunks.push_back(str(v))
	return "\n".join(chunks)
