# Buoyancy and interactive waves plan

Status: Phases 0–3 done · Written 2026-10-21 · Target: Godot 4.8 Forward+

Objects on the ocean should interact with the water in a visually realistic way;
physical accuracy is not a goal. Scale: about 10 floaters at once, ships up to
battleship size. Splash effects (particles, impact rings) are postponed: they
will be pre-baked effects, done separately.

## Why the previous systems were removed

Both were deleted on 2026-10-21 (`f99900e`). Two problems:

- **Bodies rocked harder and harder.** The iWave simulation's waves went back
  into buoyancy, with a per-body copy of the simulation meant to subtract each
  body's own waves. Any mismatch fed energy back into the body.
- **The waves around bodies looked wrong.** A hull pushed on the simulation by
  its whole draft below the FFT surface (`iwave_pressure.glsl`). That dug a
  permanent trough as deep as the draft, and every swell passing under the hull
  changed the draft, so a boat simply riding the waves kept sending out rings.
  The bow wave had to be added as a separate band, because a pressure patch puts
  its first crest behind the hull.

Buoyancy itself already measured depth from the body's current pose and only
extrapolated the water's height; that part stays.

## Principles

1. **Visual first.** Settings in units you can see (draft in m, a damping
   ratio, drag in 1/s); a body behaves the same at any mass.
2. **One-way coupling.** Bodies make interactive waves; buoyancy and every
   surface query read only the FFT sea. Nothing feeds back.
3. **Waves only from motion relative to the water.** A body moving with the
   water makes no waves (see Phase 2, Sources).
4. **One foam look.** Interaction foam goes through the water's existing foam
   path (`foam_signal`), so wakes look like the whitecaps.
5. **Addon boundaries stay.** `buoyancy_system` depends only on `core`;
   `ocean_system` draws the waves; `boat_template` composes them.

```
core             WaterSurface: + submit_disturbance(), release_disturbance(), get_surface_drift();
                 WaterDisturbance (data)
buoyancy_system  BuoyantBody (child of a RigidBody3D): forces from queries; reports its hull
ocean_system     OceanInteraction (internal, like WaveGenerator): wave simulation and foam
                 around the camera, sampled by the water shader
boat_template    boat.tscn gets a BuoyantBody (and a WaterMask, Phase 4)
```

## Phase 0 — Spikes

Throwaway tests that decide the risky parts. Results are recorded here; the test
code is not kept.

### 0.1 Can a spatial iWave kernel draw a Kelvin wake? — No

The Kelvin wake (a fixed ~19.5° V at any speed) needs dispersion: long waves
faster than short ones, `ω² = g|k|`. A spatial kernel of (2P+1)² taps
approximates `|k|` only for short waves. The phase-speed ratio
`c_kernel / c_exact` along the grid axis, for Tessendorf's kernel (σ = 1, made
zero-sum) and for one least-squares fitted to `|k|`:

| Wavelength (cells) | 6 | 12 | 24 | 64 | 128 | 256 |
| --- | --- | --- | --- | --- | --- | --- |
| Tessendorf, 13×13 | 0.44 | 0.69 | 0.59 | 0.38 | 0.27 | 0.19 |
| Fitted, 13×13 | 0.94 | 1.10 | 0.95 | 0.62 | 0.44 | 0.31 |
| Fitted, 21×21 | 1.01 | 0.97 | 1.09 | 0.79 | 0.57 | 0.41 |

Beyond the kernel's reach every wave moves at about the same speed (13×13 at
0.25 m cells: ~3.1 m/s), so a boat faster than that leaves a speed-dependent
Mach cone instead of a Kelvin wake. A 5 m/s boat's transverse wake waves are
16 m (64 cells) long. **Decision: a spectral simulation** (Phase 2): every
Fourier mode evolves with its exact frequency, at the cost of one forward and
one inverse FFT per step. The window is toroidal anyway, which is what an FFT
assumes.

### 0.2 Stencil cutout for open hulls

Godot 4.8 spatial shaders have `stencil_mode` (`read`, `write`,
`write_depth_fail`, `compare_*`, reference value).

Test: the example boat (`simple_boat.tscn`, open, frozen at the water line, so
water filled it) in `ocean_environment.tscn`, wind 4 m/s. A lid over the
opening just below the gunwale (a strip along the inner skin) used

```glsl
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
stencil_mode write, compare_always, 1;
// fragment: ALPHA = 0.0
```

