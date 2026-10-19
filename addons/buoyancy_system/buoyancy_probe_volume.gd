@tool
class_name BuoyancyProbeVolume
extends Node3D
## A body's buoyancy probes (BuoyancyProbeNode and BuoyancyFxProbeNode children),
## which BuoyantBody samples. In the editor it bakes the hull under source_paths into
## physical probes, columns on a grid over the hull's plan that measure its shape
## (waterplane area at every height, its sides), and places contact (FX) probes
## along the waterline it floats at; save the scene to keep them. Its configuration
## warnings report how the body floats (draft, trim, heel, stability) for its mass
## and centre of mass. Probes are never generated at runtime.

## Emitted when probes are added, removed, enabled, disabled or edited, or the
## volume itself is toggled. BuoyantBody rebuilds its probe cache on it.
signal probes_changed

const GENERATED_PROBES_NAME := "GeneratedProbes"
const DEBUG_NODE_NAME := "DebugDraw"
const EPSILON := 0.0001
## Raster cells per column side when baking (the hull's slices are measured on
## a grid this much finer than the columns').
const RASTER_PER_COLUMN := 6
## Height bands of each column's area_profile.
const PROFILE_BANDS := 8
## Water density (kg/m³) of the report without a BuoyantBody on the body.
const DEFAULT_WATER_DENSITY := 1025.0

const PHYSICAL_COLOR := Color(0.1, 0.8, 1.0, 0.9)
const FX_COLOR := Color(1.0, 0.62, 0.14, 0.9)
const WATERLINE_COLOR := Color(0.2, 0.9, 1.0, 0.9)
const WATERLINE_HULL_COLOR := Color(1.0, 0.15, 0.95, 0.95)
const FORCE_COLOR := Color(0.1, 0.95, 0.35, 1.0)
const GRAVITY_COLOR := Color(1.0, 0.2, 0.05, 1.0)
const NET_FORCE_COLOR := Color(1.0, 0.9, 0.15, 1.0)
const CENTER_OF_MASS_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const PHYSICAL_DEBUG_CROSS_SIZE := 0.16
const DEBUG_FORCE_SCALE := 0.015
const DEBUG_BODY_FORCE_SCALE := 0.004
const DEBUG_CENTER_OF_MASS_SIZE := 0.35

## Enables this probe volume for buoyancy sampling and contact events.
@export var enabled := true :
	set(value):
		enabled = value
		probes_changed.emit()

@export_group("Generation")
## Mesh roots of the hull the probes are baked from. Empty: the parent's meshes.
@export var source_paths : Array[NodePath] = []
## Local height (m) above which the hull no longer keeps water out. Below it, the
## hull displaces everything at each height that the water cannot reach from the side:
## its solid parts and the air its sides enclose (an open boat's inside below the
## gunwale), but not what open water flows between (a lattice tower). Lower it to a
## deck below which a superstructure lets water in. Infinite: the whole mesh.
@export var watertight_top_y := INF
## Local X coordinate used as the mirror plane when symmetric generation is enabled.
@export var symmetry_plane_x := 0.0
## Bakes the columns of one side of symmetry_plane_x and mirrors them, so the
## body floats level whatever small asymmetries its mesh has.
@export var mirror_across_yz_plane := true
## Interprets the bow as local -Z when tagging generated FX/contact probes.
@export var bow_is_negative_z := true
## About how many columns cover the hull's plan. More follow its shape more closely
## (and cost a little more each physics tick).
@export_range(1, 256, 1) var physical_probe_count := 24
## Target number of generated FX/contact probes around the waterline edge.
@export_range(0, 256, 1) var fx_probe_count := 24
## Fraction of hull length skipped near bow and stern when placing contact probes.
@export_range(0.0, 0.45, 0.01) var longitudinal_margin_fraction := 0.08
## Generates the physical probes in the editor when this volume has none yet.
@export var editor_auto_generate_if_empty := true
## Replaces the generated physical probes (generate_probes()).
@export_tool_button("Generate Physical Probes", "Reload") var generate_physical_probes_action := generate_probes.bind(true, false)
## Replaces the generated contact (FX) probes (generate_probes()).
@export_tool_button("Generate FX Probes", "Reload") var generate_fx_probes_action := generate_probes.bind(false, true)
## Replaces all generated probes (generate_probes()).
@export_tool_button("Generate All Probes", "Reload") var generate_all_probes_action := generate_probes
@export_subgroup("New Probes")
## Editor display radius of each new contact (FX) probe.
@export_range(0.01, 5.0, 0.01, "or_greater", "suffix:m") var generated_fx_probe_display_radius := 0.12

@export_group("Contact Events")
## Depth (m) under the water at which a dry probe becomes wet: for the physical
## probes, and copied into new contact probes (each has its own).
@export_range(-10.0, 10.0, 0.001, "suffix:m") var enter_depth_threshold := 0.03
## Depth (m) at which a wet probe becomes dry again; below enter_depth_threshold.
@export_range(-10.0, 10.0, 0.001, "suffix:m") var exit_depth_threshold := -0.03
## Minimum seconds between two wet/dry changes of a probe.
@export_range(0.0, 10.0, 0.001, "or_greater", "suffix:s") var min_event_interval := 0.08

@export_group("Debug Draw")
## Draws the probes, their water contact, the waterline outline and the forces, in
## the editor and at runtime.
@export var debug_enabled := false :
	set(value):
		debug_enabled = value
		if not debug_enabled:
			_debug_mesh.clear_surfaces()
		elif is_inside_tree():
			_ensure_debug_nodes()
		_update_debug_visibility()
		_queue_debug_rebuild()

var _physical_cache : Array[Node3D] = []
var _fx_cache : Array[Node3D] = []
var _cache_dirty := true
var _warned_missing_runtime_probes := false
## Probe instance id -> BuoyancyProbeState, for the probes currently in this volume.
var _states_by_probe := {}
var _debug_body_state := {}
var _debug_mesh_instance : MeshInstance3D
var _debug_mesh := ImmediateMesh.new()
var _debug_line_vertices := PackedVector3Array()
var _debug_rebuild_queued := false
var _physical_material : StandardMaterial3D
var _fx_material : StandardMaterial3D
var _waterline_material : StandardMaterial3D
var _waterline_hull_material : StandardMaterial3D
var _force_material : StandardMaterial3D
var _gravity_material : StandardMaterial3D
var _net_force_material : StandardMaterial3D
var _center_of_mass_material : StandardMaterial3D


