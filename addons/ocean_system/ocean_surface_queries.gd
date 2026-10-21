class_name OceanSurfaceQueries
extends WaterSurface
## The ocean's WaterSurface: batches every owner's query points into one compute
## dispatch per frame and reads the results back asynchronously, and routes
## impulses to the interaction simulation. Owned by OceanSystem, which registers
## it for its world.
##
## A ring of SLOT_COUNT buffer sets lets new dispatches start while earlier
## readbacks are still in flight; each slot is reused only after its readback
## has been delivered.

const SHADER_PATH := 'res://addons/ocean_system/shaders/compute/surface_query.glsl'
const SLOT_COUNT := 3
const WORKGROUP_SIZE := 64
## Points are uploaded as tightly packed xyz floats (PackedVector3Array bytes).
const BYTES_PER_POINT := 12
## Floats of one cascade record (OceanCascade in ocean_sampling.glslinc).
const FLOATS_PER_CASCADE := 12
const BYTES_PER_CASCADE := FLOATS_PER_CASCADE * 4
const BYTES_PER_SAMPLE := 48
const FLOATS_PER_SAMPLE := 12
const NORMAL_SAMPLE_DISTANCE := 0.25
## Own-wave simulations a dispatch can take out of the interaction waves (one per
## wave-making body: OWN_WAVE_SLOTS in surface_query.glsl).
const OWN_WAVE_SLOTS := WaterInteractionSim.MAX_HULLS
## A point's mode (surface_query.glsl): the interaction waves masked under hulls, for
## bodies that make no waves; k >= 0 instead takes own-wave simulation k out of them.
const MODE_INTERACTION := -1

class QuerySlot:
	var capacity := 0
	var point_buffer := RID()
	var mode_buffer := RID()
	var cascade_buffer := RID()
	var own_window_buffer := RID()
	var sample_buffer := RID()
	## "current_rid:previous_rid" -> uniform set RID.
	var uniform_sets := {}
	var in_flight := false
	var points := PackedVector3Array()
	## [{owner_id, offset, count}] in dispatch order.
	var requests : Array[Dictionary] = []
	var dispatch_time := 0.0

## Frames whose queued queries could not be dispatched because every slot was
## still waiting on a readback. The queries stay queued for the next frame.
var skipped_dispatch_count := 0
## The ocean's interaction simulation, or null while it is off: queries add its
## waves, impulses go to it.
var interaction : WaterInteractionSim
## Own-wave simulations by slot (null where free) and the slot of each body's
## (body instance id -> slot), set by OceanSystem every simulation step.
var _own_waves : Array[WaterInteractionSim] = []
var _own_wave_slots := {}

var _device : RenderingDevice
## The ocean clock (s), advanced once per frame (advance_clock()), and the physics
## frame, interpolation fraction and physics step at that moment.
var _clock := 0.0
var _clock_physics_frame := 0
var _clock_physics_fraction := 0.0
var _physics_step := 0.0
var _shader : RID
var _pipeline : RID
var _slots : Array[QuerySlot] = []
var _queued := {}   # owner_id -> [PackedVector3Array points, body instance id or 0]
var _owners := {}   # owner_id -> true, for owners that have not been released
var _results := {}  # owner_id -> WaterSurfaceQueryResult
var _retired := false
## Bound in place of the interaction render and rate textures while the simulation is off.
var _no_interaction_texture : RID
var _no_interaction_rate_texture : RID
var _displacement_sampler : RID


## Sampler for the wave displacement maps in compute shaders (ocean_sampling.glslinc):
## repeat wrapping and bilinear filtering, as the water material samples them.
static func create_displacement_sampler_state() -> RDSamplerState:
	return RenderingContext.linear_sampler_state(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)


func _init(device : RenderingDevice) -> void:
	_device = device
	var shader_file : RDShaderFile = load(SHADER_PATH)
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute.is_empty():
		_shader = _device.shader_create_from_spirv(spirv)
		_pipeline = _device.compute_pipeline_create(_shader)
	else:
		# Queries stay queued and never answer: floating bodies wait frozen.
		push_error("%s failed to compile; water surface queries are off: %s" % [SHADER_PATH, spirv.compile_error_compute])
	for i in SLOT_COUNT:
		_slots.push_back(QuerySlot.new())
	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var empty_texel := PackedByteArray()
	empty_texel.resize(8)
	_no_interaction_texture = _device.texture_create(texture_format, RDTextureView.new(), [empty_texel])
	texture_format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	_no_interaction_rate_texture = _device.texture_create(texture_format, RDTextureView.new(), [PackedByteArray([0, 0])])
	_displacement_sampler = _device.sampler_create(create_displacement_sampler_state())


