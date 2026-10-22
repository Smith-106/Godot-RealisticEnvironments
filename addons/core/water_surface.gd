@abstract
class_name WaterSurface
extends RefCounted
## The contract between a water simulation (OceanSystem) and what samples its
## surface. Consumers depend on this class only, never on the simulation's own types.
##
## A simulation registers its surface for the World3D it renders in; consumers
## look it up with [method find]. One surface per world.
##
## Queries are asynchronous: submit points every physics tick, read the latest
## completed result (null until the first one arrives, a few frames later) and
## extrapolate its heights by [method get_query_age]. Release the owner when it
## stops querying (e.g. in _exit_tree).

## World3D instance id -> WaterSurface.
static var _surfaces := {}


## Makes surface the one find() returns for nodes in world.
static func register(world : World3D, surface : WaterSurface) -> void:
	var id := world.get_instance_id()
	if _surfaces.has(id) and _surfaces[id] != surface:
		push_error("A WaterSurface is already registered for this World3D; only one per world is supported.")
		return
	_surfaces[id] = surface


## Removes surface as world's water surface (only if it is the registered one). Call from
## the simulation's _exit_tree.
static func unregister(world : World3D, surface : WaterSurface) -> void:
	var id := world.get_instance_id()
	if _surfaces.get(id) == surface:
		_surfaces.erase(id)


## The surface of the world node is in, or null when there is none (or node is
## not inside the tree).
static func find(node : Node) -> WaterSurface:
	if not node.is_inside_tree():
		return null
	var world := node.get_viewport().find_world_3d()
	return _surfaces.get(world.get_instance_id()) if world != null else null


## Queues points for the next query dispatch; the latest submission per owner
## wins.
@abstract func submit_query(query_owner : Object, points : PackedVector3Array) -> void

## The latest completed query for query_owner, or null before the first one.
## Its points may differ from the most recent submission.
@abstract func get_query_result(query_owner : Object) -> WaterSurfaceQueryResult

## Seconds from result's dispatch to the caller's moment (in a physics tick: the
## moment of the bodies' state at its start), for
## WaterSurfaceSample.extrapolated_height().
@abstract func get_query_age(result : WaterSurfaceQueryResult) -> float

## Forgets query_owner's submissions and results.
@abstract func release_query(query_owner : Object) -> void

## The surface's clock, in the units of WaterSurfaceQueryResult.dispatch_time:
## a result dispatched at or before a moment read here predates it.
@abstract func get_clock() -> float
