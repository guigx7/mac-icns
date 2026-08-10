import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MappingListView: View {
    @ObservedObject var appState: AppState
    @State private var isPresentingEditor = false
    @State private var mappingPendingDeletion: IconMapping?
    private let iconProvider = ApplicationIconProvider()

    var body: some View {
        NavigationStack {
            Group {
                if appState.mappings.isEmpty {
                    ContentUnavailableView(
                        "No Icon Mappings",
                        systemImage: "app.dashed",
                        description: Text("Choose an application and an ICNS file to create a local mapping.")
                    )
                } else {
                    List {
                        ForEach(appState.mappings) { mapping in
                            MappingRowView(
                                mapping: mapping,
                                originalIcon: iconProvider.originalIcon(for: mapping.applicationURL),
                                customIcon: iconProvider.customIcon(at: mapping.iconURL),
                                isBusy: appState.isBusy(mapping),
                                failureMessage: appState.failureMessage(for: mapping),
                                apply: { Task { await appState.apply(mapping) } },
                                changeIcon: { chooseReplacementIcon(for: mapping) },
                                setEnabled: { isEnabled in
                                    Task { await appState.setEnabled(isEnabled, for: mapping) }
                                },
                                delete: { mappingPendingDeletion = mapping }
                            )
                        }
                    }
                }
            }
            .navigationTitle("MacICNS")
            .toolbar {
                Button("Add Mapping", systemImage: "plus") {
                    isPresentingEditor = true
                }
            }
            .sheet(isPresented: $isPresentingEditor) {
                MappingEditorView { applicationURL, iconURL in
                    Task { await appState.addMapping(applicationURL: applicationURL, iconURL: iconURL) }
                    isPresentingEditor = false
                }
            }
            .alert("Local Mappings", isPresented: Binding(
                get: { appState.persistenceError != nil },
                set: { if !$0 { appState.dismissPersistenceError() } }
            )) {
                Button("OK") { appState.dismissPersistenceError() }
            } message: {
                Text(appState.persistenceError ?? "")
            }
            .alert("Could Not Complete Action", isPresented: Binding(
                get: { appState.operationError != nil },
                set: { if !$0 { appState.dismissOperationError() } }
            )) {
                Button("OK") { appState.dismissOperationError() }
            } message: {
                Text(appState.operationError ?? "")
            }
            .alert(
                "Delete Icon Mapping?",
                isPresented: Binding(
                    get: { mappingPendingDeletion != nil },
                    set: { if !$0 { mappingPendingDeletion = nil } }
                ),
                presenting: mappingPendingDeletion
            ) { mapping in
                Button("Delete", role: .destructive) {
                    mappingPendingDeletion = nil
                    Task { await appState.delete(mapping) }
                }
                Button("Cancel", role: .cancel) {
                    mappingPendingDeletion = nil
                }
            } message: { mapping in
                Text("MacICNS will restore the original icon for \(mapping.applicationURL.deletingPathExtension().lastPathComponent) before deleting this mapping.")
            }
        }
    }

    private func chooseReplacementIcon(for mapping: IconMapping) {
        let panel = NSOpenPanel()
        panel.title = "Choose Replacement ICNS File"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [FileSelectionValidator.icnsType]
        panel.directoryURL = FileSelectionValidator.lastIconDirectory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  FileSelectionValidator.isIcon(url) else { return }

            FileSelectionValidator.lastIconDirectory = url.deletingLastPathComponent()
            Task { await appState.replaceIcon(for: mapping, with: url) }
        }
    }
}

