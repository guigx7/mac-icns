import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MappingListPresentation {
    static let refreshIconsLabel = "Refresh Icons"
}

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
                Button(MappingListPresentation.refreshIconsLabel, systemImage: "arrow.clockwise") {
                    Task { await appState.refreshAll() }
                }
                .disabled(appState.isRefreshingAll)

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
                Text(MappingRowPresentation.statusName(for: mapping))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        MappingRowPresentation.isAttentionStatus(mapping) ? .orange : .secondary
                    )
                if let statusMessage = MappingRowPresentation.statusMessage(
                    for: mapping,
                    failureMessage: failureMessage
                ) {
                    Text(statusMessage)
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
                if mapping.isEnabled {
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
    static let restartRequiredMessage = "Quit and reopen this app to refresh its Dock icon."

    static func toggleLabel(isEnabled: Bool) -> String {
        isEnabled ? "Enabled" : "Disabled"
    }

    static func statusName(for mapping: IconMapping) -> String {
        mapping.isEnabled ? mapping.status.displayName : "Disabled"
    }

    static func statusMessage(
        for mapping: IconMapping,
        failureMessage: String?
    ) -> String? {
        guard mapping.isEnabled else { return nil }
        return mapping.status == .restartRequired ? restartRequiredMessage : failureMessage
    }

    static func isAttentionStatus(_ mapping: IconMapping) -> Bool {
        mapping.isEnabled
            && (mapping.status == .needsPermission || mapping.status == .restartRequired)
    }
}

private struct MappingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = ApplicationCatalog(entries: [])
    @State private var searchText = ""
    @State private var applicationURL: URL?
    @State private var iconURL: URL?
    @State private var validationMessage: String?
    @State private var isLoading = true

    private let catalogLoader: ApplicationCatalogLoader
    private let iconProvider = ApplicationIconProvider()
    let save: (URL, URL) -> Void

    init(
        catalogLoader: ApplicationCatalogLoader = ApplicationCatalogLoader(),
        save: @escaping (URL, URL) -> Void
    ) {
        self.catalogLoader = catalogLoader
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Icon Mapping")
                .font(.title2.weight(.semibold))

            Text("MacICNS supports applications that your user account can modify safely.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Search Applications", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))

            Group {
                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading applications…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleEntries) { entry in
                                catalogRow(entry)
                                if entry.id != visibleEntries.last?.id {
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 280)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 1)
            }

            HStack {
                Button("Browse…") { chooseApplication() }
                Spacer()
                if let applicationURL {
                    Label(
                        applicationURL.deletingPathExtension().lastPathComponent,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if applicationURL != nil {
                selectionRow(
                    title: "ICNS File",
                    selection: iconURL?.lastPathComponent,
                    actionTitle: "Choose ICNS File"
                ) {
                    chooseIcon()
                }
            }

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
        .frame(width: 620)
        .task {
            let loader = catalogLoader
            catalog = await Task.detached(priority: .userInitiated) {
                loader.load()
            }.value
            isLoading = false
        }
    }

    private var visibleEntries: [ApplicationCatalogEntry] {
        catalog.entries(searchText: searchText)
    }

    @ViewBuilder
    private func catalogRow(_ entry: ApplicationCatalogEntry) -> some View {
        let row = HStack(spacing: 12) {
            Image(nsImage: iconProvider.originalIcon(for: entry.url))
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if entry.eligibility != .compatible {
                    Text("macOS does not allow this app's icon to be changed safely.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(entry.eligibility.catalogLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.eligibility == .compatible ? .secondary : .tertiary)

            if applicationURL == entry.url {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .background(
            applicationURL == entry.url ? Color.accentColor.opacity(0.12) : Color.clear
        )

        if entry.eligibility == .compatible {
            Button {
                applicationURL = entry.url
                validationMessage = nil
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.displayName), Compatible")
        } else {
            row
                .opacity(0.72)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.displayName), \(entry.eligibility.catalogLabel)")
        }
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
            guard let entry = catalogLoader.entry(for: url) else {
                applicationURL = nil
                validationMessage = "The selected item is not a valid application."
                return
            }
            guard entry.eligibility == .compatible else {
                applicationURL = nil
                validationMessage = "\(entry.displayName) is \(entry.eligibility.catalogLabel.lowercased()). macOS does not allow this app's icon to be changed safely."
                return
            }
            applicationURL = entry.url
            validationMessage = nil
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

private extension ApplicationEligibility {
    var catalogLabel: String {
        switch self {
        case .compatible: "Compatible"
        case .protected: "Protected"
        case .systemApplication: "System App"
        case .missing, .invalid: "Unavailable"
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
        case .restartRequired: "Restart required"
        case .needsPermission: "Needs permission"
        case .missingApp: "Application missing"
        case .failed: "Could not apply"
        }
    }
}