func _enter_tree() -> void:
	add_to_group(&"buoyancy_probe_volume")


func _exit_tree() -> void:
	remove_from_group(&"buoyancy_probe_volume")


func _notification(what: int) -> void:
	if what == NOTIFICATION_CHILD_ORDER_CHANGED:
		_invalidate_probe_cache()
		_queue_probe_refresh()


func _ready() -> void:
	if _get_physical_probes().is_empty() and _get_fx_probes().is_empty():
		if editor_auto_generate_if_empty and Engine.is_editor_hint():
			generate_probes(true, false)
		elif not Engine.is_editor_hint():
			_warn_missing_runtime_probes_once()
	_connect_probe_signals()
	if debug_enabled:
		_ensure_debug_nodes()
	_queue_debug_rebuild()


## Editor only: replaces the generated physical and/or contact (FX) probes with new
## ones from the waterline outline of the meshes under source_paths. Save the scene to
## keep them. The Generate buttons call it.
func generate_probes(physical := true, fx := true) -> void:
	if not Engine.is_editor_hint():
		push_error("BuoyancyProbeVolume %s: probes can only be generated in the editor; generate and save them before running." % get_path())
		return
	var start_usec := Time.get_ticks_usec()
	var root := _get_or_create_generated_root()
	root.transform = Transform3D.IDENTITY
	var counts := PackedStringArray()
	if physical:
		_clear_generated_probes(root, false)
		counts.push_back("%d physical" % _generate_physical_probes(root, HullSlicer.collect_triangles(_get_source_mesh_instances(), global_transform.affine_inverse())))
		_invalidate_probe_cache()
	if fx:
		# On the waterline the new physical probes float at.
		_clear_generated_probes(root, true)
		counts.push_back("%d FX" % _generate_fx_probes(root, _get_generation_context(_get_waterline_y())))
	_finalize_generation()
	print("BuoyancyProbeVolume generated %s probes in %.0f ms: %s" % [" and ".join(counts), float(Time.get_ticks_usec() - start_usec) / 1000.0, get_path()])
	var report := get_hydrostatics_report()
	if not report.is_empty():
		print("  ", report)


## The hull's outline at the waterline y (local) and its bounds, for the contact probes.
func _get_generation_context(y : float) -> Dictionary:
	var source_mesh_instances := _get_source_mesh_instances()
	if source_mesh_instances.is_empty():
		push_warning("%s found no MeshInstance3D sources for buoyancy probe generation." % str(get_path()))
	var segments := _build_waterline_segments(source_mesh_instances, y)
	var bounds := _get_segments_bounds(segments, y)
	if bounds.size.length_squared() <= EPSILON:
		bounds = _get_source_bounds_in_local_space(source_mesh_instances)
	if bounds.size.length_squared() <= EPSILON:
		bounds = AABB(Vector3(-1.5, y, -3.0), Vector3(3.0, 0.01, 6.0))
	var hull_points := _build_waterline_hull_points(segments, bounds)
	return {"y": y, "hull_points": hull_points, "bounds": bounds}


func _generate_physical_probes(root: Node, triangles: PackedVector3Array) -> int:
	var columns := _bake_columns(triangles)
	if columns.is_empty():
		push_warning("%s: the hull meshes under source_paths have no volume below watertight_top_y; no physical probes." % get_path())
	var generated_owner := _get_generated_node_owner()
	for i in columns.size():
		var column : Dictionary = columns[i]
		var probe := BuoyancyProbeNode.new()
		probe.name = "Probe_%03d" % i
		probe.position = column["position"]
		probe.height = column["height"]
		probe.area_profile = column["area_profile"]
		probe.side_panels = column["side_panels"]
		root.add_child(probe)
		probe.owner = generated_owner
	return columns.size()


## The plan (x, z) bounds of the triangles reaching below watertight_top_y.
func _get_plan_bounds(triangles : PackedVector3Array) -> Rect2:
	var plan := Rect2()
	var found := false
	for i in range(0, triangles.size() - 2, 3):
		if minf(triangles[i].y, minf(triangles[i + 1].y, triangles[i + 2].y)) >= watertight_top_y:
			continue
		for vertex in [triangles[i], triangles[i + 1], triangles[i + 2]]:
			var point := Vector2(vertex.x, vertex.z)
			plan = plan.expand(point) if found else Rect2(point, Vector2.ZERO)
			found = true
	return plan


## The hull's columns: a square grid over its plan (physical_probe_count cells or
## so), each measured on the hull's slices (_HullSlices): its cross-section at every
## height, and the sides it owns (each slice of the hull's side belongs to the column
## just inside it).
func _bake_columns(triangles: PackedVector3Array) -> Array[Dictionary]:
	var mirror := mirror_across_yz_plane
	var plan := _get_plan_bounds(triangles)
	if plan.get_area() <= EPSILON:
		return []
	var spacing := sqrt(plan.get_area() / maxf(physical_probe_count, 1))
	var slices := _HullSlices.new(triangles, watertight_top_y, plan, spacing / RASTER_PER_COLUMN)
	# The grid is sized for the target count, then again for the cells the hull fills.
	var cells : Array[Dictionary] = []
	for attempt in 2:
		if attempt > 0:
			spacing *= sqrt(float(cells.size() * (2 if mirror else 1)) / physical_probe_count)
		cells = _measure_cells(slices, spacing, mirror)
		if cells.is_empty():
			return []
	var step := 1.5 * slices.resolution
	for level in slices.levels.size():
		var y := slices.get_level_height(level)
		var points := slices.segments[level]
		for i in range(0, points.size(), 2):
			var a := points[i]
			var b := points[i + 1]
			var length := a.distance_to(b)
			var middle := (a + b) * 0.5
			if length <= EPSILON or (mirror and middle.x < symmetry_plane_x):
				continue
			var normal := Vector2(b.y - a.y, a.x - b.x) / length
			var hull_front := slices.is_hull(level, middle + normal * step)
			if hull_front == slices.is_hull(level, middle - normal * step):
				continue # Enclosed (an inner wall), or a sliver in open water.
			if hull_front:
				normal = -normal
			var owner_cell := cells[_nearest_cell(cells, middle - normal * step)]
			var bottom : float = owner_cell["position"].y
			if y < bottom or y > bottom + owner_cell["height"]:
				continue
			# Averaged over the column's levels: a side length per unit of height.
			var panels : PackedVector2Array = owner_cell["side_panels"]
			var bin := posmod(roundi(atan2(normal.y, normal.x) / (TAU / BuoyancyProbeNode.SIDE_PANEL_BINS)), BuoyancyProbeNode.SIDE_PANEL_BINS)
			panels[bin] += normal * (length * slices.level_height / owner_cell["height"])
			owner_cell["side_panels"] = panels
	var columns : Array[Dictionary] = []
	for cell in cells:
		columns.push_back(cell)
		if mirror:
			columns.push_back(_mirrored_column(cell))
	columns.sort_custom(func(a : Dictionary, b : Dictionary) -> bool:
		var pa : Vector3 = a["position"]
		var pb : Vector3 = b["position"]
		return pa.z < pb.z - EPSILON or (absf(pa.z - pb.z) <= EPSILON and pa.x < pb.x))
	return columns