## Heights and velocities include the interaction simulation's waves. A body that
## makes waves itself feels them without its own (its own-wave simulation's): it
## feels its own radiation through its buoyancy's damping and added mass, and read
## back after the query delay its own waves would act as a lagging spring.
func submit_query(query_owner : Object, points : PackedVector3Array, body : PhysicsBody3D = null) -> void:
	if _retired:
		push_error("Surface query submitted after the ocean was freed.")
		return
	if points.is_empty():
		push_error("Surface queries need at least one point; release the owner instead.")
		return
	if body == null and query_owner is Node:
		body = find_physics_body(query_owner)
	var owner_id := query_owner.get_instance_id()
	_owners[owner_id] = true
	_queued[owner_id] = [points, body.get_instance_id() if body != null else 0]


## Latest completed result for query_owner, or null before its first one arrives.
func get_query_result(query_owner : Object) -> WaterSurfaceQueryResult:
	return _results.get(query_owner.get_instance_id())


## Ocean seconds from result's dispatch to now (the current physics tick, or the frame).
## Pass it to WaterSurfaceSample.extrapolated_height().
func get_query_age(result : WaterSurfaceQueryResult) -> float:
	if not Engine.is_in_physics_frame():
		return _clock - result.dispatch_time
	# Several ticks may fall between two frames, each at its own moment: a frame's
	# clock lies _clock_physics_fraction of a tick past its last tick.
	var ticks_since_frame := Engine.get_physics_frames() - _clock_physics_frame
	var tick_time := _clock + (float(ticks_since_frame - 1) - _clock_physics_fraction) * _physics_step
	return tick_time - result.dispatch_time


## Forgets query_owner's points and results. Call from the owner's _exit_tree.
func release_query(query_owner : Object) -> void:
	var owner_id := query_owner.get_instance_id()
	_owners.erase(owner_id)
	_queued.erase(owner_id)
	_results.erase(owner_id)


## The ocean clock (OceanSystem.time): the clock of dispatch_time.
func get_clock() -> float:
	return _clock


## Whether add_impulse() has an effect: the interaction simulation runs (at runtime).
func can_add_impulses() -> bool:
	return interaction != null


## Queues a splash for the next simulation step: the water within radius metres of
## world_position is raised by amplitude metres (negative lowers it) and spreads as a ring.
func add_impulse(world_position : Vector3, radius : float, amplitude : float) -> void:
	if interaction != null:
		interaction.add_impulse(world_position, radius, amplitude)


## Sets the ocean clock for this frame; physics_step is the physics tick length.
func advance_clock(clock : float, physics_step : float) -> void:
	_clock = clock
	_clock_physics_frame = Engine.get_physics_frames()
	_clock_physics_fraction = Engine.get_physics_interpolation_fraction()
	_physics_step = physics_step


## The own-wave simulations by slot (OWN_WAVE_SLOTS, null where free) and each
## body's slot (body instance id -> slot).
func set_own_waves(sims : Array[WaterInteractionSim], slots : Dictionary) -> void:
	_own_waves = sims
	_own_wave_slots = slots


## node itself or its nearest PhysicsBody3D ancestor, or null.
static func find_physics_body(node : Node) -> PhysicsBody3D:
	while node != null and not node is PhysicsBody3D:
		node = node.get_parent()
	return node as PhysicsBody3D


## Displacement textures are recreated when the wave generator is rebuilt. Uniform
## sets that referenced the old textures are freed by the RenderingDevice together
## with those textures, so only the cache entries need to go.
func clear_uniform_set_cache() -> void:
	for slot in _slots:
		slot.uniform_sets.clear()


