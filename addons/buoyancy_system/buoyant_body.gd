@tool
class_name BuoyantBody
extends Node
## Floats a parent RigidBody3D on the water surface of its world (WaterSurface.find(),
## e.g. an OceanSystem) from its physical probes, columns of its hull baked by a
## BuoyancyProbeVolume: every force comes from their measured shape and the water,
## so a hull floats, trims, rolls and slows as its geometry and mass make it. FX probes
## are queried in the same batch but never apply forces. With sinking enabled it
## also sinks the body when it rolls over, floods (all sinking probes deep under
## water) or loses a hitbox group.
##
## Probe data is cached when volumes are collected and whenever a volume reports
## probes_changed. Probes must stay rigid relative to the body: each tick only
## transforms their cached body-space positions.

## Emitted when a probe becomes wet (its state's entered is true).
signal probe_entered_water(state: BuoyancyProbeState)
## Emitted when a probe becomes dry (its state's exited is true).
signal probe_exited_water(state: BuoyancyProbeState)
## Emitted once when the body starts sinking. reason is &"roll", &"draft",
## &"hitbox_group_destroyed" or the one passed to start_sinking(); data holds its details.
signal sinking_started(reason: StringName, data: Dictionary)

## Physics seconds the body is held frozen waiting for its first water sample
## before it is released anyway (and the missing sample reported).
const FIRST_SAMPLE_TIMEOUT := 5.0
## Pressure drag coefficient of a hull face meeting the water head-on (a flat plate);
## a face at an angle meets it with the velocity's normal part only, so a fine bow
## has little drag and a flat side much.
const PRESSURE_DRAG_COEFFICIENT := 1.0
## Kinematic viscosity (m²/s) of seawater at 15 °C, for the skin friction's Reynolds number.
const WATER_VISCOSITY := 1.19e-6
## Reynolds number below which the skin friction keeps the ITTC line's value there
## (the line is fitted for turbulent flow along a hull).
const MIN_REYNOLDS_NUMBER := 1.0e5
## Depth, as a share of a column's width, over which its added mass grows in as it
## gets wet (a flat section's heave added mass barely depends on its draft).
const ADDED_MASS_WETTING_SHARE := 0.25

## Optional rigid body target. Leave empty to use the parent or nearest ancestor RigidBody3D.
@export var rigid_body_path : NodePath :
	set(value):
		rigid_body_path = value
		update_configuration_warnings()
## Automatically includes child BuoyancyProbeVolume nodes in addition to explicit paths.
@export var auto_collect_child_volumes := true
## Explicit probe volumes used by this buoyant body.
@export var probe_volume_paths : Array[NodePath] = []
## Fluid density in kg/m^3. Seawater is usually around 1025, fresh water 1000.
@export_range(1.0, 2000.0, 1.0, "or_greater") var water_density := 1025.0 :
	set(value):
		water_density = value
		_probe_cache_dirty = true
## Damping of each column's bobbing while it crosses the surface, as a fraction of
## critical damping (from its waterplane stiffness and its share of the mass): the
## energy a floating body radiates as waves, which the drag (quadratic in speed) misses
## in small, slow motion. Damps heave, pitch and roll; ships are around 0.1-0.3.
@export_range(0.0, 2.0, 0.01, "or_greater") var wave_damping_ratio := 0.2
## Applies the forces and samples the water. Off: the body is left to physics alone and
## its probe states stop updating.
@export var apply_forces := true