with `render_priority` −30 (below the underwater pass's −21). The water was a
variant of `water.gdshader` with `stencil_mode read, compare_not_equal, 1;`.

**Result: works.** From above, top-down and from a seat inside, the water inside
the hull (with its caustics) is gone and the water around the boat is
unchanged. Low beside the hull and low off the bow, masked and unmasked
frames are identical outside the hull: the contact line, the hull's reflection
and the refraction stay. The lid is depth-tested, so the near hull wall hides
it, and the water seen past the wall is never cut. In production the
`stencil_mode` line goes into all three variant shaders (they hold the render
modes).

### 0.3 Spectral simulation cost and wake look

Test: a standalone local `RenderingDevice`, `vec2` storage buffers. One step:
sources and border damping, forward FFT (Stockham rows, transpose, rows, with
twiddles computed in the shader), per-mode evolution, inverse FFT: 8
dispatches. The hull: an oval 20 × 4 m, 1 m deep (`T = depth (1 − r²)²`),
moving along +x from rest; water depth 20 m, viscosity 0.01 m²/s, 12 m border
band damped at up to 8/s.

- **FFT:** a cosine of 5 cycles lands on bins ±5 with N²/2 and nothing beside
  it; a round trip comes back within 1e-6.
- **Cost** (RTX 4070 Ti, wall time over 60 steps per submit, so including
  command recording): 256²: 0.040 ms, **512²: 0.056 ms**, 1024²: 0.20 ms per
  step. At 60 steps per second, 512² is about 3.4 ms of GPU time per second.
- **Wake:** after 16 s at 5 m/s and 10 s at 8 m/s, both wakes lie inside the
  19.47° Kelvin wedge (the angle does not change with speed), with the
  transverse and diagonal (divergent) waves. At 5 m/s the transverse crests are
  about 15 m apart (theory: 2πv²/g = 16 m). Peak height 0.64 m (5 m/s) and
  0.82 m (8 m/s), RMS over the window 0.055 m and 0.090 m. The border band
  absorbs the waves: nothing wraps around.
- A pass without a push constant after a barrier gets the previous pass's one
  re-applied, which is an error (as AGENTS.md says): every pass declares one.

## Phase 1 — Buoyancy

`BuoyantBody` (`buoyancy_system`, `class_name`), a child of the `RigidBody3D` it
floats.

- **Probes** lie on the hull's waterline plane, on a grid over the collision
  shapes' outline (from their debug meshes, built in `_ready`). The grid's
  density follows the hull's proportions (about 2×2 for a barrel, 3×5 for a
  boat, more along a battleship); `probe_grid` overrides it. All probes go into
  one surface query per tick.
- **Force per probe:** `weight / N × clamp(1 + (water − probe_y) / draft, 0,
  height / draft)`. At rest the hull's lowest point sits exactly `draft` below
  calm water, whatever the mass. The body bobs at `sqrt(g / draft)`: a slow,
  heavy heave for a battleship's 10 m draft, a quick one for a crate. The
  probes' spread rights pitch and roll; a low centre of mass keeps tall bodies
  (the buoy) upright.
- **Damping** relative to the water's vertical velocity (`damping_ratio`): the
  body rides the waves instead of resisting them.
- **Drag** relative to the surface water's velocity, in the body's frame: low
  forward, high sideways (keel grip), plus yaw damping; in 1/s, scaled by mass
  and the submerged share.
- **Drift:** carried downwind by `WaterSurface.get_surface_drift()`, the same
  3 % of the wind that moves the foam (`OceanSystem._FOAM_DRIFT_WIND_SHARE`
  moves behind it), so debris and foam travel together.
- **Timing:** depth uses the body's pose this tick; only the water's height is
  delayed, extrapolated with `extrapolated_height(get_query_age())`, and
  corrected for the probe's sideways move since the query with the sample's
  slope. The water does not depend on the body, so the delay cannot feed back.
  Held frozen until the first result (error after a timeout).
- **Stability:** every mode's frequency (heave, roll, pitch) times the physics
  step stays below 0.5; tiny drafts or very light, wide bodies get a
  configuration warning.
- **Editor:** configuration warnings (no `RigidBody3D` parent, no collision
  shapes, `draft` ≥ height, body still frozen, no water); debug drawing of the
  probes and the waterline.

`FloatingBoat` drive changes: thrust at a point at the stern below the
waterline (the bow lifts as it speeds up); turning by a rudder force at the
stern that grows with speed (the boat leans and slides); both scale with the
stern's submersion from the `BuoyantBody` (`buoyancy_path`).

