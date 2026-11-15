import SwiftUI
import MapKit

enum SheetDetent {
    static let collapsed = PresentationDetent.height(270)
}

/// The map of one trip with its persistent bottom sheet.
struct ContentView: View {
    let store: TripStore
    /// Called after the sheet has gone away, to go back to the trip list.
    let onClose: () -> Void

    @State private var sheetShown = false
    @State private var leaving = false
    private var settings = AppSettings.shared
    @State private var position: MapCameraPosition = .automatic
    @State private var path: [UUID] = []
    @State private var detent: PresentationDetent = SheetDetent.collapsed
    @State private var location = LocationPermission()
    @Environment(\.scenePhase) private var scenePhase

    init(store: TripStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    private var selectedID: UUID? { path.last }

    var body: some View {
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()

                    ForEach(store.legs) { leg in
                        if let g = store.geometry[leg.id] {
                            let isSelected = leg.id == selectedID
                            let faded = selectedID != nil && !isSelected
                            MapPolyline(coordinates: g.coords, contourStyle: leg.mode == .plane ? .geodesic : .straight)
                                .stroke(
                                    leg.mode.color.opacity(faded ? 0.35 : 1),
                                    style: StrokeStyle(
                                        lineWidth: isSelected ? 6 : 4,
                                        lineCap: .round,
                                        dash: leg.mode == .plane && settings.dashedFlights ? [2, 9] : []
                                    )
                                )
                        }
                    }

                    ForEach(store.stops) { stop in
                        Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                            Circle()
                                .fill(.white)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(.black, lineWidth: 2))
                        }
                    }

                    ForEach(store.legs) { leg in
                        if let g = store.geometry[leg.id] {
                            Annotation("", coordinate: g.mid, anchor: .center) {
                                ModeBadge(
                                    mode: leg.mode,
                                    size: leg.id == selectedID ? 38 : 30,
                                    dimmed: selectedID != nil && leg.id != selectedID
                                )
                                .contentShape(Circle().inset(by: -8))
                                .onTapGesture { select(leg.id) }
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
                .mapStyle(settings.mapLook.style)
                .mapControls { MapCompass() }
                .onTapGesture { point in
                    if let id = hitTest(point, proxy: proxy) { select(id) }
                }
            }
            .safeAreaPadding(.bottom, bottomInset(height: geo.size.height))
            .overlay(alignment: .topTrailing) { mapButtons }
            .overlay(alignment: .topLeading) {
                MapRoundButton(symbol: "chevron.left", action: close)
                    .padding(.leading, 14)
                    .padding(.top, 8)
            }
            .onChange(of: path) { _, newPath in
                if let id = newPath.last { focus(on: id) }
            }
            .onAppear {
                if let r = store.allRect { position = .rect(padded(r)) }
            }
            .task {
                // Wait for any alert or picker on the home screen to finish dismissing.
                try? await Task.sleep(for: .milliseconds(350))
                sheetShown = true
            }
            .task {
                // Friends' edits show up while the trip is open.
                while !Task.isCancelled {
                    await store.sync()
                    try? await Task.sleep(for: SyncConfig.pollInterval)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.sync() } }
            }
            .onChange(of: store.geometry.count) { old, new in
                // First legs arriving from a friend: frame them.
                if old == 0, new > 0, path.isEmpty, let r = store.allRect {
                    withAnimation(.snappy) { position = .rect(padded(r)) }
                }
            }
            .sheet(isPresented: $sheetShown, onDismiss: { if leaving { onClose() } }) {
                TripSheet(store: store, path: $path, detent: $detent, onShowAll: showAll, onClose: close)
                    .presentationDetents([SheetDetent.collapsed, .medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationBackground(Theme.canvas)
                    .presentationCornerRadius(Theme.Radius.xl)
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .background(Theme.canvas)
    }

    private func close() {
        leaving = true
        sheetShown = false
    }

    // MARK: Map controls

    private var mapButtons: some View {
        VStack(spacing: 10) {
            MapRoundButton(symbol: "point.topleft.down.to.point.bottomright.curvepath") { showAll() }
            MapRoundButton(symbol: "location.fill") {
                location.request()
                withAnimation(.snappy) { position = .userLocation(fallback: position) }
            }
        }
        .padding(.trailing, 14)
        .padding(.top, 8)
    }

    private func bottomInset(height: CGFloat) -> CGFloat {
        detent == SheetDetent.collapsed ? 270 : (detent == .medium ? height * 0.5 : height * 0.5)
    }

    // MARK: Selection

    private func select(_ id: UUID) {
        if path.last != id { path = [id] }
        if detent == SheetDetent.collapsed { detent = .medium }
    }

    private func focus(on id: UUID) {
        guard let g = store.geometry[id] else { return }
        withAnimation(.snappy(duration: 0.45)) { position = .rect(padded(g.rect)) }
    }

    private func showAll() {
        path = []
        withAnimation(.snappy(duration: 0.45)) {
            if let r = store.allRect { position = .rect(padded(r)) } else { position = .automatic }
        }
    }

    private func padded(_ r: MKMapRect) -> MKMapRect {
        let minSide = 6000.0 // map points, keeps very short legs from zooming in too far
        let w = max(r.width, minSide), h = max(r.height, minSide)
        let base = MKMapRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        return base.insetBy(dx: -w * 0.25, dy: -h * 0.25)
    }

    /// Finds the leg line closest to a tap, in screen points.
    private func hitTest(_ point: CGPoint, proxy: MapProxy) -> UUID? {
        var best: (UUID, CGFloat)?
        for leg in store.legs {
            guard let g = store.geometry[leg.id] else { continue }
            let pts = g.coords.compactMap { proxy.convert($0, to: .local) }
            guard pts.count > 1 else { continue }
            for i in 0..<(pts.count - 1) {
                let d = distance(point, pts[i], pts[i + 1])
                if d < (best?.1 ?? .infinity) { best = (leg.id, d) }
            }
        }
        guard let best, best.1 < 26 else { return nil }
        return best.0
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

struct MapRoundButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.canvas.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RootView()
}