## The grid cells of side spacing the hull fills, each with its lowest point, height
## and band areas. Mirrored: only those right of symmetry_plane_x, where the grid starts.
func _measure_cells(slices : _HullSlices, spacing : float, mirror : bool) -> Array[Dictionary]:
	var plan := slices.plan
	var origin_x := symmetry_plane_x if mirror else plan.position.x
	var count_x := maxi(ceili((plan.end.x - origin_x) / spacing - EPSILON), 1)
	var count_z := maxi(ceili(plan.size.y / spacing - EPSILON), 1)
	var origin_z := plan.get_center().y - count_z * spacing * 0.5
	var cells : Array[Dictionary] = []
	for iz in count_z:
		for ix in count_x:
			var cell := Rect2(origin_x + ix * spacing, origin_z + iz * spacing, spacing, spacing)
			var areas := PackedFloat32Array()
			var first := -1
			var last := -1
			for level in slices.levels.size():
				var area := slices.get_area(level, cell)
				areas.push_back(area)
				if area > 0.0:
					first = level if first < 0 else first
					last = level
			if first < 0:
				continue
			var bottom := slices.get_level_height(first) - 0.5 * slices.level_height
			var height := (last - first + 1) * slices.level_height
			# Each band's mean section, from the levels it spans (partly at its ends).
			var band := height / PROFILE_BANDS
			var profile := PackedFloat32Array()
			profile.resize(PROFILE_BANDS)
			for k in PROFILE_BANDS:
				var band_bottom := bottom + k * band
				var volume := 0.0
				for level in range(first, last + 1):
					var level_bottom := slices.get_level_height(level) - 0.5 * slices.level_height
					volume += areas[level] * maxf(minf(level_bottom + slices.level_height, band_bottom + band) - maxf(level_bottom, band_bottom), 0.0)
				profile[k] = volume / band
			var panels := PackedVector2Array()
			panels.resize(BuoyancyProbeNode.SIDE_PANEL_BINS)
			cells.push_back({
				"position": Vector3(cell.get_center().x, bottom, cell.get_center().y),
				"height": height,
				"area_profile": profile,
				"side_panels": panels,
			})
	return cells


## Index of the cell nearest point (in the plan).
func _nearest_cell(cells : Array[Dictionary], point : Vector2) -> int:
	var nearest := 0
	var nearest_distance := INF
	for i in cells.size():
		var center : Vector3 = cells[i]["position"]
		var distance := Vector2(center.x, center.z).distance_squared_to(point)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = i
	return nearest


## cell mirrored across symmetry_plane_x.
func _mirrored_column(cell : Dictionary) -> Dictionary:
	var mirrored := cell.duplicate(true)
	var center : Vector3 = cell["position"]
	mirrored["position"] = Vector3(2.0 * symmetry_plane_x - center.x, center.y, center.z)
	var panels : PackedVector2Array = cell["side_panels"]
	var mirrored_panels := PackedVector2Array()
	mirrored_panels.resize(panels.size())
	for bin in panels.size():
		# A normal (x, z) mirrors to (-x, z): its angle t to pi - t.
		@warning_ignore("integer_division")
		var mirrored_bin := posmod(BuoyancyProbeNode.SIDE_PANEL_BINS / 2 - bin, BuoyancyProbeNode.SIDE_PANEL_BINS)
		mirrored_panels[mirrored_bin] = Vector2(-panels[bin].x, panels[bin].y)
	mirrored["side_panels"] = mirrored_panels
	return mirrored


func _generate_fx_probes(root: Node, context: Dictionary) -> int:
	var hull_points : Array = context["hull_points"]
	var bounds : AABB = context["bounds"]
	var fx_specs := _build_fx_probe_specs(hull_points, bounds)
	var generated_owner := _get_generated_node_owner()
	var fx_count := 0
	for spec in fx_specs:
		var probe := BuoyancyFxProbeNode.new()
		probe.name = "FxProbe_%03d_%s" % [fx_count, str(spec.get("tag", "side")).capitalize()]
		probe.position = Vector3(float(spec["x"]), float(context["y"]), float(spec["z"]))
		probe.display_radius = generated_fx_probe_display_radius
		probe.tag = str(spec.get("tag", "side"))
		probe.enter_depth_threshold = enter_depth_threshold
		probe.exit_depth_threshold = exit_depth_threshold
		root.add_child(probe)
		probe.owner = generated_owner
		fx_count += 1
	return fx_count


func _finalize_generation() -> void:
	_invalidate_probe_cache()
	_connect_probe_signals()
	_queue_debug_rebuild()
	update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	if _get_physical_probes().is_empty():
		return PackedStringArray(["No buoyancy probes: the body does not float. Set source_paths to the hull meshes, press Generate All Probes, and save the scene."])
	var warnings := PackedStringArray()
	var h := _get_hydrostatics()
	if h.is_empty():
		return warnings
	if not h.has("waterline"):
		warnings.push_back(get_hydrostatics_report() + " Give it more hull (watertight_top_y) or less mass.")
		return warnings
	var gm : Vector2 = h["metacentric_height"]
	if gm.x <= 0.0 or gm.y <= 0.0:
		warnings.push_back("Unstable upright: its metacentric height is %.2f m across and %.2f m along, so it rolls over and floats tilted or on its side (as a light cube or a log does). For a hull that should float upright, lower the body's center_of_mass (custom mode) or widen the hull." % [gm.x, gm.y])
	if absf(h["heel_degrees"]) > 2.0 or absf(h["trim_degrees"]) > 3.0:
		var center : Vector3 = h["buoyancy_center"]
		warnings.push_back("Floats heeled %.1f and trimmed %.1f degrees: its centre of mass is off the hull's centre of buoyancy. To float level, set the body's center_of_mass (custom mode) to x = %.2f, z = %.2f." % [h["heel_degrees"], h["trim_degrees"], center.x, center.z])
	if h["freeboard"] < 0.05 * h["hull_height"]:
		warnings.push_back("Floats with only %.2f m freeboard: the smallest wave floods it. Give it more hull (watertight_top_y) or less mass." % h["freeboard"])
	var fx_probes := _get_fx_probes()
	if not fx_probes.is_empty() and absf(fx_probes[0].position.y - h["waterline_local"]) > maxf(0.05, 0.1 * h["hull_height"]):
		warnings.push_back("The contact probes are at local y = %.2f m, but the body floats with its waterline at %.2f m: press Generate FX Probes." % [fx_probes[0].position.y, h["waterline_local"]])
	return warnings