Remove `freeze = true` from the template, demo boats, buoy and example floaters
and the "rewrite in progress" notes.

**Acceptance:** a drop test in calm water comes to rest; in steady swell the
motion levels off; the boats drive and turn plausibly; the buoy stays upright.

### Phase 1 implementation notes (2026-10-21)

Done as planned, with these differences:

- **Shares balance about the centre of mass** (`_balance_probes()`, first
  tick, from the physics state's `center_of_mass_local`). With even shares the
  boats trimmed 3°: the probes' centre is not under the centre of mass. Now
  every body rests level at `draft`. A centre of mass at the footprint's edge
  clamps the shares (error); outside it is a configuration warning.
- **The lift acts no lower than the centre of mass.** The caravel (centre of
  mass 0.6 m above its probes, 4.7 m beam) listed 45° and never settled.
  Ballast below the probes (the buoy's centre of mass is 4.4 m under them)
  still steadies a body.
- **Drift** is `WaterSurface.get_surface_drift()`, from
  `OceanSystem._get_surface_drift()`, which also moves the foam.
- **`FloatingBoat`:** `turn_acceleration` (degrees/s², from the body's yaw
  inertia) replaces `turn_torque_per_kg`; the rudder is a side force at
  `propulsion_position`. Thrust fades over the last 10 % below the speed
  limit: switched on and off at the cap, it rocked the bow.
- **Godot's default linear damping** (0.1/s) added to the water's drag (the
  caravel topped out near 3 m/s). The template body uses `linear_damp_mode`
  Replace.
- No probe preview in the editor (runtime nodes stay off there); the runtime
  debug view draws the probes and the water over each.

The floaters (drafts reproduce the waterlines of the removed geometry-based
system; the crate's and barrel's follow from their density):

| Scene | `draft` | forward / sideways drag | Drive |
| --- | --- | --- | --- |
| `boat.tscn` (template box) | 0.3 m | 0.2 / 2.0 | propulsion (0, −0.4, 2.3), 40°/s² |
| `demo/rowboat.tscn` | 0.26 m | 0.3 / 2.0 | (0, −0.35, 2.4), 30°/s² |
| `demo/floating_box.tscn` (caravel) | 2.13 m | 0.1 / 2.0 | (0, −0.6, 9), 8°/s² |
| `examples/simple_boat.tscn` | 0.255 m | 0.2 / 2.0 | (0, −0.3, 2), 45°/s² |
| `demo/buoy.tscn` | 2.42 m | 1.0 / 1.0 | horizontal axes locked (moored) |
| `examples/crate.tscn` | 0.25 m | 1.0 / 1.0 | |
| `examples/barrel.tscn` | 0.13 m | 0.6 / 1.0 | |

### Phase 1 measurements

All seven floaters in `ocean_environment.tscn`, 60 physics ticks per second.

- **Calm drop** (wind 0.5 m/s, dropped from 0.5 m above rest): every body
  rests within 1 mm of its expected height, pitch and roll under 0.1°,
  settled after 1.1–3.8 s.
- **Rough sea** (wind 12 m/s, 160 s): the roll range per 20 s window
  fluctuates without a trend, so nothing excites itself. Small boats 24–53°,
  caravel 2–4°, buoy 2–4°, crate and barrel 31–63°. Free bodies drift about
  0.35 m/s, 3 % of the wind.
- **Driving** (wind 7 m/s, simulated input): the rowboat reaches 3.7 m/s (cap
  4), turns at 22°/s and heels 1.7° out of the turn; the example boat 4.3 m/s
  (cap 4.5) and 29°/s; the caravel 3.6 m/s after 12–15 s on its way to about
  5 m/s, 7°/s with 3° of heel. The bows lift about 0.6° while accelerating.
- `demo/main.tscn`, `examples/floating_objects.tscn`, `examples/boat.tscn`
  and `demo/underwater_showcase.tscn` run without errors; the changed scripts
  have no warnings.

## Phase 2 — Interactive waves

### Contract (`core`)

`WaterSurface.submit_disturbance(owner, disturbance)` every physics tick,
`release_disturbance(owner)` in `_exit_tree`, like the queries.
`WaterDisturbance` holds the hull's waterline transform, footprint half-extents
and corner roundness, draft, velocity and angular velocity, and
`wave_strength`. More than `MAX_DISTURBANCES` (16) in the window: the nearest
win, with one `push_error`.

### Simulation (`OceanInteraction`)

- **Window:** 512² cells of 0.25 m (128 m; `interaction_map_size` and
  `interaction_cell_size` as quality exports), world-locked texels with
  wrap-around addressing. Its centre follows the camera, shifted toward where it
  looks, snapped to cells; cells entering the window start flat. Fixed step rate
  (60 Hz), independent of the frame rate.
- **Step:** (1) sources and border damping in space; (2) forward FFT of
  `h + i·∂h/∂t` (two real fields, one complex transform); (3) each mode evolves
  exactly by `ω = sqrt(g |k| tanh(|k| d))`, with `d` the spectrum's
  `water_depth` (one value, one place), and viscous damping `∝ k²` for the
  shortest waves; (4) inverse FFT; (5) output: height, slopes, hull coverage.
  One FFT kernel serves both this and `WaveGenerator`: the existing Stockham
  kernel generalised with a direction sign and the spectrum count (it is fixed
  at four inverse transforms today), not a second copy.
- **Sources** (thin-ship): each hull is a smooth footprint `T(x)` (its depth
  under the waterline, an oval or rounded box from its bounds). Its source is
  the change of `T` from its motion relative to the water:
  `q = −(v − u)·∇T + (w − u_y)·∂T/∂depth`, with `u` the FFT water's velocity.
  Moving with the water gives nothing; going forward lifts the water at the bow
  and lowers it at the stern, and the Kelvin wake follows. Fast hulls add their
  source in sub-steps along the path. `wave_strength` scales it.
- **Smoothness:** soft-edged footprints, viscosity on the shortest waves, a
  soft limit on steepness, and the rendered height fades to zero inside hull
  footprints (waves never poke through a hull).

### Water shader

`displacement += h`, `gradient += ∇h`, both faded at the window's edge; the
same uniforms in all three tiers (`ocean_common.gdshaderinc` too). Waves under
about 2 m show only in the normals (the mesh near the camera has 1 m spacing;
the demo can use `mesh_base_cell_size` 0.5). The camera's above/below test adds
the interaction height (one flagged query point). Surface queries otherwise stay
FFT-only. Debug views for height and coverage.

### Phase 2 implementation notes (2026-10-21)

Done as planned, with these differences:

- **Sources from poses, not velocities.** Each step adds
  `T(pose now) − T(previous pose moved by the water's velocity × step)`, which
  covers translation, turning and heave in one difference and needs no
  sub-steps (the differences telescope). `OceanInteraction` keeps each hull's
  last pose; a hull seen for the first time, or one that jumped more than half
  its half length in a step, starts over instead of making a wave. Depth is
  `draft` plus the waterline plane's mean depth below the water, so a hull
  riding the swell keeps its depth and makes nothing.
- **Footprint:** a superellipse, `(1 − r²)²` deep, fitted to the collision
  shapes' outline from above (the share of the bounding box it fills picks the
  exponent). The water sees no pointed bows.
- **Steps run in `OceanSystem._physics_process`**, one per physics tick, after
  the bodies (`process_physics_priority` 100), not at a separate 60 Hz.
- **FFT kernel:** `fft_compute.glsl` and `transpose.glsl` take the spectrum
  count, and the former a direction, as push constants (the butterfly factors
  are conjugated for the forward transform).
- **Output:** `(height, slope x, slope z, squared slope)`, rgba16f with mips
  from `mip_chain.glsl` (the map bound to both of its inputs, one dispatched).
  The fragment shader reads it with `textureGrad` and anisotropic filtering,
  adding the hidden slope variance to the roughness. Instead of a coverage
  debug view, view 17 shows the slopes.
- **Window centre:** the camera plus 0.25 × the window along its view
  direction's horizontal part, so a camera looking down gets no lead.
- Other: drifting debris makes no waves (its velocity matches the water's);
  `BuoyantBody.wake_strength` scales a body's waves; at most 16 hulls, the
  nearest, with one error past that.

### Phase 2 measurements

- **Wake shape** (wind 2 m/s, height debug view from 55 m up): the example
  boat at 4.3 m/s draws a Kelvin wake with transverse and divergent waves;
  the caravel's dropped start sent out rings, as a dropped hull does.
- **Heights** (map read back after 12 s at full throttle, within 25 m of each
  boat): example boat 0.24 m, rowboat 0.27 m, caravel 0.38 m at 3.5 m/s;
  steepest slope 0.41.
- **Look** (wind 6 m/s, chase camera): a visible but subtle V behind the small
  boats and a smooth wake band behind the caravel; no artifacts at the hulls.
  Without foam (Phase 3) wakes read mostly through their shading.
- **Cost** (RTX 4070 Ti, GPU timestamps around one step, 512² cells, 8 hulls):
  0.076 ms median, 0.078 ms at the 90th percentile.
- The demo, the examples and `ocean_optics_debug.tscn` run without errors;
  the changed scripts have no warnings.

## Phase 3 — Foam

A foam coverage map in the same window. Sources: the waterline band of each hull
(grows with relative speed), a churned trail behind the stern (grows with
speed), and steep simulated crests. It drifts with `get_surface_drift()`, decays
over a lifetime, and is added to `foam_signal`, so it gets the same lace,
roughness and lighting as the whitecaps. Coverage stays linearly averageable
(mips).

### Phase 3 implementation notes (2026-10-21)

- **Pass:** `interaction_foam.glsl`, beside the second output pass. Coverage
  lives in two halves of a buffer and in a second rgba16f map; `mip_chain.glsl`
  now filters both maps in one dispatch.
- **Drift** in whole cells with the remainder carried over (as the cascades'
  foam), so the foam never blurs; cells new to the window start clean.
- **Hull foam by speed, not displacement.** The first version grew foam with
  how fast a hull displaces water (|dT/dt|). Over one passage that adds up to
  roughly the draft, so the caravel (2.13 m) laid a solid white stripe while
  the small boats looked right. Now each hull holds a coverage set by its speed
  through the water, turning included (`_hull_foam()`: none below 1 m/s, 0.6 at
  8 m/s, times `wake_strength`), over its footprint grown by 25 %, densest in
  the middle: the trail's width follows the hull, its density the speed.
- **Crest foam** past slope 0.35, growing toward 0.6 only: uncapped, a
  skidding caravel's stern turned into a solid sheet.
- Foam fades with an e-folding lifetime of 8 s; it joins `foam_signal`, so
  `foam_intensity` scales it like the whitecaps. Debug view 18 shows it.

### Phase 3 measurements

- **Coverage** (map read back, wind 6 m/s): rowboat at 3.7 m/s peaks at 0.25
  on a straight course and 0.33 in a turn; caravel 0.22 at 3.4 m/s, 0.40 in a
  turn at 3.9 m/s. No cell reaches 0.6.
- **Look:** a patchy lace trail behind the small boats, foam at the bow
  waterline, and a lighter streak behind the caravel that breaks up with
  distance.
- **Cost:** a step with foam takes 0.093 ms (was 0.076 ms; 512², 8 hulls,
  RTX 4070 Ti).

## Phase 4 — Hull cutouts

`WaterMask`: an invisible lid mesh over an open hull's opening at gunwale
height, writing stencil before the water; the water skips those pixels (see
0.2). Screen space, so hulls wider above the waterline stay correct; no baking.
Known limit: a crest rising above the gunwale in front of the boat is cut where
it overlaps the opening. AGENTS.md gets the exception to "water has the lowest
transparent priority".

## Later

- **Coarse level for ships:** a second window (e.g. 512² × 2 m, ~1 km), each
  hull writing into the level that suits its size, so a battleship's whole wake
  shows (its transverse waves are ~140 m long at 30 knots). About doubles the
  simulation cost.
- **Splashes:** a water-entry signal on `BuoyantBody` for pre-baked effects,
  impact rings in the simulation.
- **Sinking.**

## Documentation and AGENTS.md

Each phase updates both README languages of the touched addons, the examples
README, the CHANGELOG and AGENTS.md (one-way coupling, the disturbance
contract, the interaction window in the water shader, the stencil exception).

## Deferred verification

- Stencil cutout (0.2), not covered by the test: the camera under the
  surface (underwater pass and the surface seen from below), a crest above the
  gunwale in front of the boat, MSAA, the screen-space reflection mode, a
  pitching and rolling hull.
- Simulation cost (0.3) on a mid-range or integrated GPU, and inside the full
  frame (the test ran alone on a local device).
- Buoyancy (1): driving by hand (the test used simulated input); opening and
  saving the inherited boat scenes in the editor (the `BuoyantBody` overrides
  have no `index` attribute yet); a battleship-sized hull; the configuration
  warnings in the Scene dock.
- Interactive waves (2): the camera's above/below switch near a wake crest;
  the window following a fast-moving camera; 1024² and other cell sizes; the
  Low and Medium shader tiers; caustics under wakes (the underwater view does
  not include them).
