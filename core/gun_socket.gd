class_name GunSocket
extends Resource
## One mating face on a receiver, in receiver-local model units (1 unit = 90 mm).
##
## `height` is measured along X for the bottom and top sockets and along Y for the
## front and rear sockets — an artefact of how the donor guns were cut apart, and
## the reason `fit()` compares it against the mating part's `fit_height` rather
## than against any particular axis of its bounding box.

@export var position: Vector3 = Vector3.ZERO
@export var height: float = 0.0
@export var width: float = 0.0


static func make(pos: Vector3, h: float, w: float) -> GunSocket:
	var s := GunSocket.new()
	s.position = pos
	s.height = h
	s.width = w
	return s
