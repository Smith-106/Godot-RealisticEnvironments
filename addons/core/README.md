# Core

**English** · [简体中文](README.zh-CN.md)

The shared foundation of the ocean addons. It depends on nothing; `ocean_system`,
`sky_system` and `boat_template` depend on it. Enable it
before them.

## How it works

The systems never use each other's types. When two of them have to work
together, the contract between them lives here:

| Class | Role |
| --- | --- |
| `WaterSurface` | The water contract. A water simulation (`OceanSystem`) registers one per `World3D`; anything that samples the water finds it with `WaterSurface.find(node)`. |
| `WaterSurfaceQueryResult`, `WaterSurfaceSample` | The answer to a water query: per point, the surface height, normal, displacement and water velocity. |
| `WindSource` | Reads any wind provider (a `WindSystem` or a node of your own) by its methods or properties. |
| `ProjectSetup` | Lets the addons' plugins add missing project settings (global shader uniforms, input actions) without changing existing ones. |
| `RenderingContext` | Owns a compute feature's `RenderingDevice` resources, frees them together and records failures. |

Water queries are asynchronous: the points of every consumer are sampled on
the GPU in one batch and read back a few frames later. A result is therefore
slightly old, and each sample can extrapolate its height to the present.

## How to use

### Read the water height

```gdscript
var _water : WaterSurface

func _ready() -> void:
	_water = WaterSurface.find(self)  # null if no water is registered in this world

func _physics_process(_delta : float) -> void:
	if _water == null:
		return
	_water.submit_query(self, PackedVector3Array([global_position]))  # every tick
	var result := _water.get_query_result(self)  # null until the first readback
	if result != null and result.samples.size() == 1:
		var sample := result.samples[0]
		var height := sample.extrapolated_height(_water.get_query_age(result))
		# sample.normal, sample.surface_velocity, ...

func _exit_tree() -> void:
	if _water != null:
		_water.release_query(self)
```

- Submit every physics tick; the latest submission per owner wins.
- A result answers the points of its own dispatch (`result.points`). If you
  change the number of points, check the sample count.
- Always extrapolate with `get_query_age(result)`.

### Provide or read wind

A wind source is any node with `get_wind_speed()` (m/s) and
`get_wind_direction_degrees()`, or with `wind_speed` and `wind_direction`
properties. Directions are the way the wind blows toward, in degrees: 0 = +Z,
90 = +X. Read one with `WindSource.is_valid(node)`, `get_speed(node)`,
`get_direction(node)` and `get_velocity(node)`.

### Write your own water

Extend `WaterSurface` and implement its abstract methods. Call
`WaterSurface.register(get_world_3d(), surface)` in `_enter_tree()` and
`unregister()` in `_exit_tree()`. Each world can have only one water surface.