@export_group("Sinking")
## Enables roll, draft and damage-triggered sinking. start_sinking() works either way.
@export var sinking_enabled := false
## Starts sinking when absolute roll reaches this angle. Set 0 to disable roll sinking.
@export_range(0.0, 180.0, 0.1, "degrees") var max_roll_degrees := 70.0
## Physical probes that must all be flooded (at least sink_submersion_threshold of
## their column under water) to start sinking. Each must be an enabled physical
## probe of this body. Empty disables it.
@export var sinking_probe_paths : Array[NodePath] = []
## Share of a sinking probe's column under water that counts as flooded: about 0.9
## with the deck awash.
@export_range(0.0, 1.0, 0.01) var sink_submersion_threshold := 0.9
## Hitbox groups whose destruction starts sinking, reported through
## _on_hitbox_group_destroyed (connect a damage system's signal to it).
@export var sink_on_destroyed_groups : Array[StringName] = [&"hull"]
## The buoyancy is multiplied by this once sinking starts.
@export_range(0.0, 1.0, 0.01) var sink_buoyancy_multiplier := 0.3
## Seconds after sinking starts before delete_root_path is freed. 0 frees immediately.
@export_range(0.0, 60.0, 0.01, "or_greater") var delete_delay := 5.0
## Node freed after delete_delay. Empty frees the rigid body.
@export var delete_root_path : NodePath

## The body the forces act on (resolved in _ready).
var rigid_body : RigidBody3D
## The water surface of this body's world (resolved in _ready); null disables buoyancy.
var _water : WaterSurface
## The probe volumes in use (see refresh_volumes()).
var probe_volumes : Array[BuoyancyProbeVolume] = []
## True while the body is held frozen waiting for its first water sample.
var _awaiting_first_sample := false
var _gravity := 9.8
## Physics time (s) this node has run: the clock of probe states and events.
var _physics_time := 0.0

# Probe cache. Force (physical) probes come first in every per-point array,
# contact probes after them.
var _probe_cache_dirty := true
var _force_states : Array[BuoyancyProbeState] = []
var _contact_states : Array[BuoyancyProbeState] = []
var _states_by_probe := {}
var _body_offsets := PackedVector3Array()
var _points := PackedVector3Array()
# Per physical probe: its column's height, area_profile, full volume, its share of
# the body's mass, its width (for tilted columns) and its heave added mass (kg).
var _column_heights := PackedFloat32Array()
var _profiles : Array[PackedFloat32Array] = []
var _full_volumes := PackedFloat32Array()
var _volume_shares := PackedFloat32Array()
var _column_widths := PackedFloat32Array()
var _added_masses := PackedFloat32Array()
## Every column's side panels, flattened (column i owns panels _panel_starts[i] to
## _panel_starts[i + 1] - 1): outward normal (body space) and length (m).
var _panel_starts := PackedInt32Array()
var _panel_normals := PackedVector3Array()
var _panel_lengths := PackedFloat32Array()
## Length (m) of the hull along the body's forward axis, for the skin friction.
var _hull_length := 1.0
## The hull's draft (m, its deepest column's wet length) and wetted lateral area
## (m², each column's wet length times its width) of the last tick, for the hull lift.
var _draft := 0.0
var _lateral_area := 0.0
## Water vertical velocity and acceleration at each physical probe, from the
## last two results (for the added mass), and the clock of the last one.
var _water_velocity_y := PackedFloat32Array()
var _water_acceleration_y := PackedFloat32Array()
var _water_sample_time := -INF
## Water clock (WaterSurface.get_clock()) when the probe set last changed. Results dispatched before
## then answer the old point set.
var _probe_set_time := -INF
var _sinking_probes : Array[Node] = []
var _is_sinking := false
## sink_buoyancy_multiplier once sinking, else 1.
var _sink_scale := 1.0


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	rigid_body = _resolve_rigid_body()
	_water = WaterSurface.find(self)
	if rigid_body == null or _water == null:
		if _water == null:
			push_error("BuoyantBody %s: no WaterSurface in this world (add an OceanSystem). Buoyancy is disabled." % get_path())
		set_physics_process(false)
		return
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_collect_volumes()
	if probe_volumes.is_empty():
		push_error("BuoyantBody found no probe volumes: %s" % get_path())
	_rebuild_probe_cache()
	for path in sinking_probe_paths:
		var probe := get_node_or_null(path)
		if not probe is BuoyancyProbeNode or not _states_by_probe.has(probe.get_instance_id()):
			push_error("BuoyantBody %s: sinking probe %s is not an enabled physical probe of this body; ignored." % [get_path(), path])
			continue
		_sinking_probes.push_back(probe)
	# The first surface query result arrives several frames after the first submit,
	# and much later in physics time when startup frames hitch. Hold the body still
	# until then instead of letting it free-fall through the water.
	if apply_forces and not rigid_body.freeze:
		_awaiting_first_sample = true
		rigid_body.freeze = true