private struct MappingRowView: View {
    let mapping: IconMapping
    let originalIcon: NSImage
    let customIcon: NSImage
    let isBusy: Bool
    let failureMessage: String?
    let apply: () -> Void
    let changeIcon: () -> Void
    let setEnabled: (Bool) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                iconPreview(originalIcon, accessibilityLabel: "Original icon")

                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                iconPreview(customIcon, accessibilityLabel: "Custom icon")
                    .opacity(mapping.isEnabled ? 1 : 0.45)
            }
            .frame(width: 116, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(mapping.applicationURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                Text(mapping.iconURL.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                if let failureMessage, mapping.isEnabled {
                    Text(failureMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating icon")
            }

            HStack(spacing: 10) {
                if mapping.status == .needsPermission, mapping.isEnabled {
                    SettingsLink {
                        Text("Set Up Helper")
                    }
                    .controlSize(.small)
                } else if mapping.isEnabled {
                    Button(action: apply) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Apply Custom Icon Again")
                    .accessibilityLabel("Apply custom icon again")
                }

                Button(action: changeIcon) {
                    Image(systemName: "photo.badge.arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Change Icon")
                .accessibilityLabel(MappingRowPresentation.changeIconLabel)

                Toggle("Enabled", isOn: Binding(
                    get: { mapping.isEnabled },
                    set: { newValue in setEnabled(newValue) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(mapping.isEnabled ? "Restore Original Icon" : "Apply Custom Icon")
                .accessibilityLabel(MappingRowPresentation.toggleLabel(isEnabled: mapping.isEnabled))

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete Mapping")
                .accessibilityLabel("Delete mapping")
            }
            .disabled(isBusy)
        }
        .padding(.vertical, 8)
    }

    private var statusName: String {
        mapping.isEnabled ? mapping.status.displayName : "Disabled"
    }

    private var statusColor: Color {
        mapping.isEnabled && mapping.status == .needsPermission ? .orange : .secondary
    }

    private func iconPreview(_ image: NSImage, accessibilityLabel: String) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 40, height: 40)
            .accessibilityLabel(accessibilityLabel)
    }
}

enum MappingRowPresentation {
    static let changeIconLabel = "Change icon"

    static func toggleLabel(isEnabled: Bool) -> String {
        isEnabled ? "Enabled" : "Disabled"
    }
}

private struct MappingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var applicationURL: URL?
    @State private var iconURL: URL?

    let save: (URL, URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Icon Mapping")
                .font(.title2.weight(.semibold))

            selectionRow(
                title: "Application",
                selection: applicationURL?.lastPathComponent,
                actionTitle: "Choose Application"
            ) {
                chooseApplication()
            }

            selectionRow(
                title: "ICNS File",
                selection: iconURL?.lastPathComponent,
                actionTitle: "Choose ICNS File"
            ) {
                chooseIcon()
            }

            Text("Mappings are saved locally. Protected applications use the privileged helper configured in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Mapping") {
                    if let applicationURL, let iconURL {
                        save(applicationURL, iconURL)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applicationURL == nil || iconURL == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  FileSelectionValidator.isApplication(url) else { return }
            applicationURL = url
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose ICNS File"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [FileSelectionValidator.icnsType]
        panel.directoryURL = FileSelectionValidator.lastIconDirectory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  FileSelectionValidator.isIcon(url) else { return }
            FileSelectionValidator.lastIconDirectory = url.deletingLastPathComponent()
            iconURL = url
        }
    }

    @ViewBuilder
    private func selectionRow(
        title: String,
        selection: String?,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(selection ?? "No file selected")
                    .foregroundStyle(selection == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer()
            Button(actionTitle, action: action)
        }
    }
}

enum FileSelectionValidator {
    private static let lastIconDirectoryKey = "lastIconDirectory"
    static let icnsType = UTType(filenameExtension: "icns") ?? .data

    static var lastIconDirectory: URL? {
        get { UserDefaults.standard.url(forKey: lastIconDirectoryKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastIconDirectoryKey) }
    }

    static func isApplication(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    static func isIcon(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("icns") == .orderedSame
    }
}

private extension MappingStatus {
    var displayName: String {
        switch self {
        case .upToDate: "Applied"
        case .needsPermission: "Needs permission"
        case .missingApp: "Application missing"
        case .failed: "Could not apply"
        }
    }
}
