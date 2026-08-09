# Secure Helper Icon Writing Design

## Goal

Allow MacICNS to apply and restore custom icons on root-owned applications under the standard `/Applications` directory without weakening the privileged helper's protection against symlink and pathname replacement attacks.

The change also removes the duplicated static `Enabled` text beside mapping switches and gives users an explicit way to update an already registered helper after installing a newer MacICNS build.

## Confirmed Root Causes

The persisted ClickUp mapping is correctly disabled. Its contradictory presentation comes from two separate labels: the derived row status says `Disabled`, while the native toggle has a hard-coded visible label of `Enabled`.

WhatsApp is root-owned and correctly routes through the helper. The helper is registered and running as root, but `PrivilegedPathValidator` rejects the target before applying the icon because `/Applications` is normally `root:admin` with mode `0775`. Rejecting every group-writable ancestor therefore rejects protected applications installed in the normal macOS location.

## Mapping Toggle Presentation

The switch will not display a duplicated text label. The row status remains the single visible `Enabled` or `Disabled` state, while the switch exposes a state-sensitive accessibility label. Persisted enabled state and toggle behavior remain unchanged.

## Stable Privileged Target

The helper will stop passing the requested application pathname to `NSWorkspace.setIcon`. Instead, it will open the path component-by-component from `/` with `openat`, `O_DIRECTORY`, `O_NOFOLLOW`, and `O_CLOEXEC`. Each opened descriptor anchors the next lookup to the directory already opened, so a rename or replacement in a writable ancestor cannot redirect the operation.

The final application descriptor must identify a directory that:

- is owned by root in production;
- is not group- or world-writable;
- has no extended ACL granting independent access;
- was reached without following a symlink;
- corresponds to a request already validated as an existing `.app` bundle.

Tests may inject the current test user's UID while exercising the same descriptor implementation on temporary bundles. Production always requires UID 0.

## Finder Custom-Icon Writer

The helper will write the Finder custom icon through file descriptors rather than a mutable pathname.

For apply:

1. Render the validated ICNS image onto a root-owned, mode-0700 staging directory using `NSWorkspace.setIcon`.
2. Read the generated `Icon\r` Finder metadata from the trusted staging directory.
3. Open or create `Icon\r` relative to the stable target application descriptor with `openat` and `O_NOFOLLOW`.
4. Copy only the `com.apple.ResourceFork` and `com.apple.FinderInfo` attributes to that descriptor.
5. Read the target bundle's existing `com.apple.FinderInfo`, preserve unrelated bits, and set Apple's `kHasCustomIcon` flag (`0x0400`).

For reset:

1. Open and validate the application through the same stable descriptor walk.
2. Remove `Icon\r` with `unlinkat`, treating an absent file as already reset.
3. Preserve unrelated Finder flags while clearing `kHasCustomIcon`.

The constants and attribute names come from the macOS SDK's `Finder.h` and `sys/xattr.h`. Resource-fork reads remain bounded by the existing 64 MiB icon limit. Temporary staging data is removed after each operation.

After a successful operation, the helper notifies `NSWorkspace` that the application changed so Finder and Dock can refresh their caches.

## Helper Lifecycle and Diagnostics

An enabled `SMAppService` may still be running an older helper process after MacICNS is rebuilt. Settings will therefore offer `Update Helper` whenever the helper is installed. Updating unregisters and re-registers the daemon through `SMAppService`, then refreshes status and reapplies mappings when the new helper becomes available.

The app's local diagnostic log will record the error domain, code, and localized description returned by failed apply/reset operations. The UI will distinguish these cases:

- helper unavailable or rejected connection;
- unsafe target path;
- helper reached the target but could not write Finder metadata.

No file contents or sensitive user data are logged.

## Security Boundaries

- The app and helper retain their Team-ID-bound mutual code-signing requirements.
- The helper continues accepting only secure-coded `.app` and `.icns` requests.
- Source ICNS bytes remain opened component-by-component with no symlink following, regular-file validation, nonblocking I/O, and a 64 MiB limit.
- Mutable parent directories are allowed only because the privileged write is anchored to the final validated descriptor.
- The helper never accepts an arbitrary file descriptor from the client.
- Only Finder icon metadata inside the validated application directory can be changed.

## Tests and Verification

Automated tests must prove:

- enabled and disabled mappings expose the correct switch accessibility state;
- a root-owned application beneath the normal group-writable `/Applications` parent passes descriptor validation;
- a leaf or intermediate symlink is rejected;
- a writable or wrong-owner final application is rejected;
- applying through a stable descriptor creates `Icon\r`, writes a resource fork, and sets `kHasCustomIcon`;
- resetting removes `Icon\r`, clears only `kHasCustomIcon`, and preserves unrelated Finder flags;
- helper update errors and operation errors remain visible and diagnostic;
- all existing request, helper security, monitor, persistence, and UI-state tests remain green.

Final verification requires the complete test suite, a signed Debug build, strict signature validation for app and helper, inspection of the embedded daemon layout, helper update/restart, and a real apply/reset cycle against `/Applications/WhatsApp.app` using the selected WhatsApp ICNS file.