func _exit_tree() -> void:
	if _water != null:
		_water.release_query(self)


func _physics_process(delta : float) -> void:
	_physics_time += delta
	if not apply_forces:
		_end_first_sample_hold()
		return
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	# Every volume and probe is disabled: nothing to float, and no sample to wait for.
	if _points.is_empty():
		_end_first_sample_hold()
		return

	var body_transform := rigid_body.global_transform
	_submit_points(body_transform)
	var result := _water.get_query_result(self)
	# The first readback arrives a few frames after the first submit.
	if result == null or result.dispatch_time <= _probe_set_time:
		if _awaiting_first_sample and _physics_time > FIRST_SAMPLE_TIMEOUT:
			push_error("BuoyantBody %s: no water sample after %d s (does the ocean have wave cascades?); released without buoyancy." % [get_path(), FIRST_SAMPLE_TIMEOUT])
			_end_first_sample_hold()
		return
	if result.samples.size() != _points.size():
		push_error("BuoyantBody %s: query result has %d samples for %d probes; tick skipped." % [get_path(), result.samples.size(), _points.size()])
		return
	_end_first_sample_hold()
	var elapsed := _water.get_query_age(result)
	_update_water_acceleration(result)
	var body_basis := body_transform.basis.orthonormalized()
	var body_up := body_basis.y
	var mass := rigid_body.mass
	var linear_velocity := rigid_body.linear_velocity
	var angular_velocity := rigid_body.angular_velocity
	var body_state := PhysicsServer3D.body_get_direct_state(rigid_body.get_rid())
	# Probe forces are summed into one force and one torque about the center of mass
	# (what apply_force() at each probe adds up to), sent with two calls per tick.
	var center_of_mass := body_state.center_of_mass
	# Columns rise from their probes along the body's up axis and turn with it: a
	# capsized body displaces what it does upright, from its other end.
	var column_tilt := sqrt(maxf(1.0 - body_up.y * body_up.y, 0.0))
	var weight_per_volume := water_density * _gravity * _sink_scale
	# Hull lift (slender-body theory): a hull moving at a small drift angle is a wing of
	# aspect ratio 2·draft / length, whose side force (π/2)·ρ·T²·U·v grows with the
	# side speed v at forward speed U, shared by the columns by their lateral area.
	var right := body_basis.x
	var forward := -body_basis.z
	var lift_per_area := 0.5 * PI * water_density * _draft * _draft / _lateral_area if _lateral_area > 0.0 else 0.0
	var draft := 0.0
	var lateral_area := 0.0

	var total_external_force := Vector3.ZERO
	var total_torque := Vector3.ZERO
	var added_mass := 0.0
	var added_mass_water_force := 0.0
	for i in _force_states.size():
		var sample := result.samples[i]
		var water_height := sample.extrapolated_height(elapsed)
		var bottom := _points[i]
		var column_height := _column_heights[i]
		var column_width := _column_widths[i]
		var column_center := bottom + body_up * (column_height * 0.5)
		# A tilted column is a prism of its own width, so the submerged share stays
		# smooth all the way to a horizontal column.
		var vertical_extent := column_height * absf(body_up.y) + column_width * column_tilt
		var submersion := clampf((water_height - column_center.y) / vertical_extent + 0.5, 0.0, 1.0)
		var applied_force := Vector3.ZERO
		if submersion > 0.0:
			# The submerged part: wet from the lower end, the bottom unless capsized.
			var profile := _profiles[i]
			var wet_length := submersion * column_height
			var wet := BuoyancyProbeNode.volume_below(profile, column_height, wet_length)
			var waterline_height := wet_length
			if body_up.y < 0.0:
				var dry := BuoyancyProbeNode.volume_below(profile, column_height, column_height - wet_length)
				wet = Vector2(_full_volumes[i] - dry.x, BuoyancyProbeNode.volume_below(profile, column_height, column_height).y - dry.y)
				waterline_height = column_height - wet_length
			var probe_mass := mass * _volume_shares[i]
			# Buoyancy acts at the centroid of the water the column displaces.
			var force_point := bottom + body_up * (wet.y / wet.x if wet.x > 0.0 else waterline_height)
			# linear_velocity is the center of mass's, so the lever arm is from there.
			var arm := force_point - body_transform.origin - center_of_mass
			var relative_velocity := linear_velocity + angular_velocity.cross(arm) - sample.surface_velocity
			var buoyancy_force := Vector3.UP * (weight_per_volume * wet.x)

			# Water resistance, each part as a rate on the column's share of the mass
			# (_stable_drag_rate()). Pressure drag: the faces moving into the water push
			# it aside, ½·ρ·C_p·area·u² against them, u the velocity along their outward
			# normal. The bottom (the submerged part's plan, which meets the water fully
			# once a column width deep) along the body's axis, then the sides.
			var drag_per_area := 0.5 * water_density / probe_mass
			var plan_area := wet.x / maxf(wet_length, 1e-4)
			var end_area := plan_area * minf(wet_length / column_width, 1.0)
			var up_speed := relative_velocity.dot(body_up)
			var drag_acceleration := -body_up * up_speed * _stable_drag_rate(drag_per_area * PRESSURE_DRAG_COEFFICIENT * end_area * absf(up_speed), delta)
			var side_area := 0.0
			for panel in range(_panel_starts[i], _panel_starts[i + 1]):
				var normal := body_basis * _panel_normals[panel]
				var area := _panel_lengths[panel] * wet_length
				side_area += area
				var speed := relative_velocity.dot(normal)
				if speed > 0.0:
					drag_acceleration -= normal * speed * _stable_drag_rate(drag_per_area * PRESSURE_DRAG_COEFFICIENT * area * speed, delta)
			draft = maxf(draft, wet_length)
			lateral_area += wet_length * column_width
			if lift_per_area > 0.0:
				var side_speed := relative_velocity.dot(right)
				drag_acceleration -= right * side_speed * _stable_drag_rate(lift_per_area * wet_length * column_width * absf(relative_velocity.dot(forward)) / probe_mass, delta)
			# Skin friction along the hull (ITTC 1957), on the wetted sides and bottom.
			var along := relative_velocity - body_up * up_speed
			var along_speed := along.length()
			if along_speed > 1e-4:
				drag_acceleration -= along * _stable_drag_rate(drag_per_area * _friction_coefficient(along_speed) * (side_area + plan_area) * along_speed, delta)
			# Wave-making damping while the column crosses the surface (where its
			# waterplane gives it a stiffness k): c = 2·ζ·√(k·m).
			var waterplane_area := BuoyancyProbeNode.area_at(profile, column_height, waterline_height)
			if submersion < 1.0 and wave_damping_ratio > 0.0 and waterplane_area > 0.0:
				var stiffness := weight_per_volume * waterplane_area
				drag_acceleration.y -= relative_velocity.y * _stable_drag_rate(2.0 * wave_damping_ratio * sqrt(stiffness / probe_mass), delta)
			applied_force = buoyancy_force + drag_acceleration * probe_mass
			total_external_force += applied_force
			total_torque += arm.cross(applied_force)
			var probe_added_mass := _added_masses[i] * minf(wet_length / (ADDED_MASS_WETTING_SHARE * column_width), 1.0)
			added_mass += probe_added_mass
			added_mass_water_force += probe_added_mass * _water_acceleration_y[i]
		_update_state(_force_states[i], bottom, sample, water_height, applied_force, submersion, _physics_time)

	_draft = draft
	_lateral_area = lateral_area
	# Added mass in heave: (m + M_a)·a = F + m·g + M_a·a_water. The engine only
	# knows m, so add the force that gives that acceleration. It comes from this
	# tick's forces, not from measured accelerations, so it cannot feed back and
	# go unstable however large M_a gets.
	if added_mass > 0.0:
		var net_vertical_force := total_external_force.y + mass * body_state.total_gravity.y
		total_external_force.y += (mass * added_mass_water_force - added_mass * net_vertical_force) / (mass + added_mass)

	if total_external_force != Vector3.ZERO:
		rigid_body.apply_central_force(total_external_force)
		rigid_body.apply_torque(total_torque)

	var force_count := _force_states.size()
	for j in _contact_states.size():
		var sample := result.samples[force_count + j]
		_update_state(_contact_states[j], _points[force_count + j], sample, sample.extrapolated_height(elapsed), Vector3.ZERO, 0.0, _physics_time)

	_update_volume_debug(body_transform.origin + center_of_mass, body_state.total_gravity * mass, total_external_force)
	if sinking_enabled and not _is_sinking:
		_check_sinking()


