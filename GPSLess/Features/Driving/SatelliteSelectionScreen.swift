import MapKit
import SwiftUI

/// Apple satellite imagery with Apple's labels and points of interest. It
/// stays mounted after first use and is aligned to the offline map before each
/// reveal, so switching maps is a crossfade between identical views.
struct SatelliteSelectionMap: UIViewRepresentable {
    @ObservedObject var store: NavigationStore
    @Binding var imageryStatus: String
    var isVisible: Bool
    /// Incremented to align with the offline map's viewport and reveal.
    var revealRequest: Int
    var onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        return Coordinator(store: store, status: $imageryStatus)
    }

    func makeUIView(context: Context) -> SatelliteMapContainer {
        let container = SatelliteMapContainer()
        let map = container.map
        context.coordinator.container = container
        let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .includingAll
        map.preferredConfiguration = configuration
        map.showsUserLocation = false
        map.userTrackingMode = .none
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.delegate = context.coordinator
        map.accessibilityIdentifier = "satelliteMap"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        map.addGestureRecognizer(tap)
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        container.marker.addGestureRecognizer(drag)
        context.coordinator.update(map)
        return container
    }

    func updateUIView(_ container: SatelliteMapContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.isVisible = isVisible
        coordinator.onReady = onReady
        if revealRequest != coordinator.lastRevealRequest {
            coordinator.lastRevealRequest = revealRequest
            coordinator.alignForReveal()
        }
        coordinator.update(container.map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let store: NavigationStore
        let status: Binding<String>
        weak var container: SatelliteMapContainer?
        var displayedEdge: Int?
        private var lastFocusRequest: Int
        var isVisible = false
        var lastRevealRequest = 0
        var onReady: (() -> Void)?
        private var awaitingReveal = false
        private var hasRendered = false

        init(store: NavigationStore, status: Binding<String>) {
            self.store = store
            self.status = status
            lastFocusRequest = store.mapFocusRequest
        }

        /// Shows exactly what the offline map shows; the reveal waits for the
        /// imagery to render, briefly, so the crossfade never shows blank tiles.
        func alignForReveal() {
            guard let container else {
                return
            }
            let region: MKCoordinateRegion
            if let viewport = store.mapViewport {
                region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: viewport.center.latitude, longitude: viewport.center.longitude),
                    span: MKCoordinateSpan(latitudeDelta: viewport.latitudeDelta, longitudeDelta: viewport.longitudeDelta))
            } else {
                let coordinate = store.coordinate ?? store.region.center
                region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                            latitudinalMeters: 500, longitudinalMeters: 500)
            }
            let current = container.map.region
            let unchanged = hasRendered && container.bounds.width > 0
                && abs(current.center.latitude - region.center.latitude) < region.span.latitudeDelta * 0.01
                && abs(current.center.longitude - region.center.longitude) < region.span.longitudeDelta * 0.01
                && abs(current.span.longitudeDelta / region.span.longitudeDelta - 1) < 0.02
            container.show(region)
            awaitingReveal = true
            guard !unchanged else {
                reveal()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (hasRendered ? 0.45 : 1.5)) { [weak self] in
                self?.reveal()
            }
        }

        private func reveal() {
            guard awaitingReveal else {
                return
            }
            awaitingReveal = false
            DispatchQueue.main.async {
                self.onReady?()
            }
        }

        func update(_ map: MKMapView) {
            if store.mapFocusRequest != lastFocusRequest {
                lastFocusRequest = store.mapFocusRequest
                if let focus = store.mapFocus {
                    map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude),
                                                     latitudinalMeters: 600, longitudinalMeters: 600), animated: true)
                }
            }
            guard let coordinate = store.coordinate, let selection = store.selection, let graph = store.graph else {
                return
            }
            container?.coordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            container?.positionMarker()
            container?.marker.transform = CGAffineTransform(rotationAngle: store.heading)
            let degrees = Int((store.heading * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
            container?.marker.accessibilityValue = "Facing \(degrees) degrees"
            if displayedEdge != selection.edge {
                displayedEdge = selection.edge
                map.removeOverlays(map.overlays)
                let path = graph.paths[graph.pathIndex[selection.edge]]
                for index in path.edges {
                    let coordinates = graph.edges[index].record.points.map { point in
                        return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                    }
                    map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
                }
            }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else {
                return
            }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            store.select(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        @objc func drag(_ gesture: UIPanGestureRecognizer) {
            guard let map = container?.map else {
                return
            }
            switch gesture.state {
            case .began, .changed:
                let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
                store.drag(to: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
                update(map)
            default:
                break
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            container?.positionMarker()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // While hidden the offline map leads; only the visible map reports.
            guard isVisible else {
                return
            }
            let region = mapView.region
            guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else {
                return
            }
            store.mapViewport = NavigationMapViewport(
                center: Coordinate(
                    latitude: region.center.latitude,
                    longitude: region.center.longitude
                ),
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = .systemGreen
            renderer.lineWidth = 3
            return renderer
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            hasRendered = true
            if awaitingReveal {
                reveal()
            }
            if fullyRendered {
                DispatchQueue.main.async {
                    self.status.wrappedValue = "Online imagery · GPS off"
                }
            }
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            hasRendered = true
            if awaitingReveal {
                reveal()
            }
            DispatchQueue.main.async {
                self.status.wrappedValue = "Imagery unavailable. Check your internet connection or return to the offline map."
            }
        }
    }
}

final class SatelliteMapContainer: UIView {
    let map = MKMapView()
    let marker = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    var coordinate: CLLocationCoordinate2D?
    /// A region requested before the view had a size; MapKit fits a region
    /// to the current bounds, so it is applied at the first layout.
    private var pendingRegion: MKCoordinateRegion?

    func show(_ region: MKCoordinateRegion) {
        guard bounds.width > 0, bounds.height > 0 else {
            pendingRegion = region
            return
        }
        map.frame = bounds
        map.setRegion(region, animated: false)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(map)
        marker.backgroundColor = .systemGreen
        marker.layer.cornerRadius = 24
        marker.layer.borderColor = UIColor.white.cgColor
        marker.layer.borderWidth = 3
        let arrow = UIImageView(image: UIImage(systemName: "location.north.fill"))
        arrow.tintColor = .white
        arrow.frame = marker.bounds.insetBy(dx: 13, dy: 11)
        marker.addSubview(arrow)
        marker.isAccessibilityElement = true
        marker.accessibilityLabel = "Selected road position and facing direction"
        marker.accessibilityIdentifier = "satellitePosition"
        addSubview(marker)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        if let region = pendingRegion, bounds.width > 0, bounds.height > 0 {
            pendingRegion = nil
            map.setRegion(region, animated: false)
        }
        positionMarker()
    }

    func positionMarker() {
        guard let coordinate else {
            marker.isHidden = true
            return
        }
        marker.isHidden = false
        marker.center = map.convert(coordinate, toPointTo: self)
    }
}