## States of the enabled physical probes, created once per probe and reused.
## Empty while the volume is disabled.
func get_physical_probe_states() -> Array[BuoyancyProbeState]:
	var states : Array[BuoyancyProbeState] = []
	if not enabled:
		return states
	var probes := _get_physical_probes()
	if probes.is_empty():
		_warn_missing_runtime_probes_once()
	for probe in probes:
		if (probe as BuoyancyProbeNode).enabled:
			states.push_back(_get_or_create_state(probe, false, "", enter_depth_threshold, exit_depth_threshold))
	return states


## States of the enabled contact (FX) probes. Empty while the volume is disabled.
func get_contact_probe_states() -> Array[BuoyancyProbeState]:
	var states : Array[BuoyancyProbeState] = []
	if not enabled:
		return states
	for probe in _get_fx_probes():
		var fx_probe := probe as BuoyancyFxProbeNode
		if fx_probe.enabled:
			states.push_back(_get_or_create_state(probe, true, fx_probe.tag, fx_probe.enter_depth_threshold, fx_probe.exit_depth_threshold))
	return states


func _get_or_create_state(probe : Node3D, is_fx_probe : bool, tag : String, enter_threshold : float, exit_threshold : float) -> BuoyancyProbeState:
	var key := probe.get_instance_id()
	if not _states_by_probe.has(key):
		_states_by_probe[key] = BuoyancyProbeState.new(probe, is_fx_probe, tag, enter_threshold, exit_threshold, min_event_interval)
	return _states_by_probe[key]


## Called by BuoyantBody each tick with the body's centre of mass and forces, for the debug draw.
func set_debug_body_state(center_of_mass_world: Vector3, gravity_force: Vector3, external_force: Vector3) -> void:
	if not debug_enabled:
		return
	_debug_body_state = {
		"center_of_mass_world": center_of_mass_world,
		"gravity_force": gravity_force,
		"external_force": external_force,
	}
	_queue_debug_rebuild()


## The hull's outline at local height y.
func _build_waterline_segments(mesh_instances: Array[MeshInstance3D], y : float) -> Array[Dictionary]:
	var triangles := HullSlicer.collect_triangles(mesh_instances, global_transform.affine_inverse())
	var points := HullSlicer.slice(triangles, y)
	var segments : Array[Dictionary] = []
	for i in range(0, points.size(), 2):
		segments.push_back({"a": points[i], "b": points[i + 1]})
	return segments


func _build_waterline_hull_points(segments: Array, bounds: AABB) -> Array:
	var points : Array = []
	for segment in segments:
		points.push_back(segment["a"])
		points.push_back(segment["b"])
	points = _deduplicate_vector2_points(points)
	if points.size() < 3:
		points = _get_bounds_footprint_points(bounds)
	return _build_convex_hull_2d(points)


func _get_bounds_footprint_points(bounds: AABB) -> Array:
	var min_x := bounds.position.x
	var max_x := bounds.position.x + bounds.size.x
	var min_z := bounds.position.z
	var max_z := bounds.position.z + bounds.size.z
	return [
		Vector2(min_x, min_z),
		Vector2(max_x, min_z),
		Vector2(max_x, max_z),
		Vector2(min_x, max_z),
	]


func _deduplicate_vector2_points(points: Array) -> Array:
	var result : Array = []
	for point in points:
		var p : Vector2 = point
		var is_duplicate := false
		for existing in result:
			if p.distance_squared_to(existing) <= EPSILON * EPSILON:
				is_duplicate = true
				break
		if not is_duplicate:
			result.push_back(p)
	return result


func _build_convex_hull_2d(points: Array) -> Array:
	points = _deduplicate_vector2_points(points)
	if points.size() < 3:
		return points
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		if absf(a.x - b.x) > EPSILON:
			return a.x < b.x
		return a.y < b.y
	)
	var lower : Array = []
	for point in points:
		var p : Vector2 = point
		while lower.size() >= 2 and _cross_2d(lower[lower.size() - 2], lower[lower.size() - 1], p) <= EPSILON:
			lower.remove_at(lower.size() - 1)
		lower.push_back(p)
	var upper : Array = []
	for reverse_index in points.size():
		var p : Vector2 = points[points.size() - 1 - reverse_index]
		while upper.size() >= 2 and _cross_2d(upper[upper.size() - 2], upper[upper.size() - 1], p) <= EPSILON:
			upper.remove_at(upper.size() - 1)
		upper.push_back(p)
	lower.remove_at(lower.size() - 1)
	upper.remove_at(upper.size() - 1)
	var hull : Array = []
	hull.append_array(lower)
	hull.append_array(upper)
	return hull if hull.size() >= 3 else points


func _cross_2d(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b - a).cross(c - a)


func _build_fx_probe_specs(hull_points: Array, bounds: AABB) -> Array[Dictionary]:
	var specs : Array[Dictionary] = []
	if fx_probe_count <= 0:
		return specs
	@warning_ignore("integer_division")
	var pair_count := maxi(fx_probe_count / 2, 1)
	for station_index in pair_count:
		var z := _get_station_z(station_index, pair_count, bounds)
		var interval := _get_hull_interval_at_z(hull_points, bounds, z)
		var left_point := Vector2(interval.x, z)
		var right_point := Vector2(interval.y, z)
		specs.push_back({"x": left_point.x, "z": left_point.y, "tag": _get_fx_tag(left_point, bounds)})
		if specs.size() >= fx_probe_count:
			break
		specs.push_back({"x": right_point.x, "z": right_point.y, "tag": _get_fx_tag(right_point, bounds)})
	if fx_probe_count % 2 != 0 and specs.size() < fx_probe_count:
		var z := bounds.position.z if bow_is_negative_z else bounds.position.z + bounds.size.z
		specs.push_back({"x": symmetry_plane_x, "z": z, "tag": "bow"})
	return specs


