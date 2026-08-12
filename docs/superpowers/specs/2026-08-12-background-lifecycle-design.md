# Background Lifecycle Design

## Goal

MacICNS must remain running after the user closes its last window. While no app window is visible, it must disappear from the Dock and remain available from the menu bar. Reopening the management window or Settings must restore the Dock presence while a window is visible.

The installed copy in `/Applications/MacICNS.app` must be replaced with the newly built version after verification.

## User Experience

- Launching MacICNS opens the management window and shows the app in the Dock.
- Clicking the red close button closes the window without terminating MacICNS.
- After the last MacICNS window closes, the app changes to accessory mode and disappears from the Dock.
- The menu bar item remains available with `Show MacICNS`, `Refresh Icons`, and `Quit`.
- Selecting `Show MacICNS` changes the app back to regular mode, restores its Dock presence, opens or raises the management window, and activates the app.
- Opening Settings also changes the app back to regular mode.
- `Quit` remains the only UI action that explicitly terminates the process.

## Architecture

Introduce a small lifecycle controller with one responsibility: coordinate the macOS activation policy with window visibility.

The controller depends on an activation-policy boundary rather than calling `NSApplication` directly in its decision logic. It exposes two operations:

- `showApplication()`: switch to regular activation policy before a window is opened or raised.
- `windowsDidChange(hasVisibleWindows:)`: stay regular when at least one app window is visible; switch to accessory when none are visible.

An `NSApplicationDelegate` bridge observes relevant AppKit window close/key events and evaluates visibility on the next main-run-loop turn, after AppKit has finished updating window state. SwiftUI menu and command actions call `showApplication()` before `openWindow` and activation.

Settings receives the same treatment through the application delegate's window visibility observation, so closing either the management window or Settings cannot terminate the process or leave a visible window without Dock presence.

The app will not use `LSUIElement`; that would hide the Dock icon permanently and conflict with the approved behavior.

## Window Visibility Rules

Only visible, non-panel windows owned by MacICNS count toward regular mode. Transient system panels and menu bar popovers must not keep the app in the Dock. The transition to accessory mode is deferred by one main-run-loop turn to avoid inspecting a window before AppKit completes a close operation.

The app delegate explicitly returns `false` from `applicationShouldTerminateAfterLastWindowClosed` as a defensive declaration of the intended lifecycle.

## Testing

Unit tests will use a recording activation-policy boundary to verify:

1. Showing the app requests regular mode.
2. Closing the last visible app window requests accessory mode.
3. Closing one window while another remains visible keeps regular mode.
4. Reopening after backgrounding requests regular mode before the window action.

The full macOS test suite and a clean Debug build must pass. Bundle verification must confirm the built app contains no privileged helper artifacts.

## Installation

After verification:

1. Stop any currently running MacICNS instance.
2. Build the current branch using the configured Apple Development signing identity.
3. Replace `/Applications/MacICNS.app` with the verified build as one scoped installation operation.
4. Validate the installed build number, code signature, executable checksum, and absence of the removed helper files.
5. Launch the installed application for user testing.

The replacement is limited to `/Applications/MacICNS.app`; no other application or user data is removed.
