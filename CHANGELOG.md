# Changelog

Engine versions are recorded in every drive recording (`engineVersion`).

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