## Lowers buoyancy, emits sinking_started and frees delete_root_path after
## delete_delay. Only the first call has an effect.
func start_sinking(reason : StringName = &"manual", data : Dictionary = {}) -> void:
	if _is_sinking:
		return
	_is_sinking = true
	_sink_scale = sink_buoyancy_multiplier
	sinking_started.emit(reason, data)
	var delete_root : Node = rigid_body
	if not delete_root_path.is_empty():
		delete_root = get_node_or_null(delete_root_path)
		if delete_root == null:
			push_error("BuoyantBody %s: delete_root_path %s not found; freeing the rigid body instead." % [get_path(), delete_root_path])
			delete_root = rigid_body
	if delete_delay <= 0.0:
		delete_root.queue_free()
	else:
		get_tree().create_timer(delete_delay).timeout.connect(delete_root.queue_free)


## Whether start_sinking() has run.
func is_sinking() -> bool:
	return _is_sinking


func _on_hitbox_group_destroyed(hitbox_group : StringName, hit_data : Dictionary) -> void:
	if sinking_enabled and sink_on_destroyed_groups.has(hitbox_group):
		start_sinking(&"hitbox_group_destroyed", {"hitbox_group": hitbox_group, "hit_data": hit_data})


## Re-collects probe volumes (after adding or removing volumes at runtime).
func refresh_volumes() -> void:
	_collect_volumes()


