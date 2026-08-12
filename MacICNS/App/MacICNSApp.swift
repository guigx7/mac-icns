import AppKit
import SwiftUI

@main
struct MacICNSApp: App {
    private static let managementWindowID = "management"

    @StateObject private var appState = AppState()
    @StateObject private var loginItemService = LoginItemService()
    @NSApplicationDelegateAdaptor(MacICNSApplicationDelegate.self)
    private var applicationDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: Self.managementWindowID) {
            MappingListView(appState: appState)
                .task {
                    guard NSClassFromString("XCTestCase") == nil else {
                        return
                    }
                    appState.launch()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show MacICNS") {
                    focusMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(loginItemService: loginItemService)
        }

        MenuBarExtra("MacICNS", systemImage: "square.grid.2x2") {
            Button("Show MacICNS") {
                focusMainWindow()
            }
            Button("Refresh Icons") {
                Task { await appState.refreshAll() }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func focusMainWindow() {
        applicationDelegate.lifecycleController.showApplication()
        openWindow(id: Self.managementWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var loginItemService: LoginItemService

    var body: some View {
        Form {
            Section("Launch") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                ))
                if let errorMessage = loginItemService.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

        }
        .padding()
        .frame(width: 380)
    }
}
