extends SceneTree
## Re-bakes the physical buoyancy probes of every BuoyancyProbeVolume in the given
## scenes (or every scene that has one) and saves them, printing how each body floats.
## Needs the editor (probes are only generated there), run headless:
##
##     godot --headless --path . -e -s res://tools/bake_buoyancy_probes.gd -- [--fx] [--dry-run] [res://scene.tscn ...]
##
## --fx also regenerates the contact (FX) probes; --dry-run prints without saving.

const SCENES : Array[String] = [
	"res://demo/buoy.tscn",
	"res://demo/floating_box.tscn",
	"res://demo/rowboat.tscn",
	"res://examples/barrel.tscn",
	"res://examples/crate.tscn",
	"res://examples/simple_boat.tscn",
]


# The tree is live only from the first frame.
func _process(_delta : float) -> bool:
	var arguments := OS.get_cmdline_user_args()
	var fx := arguments.has("--fx")
	var dry_run := arguments.has("--dry-run")
	var scenes : Array[String] = []
	for argument in arguments:
		if argument.begins_with("res://"):
			scenes.push_back(argument)
	if scenes.is_empty():
		scenes = SCENES
	for path in scenes:
		_bake(path, fx, dry_run)
	return true


func _bake(path : String, fx : bool, dry_run : bool) -> void:
	var packed : PackedScene = load(path)
	var inherited := packed.get_state().get_base_scene_state() != null
	var scene := packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN_INHERITED if inherited else PackedScene.GEN_EDIT_STATE_MAIN)
	root.add_child(scene)
	print(path)
	for volume : BuoyancyProbeVolume in scene.find_children("*", "BuoyancyProbeVolume", true, false):
		volume.generate_probes(true, fx)
		for warning in volume._get_configuration_warnings():
			print("  WARNING: ", warning)
	if not dry_run:
		var repacked := PackedScene.new()
		var error := repacked.pack(scene)
		if error == OK:
			error = ResourceSaver.save(repacked, path)
		if error != OK:
			push_error("%s: saving failed: %s" % [path, error_string(error)])
	root.remove_child(scene)
	scene.free()
