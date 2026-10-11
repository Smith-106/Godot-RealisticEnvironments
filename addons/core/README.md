# Core

Shared code for the ocean addons. Every `*_system` addon may depend on `core`;
`core` depends on nothing, and the systems never depend on each other.

## `WaterSurface`

How anything that floats on or disturbs water talks to a water simulation
without knowing which one. A simulation registers one surface per `World3D`
(`ocean_system` does); consumers look it up:

```gdscript
var water := WaterSurface.find(self)        # null when the world has no water
water.submit_query(self, points)            # every physics tick
var result := water.get_query_result(self)  # null until the first readback
if result != null:
	var height := result.samples[0].extrapolated_height(water.get_query_age(result))
# in _exit_tree:
water.release_query(self)
```

- Results arrive a few frames late; extrapolate with `get_query_age()`. A
  result's `points` are those of its dispatch, not your latest submission.
- `submit_query(owner, points, body)`: `body` (default: the owner's nearest
  `PhysicsBody3D`) lets the simulation leave out waves that body makes itself.
- Each `WaterSurfaceSample` has `height`, `normal`, `displacement`,
  `surface_velocity` and `extrapolated_height(age)`.
- `can_add_impulses()` / `add_impulse(position, radius, amplitude)` add a
  splash that spreads as a ring.

## Other helpers

- `RenderingContext` — owns a compute feature's `RenderingDevice` resources
  and frees them together; shader loading, buffers, textures, uniform sets and
  exact-size push constants. Check `failed` after building resources.
- `HullSlicer` — slices hull meshes with horizontal planes (hull profiles,
  buoyancy probes).
- `ProjectSetup` — used by the editor plugins to add missing project settings
  (global shader uniforms, input actions); never changes existing values.