## Every enabled probe's state, or only those with the given tag. States that
## have not been sampled yet have has_sample == false.
func get_probe_states(tag_filter := "") -> Array[BuoyancyProbeState]:
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	var states : Array[BuoyancyProbeState] = []
	for group in [_force_states, _contact_states]:
		for state : BuoyancyProbeState in group:
			if tag_filter == "" or state.tag == tag_filter:
				states.push_back(state)
	return states


## States of the probes that are under water, optionally only those with tag_filter.
func get_wet_probe_states(tag_filter := "") -> Array[BuoyancyProbeState]:
	var states : Array[BuoyancyProbeState] = []
	for state in get_probe_states(tag_filter):
		if state.is_wet:
			states.push_back(state)
	return states


## State of one probe node, or null if it is not an enabled probe of this body.
func get_probe_state(probe : Node) -> BuoyancyProbeState:
	if _probe_cache_dirty:
		_rebuild_probe_cache()
	return _states_by_probe.get(probe.get_instance_id())


## Estimates the water's vertical acceleration at each physical probe from the
## surface velocity of the last two results (once per new result).
func _update_water_acceleration(result : WaterSurfaceQueryResult) -> void:
	if result.dispatch_time == _water_sample_time:
		return
	var interval := result.dispatch_time - _water_sample_time
	for i in _force_states.size():
		var velocity_y := result.samples[i].surface_velocity.y
		# The first result (also after the probe set changed) has no predecessor;
		# the cap keeps a stalled readback from spiking it.
		var acceleration := (velocity_y - _water_velocity_y[i]) / interval if is_finite(_water_sample_time) and interval > 0.0 else 0.0
		_water_acceleration_y[i] = clampf(acceleration, -2.0 * _gravity, 2.0 * _gravity)
		_water_velocity_y[i] = velocity_y
	_water_sample_time = result.dispatch_time


