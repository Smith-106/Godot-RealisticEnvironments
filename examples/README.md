# Examples

**English** · [简体中文](README.zh-CN.md)

Small scenes that use only the open-source addons. Open one and press
**Run Current Scene** (F6). Each one starts from `ocean_environment.tscn`. The
cameras read the mouse and keyboard directly, so they need no input actions.

| Scene | Shows | Controls |
| --- | --- | --- |
| `ocean_only.tscn` | The drop-in environment: sky, clouds, wind and waves. | Hold right mouse to look; W A S D fly, Q / E down / up, Shift faster, wheel changes the speed. |
| `floating_objects.tscn` | Crates and barrels floating with probe buoyancy. | As above. |
| `boat.tscn` | A drivable boat with wake, bow spray and hull cutout, and two crates. | W A S D drive; hold right mouse to orbit, wheel zooms. |

To change the time of day, the weather or the waves, select `OceanEnvironment`,
turn on **Editable Children** (right-click), and edit `SkySystem`,
`WindSystem` or `Ocean`.

## How they were made

**Floating objects.** `crate.tscn` and `barrel.tscn` are each a `RigidBody3D`
(mass, mesh, collision shape) with a `BuoyantBody` and a
`BuoyancyProbeVolume`. The volume's `source_paths` points at the mesh, and
**Generate All Probes** baked the probes from it; the scene was saved with them.
An object floats where the water it displaces weighs as much as it does: the
250 kg crate of 1 m³ floats a quarter submerged. Such a light cube is not stable
flat side up, so it rocks onto an edge, as a real one does.

**The boat.** `simple_boat.tscn` is an inherited scene of
`addons/boat_template/boat.tscn`:

1. `Model` is `assets/simple_hull.obj`, made by `tools/make_example_hull.py`
   (bow along −Z).
2. The root sets `mass`, `center_of_mass` (over the hull's centre of buoyancy,
   which the probe volume's warning gave) and the drive settings.
   `CollisionShape3D` holds a convex shape made from the mesh.
3. `BuoyancyProbeVolume`: `source_paths` → `Model`, then
   **Generate All Probes**.
4. `HullWaterFootprint`: `bake_source_paths` → `Model`, then **Bake Profile**
   (saved as `simple_boat_hull_profile.tres`).
5. `BowSpray` was moved to the stem at the waterline, and `CameraTargets` onto
   the boat.

`boat.tscn` turns on `player_controlled` for the boat it drives. The Boat
Template plugin adds the W A S D actions.
