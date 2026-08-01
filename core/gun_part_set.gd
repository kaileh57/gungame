class_name GunPartSet
extends Resource
## The baked part manifest: all 95 `GunPart` records in flat reference order.
##
## Produced once by the part bake and saved to `res://data/guns/part_library.tres`.
## `PartLibrary` loads exactly this file; nothing else in the project reads the
## raw base64 blob from the reference prototypes.
##
## Flat order is load-bearing — a part's array index is the identity that the
## per-weapon config hash, the golden test vectors and every saved loadout use.

## All parts, index-aligned with `GunPart.index`.
@export var parts: Array[GunPart] = []

## Byte length of the source blob the parts were decoded from. The reference
## blob is 232134 bytes; a mismatch means the source prototype changed.
@export var source_blob_bytes: int = 0
## SHA-256 of the source blob, so a stale bake is detectable without re-decoding.
@export var source_hash: String = ""
## ISO-8601 timestamp of the bake that produced this file.
@export var baked_at: String = ""
## Parts that still had open boundary edges when the bake finished. Must be empty.
@export var unrepaired: PackedInt32Array = PackedInt32Array()
