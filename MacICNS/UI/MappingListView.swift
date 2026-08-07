import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MappingListView: View {
    @ObservedObject var appState: AppState
    @State private var isPresentingEditor = false

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
                            MappingRowView(mapping: mapping) {
                                Task { await appState.apply(mapping) }
                            }
                        }
                        .onDelete(perform: appState.removeMappings)
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
        }
    }
}

private struct MappingRowView: View {
    let mapping: IconMapping
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: mapping.applicationURL.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(mapping.applicationURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                Text(mapping.iconURL.lastPathComponent)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(mapping.status.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mapping.status == .needsPermission ? .orange : .secondary)
                Button("Apply", action: apply)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MappingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var applicationURL: URL?
    @State private var iconURL: URL?
    @State private var isChoosingApplication = false
    @State private var isChoosingIcon = false

    let save: (URL, URL) -> Void

    private var iconType: UTType {
        UTType(filenameExtension: "icns") ?? .data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Icon Mapping")
                .font(.title2.weight(.semibold))

            selectionRow(
                title: "Application",
                selection: applicationURL?.lastPathComponent,
                actionTitle: "Choose Application"
            ) {
                isChoosingApplication = true
            }

            selectionRow(
                title: "ICNS File",
                selection: iconURL?.lastPathComponent,
                actionTitle: "Choose ICNS File"
            ) {
                isChoosingIcon = true
            }

            Text("Mappings are saved locally. Protected applications report “Needs permission”; this version does not request elevation.")
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
        .fileImporter(
            isPresented: $isChoosingApplication,
            allowedContentTypes: [.applicationBundle]
        ) { result in
            if case let .success(url) = result {
                applicationURL = url
            }
        }
        .fileImporter(
            isPresented: $isChoosingIcon,
            allowedContentTypes: [iconType]
        ) { result in
            if case let .success(url) = result {
                iconURL = url
            }
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
