# Changelog

Engine versions are recorded in every drive recording (`engineVersion`).

## 0.3.2 (build 22)

- Corridor maps for long journeys across several oblasts: `tools/build_corridor.py` keeps full detail along a route and whole areas you name; the app offers them next to the bundled maps. They are built on your Mac and kept out of Git.
- Fuel stations are searchable by name or brand; fixed speed cameras appear on the map with their limit.
- Engine 3.1.1 `3.1.1-route-sequence`: route lookups use an index, so a 660 km route starts in 0.1 s instead of 91 s on a Mac; a locked route keeps tracking up to 10 km of uncertainty, since the driver cannot stop on a highway to set the position again.

## 0.3.1 (build 21) — first public release

- Engine 3.1 `3.1-route-sequence`: route position tracked with several weighted hypotheses across successive turns, so repeated bends on mountain roads resolve and the uncertainty shrinks at each confirmed turn; the estimate waits at a bend until the gyro shows the turn; locked routes only stop above 1,000 m of uncertainty.
- Road-bump speed corrections are counted and briefly announced on the tracking card.
- Tracking continues in other apps and with the screen locked when Location is allowed.
- Offline search of villages, towns, districts and streets; Apple Maps search over satellite imagery.
- Up to three route alternatives (fastest, shortest, distinct) and route changes while paused.
- Offline map labels for places, peaks, stations, shops, food, lodging and landmarks; Apple's hybrid labels on satellite imagery; aligned crossfade between the two maps.
- Lviv region map with Carpathian tracks and the Zakarpattia side of the passes.
- Automatic wheelbase refinement from matched turns.
- Removed: rear-camera speed assistance and the manual field-reference flow.
