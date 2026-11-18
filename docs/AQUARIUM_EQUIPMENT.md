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
## Native workbench

The basic setup lists the filter, heater and thermometer in an Equipment section.
They can be selected in the scene or list, moved with the pointer or coordinate
inspector, and undone/redone. Unsupported axes and rotation are disabled. Equipment
removal and premium/waterfall component editing remain unfinished.

A live command requires all three complete poses and the current document
revision. It builds a candidate assembly and counter connections, checks actual
component/hardscape/plant clearance, then replaces the groups. Rejected and
replaced resources are released once. The riser and submerged leads join the
collision world;
Cable and airline clearance is checked against hardscape and added specimens; the bubble and current origin follow the new filter outlet.
The biological clock, feeding and ecosystem state continue through the edit.

Scene configuration schema 2 saves the three poses separately from planted-tank
objects. Schema 1 remains readable with authored equipment defaults. Unsupported
future versions and incomplete poses are rejected. Native equipment IDs use an
`equipment/` namespace outside the saved plant/hardscape ID grammar, so existing
object names remain usable. Transactional replacement retains the previous
assembly until the edit succeeds.

Equipment removal, temperature/heater behavior, premium/HOB hardware controls
and final native visual/performance acceptance remain integration work.