## Dispatches every queued query. interaction_window is (center x, center z,
## fade start, fade end), see OceanSystem._get_interaction_window().
func dispatch(displacement_a : RID, displacement_b : RID, cascade_data : PackedByteArray, cascade_count : int, water_level : float, interaction_window : Vector4, interaction_cell_size : float) -> void:
	if _queued.is_empty() or not _pipeline.is_valid():
		return
	var slot := _get_idle_slot()
	if slot == null:
		skipped_dispatch_count += 1
		return

	var points := PackedVector3Array()
	var modes := PackedInt32Array()
	var requests : Array[Dictionary] = []
	for owner_id in _queued:
		var owner_points : PackedVector3Array = _queued[owner_id][0]
		requests.push_back({"owner_id": owner_id, "offset": points.size(), "count": owner_points.size()})
		points.append_array(owner_points)
		var mode_values := PackedInt32Array()
		mode_values.resize(owner_points.size())
		mode_values.fill(_own_wave_slots.get(_queued[owner_id][1], MODE_INTERACTION))
		modes.append_array(mode_values)
	_queued.clear()

	var interaction_enabled := interaction != null
	# Each own-wave simulation's window: center x, z and its fade by Chebyshev
	# distance, ending where its absorbing border begins.
	var own_windows := PackedFloat32Array()
	own_windows.resize(OWN_WAVE_SLOTS * 4)
	var renders : Array[RID] = [interaction.render_texture if interaction_enabled else _no_interaction_texture]
	var rates : Array[RID] = [interaction.rate_texture if interaction_enabled else _no_interaction_rate_texture]
	for slot_index in OWN_WAVE_SLOTS:
		var sim : WaterInteractionSim = _own_waves[slot_index] if interaction_enabled and slot_index < _own_waves.size() else null
		renders.push_back(sim.render_texture if sim != null else _no_interaction_texture)
		rates.push_back(sim.rate_texture if sim != null else _no_interaction_rate_texture)
		if sim != null:
			var center := sim.get_window_center()
			var border := sim.sponge_cells * sim.cell_size
			own_windows[4 * slot_index] = center.x
			own_windows[4 * slot_index + 1] = center.y
			own_windows[4 * slot_index + 2] = sim.get_half_extent() - 2.0 * border
			own_windows[4 * slot_index + 3] = sim.get_half_extent() - border

	_ensure_slot_capacity(slot, points.size(), cascade_data.size())
	var point_data := points.to_byte_array()
	_device.buffer_update(slot.point_buffer, 0, point_data.size(), point_data)
	var mode_data := modes.to_byte_array()
	_device.buffer_update(slot.mode_buffer, 0, mode_data.size(), mode_data)
	_device.buffer_update(slot.cascade_buffer, 0, cascade_data.size(), cascade_data)
	var window_data := own_windows.to_byte_array()
	_device.buffer_update(slot.own_window_buffer, 0, window_data.size(), window_data)

	var push_constant := RenderingContext.create_push_constant([
		points.size(),
		cascade_count,
		water_level,
		NORMAL_SAMPLE_DISTANCE,
		interaction_window.x,
		interaction_window.y,
		interaction_cell_size,
		interaction_window.z,
		interaction_window.w,
	])
	var compute_list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_device.compute_list_bind_uniform_set(compute_list, _get_uniform_set(slot, displacement_a, displacement_b, renders, rates), 0)
	_device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
	_device.compute_list_dispatch(compute_list, ceili(float(points.size()) / float(WORKGROUP_SIZE)), 1, 1)
	_device.compute_list_end()

	slot.in_flight = true
	slot.points = points
	slot.requests = requests
	slot.dispatch_time = _clock
	# The callback may run outside the main thread's frame logic; hand the data
	# over deferred. The lambda also keeps this object alive until it runs.
	var on_read := func(data : PackedByteArray) -> void:
		_on_samples_read.call_deferred(slot, data)
	var error := _device.buffer_get_data_async(slot.sample_buffer, on_read, 0, points.size() * BYTES_PER_SAMPLE)
	if error != OK:
		slot.in_flight = false
		push_error("Surface query readback failed: %s" % error_string(error))


## Frees GPU resources when the owning ocean goes away. Readbacks already in
## flight are ignored when they arrive.
func retire() -> void:
	_retired = true
	for slot in _slots:
		_free_slot_buffers(slot)
	_device.free_rid(_no_interaction_texture)
	_device.free_rid(_no_interaction_rate_texture)
	_device.free_rid(_displacement_sampler)
	if _shader.is_valid():
		_device.free_rid(_shader)
	_owners.clear()
	_queued.clear()
	_results.clear()


