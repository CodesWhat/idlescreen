# Original ornament assets

`Sources/IdleScreenRenderer/Resources/AquariumRuntime/kitsch-ornaments-v1.js`
contains three original procedural models. They are bundled renderer resources,
with `reviewOnly: true` and `defaultPlacement: false`. They are not in the
placement or shop catalogs and do not appear in default tanks.

These dimensions are authored and measured from the rendered geometry. They
are not measurements of retail products.

| Kind | Width × height × depth, cm | Triangles | Verified body diameter through the opening, cm |
| --- | --- | ---: | ---: |
| Pirate chest | 12 × 12.92 × 9.63 | 468 | 0.7 |
| Wreck | 24 × 15.8 × 10 | 396 | 0.8 |
| Diver helmet | 14 × 16.2 × 14 | 1,212 | 1.0 |

The opening values are conservative tested diameters, not maximum capacities.
All three fit inside the authored 60 × 36 × 36 cm reference aquarium above its
5 cm substrate. Their local floor is zero; placement must translate the model
onto its actual substrate or support.

## Factory contract

`create(THREE, { kind, seed, cmPerUnit })` returns the group, its owned resources,
measured dimensions, component ranges, ground contacts, exposed mount anchors
and passage probes. `worldAnchor(id)` follows the group's current parent
transform. `dispose()` releases the instance's resources once; callers first
remove the group from their scene.

Components are closed solids batched into at most two visible meshes. Wood,
weathered metal and patina use an original seeded pixel texture. All rendered
meshes provide collision, climbing and shadow flags. Openings are gaps in the
actual geometry, rather than invisible substitutes for a solid mesh.

The Node check is `node --test Support/AquariumRuntimeChecks/kitsch-ornaments.cjs`.
The renderer test suite also runs the geometry, winding, capsule clearance,
mount, scale and resource-ownership checks inside the bundled WebKit runtime.

Visual approval, placement catalog registration, support-graph integration and
shop inventory remain separate work. Passing geometry checks does not establish
that the art has been visually reviewed.