func _get_station_z(index: int, count: int, bounds: AABB) -> float:
	var margin := bounds.size.z * clampf(longitudinal_margin_fraction, 0.0, 0.45)
	var start_z := bounds.position.z + margin
	var end_z := bounds.position.z + bounds.size.z - margin
	if count <= 1:
		return (start_z + end_z) * 0.5
	return lerpf(start_z, end_z, (float(index) + 0.5) / float(count))


func _get_hull_interval_at_z(hull_points: Array, bounds: AABB, z: float) -> Vector2:
	if hull_points.size() < 3:
		return Vector2(bounds.position.x, bounds.position.x + bounds.size.x)
	var intersections : Array[float] = []
	for i in hull_points.size():
		var a : Vector2 = hull_points[i]
		var b : Vector2 = hull_points[(i + 1) % hull_points.size()]
		var min_z := minf(a.y, b.y)
		var max_z := maxf(a.y, b.y)
		if z < min_z - EPSILON or z > max_z + EPSILON:
			continue
		if absf(a.y - b.y) <= EPSILON:
			if absf(z - a.y) <= EPSILON:
				intersections.push_back(a.x)
				intersections.push_back(b.x)
			continue
		var t := (z - a.y) / (b.y - a.y)
		if t < -EPSILON or t > 1.0 + EPSILON:
			continue
		intersections.push_back(lerpf(a.x, b.x, clampf(t, 0.0, 1.0)))
	if intersections.size() < 2:
		return Vector2(bounds.position.x, bounds.position.x + bounds.size.x)
	intersections.sort()
	intersections = _deduplicate_floats(intersections)
	if intersections.size() < 2:
		return Vector2(bounds.position.x, bounds.position.x + bounds.size.x)
	return Vector2(intersections[0], intersections[intersections.size() - 1])


func _deduplicate_floats(values: Array[float]) -> Array[float]:
	var result : Array[float] = []
	for value in values:
		if result.is_empty() or absf(value - result[result.size() - 1]) > EPSILON:
			result.push_back(value)
	return result


func _get_fx_tag(point: Vector2, bounds: AABB) -> String:
	var length := maxf(bounds.size.z, EPSILON)
	var bow_t := (point.y - bounds.position.z) / length
	if not bow_is_negative_z:
		bow_t = 1.0 - bow_t
	if bow_t <= 0.22:
		return "bow"
	if bow_t >= 0.82:
		return "stern"
	return "side"


func _get_source_roots() -> Array[Node3D]:
	var roots : Array[Node3D] = []
	if source_paths.is_empty():
		var parent_node := get_parent() as Node3D
		if parent_node != null:
			roots.push_back(parent_node)
		return roots
	for source_path in source_paths:
		var source := get_node_or_null(source_path) as Node3D
		if source != null and not roots.has(source):
			roots.push_back(source)
	return roots


func _get_source_mesh_instances() -> Array[MeshInstance3D]:
	var mesh_instances : Array[MeshInstance3D] = []
	for source_root in _get_source_roots():
		for mesh_instance in HullSlicer.collect_mesh_instances(source_root):
			# The probes (and the debug draw) are meshes too, but not the hull's.
			if not is_ancestor_of(mesh_instance) and not mesh_instances.has(mesh_instance):
				mesh_instances.push_back(mesh_instance)
	return mesh_instances


func _get_source_bounds_in_local_space(mesh_instances: Array[MeshInstance3D]) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for mesh_instance in mesh_instances:
		if mesh_instance.mesh == null:
			continue
		var mesh_bounds := mesh_instance.mesh.get_aabb()
		for corner in _get_aabb_corners(mesh_bounds):
			var local_corner := to_local(mesh_instance.global_transform * corner)
			if not has_bounds:
				bounds = AABB(local_corner, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(local_corner)
	return bounds if has_bounds else AABB()


func _get_segments_bounds(segments: Array[Dictionary], y : float) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for segment in segments:
		var a : Vector2 = segment["a"]
		var b : Vector2 = segment["b"]
		for point in [Vector3(a.x, y, a.y), Vector3(b.x, y, b.y)]:
			if not has_bounds:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point)
	return bounds if has_bounds else AABB()


func _get_aabb_corners(bounds: AABB) -> Array[Vector3]:
	var p := bounds.position
	var s := bounds.size
	return [
		p,
		p + Vector3(s.x, 0.0, 0.0),
		p + Vector3(0.0, s.y, 0.0),
		p + Vector3(0.0, 0.0, s.z),
		p + Vector3(s.x, s.y, 0.0),
		p + Vector3(s.x, 0.0, s.z),
		p + Vector3(0.0, s.y, s.z),
		p + s,
	]


func _get_or_create_generated_root() -> Node3D:
	var root := get_node_or_null(GENERATED_PROBES_NAME) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = GENERATED_PROBES_NAME
		add_child(root)
	root.owner = _get_generated_node_owner()
	return root


## Removes root's physical probes, or its contact probes when fx.
func _clear_generated_probes(root: Node, fx : bool) -> void:
	for child in root.get_children():
		var is_kind := _is_fx_probe(child) if fx else _is_physical_probe(child)
		if is_kind:
			root.remove_child(child)
			child.queue_free()


func _get_generated_node_owner() -> Node:
	if Engine.is_editor_hint() and is_inside_tree():
		var edited_scene_root := get_tree().edited_scene_root
		if edited_scene_root != null:
			return edited_scene_root
	return owner


func _get_physical_probes() -> Array[Node3D]:
	if _cache_dirty:
		_rebuild_probe_cache()
	return _physical_cache


func _get_fx_probes() -> Array[Node3D]:
	if _cache_dirty:
		_rebuild_probe_cache()
	return _fx_cache


func _is_physical_probe(node: Node) -> bool:
	return node is BuoyancyProbeNode


func _is_fx_probe(node: Node) -> bool:
	return node is BuoyancyFxProbeNode


func _rebuild_probe_cache() -> void:
	_physical_cache.clear()
	_fx_cache.clear()
	_collect_probes(self)
	_cache_dirty = false
	var kept := {}
	for probe in _physical_cache + _fx_cache:
		var key := probe.get_instance_id()
		if _states_by_probe.has(key):
			kept[key] = _states_by_probe[key]
	_states_by_probe = kept


