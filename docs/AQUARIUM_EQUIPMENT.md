# Equipment placement geometry

`AquariumMetricBasicArt.create` accepts `placementsCm` for `filter`, `heater`
and `thermometer`. Positions use centimeters, with X measured from the tank
center and Z from the center between its front and back panes. Each returned
placement contains `x`, `y`, `z` and `rotationY` and can be passed back into the
factory. Partial input records inherit the authored default coordinates.

The sponge filter can move across the substrate in X and Z. The heater and
thermometer move along their existing back and front mounting panes in X.
Supported height, mounting depth and zero rotation remain fixed. Unsupported
fields, nonfinite coordinates and glass crossings are rejected before geometry
or material allocation. The scene must still validate clearance against other
hardware and hardscape before accepting an edit.

Regeneration moves the wet filter body, riser and bubble/current outlet together.
The airline and heater cord start at the corresponding moved equipment ports,
then follow their rear-rim clips. The returned `airlineEnd` and `heaterEnd` feed
`AquariumMetricConnections.create`, which routes their counter leads to the
existing power strip and pump. Default geometry remains unchanged.

The factory owns its groups and resource arrays; `dispose()` releases its
resources once. Callers remove both groups before replacing an instance.
Native equipment editing, transactional replacement, persistence/migration and
functional effects are still integration work. This geometry API alone does
not make hardware editable in the workbench.
