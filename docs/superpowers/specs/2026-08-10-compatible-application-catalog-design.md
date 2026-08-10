# Compatible Application Catalog Design

## Goal

MacICNS will support only application bundles whose custom Finder icon can be changed safely by the current user. The app will stop presenting privileged-helper setup as a solution for protected application bundles.

The application picker will become a catalog that makes compatibility visible before a mapping is created. Existing mappings that are no longer supported will be removed silently.

## Product Decisions

- MacICNS will not attempt to modify root-owned or system-protected application bundles.
- Unsupported applications remain visible in the catalog but cannot be selected.
- Unsupported mappings are removed silently; no migration alert or activity notification is shown.
- The privileged helper, its registration UI, and App Management permission are removed.
- Launch at Login remains available and is independent of privileged icon writing.
- The main interface redesign remains a later project. This change is limited to the application-selection flow and states required by compatibility.

## Compatibility Model

Introduce an `ApplicationEligibilityService` that resolves an application URL to one of these states:

- `compatible`: the bundle exists, is an `.app` directory, is located on a writable volume, and the current user has write access to the resolved bundle directory.
- `protected`: the bundle exists but the current user cannot write to it safely.
- `systemApplication`: the resolved bundle is located in a protected system application location, including `/System/Applications` and `/System/Library/CoreServices`.
- `missing`: no application currently exists at the URL.
- `invalid`: the URL exists but is not an application bundle, resolves through an unsafe or broken link, or cannot be inspected.

The service will resolve symbolic links before classifying ownership and writability so user-writable Homebrew cask links are not rejected merely because their visible location is `/Applications`.

Eligibility checks are conservative. MacICNS must reject uncertain targets rather than route them to a privileged fallback.

## Application Catalog

The Add Mapping sheet will replace the Finder-only application row with a catalog populated from:

- `/Applications`
- `~/Applications`, when present
- `/System/Applications`

The catalog will:

- show the application icon, display name, and compatibility state;
- sort compatible applications first, alphabetically, followed by unsupported applications alphabetically;
- allow selection only for `compatible` applications;
- label unsupported entries as `Protected` or `System App`;
- show a short English explanation for disabled entries;
- provide a search field matching application name;
- provide a `Browse…` action for application bundles outside the scanned locations.

An application selected through `Browse…` passes through the same eligibility service. An unsupported selection remains unselected and shows its classification in the sheet.

After selecting a compatible application, the existing ICNS picker remains available and continues opening at the last successfully used icon directory.

## Mapping Lifecycle

At launch, AppState will validate loaded mappings before starting filesystem monitoring or repair:

1. Load persisted mappings.
2. Use the existing bundle-identifier relocation logic to resolve moved applications when possible.
3. Remove mappings classified as `protected`, `systemApplication`, or `invalid`.
4. Retain `missing` mappings in their existing inactive state so a compatible reinstall can still be found later.
5. Persist the filtered mapping collection when it changed.
6. Start monitoring and automatic repair only for compatible mappings; missing mappings retain only the existing relocation observation needed to find a reinstall.

This migration is silent.

The same eligibility check applies when a monitored application is replaced or relocated. If an application update changes the bundle to an unsupported state, MacICNS removes that mapping, persists the change, and stops monitoring it without presenting an alert.

Adding a mapping is guarded at the AppState boundary as well as in the picker. A stale catalog result cannot create a mapping after permissions or the target path change.

## Icon Application Architecture

`DirectIconApplier` becomes the only icon application implementation. It continues to use `NSWorkspace.setIcon(_:forFile:options:)` for apply and reset operations.

The following privileged-helper components will be removed:

- the `MacICNSHelper` target and executable;
- daemon plist and bundle copy phases;
- XPC protocol, requests used only by the helper, client validation, and privileged-path writer code;
- helper registration, update, handshake, and status services;
- helper settings controls and App Management settings links;
- `NSAppBundlesUsageDescription` and helper-specific signing configuration;
- helper-specific failure messaging and routing.

Finder metadata preparation and raw privileged metadata writing will also be removed if no remaining direct-flow code consumes them.

The main application stays certificate-signed. No process runs as root and MacICNS does not request App Management or Full Disk Access.

## Failure Handling

- Catalog enumeration failures skip only the affected directory or entry.
- A compatible app that becomes unwritable between selection and save is rejected without creating a mapping.
- A direct icon operation that unexpectedly fails keeps the mapping and reports the existing non-permission failure state; it is not treated as a reason to install a helper.
- Missing apps retain the existing relocation behavior only while a compatible replacement can be resolved. An incompatible replacement causes silent removal.

## Testing

Tests will cover:

- classification of writable, protected, system, symlinked, missing, and invalid application URLs;
- deterministic catalog ordering and search behavior;
- Browse validation using the same eligibility rules as scanned entries;
- refusal to create mappings from stale or unsupported selections;
- silent launch migration and persistence of the filtered collection;
- silent removal after an application replacement becomes unsupported;
- continued direct apply, reset, toggle, delete, replacement-icon, monitoring, and Launch at Login behavior;
- absence of the privileged helper and daemon from the built app bundle;
- removal of helper and App Management controls from Settings.

## Success Criteria

- Users can understand before selection which applications MacICNS supports.
- No unsupported application can create or retain an active mapping.
- MacICNS performs no privileged operation and asks for no app-management permission.
- Compatible mappings continue to repair automatically after supported application updates.
- The built app contains no privileged helper or LaunchDaemon.