func _collect_probes(root: Node) -> void:
	for child in root.get_children():
		if _is_physical_probe(child):
			_physical_cache.push_back(child)
		elif _is_fx_probe(child):
			_fx_cache.push_back(child)
		else:
			_collect_probes(child)


func _invalidate_probe_cache() -> void:
	_cache_dirty = true


func _queue_probe_refresh() -> void:
	if not is_inside_tree():
		return
	call_deferred(&"_refresh_probes_deferred")


func _refresh_probes_deferred() -> void:
	if not is_inside_tree():
		return
	_connect_probe_signals()
	_queue_debug_rebuild()
	probes_changed.emit()


func _connect_probe_signals() -> void:
	for probe in _get_physical_probes():
		if probe != null and probe.has_signal(&"probe_changed") and not probe.is_connected(&"probe_changed", Callable(self, "_on_probe_changed")):
			probe.connect(&"probe_changed", Callable(self, "_on_probe_changed"))
	for probe in _get_fx_probes():
		if probe != null and probe.has_signal(&"probe_changed") and not probe.is_connected(&"probe_changed", Callable(self, "_on_probe_changed")):
			probe.connect(&"probe_changed", Callable(self, "_on_probe_changed"))


func _on_probe_changed() -> void:
	# Threshold edits must reach the probe's state, so drop it; the next
	# get_*_probe_states() call recreates it.
	_states_by_probe.clear()
	_queue_debug_rebuild()
	probes_changed.emit()


func _warn_missing_runtime_probes_once() -> void:
	if _warned_missing_runtime_probes:
		return
	_warned_missing_runtime_probes = true
	push_warning("%s has no buoyancy probes. Generate probes in the editor and save the scene before running." % str(get_path()))


func _queue_debug_rebuild() -> void:
	if not debug_enabled or not is_inside_tree():
		return
	if _debug_rebuild_queued:
		return
	_debug_rebuild_queued = true
	call_deferred(&"_rebuild_queued_debug_mesh")


func _rebuild_queued_debug_mesh() -> void:
	_debug_rebuild_queued = false
	_rebuild_debug_mesh()


func _ensure_debug_nodes() -> void:
	if _debug_mesh_instance != null:
		return
	# Internal and unowned: debug geometry is never saved into the scene.
	_debug_mesh_instance = MeshInstance3D.new()
	_debug_mesh_instance.name = DEBUG_NODE_NAME
	add_child(_debug_mesh_instance, false, INTERNAL_MODE_BACK)
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mesh_instance.extra_cull_margin = 10000.0
	_debug_mesh_instance.mesh = _debug_mesh
	_update_debug_materials()
	_update_debug_visibility()

func _update_debug_visibility() -> void:
	if _debug_mesh_instance != null:
		_debug_mesh_instance.visible = debug_enabled


func _update_debug_materials() -> void:
	if _physical_material == null:
		_physical_material = _create_debug_material(PHYSICAL_COLOR)
	if _fx_material == null:
		_fx_material = _create_debug_material(FX_COLOR)
	if _waterline_material == null:
		_waterline_material = _create_debug_material(WATERLINE_COLOR)
	if _waterline_hull_material == null:
		_waterline_hull_material = _create_debug_material(WATERLINE_HULL_COLOR)
	if _force_material == null:
		_force_material = _create_debug_material(FORCE_COLOR)
	if _gravity_material == null:
		_gravity_material = _create_debug_material(GRAVITY_COLOR)
	if _net_force_material == null:
		_net_force_material = _create_debug_material(NET_FORCE_COLOR)
	if _center_of_mass_material == null:
		_center_of_mass_material = _create_debug_material(CENTER_OF_MASS_COLOR)


func _create_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material


func _rebuild_debug_mesh() -> void:
	if not is_inside_tree():
		return
	if not debug_enabled:
		if _debug_mesh_instance != null:
			_debug_mesh.clear_surfaces()
		return
	_ensure_debug_nodes()
	_update_debug_materials()
	_debug_mesh.clear_surfaces()

	if Engine.is_editor_hint():
		_begin_debug_lines()
		_add_debug_waterline_intersection()
		_commit_debug_lines(_waterline_material)
		_begin_debug_lines()
		_add_debug_waterline_convex_hull()
		_commit_debug_lines(_waterline_hull_material)

	_begin_debug_lines()
	for probe in _get_physical_probes():
		if probe != null:
			_add_debug_cross(probe.position, PHYSICAL_DEBUG_CROSS_SIZE)
	_commit_debug_lines(_physical_material)

	_begin_debug_lines()
	for probe in _get_fx_probes():
		if probe != null:
			_add_debug_cross(probe.position, maxf(float(probe.get(&"display_radius")), 0.04))
	_commit_debug_lines(_fx_material)

	_begin_debug_lines()
	_add_debug_water_lines()
	_commit_debug_lines(_waterline_material)

	_begin_debug_lines()
	_add_debug_force_lines()
	_commit_debug_lines(_force_material)

	if _has_debug_body_state():
		_begin_debug_lines()
		_add_debug_center_of_mass()
		_commit_debug_lines(_center_of_mass_material)
		_begin_debug_lines()
		_add_debug_body_gravity()
		_commit_debug_lines(_gravity_material)
		_begin_debug_lines()
		_add_debug_body_net_force()
		_commit_debug_lines(_net_force_material)


func _begin_debug_lines() -> void:
	_debug_line_vertices.clear()


func _add_debug_vertex(vertex: Vector3) -> void:
	_debug_line_vertices.push_back(vertex)


func _commit_debug_lines(material: Material) -> void:
	if _debug_line_vertices.is_empty() or _debug_line_vertices.size() % 2 != 0:
		return
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for vertex in _debug_line_vertices:
		_debug_mesh.surface_add_vertex(vertex)
	_debug_mesh.surface_end()
	_set_last_surface_material(material)


func _set_last_surface_material(material: Material) -> void:
	if _debug_mesh_instance == null:
		return
	var surface_index := _debug_mesh.get_surface_count() - 1
	if surface_index >= 0:
		_debug_mesh_instance.set_surface_override_material(surface_index, material)


func _add_debug_cross(center: Vector3, radius: float) -> void:
	_add_debug_vertex(center + Vector3.LEFT * radius)
	_add_debug_vertex(center + Vector3.RIGHT * radius)
	_add_debug_vertex(center + Vector3.DOWN * radius)
	_add_debug_vertex(center + Vector3.UP * radius)
	_add_debug_vertex(center + Vector3.FORWARD * radius)
	_add_debug_vertex(center + Vector3.BACK * radius)


