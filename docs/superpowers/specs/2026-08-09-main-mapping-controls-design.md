# Main Mapping Controls Design

## Goal

Make each mapping visibly reversible and directly manageable from the main MacICNS window. A person must be able to compare the original and custom icons, enable or disable the customization, and delete a mapping without leaving an unmanaged custom icon behind.

## Interaction Model

Each mapping row presents the application's original bundled icon, a right-facing arrow, and the selected custom ICNS preview. This original-to-custom pair is the row's visual focal point. The remaining hierarchy is the application name, ICNS filename, current status, an `Enabled` toggle, and an explicit delete button.

Turning `Enabled` off removes the Finder custom icon and restores the application's bundled default. A disabled mapping remains saved but is excluded from launch repairs, manual refreshes, and file-system-triggered repairs. Turning it on applies the selected custom icon immediately. Controls for that mapping are disabled while either operation is in flight.

Deleting a mapping asks for confirmation. Confirmation restores the original icon first and removes the persisted mapping only after restoration succeeds. If restoration fails, the mapping remains present and an English error is shown, preventing the UI from claiming that an unmanaged custom icon was removed.

## Data Compatibility

`IconMapping` gains a persisted Boolean enabled state. New mappings default to enabled. The decoder treats a missing enabled field as `true`, so all existing mapping files remain compatible and continue their current behavior after upgrading.

Disabling a mapping clears its applied fingerprints after a successful reset. Re-enabling therefore forces an immediate application of the custom icon. A disabled mapping displays `Disabled` in the row rather than appearing applied; this is derived from its enabled state and does not require a new repair-status case.

## Icon Operations

The icon application boundary supports two explicit operations:

- Apply a custom ICNS image.
- Reset the target application to its default Finder icon.

The direct implementation resets with `NSWorkspace.setIcon(nil, forFile:options:)`. Protected applications route the reset through the signed privileged helper, using a secure-coded reset request that validates the `.app` path with the same no-symlink and privileged-path rules as apply requests. The helper never accepts an arbitrary reset target without validation.

Automatic repair filters out disabled mappings before scheduling or applying work. Re-enabling or adding a mapping still performs an immediate apply.

## Original Icon Preview

The original preview is resolved without mutating the application. MacICNS reads the application's bundled icon declaration from its Info.plist, resolves the corresponding resource in `Contents/Resources`, and loads that image directly. This bypasses Finder's custom-icon metadata, which would otherwise return the currently applied custom image. If an application does not expose a loadable bundled icon resource, the row uses the system's generic application icon as a safe fallback.

The custom preview is loaded directly from the selected ICNS file. Preview loading never changes the application.

## Main-Window Presentation

The update stays within the current native, monochrome direction rather than becoming the final redesign:

- Native SwiftUI controls and macOS materials support light and dark appearance.
- Compact rows use a 4-point spacing rhythm.
- The original-to-custom icon pair leads the row.
- Text hierarchy uses system type weight and semantic foreground styles.
- Red is reserved for the delete action; statuses use semantic system colors only where necessary.
- Delete is an always-visible button with a tooltip and confirmation dialog, not a hidden swipe-only action.
- Toggle, delete, and apply controls expose disabled/busy states and retain native keyboard and accessibility behavior.

All visible interface copy remains in English.

## MacICNS Application Icon

The supplied `macicnslogo.png` becomes the source for a standard multi-resolution macOS `.icns` asset. The generated icon is added to the application bundle and referenced by `CFBundleIconFile`. The source artwork is square and remains uncropped; macOS handles its presentation in Finder, Dock, and the app switcher.

## Error Handling

An apply or reset failure leaves the persisted enabled state unchanged. A failed delete leaves the mapping intact. The main window presents a concise English operation error and allows retry. Permission-related failures continue to direct the person to helper setup.

The app logs toggle, reset, delete, and failure outcomes to the existing local diagnostic log without logging file contents.

## Verification

Automated coverage must prove:

- Existing JSON without the enabled field decodes as enabled.
- Disabled mappings are not automatically repaired.
- Disabling calls reset and persists the disabled state only on success.
- Re-enabling applies the custom icon and persists enabled only on success.
- Deletion resets first, removes only on success, and retains the mapping on failure.
- Direct and privileged routers select the correct reset implementation.
- Secure reset requests reject invalid, symlinked, and unsafe privileged targets.
- Original preview resolution loads a declared bundled icon and falls back safely.

Final verification includes the complete test suite, a signed Debug build, explicit code-signing requirement checks for the app and helper, project linting, and inspection that the generated application icon is present in the built bundle.
