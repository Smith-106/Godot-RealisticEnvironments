@tool
class_name BuoyancyProbeNode
extends MeshInstance3D
## A physical buoyancy probe: one column of the hull, baked from the hull mesh by
## BuoyancyProbeVolume. The node sits at the column's lowest point; the column rises
## height along the body's up axis. Its shape (waterplane area at every height, its
## sides) is measured from the mesh, so BuoyantBody
## computes buoyancy, drag and added mass from geometry alone. Re-bake instead of
## editing it by hand. Shown as a sphere in the editor only.

## Emitted when a setting of the probe changes; its volume refreshes its probe cache.
signal probe_changed

const PROBE_COLOR := Color(0.1, 0.8, 1.0, 0.32)
const DISABLED_PROBE_COLOR := Color(0.25, 0.25, 0.25, 0.12)
const EDITOR_PROBE_RADIUS := 0.16
## Directions of side_panels: bin i holds the sides facing atan2(z, x) near i * 45 degrees.
const SIDE_PANEL_BINS := 8

## Enables this physical probe for buoyancy force sampling.
@export var enabled := true :
	set(value):
		enabled = value
		_update_editor_visuals()
		_emit_probe_changed()

@export_group("Baked Shape")
## Height (m) of the column above the node: up to the hull's top, or its
## watertight_top_y.
@export_range(0.001, 100.0, 0.001, "or_greater", "suffix:m") var height := 1.0 :
	set(value):
		height = maxf(value, 0.001)
		_emit_probe_changed()
## The hull's mean horizontal cross-section (m²) inside this column in each of its
## equal height bands, bottom band first: the waterplane area the column has when
## the water stands in that band. Their sum times the band height is its volume.
@export var area_profile := PackedFloat32Array([1.0]) :
	set(value):
		area_profile = value
		_emit_probe_changed()
## The hull's sides owned by this column, SIDE_PANEL_BINS outward directions in
## the node's XZ plane: each entry sums outward normal × side length (m), averaged
## over the column's height. Pressure drag acts on the sides moving into the water.
@export var side_panels := PackedVector2Array() :
	set(value):
		side_panels = value
		_emit_probe_changed()

var _material : StandardMaterial3D


# The editor sphere and its settings are set in _ready(), never saved with the scene.
func _validate_property(property : Dictionary) -> void:
	if property.name in [&"mesh", &"material_override", &"cast_shadow", &"extra_cull_margin"]:
		property.usage &= ~PROPERTY_USAGE_STORAGE


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_notify_transform(false)
	set_notify_local_transform(Engine.is_editor_hint())
	if Engine.is_editor_hint():
		extra_cull_margin = 10000.0
		_update_editor_visuals()
	else:
		visible = false
		mesh = null
		material_override = null


func _notification(what: int) -> void:
	if Engine.is_editor_hint() and what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
		_emit_probe_changed()


## The column's volume (m³, x) below height h (m above the node) and its first
## moment about the node (m⁴, y; y / x is the height of its centroid), for a column of
## column_height whose area_profile is profile.
static func volume_below(profile : PackedFloat32Array, column_height : float, h : float) -> Vector2:
	if profile.is_empty():
		return Vector2.ZERO
	var step := column_height / profile.size()
	var top := clampf(h, 0.0, column_height)
	var result := Vector2.ZERO
	var k := 0
	while k < profile.size() and k * step < top:
		var y0 := k * step
		var y1 := minf(y0 + step, top)
		result += profile[k] * Vector2(y1 - y0, 0.5 * (y1 * y1 - y0 * y0))
		k += 1
	return result


## Height (body frame, m) of the calm waterline at which columns with these bottoms
## (body frame), heights and profiles displace volume (m³), by bisection; INF if they
## cannot (the body sinks).
static func find_waterline(bottoms : PackedFloat32Array, heights : PackedFloat32Array, profiles : Array[PackedFloat32Array], volume : float) -> float:
	var low := INF
	var high := -INF
	var capacity := 0.0
	for i in bottoms.size():
		low = minf(low, bottoms[i])
		high = maxf(high, bottoms[i] + heights[i])
		capacity += volume_below(profiles[i], heights[i], heights[i]).x
	if bottoms.is_empty() or capacity <= volume:
		return INF
	for iteration in 40:
		var y := 0.5 * (low + high)
		var displaced := 0.0
		for i in bottoms.size():
			displaced += volume_below(profiles[i], heights[i], y - bottoms[i]).x
		if displaced < volume:
			low = y
		else:
			high = y
	return 0.5 * (low + high)


## The column's waterplane area (m²) with the water h (m) above the node: 0 outside it.
static func area_at(profile : PackedFloat32Array, column_height : float, h : float) -> float:
	if profile.is_empty() or h < 0.0 or h >= column_height:
		return 0.0
	return profile[mini(int(h / column_height * profile.size()), profile.size() - 1)]


func _update_editor_visuals() -> void:
	if not Engine.is_editor_hint():
		return
	if mesh == null or not (mesh is SphereMesh):
		mesh = SphereMesh.new()
	var sphere := mesh as SphereMesh
	sphere.radius = EDITOR_PROBE_RADIUS
	sphere.height = EDITOR_PROBE_RADIUS * 2.0
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.no_depth_test = true
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = PROBE_COLOR if enabled else DISABLED_PROBE_COLOR
	material_override = _material


func _emit_probe_changed() -> void:
	if is_inside_tree():
		probe_changed.emit()