func _add_debug_waterline_intersection() -> void:
	var y := _get_waterline_y()
	for segment in _build_waterline_segments(_get_source_mesh_instances(), y):
		var a : Vector2 = segment["a"]
		var b : Vector2 = segment["b"]
		_add_debug_vertex(Vector3(a.x, y, a.y))
		_add_debug_vertex(Vector3(b.x, y, b.y))


func _add_debug_waterline_convex_hull() -> void:
	var context := _get_generation_context(_get_waterline_y())
	var hull_points : Array = context["hull_points"]
	if hull_points.size() < 2:
		return
	var hull_y : float = context["y"] + 0.03
	for i in hull_points.size():
		var a : Vector2 = hull_points[i]
		var b : Vector2 = hull_points[(i + 1) % hull_points.size()]
		_add_debug_vertex(Vector3(a.x, hull_y, a.y))
		_add_debug_vertex(Vector3(b.x, hull_y, b.y))


func _add_debug_water_lines() -> void:
	for state : BuoyancyProbeState in _states_by_probe.values():
		if state.has_sample:
			_add_debug_vertex(to_local(state.world_position))
			_add_debug_vertex(to_local(state.water_position))


func _add_debug_force_lines() -> void:
	for state : BuoyancyProbeState in _states_by_probe.values():
		if not state.is_fx_probe and state.has_sample:
			_add_debug_arrow(state.world_position, state.force, DEBUG_FORCE_SCALE)


func _has_debug_body_state() -> bool:
	return not _debug_body_state.is_empty()


func _add_debug_center_of_mass() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	_add_debug_cross(to_local(center_world), DEBUG_CENTER_OF_MASS_SIZE)


func _add_debug_body_gravity() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var gravity_force : Vector3 = _debug_body_state["gravity_force"]
	_add_debug_arrow(center_world, gravity_force, DEBUG_BODY_FORCE_SCALE)


func _add_debug_body_net_force() -> void:
	var center_world : Vector3 = _debug_body_state["center_of_mass_world"]
	var external_force : Vector3 = _debug_body_state["external_force"]
	_add_debug_arrow(center_world, external_force, DEBUG_BODY_FORCE_SCALE)


func _add_debug_arrow(start_world: Vector3, force: Vector3, force_scale: float) -> void:
	if force.length_squared() <= 0.0001:
		return
	var start_local := to_local(start_world)
	var end_local := to_local(start_world + force * force_scale)
	_add_debug_vertex(start_local)
	_add_debug_vertex(end_local)
	_add_arrowhead(end_local, start_local)


func _add_arrowhead(end_local: Vector3, start_local: Vector3) -> void:
	var direction := end_local - start_local
	if direction.length_squared() <= 0.0001:
		return
	direction = direction.normalized()
	var side := direction.cross(Vector3.UP)
	if side.length_squared() <= 0.0001:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(direction).normalized()
	var length := minf(end_local.distance_to(start_local) * 0.22, 0.45)
	var width := length * 0.45
	var base := end_local - direction * length
	_add_debug_vertex(end_local)
	_add_debug_vertex(base + side * width)
	_add_debug_vertex(end_local)
	_add_debug_vertex(base - side * width)
	_add_debug_vertex(end_local)
	_add_debug_vertex(base + up * width)
	_add_debug_vertex(end_local)
	_add_debug_vertex(base - up * width)


## How the body floats upright in calm water, for its mass and centre of mass, from
## the enabled physical probes (in the body's frame). Empty without a RigidBody3D
## ancestor or probes.
func _get_hydrostatics() -> Dictionary:
	var body := _find_rigid_body()
	var probes : Array[BuoyancyProbeNode] = []
	for probe in _get_physical_probes():
		if (probe as BuoyancyProbeNode).enabled:
			probes.push_back(probe)
	if body == null or probes.is_empty() or not body.is_inside_tree():
		return {}
	var density := DEFAULT_WATER_DENSITY
	for buoyant_body in body.find_children("*", "BuoyantBody", true, false):
		density = buoyant_body.get(&"water_density")
		break
	var to_body := body.global_transform.affine_inverse()
	var positions := PackedVector3Array()
	var bottoms := PackedFloat32Array()
	var heights := PackedFloat32Array()
	var profiles : Array[PackedFloat32Array] = []
	var bottom := INF
	var top := -INF
	var capacity := 0.0
	for probe in probes:
		var body_position := to_body * probe.global_position
		positions.push_back(body_position)
		bottoms.push_back(body_position.y)
		heights.push_back(probe.height)
		profiles.push_back(probe.area_profile)
		bottom = minf(bottom, body_position.y)
		top = maxf(top, body_position.y + probe.height)
		capacity += BuoyancyProbeNode.volume_below(probe.area_profile, probe.height, probe.height).x * density
	var result := {"mass": body.mass, "capacity": capacity, "hull_height": top - bottom}
	# The waterline where the displaced water weighs the body's mass.
	var waterline := BuoyancyProbeNode.find_waterline(bottoms, heights, profiles, body.mass / density)
	if not is_finite(waterline):
		return result
	var volume := 0.0
	var buoyancy_center := Vector3.ZERO
	var area := 0.0
	var flotation := Vector2.ZERO
	for p in probes.size():
		var submerged := BuoyancyProbeNode.volume_below(probes[p].area_profile, probes[p].height, waterline - positions[p].y)
		volume += submerged.x
		buoyancy_center += Vector3(positions[p].x * submerged.x, positions[p].y * submerged.x + submerged.y, positions[p].z * submerged.x)
		var section := BuoyancyProbeNode.area_at(probes[p].area_profile, probes[p].height, waterline - positions[p].y)
		area += section
		flotation += Vector2(positions[p].x, positions[p].z) * section
	buoyancy_center /= maxf(volume, EPSILON)
	flotation /= maxf(area, EPSILON)
	# The waterplane's second moments about its centre (each column a square of its area).
	var inertia := Vector2.ZERO
	for p in probes.size():
		var section := BuoyancyProbeNode.area_at(probes[p].area_profile, probes[p].height, waterline - positions[p].y)
		var offset := Vector2(positions[p].x, positions[p].z) - flotation
		inertia += section * (offset * offset + Vector2.ONE * section / 12.0)
	var center_of_mass := body.center_of_mass if body.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM else Vector3.ZERO
	# Metacentric heights GM = KB + BM - KG, across (roll) and along (pitch).
	var metacentric := Vector2.ONE * (buoyancy_center.y - center_of_mass.y) + inertia / maxf(volume, EPSILON)
	result.merge({
		"waterline": waterline,
		"waterline_local": waterline - (to_body * global_position).y,
		"draft": waterline - bottom,
		"freeboard": top - waterline,
		"metacentric_height": metacentric,
		"buoyancy_center": buoyancy_center,
		"heel_degrees": rad_to_deg(atan2(center_of_mass.x - buoyancy_center.x, metacentric.x)) if metacentric.x > 0.0 else 0.0,
		"trim_degrees": rad_to_deg(atan2(center_of_mass.z - buoyancy_center.z, metacentric.y)) if metacentric.y > 0.0 else 0.0,
	})
	return result


