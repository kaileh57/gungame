extends SceneTree


func _process(_d: float) -> bool:
	print("--- has PhysicalBoneSimulator3D: ", ClassDB.class_exists("PhysicalBoneSimulator3D"))
	var pb := PhysicalBone3D.new()
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
	print("--- PhysicalBone3D properties (storage) ---")
	for p: Dictionary in pb.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE:
			print("  %-46s %s" % [p["name"], type_string(int(p["type"]))])
	print("--- cone defaults ---")
	for k in ["swing_span", "twist_span", "bias", "softness", "relaxation"]:
		print("  ", k, " = ", pb.get("joint_constraints/%s" % k))
	pb.free()
	var sim := PhysicalBoneSimulator3D.new()
	print("--- simulator methods ---")
	for m: Dictionary in sim.get_method_list():
		var n: String = String(m["name"])
		if n.begins_with("physical_bones") or n.begins_with("is_simul"):
			print("  ", n)
	sim.free()
	quit(0)
	return true
