# Dock Lifecycle and Restart Status Design

## Goal

MacICNS must leave the Dock when its last user-facing window closes while remaining available from the menu bar. It must also describe accurately when a custom icon has been written to an application bundle but a currently running target application is still showing its previously loaded icon in the Dock.

## Confirmed Platform Behavior

`NSWorkspace.setIcon(_:forFile:options:)` can update the icon metadata of a writable application bundle while that application is running. macOS does not expose a public API that lets MacICNS replace the Dock image owned by another running process. The target application must quit and launch again before its Dock icon reliably reflects the updated bundle icon.

MacICNS will not terminate or relaunch target applications. This avoids interrupting work or causing unsaved data loss.

## User Experience

### MacICNS window lifecycle

- Launching or showing MacICNS opens the management window and displays MacICNS in the Dock.
- Clicking the red close button closes the user-facing window without terminating MacICNS.
- When no user-facing MacICNS window remains visible, MacICNS switches to accessory activation policy and leaves the Dock.
- The menu bar item remains available with `Show MacICNS`, `Refresh Icons`, and `Quit`.
- Selecting `Show MacICNS` switches back to regular activation policy before opening and activating the management window.
- Settings counts as a user-facing window. MacICNS remains in the Dock while either Settings or the management window is visible.

### Running target applications

- After MacICNS successfully writes a custom icon to a target application that is not running, the mapping displays `Applied`.
- After MacICNS successfully writes a custom icon to a target application that is running, the mapping displays `Restart required` in amber.
- A `Restart required` mapping displays the supporting message: `Quit and reopen this app to refresh its Dock icon.`
- MacICNS never quits or relaunches a target application automatically and does not provide a restart button in this iteration.
- When MacICNS observes the target application terminate, the mapping changes from `Restart required` to `Applied`.
- If MacICNS restarts while the target application is still running, the persisted `Restart required` state remains visible.

## Architecture

### User-facing window classification

The application delegate remains responsible for synchronizing activation policy after AppKit window events. Its visibility provider will count only windows that are:

- visible;
- not miniaturized;
- not `NSPanel` instances;
- at the normal window level; and
- able to become key windows.

This excludes SwiftUI's internal `NSStatusBarWindow` instances without depending on private class names. Those status-bar windows were the confirmed reason the current build remained in foreground activation policy after the management window closed.

The close transition remains deferred to the next main-run-loop turn so AppKit can finish updating the closing window's visibility first.

### Running-application boundary

Introduce an injectable `ApplicationRunning` boundary whose production implementation uses `NSRunningApplication.runningApplications(withBundleIdentifier:)`. A mapping is treated as running when at least one nonterminated process exists for its bundle identifier.

The boundary also exposes target-application termination events derived from `NSWorkspace.didTerminateApplicationNotification`. `AppState` uses those events only for mappings currently marked `Restart required` and whose bundle identifier matches the terminated application.

If multiple processes share the same bundle identifier, the mapping remains `Restart required` until no matching process remains.

### Mapping status

Add a persisted `restartRequired` case to `MappingStatus`. Existing mapping files remain compatible because no existing encoded case changes. A successful icon application determines the final status after the write:

- target not running: `upToDate` / `Applied`;
- target running: `restartRequired` / `Restart required`.

`restartRequired` represents a successful filesystem operation, not an error. It must not create failure details, show an error banner, or prevent later repairs.

At MacICNS launch, persisted `restartRequired` mappings are reconciled with current process state. If the target is no longer running, the status becomes `upToDate`; otherwise it remains `restartRequired`.

### Forced manual refresh

Fingerprint comparison remains the optimization for launch and filesystem-triggered repairs. A manual repair must bypass the unchanged-fingerprint early return and call the icon applier again.

Both the menu-bar `Refresh Icons` command and per-row manual refresh use the manual repair reason, so they share the same forced behavior. After a successful forced write, running-target detection chooses between `Applied` and `Restart required`.

## Data Flow

1. A mapping repair resolves the current application URL and fingerprints the application and icon.
2. Automatic repair reasons stop when both fingerprints match.
3. Manual repair continues even when the fingerprints match.
4. The direct icon applier writes the icon through `NSWorkspace`.
5. On success, the coordinator stores the new fingerprints and timestamp.
6. The running-application boundary determines whether the final status is `upToDate` or `restartRequired`.
7. `AppState` persists the mapping and the row renders the corresponding English status and guidance.
8. A matching target termination event reconciles `restartRequired` to `upToDate` once no matching process remains.

## Error Handling

- A failed icon write continues to produce `needsPermission` or `failed`; it never produces `restartRequired`.
- A missing bundle identifier cannot be matched to a running process and therefore uses `Applied` after a successful write.
- Termination notifications for unknown or unrelated bundle identifiers are ignored.
- If the target launches again before termination reconciliation runs, current process state wins and the mapping remains `Restart required`.
- Failures to persist the updated status use the existing persistence error handling.

## Testing

Unit tests will verify:

1. Internal status-bar windows do not keep regular activation policy active.
2. A visible normal key-capable window keeps regular activation policy active.
3. Closing the last user-facing window requests accessory policy.
4. A successful apply to a stopped target produces `upToDate`.
5. A successful apply to a running target produces `restartRequired` without failure details.
6. Manual refresh invokes the applier even when fingerprints are unchanged.
7. Automatic repair still skips unchanged fingerprints.
8. A matching termination event clears `restartRequired` only after all matching processes stop.
9. Unrelated termination events do not change mapping state.
10. Persisted `restartRequired` state is reconciled correctly at launch.

The focused suites, full macOS test suite, and a clean Debug build must pass. The installed test bundle must be advanced to a new build number, verified, backed up, replaced in `/Applications`, and opened for manual acceptance testing.

## Out of Scope

- Restarting or terminating target applications.
- Private Dock, LaunchServices, or process-injection APIs.
- Restarting the Dock process to invalidate caches.
- Reintroducing a privileged helper.
- Redesigning the mapping list beyond the new status and supporting message.
