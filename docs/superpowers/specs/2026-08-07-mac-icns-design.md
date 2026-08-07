# MacICNS — Product Design

## Purpose

MacICNS is a native macOS app for assigning a chosen `.icns` file to an installed application and keeping that custom icon in place after the application updates.

## Scope

- Native SwiftUI application for macOS 14 Sonoma and later.
- English-only interface.
- Monochrome, minimal visual system that follows the system light and dark appearance.
- Users can select any local `.app` bundle and any local `.icns` file.
- Mappings persist across app relaunches.
- The app can start at login, controlled by a user setting.
- A menu-bar control exposes `Refresh Icons` and `Quit`, and opens the main window on click.

## Mapping Model

Each mapping stores:

- Stable mapping identifier.
- Application display name, selected URL, and bundle identifier.
- Selected `.icns` URL and an icon-content fingerprint.
- Latest known application bundle fingerprint.
- Last attempted and successful repair dates.
- Current status: `Up to date`, `Needs permission`, `Missing app`, or `Failed`.

The app identifies a moved application by its bundle identifier when possible. If no matching bundle can be found, the mapping remains visible as `Missing app` rather than being deleted.

## Components

### MacICNSApp

Owns the SwiftUI lifecycle, main window, menu-bar integration, and launch-at-login setting.

### IconMappingStore

Persists mappings locally and publishes mapping changes to the UI and repair pipeline.

### IconApplier

Loads an `.icns` file, applies it as a Finder custom icon to a target application bundle, and returns explicit permission or filesystem failures.

### UpdateMonitor

Observes each mapped application and its parent folder for filesystem changes. It debounces rapid events, allowing application updaters to finish replacing a bundle before repair is considered.

### RepairCoordinator

Runs a single deduplicated repair pipeline for mapping creation, filesystem events, app launch, login, and manual refresh. It verifies the app fingerprint and selected icon fingerprint before applying an icon, preventing redundant writes and self-triggered monitoring loops.

## Repair Strategy

The first release uses layered repair through the signed main app and its minimally privileged helper:

1. Apply an icon immediately when the user creates or edits a mapping.
2. Observe filesystem changes for mapped applications and their parent folders.
3. Debounce update activity and inspect the completed bundle.
4. Reapply an icon only when the bundle changed or the Finder custom icon is absent.
5. Run a full repair check when the app opens, when the user logs in, and when they choose `Refresh Icons`.

This combination covers normal update replacements while ensuring a later repair opportunity if a specific installer emits incomplete filesystem events.

## Privileged Helper and Permissions

The first release includes a minimal privileged helper installed once with administrator approval through macOS Service Management. It runs only the narrowly defined icon-application operation requested by the signed main app through a validated IPC interface; it does not accept arbitrary shell commands, paths, or executable arguments.

The helper makes automatic repair possible for protected locations such as `/Applications` without repeatedly requesting a password. The main app never stores passwords or elevated credentials. Settings shows the installation status and provides an explicit action to remove the helper.

## User Interface

The main window contains:

- A concise header with `Add Mapping` and `Refresh Icons` actions.
- A clean mapping list showing the application icon/name, selected icon name, status, last repair time, and item actions.
- Per-item actions to retry, edit, reveal the app/icon in Finder, or remove the mapping.
- A compact Settings area containing `Launch at Login` and local diagnostic-log controls.

The menu bar contains `Refresh Icons` and `Quit`. Selecting the app's status item opens or focuses the main window.

## Error Handling and Diagnostics

Failures are isolated to the affected mapping. The UI displays actionable statuses without blocking repairs for other mappings. A local diagnostic log records technical details and offers a copy action; no data is transmitted externally.

## Testing and Verification

- Unit tests cover mapping persistence, fingerprint comparison, move resolution, and repair scheduling/debounce.
- Integration tests exercise apply and reapply behavior using a disposable test application bundle.
- `xcodebuild` verifies the project builds and tests successfully.

## Distribution Direction

The project will be organized as a standard signed and notarizable macOS application, including the helper's client-validation requirements. Future Homebrew Cask distribution will package the built `.app`; code signing and notarization configuration will be added before public release.
