import SwiftUI

struct ContentView: View {
    @StateObject private var store = NavigationStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DrivingScreen(store: store)
            .onChange(of: scenePhase) { _, phase in
                store.sceneChanged(phase)
            }
            .onOpenURL { url in
                store.open(url)
            }
    }
}
