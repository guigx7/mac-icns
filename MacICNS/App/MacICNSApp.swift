import SwiftUI

@main
struct MacICNSApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MappingListView(appState: appState)
                .task {
                    guard NSClassFromString("XCTestCase") == nil else {
                        return
                    }
                    appState.loadMappings()
                }
        }
    }
}
