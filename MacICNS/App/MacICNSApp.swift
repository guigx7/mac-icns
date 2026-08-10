import AppKit
import SwiftUI

@main
struct MacICNSApp: App {
    private static let managementWindowID = "management"

    @StateObject private var appState = AppState()
    @StateObject private var loginItemService = LoginItemService()
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
        openWindow(id: Self.managementWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
                if let actionTitle = HelperSettingsPresentation.primaryActionTitle(
                    for: appState.helperStatus
                ) {
                    Button(actionTitle) {
                        if appState.helperStatus == .notInstalled {
                            Task { await appState.installHelper() }
                        } else {
                            Task { await appState.updateHelper() }
                        }
                    }
                    .disabled(appState.helperIsUpdating)
                }
                if appState.helperIsUpdating {
                    ProgressView("Updating helper…")
                        .controlSize(.small)
                }
                if appState.helperStatus == .requiresApproval {
                    Button("Open Login Items Settings") {
                        appState.openHelperApprovalSettings()
                    }
                }
                if let helperError = appState.helperError {
                    Text(helperError)
                        .foregroundStyle(.red)
                }
                Button("Refresh Helper Status") {
                    Task { await appState.refreshHelperStatus() }
                }
                .disabled(appState.helperIsUpdating)
            }
        }
        .padding()
        .frame(width: 380)
        .onAppear {
            Task { await appState.refreshHelperStatus() }
        }
    }

    private var helperStatusMessage: String {
        switch appState.helperStatus {
        case .installed:
            "Helper is installed."
        case .requiresApproval:
            "Helper needs approval in Login Items & Extensions."
        case .notInstalled:
            "Helper is not installed."
        case .updateRequired:
            "Helper update required."
        case .unavailable:
            "Helper is registered but unavailable."
        }
    }
}

enum HelperSettingsPresentation {
    static func primaryActionTitle(
        for status: HelperInstallationService.OperationalStatus
    ) -> String? {
        switch status {
        case .installed, .updateRequired, .unavailable:
            "Update Helper"
        case .notInstalled:
            "Install Helper"
        case .requiresApproval:
            nil
        }
    }
}