## The heave added mass (kg) of each column: the body's waterplane at rest (for its
## mass) as a flat plate on the surface, of the ellipse of its length and area, whose
## added mass is (2/3)·π·ρ·a·b² / E(k) for semi-axes a ≥ b (exact in 3D, at high
## frequency), E the complete elliptic integral of the second kind with
## k² = 1 - b²/a²; shared by the columns by their waterplane area.
func _update_added_masses() -> void:
	var count := _force_states.size()
	_added_masses.resize(count)
	_added_masses.fill(0.0)
	var bottoms := PackedFloat32Array()
	for i in count:
		bottoms.push_back(_body_offsets[i].y)
	var waterline := BuoyancyProbeNode.find_waterline(bottoms, _column_heights, _profiles, rigid_body.mass / water_density)
	if not is_finite(waterline):
		return
	var area := 0.0
	var extent := Vector2(INF, -INF)
	for i in count:
		_added_masses[i] = BuoyancyProbeNode.area_at(_profiles[i], _column_heights[i], waterline - bottoms[i])
		if _added_masses[i] > 0.0:
			area += _added_masses[i]
			extent = Vector2(minf(extent.x, _body_offsets[i].z - 0.5 * _column_widths[i]), maxf(extent.y, _body_offsets[i].z + 0.5 * _column_widths[i]))
	if area <= 0.0:
		return
	var a := 0.5 * (extent.y - extent.x)
	var b := area / (PI * a)
	if b > a:
		var swap := a
		a = b
		b = swap
	var k_squared := 1.0 - b * b / (a * a)
	var elliptic := 0.0
	const STEPS := 32
	for step in STEPS:
		elliptic += sqrt(1.0 - k_squared * pow(sin((step + 0.5) / STEPS * 0.5 * PI), 2.0))
	elliptic *= 0.5 * PI / STEPS
	var added_mass := 2.0 / 3.0 * PI * water_density * a * b * b / elliptic
	for i in count:
		_added_masses[i] *= added_mass / area


## Skin friction coefficient of the hull at speed (m/s) along it: the ITTC 1957
## correlation line, 0.075 / (log10 Re - 2)², Re from the hull's length.
func _friction_coefficient(speed : float) -> float:
	var reynolds := maxf(speed * _hull_length / WATER_VISCOSITY, MIN_REYNOLDS_NUMBER)
	var log_reynolds := log(reynolds) / log(10.0) - 2.0
	return 0.075 / (log_reynolds * log_reynolds)


## Drag rate (1/s) that removes over one tick of delta what rate would remove
## continuously: never more than the relative velocity, so even strong drag
## cannot overshoot and oscillate.
static func _stable_drag_rate(rate : float, delta : float) -> float:
	return (1.0 - exp(-rate * delta)) / delta if delta > 0.0 else rate