func _on_samples_read(slot : QuerySlot, data : PackedByteArray) -> void:
	slot.in_flight = false
	if _retired:
		return
	if data.size() != slot.points.size() * BYTES_PER_SAMPLE:
		push_error("Surface query readback has %d bytes, expected %d; dropped." % [data.size(), slot.points.size() * BYTES_PER_SAMPLE])
		return
	var samples := _unpack_samples(slot.points, data)
	for request in slot.requests:
		var owner_id : int = request["owner_id"]
		# The owner may have been released while its query was in flight.
		if not _owners.has(owner_id):
			continue
		var offset : int = request["offset"]
		var count : int = request["count"]
		var result := WaterSurfaceQueryResult.new()
		result.points = slot.points.slice(offset, offset + count)
		result.samples.assign(samples.slice(offset, offset + count))
		result.dispatch_time = slot.dispatch_time
		_results[owner_id] = result


func _get_idle_slot() -> QuerySlot:
	for slot in _slots:
		if not slot.in_flight:
			return slot
	return null


func _ensure_slot_capacity(slot : QuerySlot, point_count : int, cascade_bytes : int) -> void:
	if point_count <= slot.capacity:
		return
	_free_slot_buffers(slot)
	var capacity := WORKGROUP_SIZE
	while capacity < point_count:
		capacity *= 2
	slot.capacity = capacity
	slot.point_buffer = _device.storage_buffer_create(capacity * BYTES_PER_POINT)
	slot.mode_buffer = _device.storage_buffer_create(capacity * 4)
	slot.cascade_buffer = _device.storage_buffer_create(cascade_bytes)
	slot.own_window_buffer = _device.storage_buffer_create(OWN_WAVE_SLOTS * 16)
	slot.sample_buffer = _device.storage_buffer_create(capacity * BYTES_PER_SAMPLE)


func _free_slot_buffers(slot : QuerySlot) -> void:
	if slot.capacity == 0:
		return
	# Uniform sets depend on these buffers and are freed with them.
	_device.free_rid(slot.point_buffer)
	_device.free_rid(slot.mode_buffer)
	_device.free_rid(slot.cascade_buffer)
	_device.free_rid(slot.own_window_buffer)
	_device.free_rid(slot.sample_buffer)
	slot.uniform_sets.clear()
	slot.capacity = 0


## renders and rates: the interaction simulation's textures, then each own-wave slot's.
func _get_uniform_set(slot : QuerySlot, displacement_a : RID, displacement_b : RID, renders : Array[RID], rates : Array[RID]) -> RID:
	var ids := PackedStringArray([str(displacement_a.get_id()), str(displacement_b.get_id())])
	for texture in renders + rates:
		ids.push_back(str(texture.get_id()))
	var key := ":".join(ids)
	if slot.uniform_sets.has(key):
		return slot.uniform_sets[key]
	var own_render := RDUniform.new()
	own_render.binding = 9
	own_render.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	var own_rate := RDUniform.new()
	own_rate.binding = 10
	own_rate.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	for slot_index in OWN_WAVE_SLOTS:
		own_render.add_id(renders[slot_index + 1])
		own_rate.add_id(rates[slot_index + 1])
	var uniforms : Array[RDUniform] = [
		RenderingContext.buffer_uniform(0, slot.point_buffer),
		RenderingContext.buffer_uniform(1, slot.cascade_buffer),
		RenderingContext.buffer_uniform(2, slot.sample_buffer),
		RenderingContext.sampled_uniform(3, _displacement_sampler, displacement_a),
		RenderingContext.sampled_uniform(4, _displacement_sampler, displacement_b),
		RenderingContext.image_uniform(5, renders[0]),
		RenderingContext.image_uniform(6, rates[0]),
		RenderingContext.buffer_uniform(7, slot.mode_buffer),
		RenderingContext.buffer_uniform(8, slot.own_window_buffer),
		own_render,
		own_rate,
	]
	var uniform_set := _device.uniform_set_create(uniforms, _shader, 0)
	slot.uniform_sets[key] = uniform_set
	return uniform_set


func _unpack_samples(points : PackedVector3Array, data : PackedByteArray) -> Array[WaterSurfaceSample]:
	var values := data.to_float32_array()
	var samples : Array[WaterSurfaceSample] = []
	samples.resize(points.size())
	for i in points.size():
		var o := i * FLOATS_PER_SAMPLE
		var sample := WaterSurfaceSample.new()
		sample.position = points[i]
		sample.displacement = Vector3(values[o], values[o + 1], values[o + 2])
		sample.height = values[o + 3]
		sample.normal = Vector3(values[o + 4], values[o + 5], values[o + 6])
		sample.surface_velocity = Vector3(values[o + 8], values[o + 9], values[o + 10])
		samples[i] = sample
	return samples
