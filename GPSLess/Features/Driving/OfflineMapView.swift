import MapLibre
import SwiftUI

struct OfflineMapView: UIViewRepresentable {
    @ObservedObject var store: NavigationStore
    var bottomInset: CGFloat = 400
    var isActive = true

    func makeCoordinator() -> Coordinator {
        return Coordinator(store: store, isActive: isActive)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleJSON: "{\"version\":8,\"sources\":{},\"layers\":[]}")
        map.delegate = context.coordinator
        map.automaticallyAdjustsContentInset = false
        map.contentInset = UIEdgeInsets(top: 140, left: 0, bottom: bottomInset, right: 0)
        map.locationManager = DisabledLocationProvider()
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        // Low enough to show a whole long-distance route; minor roads only
        // appear from zoom 10 so the overview stays fast.
        map.minimumZoomLevel = 5
        map.maximumZoomLevel = 19
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true
        Self.showInitialCamera(for: store.region, on: map)
        map.accessibilityIdentifier = "offlineMap"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        context.coordinator.loadedRegion = store.region
        map.styleJSON = Self.offlineStyle(store.region)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.store = store
        context.coordinator.isActive = isActive
        let inset = UIEdgeInsets(top: 140, left: 0, bottom: bottomInset, right: 0)
        if map.contentInset != inset {
            map.contentInset = inset
            if store.phase == .selecting {
                context.coordinator.invalidateRouteLayout()
            }
        }
        if context.coordinator.loadedRegion != store.region {
            context.coordinator.loadedRegion = store.region
            map.styleJSON = Self.offlineStyle(store.region)
            Self.showInitialCamera(for: store.region, on: map)
        }
        if !isActive, let viewport = store.mapViewport {
            context.coordinator.apply(viewport, to: map)
        }
        context.coordinator.update()
    }

    /// The map reopens where it was last left in each region, otherwise at the
    /// region's default view. UI tests always start from the default.
    private static func showInitialCamera(for region: MapRegion, on map: MLNMapView) {
        if !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let saved = UserDefaults.standard.array(forKey: cameraKey(region)) as? [Double], saved.count == 3 {
            map.setCenter(CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1]), zoomLevel: saved[2], animated: false)
        } else {
            map.setCenter(CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude),
                          zoomLevel: region.zoom, animated: false)
        }
    }

    /// The chosen route, matching `Theme.route`.
    static let routeColor = UIColor(red: 0.20, green: 0.78, blue: 1.0, alpha: 1)

    static func cameraKey(_ region: MapRegion) -> String {
        return "mapCamera.\(region.id)"
    }

    /// Place and point-of-interest categories written by tools/build_pois.py,
    /// with an SF Symbol and colour in the manner of Apple Maps.
    static let poiCategories: [(name: String, symbol: String, color: String)] = [
        ("shop", "bag.fill", "#E3A21A"), ("grocery", "cart.fill", "#E3A21A"), ("food", "fork.knife", "#F2853A"),
        ("fuel", "fuelpump.fill", "#3D8BEB"), ("pharmacy", "pills.fill", "#E5534B"), ("health", "cross.fill", "#E5534B"),
        ("lodging", "bed.double.fill", "#9B7BF0"), ("landmark", "star.fill", "#D766B8"), ("culture", "theatermasks.fill", "#D766B8"),
        ("worship", "building.columns.fill", "#9AA3A8"), ("education", "graduationcap.fill", "#B08968"),
        ("bank", "banknote.fill", "#6F86B0"), ("post", "envelope.fill", "#6F86B0"), ("civic", "building.2.fill", "#6F86B0"),
        ("emergency", "shield.fill", "#E5534B"), ("sport", "figure.run", "#43A96E"), ("park", "leaf.fill", "#43A96E"),
        ("camp", "tent.fill", "#43A96E"), ("peak", "mountain.2.fill", "#B08968"), ("ski", "cablecar.fill", "#45A9DE"),
        ("rail", "tram.fill", "#4A86DE"), ("transit", "bus.fill", "#4A86DE"), ("camera", "camera.fill", "#E5484D")
    ]

    /// Settlements, districts and points of interest above the roads. Each
    /// POI carries the zoom from which it appears (`z`); lower `r` wins
    /// collisions, so stations and fuel outlast shops as the map zooms out.
    private static var labelLayers: [[String: Any]] {
        var colors: [Any] = ["match", ["get", "c"]]
        for category in poiCategories {
            colors += [category.name, category.color]
        }
        colors.append("#c5d2d3")
        var layers: [[String: Any]] = [
            ["id": "district-labels", "type": "symbol", "source": "pois", "minzoom": 12, "filter": ["==", "c", "district"],
             "layout": ["text-field": "{n}", "text-font": ["Open Sans Semibold"], "text-size": 10.5, "text-transform": "uppercase",
                        "text-letter-spacing": 0.08, "text-max-width": 8, "symbol-sort-key": ["get", "r"]],
             "paint": ["text-color": "#8fa2a8", "text-halo-color": "#111c22", "text-halo-width": 1.5]]
        ]
        for zoom in [11, 12, 13, 14, 15, 16, 17] {
            layers.append(["id": "poi-labels-\(zoom)", "type": "symbol", "source": "pois", "minzoom": zoom,
                           "filter": ["all", ["==", "z", zoom], ["!in", "c", "place", "district"]],
                           "layout": ["icon-image": "poi-{c}", "text-field": "{n}", "text-font": ["Open Sans Semibold"],
                                      "text-size": 10.5, "text-offset": [0, 1.15], "text-anchor": "top", "text-max-width": 8,
                                      "text-optional": true, "symbol-sort-key": ["get", "r"], "icon-padding": 3],
                           "paint": ["text-color": colors, "text-halo-color": "#111c22", "text-halo-width": 1.4]])
        }
        // Towns and cities from the outermost zoom, villages from 11, hamlets from 13.
        for (id, places, minimum) in [("place-labels-major", ["city", "town"], 0), ("place-labels-village", ["village"], 11),
                                      ("place-labels-hamlet", ["hamlet"], 13)] {
            layers.append(["id": id, "type": "symbol", "source": "pois", "minzoom": minimum,
                           "filter": ["all", ["==", "c", "place"], ["in", "p"] + places],
                           "layout": ["text-field": "{n}", "text-font": ["Open Sans Semibold"], "text-max-width": 9,
                                      "text-size": ["match", ["get", "p"], "city", 17, "town", 15, "village", 13, 11.5],
                                      "symbol-sort-key": ["get", "r"]],
                           "paint": ["text-color": "#e8f0f1", "text-halo-color": "#111c22", "text-halo-width": 2]])
        }
        return layers
    }

    /// Round coloured badges with a white SF Symbol, registered as `poi-<category>`.
    static func poiIcons() -> [String: UIImage] {
        var icons: [String: UIImage] = [:]
        let size = CGSize(width: 20, height: 20)
        let configuration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        for category in poiCategories {
            let symbol = UIImage(systemName: category.symbol, withConfiguration: configuration)
                ?? UIImage(systemName: "mappin", withConfiguration: configuration)
            let color = UIColor(hex: category.color)
            icons["poi-\(category.name)"] = UIGraphicsImageRenderer(size: size).image { _ in
                let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
                color.setFill()
                circle.fill()
                UIColor(red: 0.07, green: 0.11, blue: 0.13, alpha: 1).setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
                if let symbol = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    let origin = CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
                    symbol.draw(at: origin)
                }
            }
        }
        return icons
    }

    private static func offlineStyle(_ region: MapRegion) -> String {
        let resources = Bundle.main.resourceURL!.appendingPathComponent("OfflineData")
        let fontURL = resources.appendingPathComponent("fonts").absoluteString + "/{fontstack}/{range}.pbf"
        let emptyGeoJSON: [String: Any] = ["type": "FeatureCollection", "features": []]
        let style: [String: Any] = [
            "version": 8,
            "name": "\(region.name) Offline",
            "glyphs": fontURL,
            "sources": [
                "roads": ["type": "geojson", "data": region.roadsURL.map { url -> Any in url.absoluteString } ?? emptyGeoJSON],
                "areas": ["type": "geojson", "data": region.areasURL.map { url -> Any in url.absoluteString } ?? emptyGeoJSON],
                "pois": ["type": "geojson", "data": region.poisURL.map { url -> Any in url.absoluteString } ?? emptyGeoJSON]
            ],
            "layers": [
                ["id": "background", "type": "background", "paint": ["background-color": "#111c22"]],
                ["id": "green", "type": "fill", "source": "areas", "filter": ["==", "kind", "green"], "paint": ["fill-color": "#203932", "fill-opacity": 0.8]],
                ["id": "water", "type": "fill", "source": "areas", "filter": ["==", "kind", "water"], "paint": ["fill-color": "#173f52"]],
                ["id": "road-casing", "type": "line", "source": "roads", "minzoom": 10, "layout": ["line-cap": "round", "line-join": "round"], "paint": ["line-color": "#0b1318", "line-width": ["interpolate", ["linear"], ["zoom"], 10, 1.5, 14, 5, 18, 16]]],
                ["id": "streets", "type": "line", "source": "roads", "minzoom": 10, "filter": ["!=", "kind", "track"], "layout": ["line-cap": "round", "line-join": "round"], "paint": ["line-color": "#52646d", "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.6, 14, 2.5, 18, 12]]],
                ["id": "tracks", "type": "line", "source": "roads", "minzoom": 11, "filter": ["==", "kind", "track"], "paint": ["line-color": "#7a6a52", "line-dasharray": [2, 1.5], "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.5, 14, 1.8, 18, 7]]],
                ["id": "major-roads", "type": "line", "source": "roads", "filter": ["in", "kind", "primary", "secondary", "trunk", "motorway", "tertiary"], "layout": ["line-cap": "round", "line-join": "round"], "paint": ["line-color": "#879896", "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.6, 10, 1.5, 14, 4, 18, 14]]],
                ["id": "street-labels", "type": "symbol", "source": "roads", "minzoom": 13, "layout": ["symbol-placement": "line", "text-field": "{name}", "text-font": ["Open Sans Semibold"], "text-size": 11, "symbol-spacing": 350, "text-max-angle": 35], "paint": ["text-color": "#c5d2d3", "text-halo-color": "#142129", "text-halo-width": 1.5]]
            ] + labelLayers
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: style)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "{\"version\":8,\"sources\":{},\"layers\":[]}"
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var store: NavigationStore
        var isActive: Bool
        weak var map: MLNMapView?
        private let marker = MLNPointAnnotation()
        private var markerAdded = false
        private var lastCameraRequest = -1
        private var lastTrailCount = -1
        private var lastTrailEnd: Coordinate?
        private var trailSource: MLNShapeSource?
        private var uncertaintySource: MLNShapeSource?
        private var arrowView: PositionAnnotationView?
        private var routeSource: MLNShapeSource?
        private var renderedRoute: SelectedRoute?
        private var routeLayoutInvalidated = false
        private let destinationMarker = MLNPointAnnotation()
        private var destinationAdded = false
        var loadedRegion: MapRegion?
        private var alternativesSource: MLNShapeSource?
        private var renderedOptionsKey: String?
        private var renderedSelectedIndex = -1
        private var lastFocusRequest = 0
        private var lastOverviewRequest = 0

        /// Shows every point inside the part of the map the cards leave free.
        func frame(_ points: [CLLocationCoordinate2D], on map: MLNMapView, animated: Bool) {
            guard let first = points.first else {
                return
            }
            var south = first.latitude
            var north = first.latitude
            var west = first.longitude
            var east = first.longitude
            for point in points {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
                west = min(west, point.longitude)
                east = max(east, point.longitude)
            }
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
                                             ne: CLLocationCoordinate2D(latitude: north, longitude: east))
            map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 30, left: 40, bottom: 30, right: 70),
                                           animated: animated, completionHandler: nil)
        }
        private var coverageSource: MLNShapeSource?
        private var coverageBounds: [Double]?

        init(store: NavigationStore, isActive: Bool) {
            self.store = store
            self.isActive = isActive
        }

        func invalidateRouteLayout() {
            routeLayoutInvalidated = true
        }

        /// Drawn beneath street, place and POI labels, as route lines are in Apple Maps.
        private func addBelowLabels(_ layer: MLNStyleLayer, to style: MLNStyle) {
            if let labels = style.layer(withIdentifier: "street-labels") {
                style.insertLayer(layer, below: labels)
            } else {
                style.addLayer(layer)
            }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            for (name, image) in OfflineMapView.poiIcons() {
                style.setImage(image, forName: name)
            }
            // Offered routes that are not chosen sit beneath the chosen one.
            let alternatives = MLNShapeSource(identifier: "route-alternatives", shape: nil, options: nil)
            style.addSource(alternatives)
            let alternativesLayer = MLNLineStyleLayer(identifier: "route-alternatives-line", source: alternatives)
            alternativesLayer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.55, green: 0.62, blue: 0.66, alpha: 1))
            alternativesLayer.lineWidth = NSExpression(forConstantValue: 5)
            alternativesLayer.lineOpacity = NSExpression(forConstantValue: 0.75)
            addBelowLabels(alternativesLayer, to: style)
            alternativesSource = alternatives
            renderedOptionsKey = nil
            let route = MLNShapeSource(identifier: "selected-route", shape: nil, options: nil)
            style.addSource(route)
            // A dark casing keeps the route readable over busy streets.
            let casing = MLNLineStyleLayer(identifier: "selected-route-casing", source: route)
            casing.lineColor = NSExpression(forConstantValue: UIColor(red: 0.02, green: 0.18, blue: 0.26, alpha: 1))
            casing.lineWidth = NSExpression(forConstantValue: 10)
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            addBelowLabels(casing, to: style)
            let routeLayer = MLNLineStyleLayer(identifier: "selected-route-line", source: route)
            routeLayer.lineColor = NSExpression(forConstantValue: OfflineMapView.routeColor)
            routeLayer.lineWidth = NSExpression(forConstantValue: 6)
            routeLayer.lineCap = NSExpression(forConstantValue: "round")
            routeLayer.lineJoin = NSExpression(forConstantValue: "round")
            addBelowLabels(routeLayer, to: style)
            routeSource = route
            renderedRoute = nil
            let trail = MLNShapeSource(identifier: "drive-trail", shape: nil, options: nil)
            style.addSource(trail)
            let trailLayer = MLNLineStyleLayer(identifier: "drive-trail-line", source: trail)
            trailLayer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.69, green: 0.96, blue: 0.39, alpha: 0.85))
            trailLayer.lineWidth = NSExpression(forConstantValue: 4)
            addBelowLabels(trailLayer, to: style)
            trailSource = trail
            let uncertainty = MLNShapeSource(identifier: "uncertainty", shape: nil, options: nil)
            style.addSource(uncertainty)
            let uncertaintyLayer = MLNFillStyleLayer(identifier: "uncertainty-fill", source: uncertainty)
            uncertaintyLayer.fillColor = NSExpression(forConstantValue: UIColor(red: 0.73, green: 0.88, blue: 0.42, alpha: 1))
            uncertaintyLayer.fillOpacity = NSExpression(forConstantValue: 0.10)
            addBelowLabels(uncertaintyLayer, to: style)
            uncertaintySource = uncertainty
            // The outline follows the loaded graph's bounds once it is available.
            let coverage = MLNShapeSource(identifier: "coverage", shape: nil, options: nil)
            style.addSource(coverage)
            coverageSource = coverage
            coverageBounds = nil
            let coverageLayer = MLNLineStyleLayer(identifier: "coverage-line", source: coverage)
            coverageLayer.lineColor = NSExpression(forConstantValue: UIColor.systemOrange.withAlphaComponent(0.55))
            coverageLayer.lineWidth = NSExpression(forConstantValue: 1.5)
            coverageLayer.lineDashPattern = NSExpression(forConstantValue: [2, 4])
            addBelowLabels(coverageLayer, to: style)
            DispatchQueue.main.async {
                self.store.mapReady = true
            }
            update()
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async {
                self.store.message = "Offline map error: \(error.localizedDescription)"
                self.store.mapReady = false
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation === destinationMarker {
                return mapView.dequeueReusableAnnotationView(withIdentifier: "destination")
                    ?? DestinationAnnotationView(annotation: annotation, reuseIdentifier: "destination")
            }
            guard annotation === marker else {
                return nil
            }
            let view = PositionAnnotationView(annotation: annotation, reuseIdentifier: "position")
            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragMarker(_:)))
            drag.delegate = self
            view.addGestureRecognizer(drag)
            for gesture in mapView.gestureRecognizers ?? [] {
                if gesture is UIPanGestureRecognizer {
                    gesture.require(toFail: drag)
                }
            }
            arrowView = view
            view.arrow.transform = CGAffineTransform(rotationAngle: store.heading)
            return view
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if reason.contains(.gesturePan) || reason.contains(.gesturePinch) {
                DispatchQueue.main.async {
                    self.store.follow = false
                }
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            guard isActive else {
                return
            }
            let bounds = mapView.visibleCoordinateBounds
            let latitudeDelta = bounds.ne.latitude - bounds.sw.latitude
            let longitudeDelta = bounds.ne.longitude - bounds.sw.longitude
            guard latitudeDelta > 0, longitudeDelta > 0 else {
                return
            }
            let viewport = NavigationMapViewport(
                center: Coordinate(
                    latitude: (bounds.ne.latitude + bounds.sw.latitude) / 2,
                    longitude: (bounds.ne.longitude + bounds.sw.longitude) / 2
                ),
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
            let camera = [mapView.centerCoordinate.latitude, mapView.centerCoordinate.longitude, mapView.zoomLevel]
            DispatchQueue.main.async {
                guard self.isActive else {
                    return
                }
                self.store.mapViewport = viewport
                // Views the user chose, not the camera following a drive.
                if !self.store.follow, self.loadedRegion == self.store.region {
                    UserDefaults.standard.set(camera, forKey: OfflineMapView.cameraKey(self.store.region))
                }
            }
        }

        func apply(_ viewport: NavigationMapViewport, to map: MLNMapView) {
            let halfLatitude = viewport.latitudeDelta / 2
            let halfLongitude = viewport.longitudeDelta / 2
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(
                    latitude: viewport.center.latitude - halfLatitude,
                    longitude: viewport.center.longitude - halfLongitude
                ),
                ne: CLLocationCoordinate2D(
                    latitude: viewport.center.latitude + halfLatitude,
                    longitude: viewport.center.longitude + halfLongitude
                )
            )
            // The viewport covers the whole view, like the satellite map's
            // region; cancel the content inset MapLibre adds to the padding.
            let inset = map.contentInset
            map.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: -inset.top, left: -inset.left, bottom: -inset.bottom, right: -inset.right),
                animated: false,
                completionHandler: nil
            )
        }

        func update() {
            guard let map else {
                return
            }
            if let source = coverageSource, let bounds = store.graph?.dataset.bounds, bounds != coverageBounds {
                coverageBounds = bounds
                var coordinates = [(bounds[0], bounds[1]), (bounds[2], bounds[1]), (bounds[2], bounds[3]), (bounds[0], bounds[3]), (bounds[0], bounds[1])].map { point in
                    return CLLocationCoordinate2D(latitude: point.0, longitude: point.1)
                }
                source.shape = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
            }
            let optionsKey = store.routeOptions.map { option in
                return "\(option.route.start.edge)-\(option.route.edges.count)-\(option.route.destination.edge)"
            }.joined(separator: ",")
            if alternativesSource != nil, optionsKey != renderedOptionsKey || store.selectedRouteIndex != renderedSelectedIndex {
                renderedSelectedIndex = store.selectedRouteIndex
                if let graph = store.graph {
                    let lines = store.routeOptions.enumerated().filter { index, _ in
                        return index != store.selectedRouteIndex
                    }.map { _, option -> MLNPolylineFeature in
                        var points = option.route.coordinates(in: graph).map { coordinate in
                            return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        }
                        return MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
                    }
                    alternativesSource?.shape = MLNShapeCollectionFeature(shapes: lines)
                }
            }
            if routeSource != nil, routeLayoutInvalidated || renderedRoute != store.selectedRoute || optionsKey != renderedOptionsKey {
                // Fit the camera to a new set of routes, not to every choice among them.
                let fit = routeLayoutInvalidated || optionsKey != renderedOptionsKey || store.routeOptions.isEmpty
                routeLayoutInvalidated = false
                renderedRoute = store.selectedRoute
                renderedOptionsKey = optionsKey
                if let route = store.selectedRoute, let graph = store.graph {
                    var points = route.coordinates(in: graph).map { coordinate in
                        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }
                    routeSource?.shape = MLNPolyline(coordinates: &points, count: UInt(points.count))
                    let framed = store.routeOptions.flatMap { option in
                        return option.route.coordinates(in: graph).map { coordinate in
                            return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        }
                    } + points
                    if fit {
                        frame(framed, on: map, animated: false)
                    }
                    let destination = graph.coordinate(route.destination)
                    destinationMarker.coordinate = CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
                    destinationMarker.title = "B · Destination"
                    if !destinationAdded {
                        map.addAnnotation(destinationMarker)
                        destinationAdded = true
                    }
                } else {
                    routeSource?.shape = nil
                    if destinationAdded {
                        map.removeAnnotation(destinationMarker)
                        destinationAdded = false
                    }
                }
            }
            if let coordinate = store.coordinate {
                marker.coordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                if !markerAdded {
                    map.addAnnotation(marker)
                    markerAdded = true
                }
                arrowView?.arrow.transform = CGAffineTransform(rotationAngle: store.heading)
                if store.follow || store.cameraRequest != lastCameraRequest {
                    var zoom = map.zoomLevel
                    if store.cameraRequest != lastCameraRequest {
                        zoom = max(15.5, zoom)
                    }
                    map.setCenter(marker.coordinate, zoomLevel: zoom, animated: false)
                    lastCameraRequest = store.cameraRequest
                }
            }
            if store.routeOverviewRequest != lastOverviewRequest {
                lastOverviewRequest = store.routeOverviewRequest
                if let route = store.selectedRoute, let graph = store.graph {
                    frame(route.coordinates(in: graph).map { coordinate in
                        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }, on: map, animated: true)
                }
            }
            if store.mapFocusRequest != lastFocusRequest {
                lastFocusRequest = store.mapFocusRequest
                if let focus = store.mapFocus {
                    map.setCenter(CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude),
                                  zoomLevel: max(15, map.zoomLevel), animated: true)
                }
            }
            if store.trail.count != lastTrailCount || store.trail.last != lastTrailEnd {
                lastTrailCount = store.trail.count
                lastTrailEnd = store.trail.last
                var coordinates = store.trail.map { point in
                    return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                }
                if coordinates.count >= 2 {
                    trailSource?.shape = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                } else {
                    trailSource?.shape = nil
                }
            }
            if let estimate = store.estimate, store.phase != .selecting {
                var ring: [CLLocationCoordinate2D] = []
                let radius = min(350, estimate.typicalError)
                for index in 0...48 {
                    let angle = Double(index) / 48 * 2 * .pi
                    let point = Coordinate(metres: estimate.coordinate.metres + Vector2(sin(angle), cos(angle)) * radius)
                    ring.append(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                }
                uncertaintySource?.shape = MLNPolygon(coordinates: &ring, count: UInt(ring.count))
            } else {
                uncertaintySource?.shape = nil
            }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let map, store.phase == .selecting else {
                return
            }
            let point = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            store.select(Coordinate(latitude: point.latitude, longitude: point.longitude))
        }

        @objc func dragMarker(_ gesture: UIPanGestureRecognizer) {
            guard let map, store.phase == .selecting else {
                return
            }
            let location = gesture.location(in: map)
            if gesture.state == .began {
                map.isScrollEnabled = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if gesture.state == .changed || gesture.state == .began {
                let point = map.convert(location, toCoordinateFrom: map)
                store.drag(to: Coordinate(latitude: point.latitude, longitude: point.longitude))
            }
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                map.isScrollEnabled = true
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return false
        }
    }
}

/// Destination B: a flag in the route colour.
final class DestinationAnnotationView: MLNAnnotationView {
    override init(annotation: MLNAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        backgroundColor = OfflineMapView.routeColor
        layer.cornerRadius = 17
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 6
        let flag = UIImageView(image: UIImage(systemName: "flag.checkered",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
        flag.tintColor = UIColor(red: 0.02, green: 0.12, blue: 0.18, alpha: 1)
        flag.contentMode = .center
        flag.frame = bounds
        addSubview(flag)
        isAccessibilityElement = true
        accessibilityLabel = "Destination"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PositionAnnotationView: MLNAnnotationView {
    let arrow = UIImageView(image: UIImage(systemName: "location.north.fill"))

    override init(annotation: MLNAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        backgroundColor = UIColor(red: 0.69, green: 0.96, blue: 0.39, alpha: 1)
        layer.cornerRadius = 22
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 8
        arrow.tintColor = UIColor(red: 0.07, green: 0.12, blue: 0.10, alpha: 1)
        arrow.contentMode = .scaleAspectFit
        arrow.frame = bounds.insetBy(dx: 12, dy: 10)
        addSubview(arrow)
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Selected road position and facing direction"
        accessibilityIdentifier = "roadPosition"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