## Releases the body held frozen until the first water sample (see _ready()).
func _end_first_sample_hold() -> void:
	if _awaiting_first_sample:
		_awaiting_first_sample = false
		rigid_body.freeze = false


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var body : Node = get_node_or_null(rigid_body_path) if not rigid_body_path.is_empty() else _find_parent_rigid_body()
	if not body is RigidBody3D:
		warnings.push_back("Needs a RigidBody3D to float: make it a descendant of one, or set rigid_body_path.")
	elif probe_volume_paths.is_empty() and not (auto_collect_child_volumes and not body.find_children("*", "BuoyancyProbeVolume", true, false).is_empty()):
		warnings.push_back("No BuoyancyProbeVolume under the body (or in probe_volume_paths): nothing makes it float.")
	return warnings


## Null (reported) when the configured body is missing or not a RigidBody3D.
func _resolve_rigid_body() -> RigidBody3D:
	if not rigid_body_path.is_empty():
		var target := get_node_or_null(rigid_body_path)
		if not target is RigidBody3D:
			push_error("BuoyantBody %s: rigid_body_path %s is not a RigidBody3D. Buoyancy is disabled." % [get_path(), rigid_body_path])
			return null
		return target as RigidBody3D
	var ancestor := _find_parent_rigid_body()
	if ancestor == null:
		push_error("BuoyantBody %s: rigid_body_path is empty and no ancestor is a RigidBody3D. Buoyancy is disabled." % get_path())
	return ancestor


func _find_parent_rigid_body() -> RigidBody3D:
	var node := get_parent()
	while node != null:
		if node is RigidBody3D:
			return node
		node = node.get_parent()
	return null


func _collect_volumes() -> void:
	for volume in probe_volumes:
		if volume.probes_changed.is_connected(_on_probes_changed):
			volume.probes_changed.disconnect(_on_probes_changed)
	probe_volumes.clear()
	for path in probe_volume_paths:
		var node := get_node_or_null(path)
		if not node is BuoyancyProbeVolume:
			push_error("BuoyantBody %s: probe_volume_paths entry %s is not a BuoyancyProbeVolume; ignored." % [get_path(), path])
			continue
		if not probe_volumes.has(node):
			probe_volumes.push_back(node)
	if auto_collect_child_volumes:
		_collect_probe_volume_descendants(rigid_body)
	for volume in probe_volumes:
		volume.probes_changed.connect(_on_probes_changed)
	_probe_cache_dirty = true


func _collect_probe_volume_descendants(node : Node) -> void:
	for child in node.get_children():
		if child is BuoyancyProbeVolume and not probe_volumes.has(child):
			probe_volumes.push_back(child)
		_collect_probe_volume_descendants(child)


func _on_probes_changed() -> void:
	_probe_cache_dirty = true


