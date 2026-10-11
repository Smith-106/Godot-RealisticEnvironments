# Wind System

A tiny wind provider node. The ocean and the clouds read it; anything else can
too. No dependencies.

Add a `WindSystem` (or `wind_system.tscn`) and point
`OceanSystem.wind_source_path` at it with `use_external_wind` on.

Exports: `wind_speed` (m/s), `wind_direction` (degrees, 0 = +Z, 90 = +X),
`gust_strength` (extra m/s), `gust_frequency` (cycles/s). Gusts only run at
runtime.

Methods: `get_wind_speed()` (with gusts), `get_base_wind_speed()`,
`get_wind_direction_degrees()`, `get_wind_vector_2d()`,
`get_wind_vector_3d()`. Signal `wind_changed` fires when an export changes.

Any node with `get_wind_speed()` and `get_wind_direction_degrees()` (or
`wind_speed` / `wind_direction` properties) can replace it.
