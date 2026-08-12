# Dock Icon Reload Design

## Goal

Make the existing `Refresh Icons` action immediately refresh changed icons for
currently running applications in the Dock, without requiring the user to quit
and reopen those applications.

## User Experience

- `Refresh Icons` remains available in the menu bar.
- The main mapping screen also exposes a `Refresh Icons` button.
- Both controls invoke the same AppState operation and share its busy state.
- The operation reapplies every enabled mapping, then reloads the Dock once.
- Reloading the Dock uses the user-level `killall Dock` command. The Dock may
  briefly disappear and return; this is expected macOS behavior.
- A failed mapping does not prevent the single Dock reload: successfully
  reapplied mappings still become visible in the Dock.
- The action never quits, relaunches, or otherwise controls target apps.

## Architecture

- Add an injectable `DockReloading` boundary with a production implementation
  that launches `/usr/bin/killall Dock` through public Foundation process APIs.
- `AppState.refreshAll()` remains the shared entry point. It awaits its existing
  mapping refresh work and then asks the injected reloader to reload the Dock.
- The reloader is called once per user-triggered refresh, including when there
  are no enabled mappings, so the command remains a dependable Dock refresh.
- If the reload command cannot start or exits unsuccessfully, mappings and
  their repair statuses remain unchanged; the app records an English diagnostic
  and exposes a concise operation error.

## Testing

- A fake reloader proves one reload follows a manual refresh.
- A test proves failed individual mapping repairs do not suppress the reload.
- A test proves reload failures do not overwrite mapping repair results.
- Row/menu controls use the existing shared `AppState.refreshAll()` pathway;
  the main-screen button is covered by a deterministic presentation/action
  boundary where practical.

## Constraints

- All user-facing copy remains English.
- Use public macOS APIs only.
- Do not terminate or relaunch target applications.
- Do not add a privileged helper or alter mapping JSON compatibility.