func _rebuild_probe_cache() -> void:
	_probe_cache_dirty = false
	_force_states.clear()
	_contact_states.clear()
	for volume in probe_volumes:
		_force_states.append_array(volume.get_physical_probe_states())
		_contact_states.append_array(volume.get_contact_probe_states())

	var force_count := _force_states.size()
	var point_count := force_count + _contact_states.size()
	var to_body := rigid_body.global_transform.affine_inverse()
	_body_offsets.resize(point_count)
	_points.resize(point_count)
	_column_heights.resize(force_count)
	_profiles.resize(force_count)
	_full_volumes.resize(force_count)
	_volume_shares.resize(force_count)
	_column_widths.resize(force_count)
	_panel_starts.resize(force_count + 1)
	_panel_normals.clear()
	_panel_lengths.clear()
	_water_velocity_y.resize(force_count)
	_water_acceleration_y.resize(force_count)
	_water_acceleration_y.fill(0.0)
	_water_sample_time = -INF
	_states_by_probe.clear()
	var total_volume := 0.0
	var forward_extent := Vector2(INF, -INF)
	for i in force_count:
		var probe := _force_states[i].probe as BuoyancyProbeNode
		_body_offsets[i] = to_body * probe.global_position
		_column_heights[i] = probe.height
		_profiles[i] = probe.area_profile
		_full_volumes[i] = BuoyancyProbeNode.volume_below(probe.area_profile, probe.height, probe.height).x
		var largest_area := 0.0
		for area in probe.area_profile:
			largest_area = maxf(largest_area, area)
		_column_widths[i] = sqrt(maxf(largest_area, 1e-6))
		# The panels' normals in the body's frame, level with its up axis.
		var to_body_basis := to_body.basis * probe.global_basis
		_panel_starts[i] = _panel_normals.size()
		for panel in probe.side_panels:
			var length := panel.length()
			if length > 1e-5:
				var normal := to_body_basis * Vector3(panel.x, 0.0, panel.y)
				_panel_normals.push_back(Vector3(normal.x, 0.0, normal.z).normalized())
				_panel_lengths.push_back(length)
		var forward_position := -_body_offsets[i].z
		forward_extent = Vector2(minf(forward_extent.x, forward_position - 0.5 * _column_widths[i]), maxf(forward_extent.y, forward_position + 0.5 * _column_widths[i]))
		_states_by_probe[probe.get_instance_id()] = _force_states[i]
		total_volume += _full_volumes[i]
	_panel_starts[force_count] = _panel_normals.size()
	_hull_length = maxf(forward_extent.y - forward_extent.x, 0.1) if force_count > 0 else 1.0
	for i in force_count:
		_volume_shares[i] = _full_volumes[i] / total_volume
	_update_added_masses()
	for j in _contact_states.size():
		var probe := _contact_states[j].probe
		_body_offsets[force_count + j] = to_body * probe.global_position
		_states_by_probe[probe.get_instance_id()] = _contact_states[j]
	# Replace any queued submission of the old probe set, so every dispatch after
	# this moment answers the new one.
	_probe_set_time = _water.get_clock()
	if point_count == 0:
		_water.release_query(self)
	else:
		_submit_points(rigid_body.global_transform)


func _submit_points(body_transform : Transform3D) -> void:
	for i in _points.size():
		_points[i] = body_transform * _body_offsets[i]
	_water.submit_query(self, _points, rigid_body)


func _update_state(state : BuoyancyProbeState, position : Vector3, sample : WaterSurfaceSample, water_height : float, applied_force : Vector3, submersion : float, now : float) -> void:
	state.update(position, sample, water_height, applied_force, submersion, now)
	if state.entered:
		probe_entered_water.emit(state)
	elif state.exited:
		probe_exited_water.emit(state)


func _check_sinking() -> void:
	var roll_degrees := _get_abs_roll_degrees()
	if max_roll_degrees > 0.0 and roll_degrees >= max_roll_degrees:
		start_sinking(&"roll", {"roll_degrees": roll_degrees})
		return
	if _sinking_probes.is_empty():
		return
	var least_submersion := INF
	for probe in _sinking_probes:
		var state := get_probe_state(probe)
		# A disabled probe has no state and cannot be flooded.
		if state == null or state.submersion < sink_submersion_threshold:
			return
		least_submersion = minf(least_submersion, state.submersion)
	start_sinking(&"draft", {"probe_count": _sinking_probes.size(), "least_submersion": least_submersion})


func _get_abs_roll_degrees() -> float:
	var basis := rigid_body.global_transform.basis.orthonormalized()
	var roll_axis := basis.z
	var target_up := Vector3.UP - roll_axis * Vector3.UP.dot(roll_axis)
	# Bow pointing straight up or down: roll is undefined.
	if target_up.length_squared() <= 0.0001:
		return 0.0
	return absf(rad_to_deg(basis.y.signed_angle_to(target_up.normalized(), roll_axis)))


func _update_volume_debug(center_of_mass_world : Vector3, gravity_force : Vector3, total_external_force : Vector3) -> void:
	for volume in probe_volumes:
		if volume.debug_enabled:
			volume.set_debug_body_state(center_of_mass_world, gravity_force, total_external_force)