## Local height of the calm-water waterline (_get_hydrostatics()), where the contact
## probes go; the hull's middle while it does not float.
func _get_waterline_y() -> float:
	var h := _get_hydrostatics()
	if h.has("waterline_local"):
		return h["waterline_local"]
	return _get_source_bounds_in_local_space(_get_source_mesh_instances()).get_center().y


## One line on how the body floats (_get_hydrostatics()), or "".
func get_hydrostatics_report() -> String:
	var h := _get_hydrostatics()
	if h.is_empty():
		return ""
	if not h.has("waterline"):
		return "Sinks: the hull displaces at most %.0f kg of water, less than the body's %.0f kg." % [h["capacity"], h["mass"]]
	var gm : Vector2 = h["metacentric_height"]
	return "Floats with its waterline at local y = %.3f m: draft %.2f m, freeboard %.2f m, reserve buoyancy %.1f x its mass, metacentric height %.2f m across and %.2f m along, heel %.1f, trim %.1f degrees." % [h["waterline_local"], h["draft"], h["freeboard"], h["capacity"] / h["mass"], gm.x, gm.y, h["heel_degrees"], h["trim_degrees"]]


func _find_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


## A hull's horizontal slices (in the volume's frame) on a raster: at each level,
## the cells open water reaches from outside (flooding in from the raster's edge
## around the slice's outline) are water, the rest hull.
class _HullSlices:
	const LEVELS := 48
	## The plan (x, z) the raster covers: the hull's, a cell wider on every side.
	var plan := Rect2()
	## Raster cell size (m).
	var resolution := 1.0
	## Height (m) of each level's slab, the lowest one starting at the hull's bottom.
	var level_height := 1.0
	## Per level, one byte per raster cell: 2 hull, 1 the outline (half hull), 0 water.
	var levels : Array[PackedByteArray] = []
	## Per level, the slice's outline as point pairs.
	var segments : Array[PackedVector2Array] = []
	var _bottom := 0.0
	var _size := Vector2i.ONE

	func _init(triangles : PackedVector3Array, watertight_top : float, hull_plan : Rect2, raster_resolution : float) -> void:
		resolution = maxf(raster_resolution, 1e-3)
		plan = hull_plan.grow(resolution)
		_size = Vector2i((plan.size / resolution).ceil())
		var low := INF
		var high := -INF
		for vertex in triangles:
			low = minf(low, vertex.y)
			high = maxf(high, vertex.y)
		high = minf(high, watertight_top)
		_bottom = low
		level_height = maxf(high - low, 1e-3) / LEVELS
		for level in LEVELS:
			var outline := HullSlicer.slice(triangles, get_level_height(level))
			segments.push_back(outline)
			levels.push_back(_rasterize(outline))

	## Height (m) of level's slice, the middle of its slab.
	func get_level_height(level : int) -> float:
		return _bottom + (level + 0.5) * level_height

	## Whether point (x, z) is hull at level.
	func is_hull(level : int, point : Vector2) -> bool:
		var cell := Vector2i(((point - plan.position) / resolution).floor())
		if cell.x < 0 or cell.y < 0 or cell.x >= _size.x or cell.y >= _size.y:
			return false
		return levels[level][cell.y * _size.x + cell.x] > 0

	## Hull area (m²) at level inside rect (the raster cells whose centre it holds).
	func get_area(level : int, rect : Rect2) -> float:
		var first := Vector2i(((rect.position - plan.position) / resolution - Vector2.ONE * 0.5).ceil()).max(Vector2i.ZERO)
		var last := Vector2i(((rect.end - plan.position) / resolution - Vector2.ONE * 0.5).ceil()).min(_size)
		var count := 0
		var raster := levels[level]
		for y in range(first.y, last.y):
			for x in range(first.x, last.x):
				count += raster[y * _size.x + x]
		return count * 0.5 * resolution * resolution

	## The hull at one level: the outline's cells (half), and everything open water from
	## the raster's edge cannot reach past them.
	func _rasterize(outline : PackedVector2Array) -> PackedByteArray:
		var raster := PackedByteArray()
		raster.resize(_size.x * _size.y)
		const WALL := 2
		for i in range(0, outline.size(), 2):
			var a := (outline[i] - plan.position) / resolution
			var b := (outline[i + 1] - plan.position) / resolution
			var steps := maxi(ceili(a.distance_to(b) * 2.0), 1)
			for t in steps + 1:
				var cell := Vector2i(a.lerp(b, float(t) / steps).floor())
				if cell.x >= 0 and cell.y >= 0 and cell.x < _size.x and cell.y < _size.y:
					raster[cell.y * _size.x + cell.x] = WALL
		# Flood the water in from the edge (marked 3), then everything else is hull.
		const WATER := 3
		var queue := PackedInt32Array()
		for x in _size.x:
			queue.push_back(x)
			queue.push_back((_size.y - 1) * _size.x + x)
		for y in _size.y:
			queue.push_back(y * _size.x)
			queue.push_back(y * _size.x + _size.x - 1)
		var head := 0
		while head < queue.size():
			var index := queue[head]
			head += 1
			if raster[index] != 0:
				continue
			raster[index] = WATER
			var x := index % _size.x
			if x > 0:
				queue.push_back(index - 1)
			if x < _size.x - 1:
				queue.push_back(index + 1)
			if index >= _size.x:
				queue.push_back(index - _size.x)
			if index < (_size.y - 1) * _size.x:
				queue.push_back(index + _size.x)
		for i in raster.size():
			raster[i] = [2, 0, 1, 0][raster[i]]
		return raster
