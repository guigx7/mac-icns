import AppKit
import SwiftUI

@main
struct MacICNSApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var loginItemService = LoginItemService()

    var body: some Scene {
        WindowGroup {
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
            SettingsView(appState: appState, loginItemService: loginItemService)
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
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var appState: AppState
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

            Section("Privileged Helper") {
                Text(helperStatusMessage)
                if appState.helperStatus == .requiresApproval {
                    Button("Open Login Items Settings") {
                        appState.openHelperApprovalSettings()
                    }
                }
                Button("Refresh Helper Status") {
                    appState.refreshHelperStatus()
                }
            }
        }
        .padding()
        .frame(width: 380)
    }

    private var helperStatusMessage: String {
        switch appState.helperStatus {
        case .installed:
            "Helper is installed."
        case .requiresApproval:
            "Helper needs approval in Login Items & Extensions."
        case .notInstalled:
            "Helper is not installed."
        }
    }
}
