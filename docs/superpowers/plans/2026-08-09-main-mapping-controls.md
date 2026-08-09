# Main Mapping Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reversible enabled mappings, original-to-custom icon previews, safe deletion, and the supplied MacICNS application icon.

**Architecture:** Persist `isEnabled` on each mapping with backward-compatible decoding. Extend the existing icon-operation boundary through the direct implementation, router, XPC client, and privileged helper so reset is as secure as apply; keep lifecycle decisions in `RepairCoordinator` and persistence/UI state in `AppState`. Resolve original previews directly from bundle resources, then compose native SwiftUI row controls around that model.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`, ServiceManagement, NSXPC secure coding, XCTest, Xcode 26, `sips`, and `iconutil`.

## Global Constraints

- Minimum deployment target remains macOS 14.0.
- All visible interface copy is English.
- The interface remains native, monochrome, light/dark compatible, and compact; this is not the final redesign.
- The signed app identifier remains `com.guigx.macicns`, the helper remains `com.guigx.macicns.helper`, and both remain bound to Team ID `DHAFYHA4FG`.
- Disabled mappings never reapply automatically.
- A toggle or delete failure must preserve the prior persisted enabled/mapping state.
- Use TDD for every behavior change and commit each completed task professionally.

## File Structure

- `MacICNS/Domain/IconMapping.swift`: persisted enabled state and backward-compatible Codable implementation.
- `MacICNS/Domain/Repairing.swift`: apply/reset operation contract.
- `Shared/IconApplyRequest.swift`: secure-coded apply and reset request validation shared by app/helper.
- `Shared/IconHelperXPCProtocol.swift`: XPC reset method.
- `MacICNS/Services/DirectIconApplier.swift`: direct apply/reset and writable/protected routing.
- `MacICNS/Services/PrivilegedHelperClient.swift`: signed XPC reset call.
- `MacICNSHelper/IconHelperService.swift`: privileged reset implementation.
- `MacICNS/Services/RepairCoordinator.swift`: enabled-state transitions and reset-before-removal.
- `MacICNS/Services/MappingFileMonitor.swift`: exclude disabled mappings from event repair scheduling.
- `MacICNS/App/AppState.swift`: busy state, toggle/delete persistence, and operation errors.
- `MacICNS/Services/ApplicationIconProvider.swift`: original bundle-resource and custom ICNS previews.
- `MacICNS/UI/MappingListView.swift`: comparison row, toggle, confirmation, deletion, and busy/error states.
- `Resources/AppIconSource.png`: repository source artwork supplied by the user.
- `MacICNS/App/AppIcon.icns`: generated multi-resolution macOS application icon.
- `MacICNS/App/Info.plist`: bundle icon declaration.
- `MacICNS.xcodeproj/project.pbxproj`: new Swift source/test membership and app-icon resource phase.
- `MacICNSTests/JSONMappingRepositoryTests.swift`: legacy JSON compatibility.
- `MacICNSTests/DirectIconApplierTests.swift`: direct/protected reset routing.
- `MacICNSTests/IconApplyRequestTests.swift`: reset request validation.
- `MacICNSTests/RepairCoordinatorTests.swift`: toggle and deletion state semantics.
- `MacICNSTests/RepairSchedulerTests.swift`: disabled mapping monitoring behavior.
- `MacICNSTests/ApplicationIconProviderTests.swift`: original icon resource resolution and fallback.

---

### Task 1: Persist Enabled Mapping State Compatibly

**Files:**
- Modify: `MacICNS/Domain/IconMapping.swift`
- Test: `MacICNSTests/JSONMappingRepositoryTests.swift`

**Interfaces:**
- Produces: `IconMapping.isEnabled: Bool`, defaulting to `true` for new and legacy mappings.
- Consumes: Existing `JSONMappingRepository` encoder/decoder without changing its file location or schema container.

- [ ] **Step 1: Write the failing legacy-decoding test**

Add a test that writes a literal JSON array whose mapping has no `isEnabled` key, loads it through the real repository, and asserts `XCTAssertTrue(mapping.isEnabled)`. Add a round-trip assertion for an explicitly disabled mapping:

```swift
func testLegacyMappingWithoutEnabledFieldDefaultsToEnabled() throws {
    let url = temporaryDirectory.appending(path: "mappings.json")
    let json = """
    [{
      "id":"00000000-0000-0000-0000-000000000001",
      "applicationURL":"file:///Applications/Test.app/",
      "bundleIdentifier":"com.example.Test",
      "iconURL":"file:///tmp/Test.icns",
      "status":"upToDate"
    }]
    """
    try Data(json.utf8).write(to: url)

    let mapping = try JSONMappingRepository(fileURL: url).load().first

    XCTAssertEqual(mapping?.isEnabled, true)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-enabled-red \
  CODE_SIGNING_ALLOWED=NO -only-testing:MacICNSTests/JSONMappingRepositoryTests
```

Expected: compilation fails because `IconMapping` has no `isEnabled` member.

- [ ] **Step 3: Implement explicit backward-compatible Codable**

Add `var isEnabled: Bool`, initialize it to `true`, and implement coding with `decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true`. Encode every current field, including explicit `nil` optionals through `encodeIfPresent`, so saved files normalize to the new schema.

```swift
var isEnabled: Bool

enum CodingKeys: String, CodingKey {
    case id, applicationURL, bundleIdentifier, iconURL
    case appFingerprint, iconFingerprint, lastSuccessAt, status, isEnabled
}

isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
```

- [ ] **Step 4: Run focused repository tests and verify GREEN**

Run the command from Step 2 with derived data `/private/tmp/macicns-enabled-green`.

Expected: all `JSONMappingRepositoryTests` pass, including disabled round-trip and legacy decoding.

- [ ] **Step 5: Commit the compatible model change**

```bash
git add MacICNS/Domain/IconMapping.swift MacICNSTests/JSONMappingRepositoryTests.swift
git commit -m "feat: persist mapping enabled state"
```

---

### Task 2: Add Secure Reset Across Direct and Privileged Boundaries

**Files:**
- Modify: `MacICNS/Domain/Repairing.swift`
- Modify: `Shared/IconApplyRequest.swift`
- Modify: `Shared/IconHelperXPCProtocol.swift`
- Modify: `MacICNS/Services/DirectIconApplier.swift`
- Modify: `MacICNS/Services/PrivilegedHelperClient.swift`
- Modify: `MacICNSHelper/IconHelperService.swift`
- Test: `MacICNSTests/DirectIconApplierTests.swift`
- Test: `MacICNSTests/IconApplyRequestTests.swift`
- Modify test doubles in: `MacICNSTests/RepairCoordinatorTests.swift`, `MacICNSTests/RepairSchedulerTests.swift`

**Interfaces:**
- Extends: `IconApplying.reset(applicationURL: URL) async throws`.
- Produces: `IconResetRequest.init(applicationURL:) throws` and `IconHelperXPCProtocol.resetIcon(_:withReply:)`.
- Preserves: Existing apply behavior and code-signing requirements.

- [ ] **Step 1: Write failing direct/router reset tests**

Inject a direct reset closure that records the application URL and assert that `DirectIconApplier.reset` invokes it. Add two router tests proving writable targets use the direct resetter and protected targets use the privileged resetter. Extend `RecordingIconApplier` with independent `appliedApplications` and `resetApplications` arrays.

```swift
try await router.reset(applicationURL: URL(filePath: "/Applications/Example.app"))
let privilegedResets = await privileged.recordedResets()
XCTAssertEqual(privilegedResets, [URL(filePath: "/Applications/Example.app")])
```

Production mutation caught: choosing the apply branch or direct branch for a protected reset.

- [ ] **Step 2: Write failing secure reset-request tests**

In `IconApplyRequestTests`, construct `IconResetRequest` with the existing valid protected app fixture, then assert rejection of a non-`.app` file, a leaf symlink, and an intermediate symlink.

```swift
XCTAssertNoThrow(try IconResetRequest(applicationURL: protectedApplicationURL))
XCTAssertThrowsError(try IconResetRequest(applicationURL: symlinkURL))
```

Production mutation caught: accepting a reset target without application/symlink validation.

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-reset-red \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacICNSTests/DirectIconApplierTests \
  -only-testing:MacICNSTests/IconApplyRequestTests
```

Expected: compilation fails because reset APIs and `IconResetRequest` do not exist.

- [ ] **Step 4: Implement the reset contracts**

Extend the domain protocol:

```swift
protocol IconApplying: Sendable {
    func apply(applicationURL: URL, iconURL: URL) async throws
    func reset(applicationURL: URL) async throws
}
```

Add `IconResetRequest` beside `IconApplyRequest`, reusing a `fileprivate` application URL validator so apply and reset enforce identical bundle and symlink rules. Secure-code only `applicationURL`.

Add a separately injected direct reset closure whose default implementation is:

```swift
NSWorkspace.shared.setIcon(nil, forFile: applicationURL.path, options: [])
```

Route reset through `IconApplierRouter` using the same writability predicate used for apply. Add explicit no-op `reset(applicationURL:)` methods to test doubles whose tests exercise only apply; do not add a production default implementation that could silently skip restoration.

- [ ] **Step 5: Implement and validate privileged reset**

Add the XPC method:

```swift
func resetIcon(_ request: IconResetRequest, withReply reply: @escaping (NSError?) -> Void)
```

`PrivilegedHelperClient.reset` creates the signed connection exactly as apply does and invokes the new method. In the helper, reconstruct `IconResetRequest`, require an identifiable current XPC connection, run `PrivilegedPathValidator.validate(applicationURL:)`, then call `NSWorkspace.shared.setIcon(nil, forFile:options:)`. Reply with a distinct helper error when reset returns `false`.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 3 command with derived data `/private/tmp/macicns-reset-green`.

Expected: all direct/router/request tests pass.

- [ ] **Step 7: Build both signed targets and inspect selectors**

```bash
xcodebuild build -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-reset-signed
```

Expected: app and helper build with the shared reset request/protocol included; no Objective-C selector collision or secure-coding error.

- [ ] **Step 8: Commit the reset boundary**

```bash
git add MacICNS/Domain/Repairing.swift Shared/IconApplyRequest.swift \
  Shared/IconHelperXPCProtocol.swift MacICNS/Services/DirectIconApplier.swift \
  MacICNS/Services/PrivilegedHelperClient.swift MacICNSHelper/IconHelperService.swift \
  MacICNSTests/DirectIconApplierTests.swift MacICNSTests/IconApplyRequestTests.swift \
  MacICNSTests/RepairCoordinatorTests.swift MacICNSTests/RepairSchedulerTests.swift
git commit -m "feat: add secure icon restoration"
```

---

### Task 3: Coordinate Toggle, Automatic Repair, and Safe Deletion

**Files:**
- Modify: `MacICNS/Services/RepairCoordinator.swift`
- Modify: `MacICNS/Services/MappingFileMonitor.swift`
- Modify: `MacICNS/App/AppState.swift`
- Test: `MacICNSTests/RepairCoordinatorTests.swift`
- Test: `MacICNSTests/RepairSchedulerTests.swift`
- Test: `MacICNSTests/MacICNSTests.swift`

**Interfaces:**
- Produces: `RepairCoordinator.setEnabled(_:for:) async -> IconMapping`.
- Produces: `RepairCoordinator.resetForRemoval(_:) async throws`.
- Produces: `AppState.setEnabled(_:for:) async`, `AppState.delete(_:) async`, `AppState.isBusy(_:) -> Bool`, and `AppState.operationError`.
- Consumes: `IconApplying.reset(applicationURL:)` from Task 2.

- [ ] **Step 1: Write failing coordinator state-transition tests**

Add separate tests for:

1. Disabling an enabled mapping calls reset, returns `isEnabled == false`, clears both fingerprints, and leaves status `.upToDate`.
2. A reset failure returns `isEnabled == true` with `.needsPermission` or `.failed` status.
3. Re-enabling a disabled mapping forces apply even when its old fingerprints match, and persists enabled only after successful apply.
4. A failed re-enable remains disabled.
5. `resetForRemoval` propagates failure rather than treating it as successful deletion preparation.

Example independent outcome assertion:

```swift
let updated = await coordinator.setEnabled(false, for: mapping)
XCTAssertFalse(updated.isEnabled)
XCTAssertNil(updated.appFingerprint)
XCTAssertEqual(await applier.recordedResets(), [applicationURL])
```

- [ ] **Step 2: Write the failing disabled-monitor test**

Create one enabled and one disabled mapping with different parent directories, start `MappingFileMonitor`, and assert the stream factory receives only the enabled parent. Emit an event for the disabled app and assert no repair request is recorded.

Production mutation caught: including a disabled mapping in directories or `affectedMappingIDs`.

- [ ] **Step 3: Run coordinator/monitor tests and verify RED**

```bash
xcodebuild test -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-lifecycle-red \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacICNSTests/RepairCoordinatorTests \
  -only-testing:MacICNSTests/RepairSchedulerTests
```

Expected: compilation fails because enabled transitions/removal APIs are absent; the monitor test fails because disabled paths are still monitored.

- [ ] **Step 4: Implement coordinator lifecycle semantics**

At the start of normal repair, return disabled mappings without fingerprinting or applying. For disable, call reset before changing `isEnabled`; on success clear fingerprints and success timestamp, set status `.upToDate`, then return disabled. For enable, create an enabled candidate with cleared fingerprints, call the existing repair path, and copy failure status back onto the still-disabled original unless repair succeeds.

`resetForRemoval` resolves a moved application with the existing locator rules and throws when no application can be resolved or reset fails.

- [ ] **Step 5: Exclude disabled mappings from monitoring**

Filter stream directories to `mappings.filter(\.isEnabled)`, and guard `mapping.isEnabled` inside `affectedMappingIDs`. Keep disabled mappings in persisted/app state; only monitoring and repair work are excluded.

- [ ] **Step 6: Implement AppState busy, toggle, delete, and errors**

Add:

```swift
@Published private(set) var operationError: String?
@Published private(set) var busyMappingIDs: Set<UUID> = []
```

`setEnabled` inserts the ID into busy state and uses `defer { busyMappingIDs.remove(mapping.id) }`. It awaits the coordinator transition, replaces and saves the returned mapping, restarts the monitor, and records a diagnostic. When `updated.isEnabled != requestedValue`, it sets `operationError` from the returned `.needsPermission` or `.failed` status while preserving the prior enabled value.

`delete` inserts busy state, awaits `resetForRemoval`, removes the mapping only after success, saves and restarts monitoring. On error it leaves the array untouched, maps the failure to a concise English message, records the diagnostic, and clears busy state.

Add `dismissOperationError()` and `isBusy(_:)` for the view. Replace the old offset-only deletion path so no UI path can delete without reset.

- [ ] **Step 7: Add AppState outcome tests**

Use a real in-memory `MappingRepository` seeded with one mapping and a controlled icon applier. Assert successful deletion leaves the saved array empty, while a reset failure leaves the saved mapping present. Assert a failed toggle preserves its previous `isEnabled` value. Expected values must be read from the repository's saved array, not from spy call counts alone.

- [ ] **Step 8: Run focused lifecycle tests and verify GREEN**

Run the Step 3 command plus `-only-testing:MacICNSTests/MacICNSTests`, using `/private/tmp/macicns-lifecycle-green`.

Expected: lifecycle, monitor, and AppState tests pass.

- [ ] **Step 9: Commit lifecycle behavior**

```bash
git add MacICNS/Services/RepairCoordinator.swift MacICNS/Services/MappingFileMonitor.swift \
  MacICNS/App/AppState.swift MacICNSTests/RepairCoordinatorTests.swift \
  MacICNSTests/RepairSchedulerTests.swift MacICNSTests/MacICNSTests.swift
git commit -m "feat: add reversible mapping lifecycle"
```

---

### Task 4: Show Original-to-Custom Rows and Native Controls

**Files:**
- Create: `MacICNS/Services/ApplicationIconProvider.swift`
- Create: `MacICNSTests/ApplicationIconProviderTests.swift`
- Modify: `MacICNS/UI/MappingListView.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `@MainActor ApplicationIconProvider.originalIconURL(for:) -> URL?` and `originalIcon(for:) -> NSImage`.
- Produces: `@MainActor ApplicationIconProvider.customIcon(at:) -> NSImage`.
- Consumes: AppState toggle/delete/busy/error APIs from Task 3.

- [ ] **Step 1: Write failing original-icon resolver tests**

Create a temporary `Example.app/Contents/Resources`, copy the system `GenericApplicationIcon.icns` fixture to `Original.icns`, and write an Info.plist with `CFBundleIconFile = Original`. Assert the provider resolves and loads the bundled resource. Create a second app with no declaration and assert the provider returns a non-zero generic application image.

```swift
let image = provider.originalIcon(for: applicationURL)
XCTAssertGreaterThan(image.size.width, 0)
XCTAssertEqual(provider.originalIconURL(for: applicationURL)?.lastPathComponent, "Original.icns")
```

Production mutation caught: using `NSWorkspace.icon(forFile:)`, which would display Finder's custom icon instead of the bundle resource.

- [ ] **Step 2: Run provider test and verify RED**

```bash
xcodebuild test -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-preview-red \
  CODE_SIGNING_ALLOWED=NO -only-testing:MacICNSTests/ApplicationIconProviderTests
```

Expected: build fails because `ApplicationIconProvider` and the test target file membership do not exist.

- [ ] **Step 3: Implement the original/custom provider**

Read `CFBundleIconFile`, then `CFBundleIconName`, append `.icns` when the declaration has no extension, and resolve inside `Contents/Resources`. Load that file directly. Fall back to `NSWorkspace.shared.icon(for: .applicationBundle)` rather than `icon(forFile:)`. Load the custom preview directly with `NSImage(contentsOf:)`, using the generic icon only for a corrupt/unavailable file.

Add the provider and test file to the explicit PBX groups and source phases.

- [ ] **Step 4: Run provider tests and verify GREEN**

Run Step 2 with `/private/tmp/macicns-preview-green`.

Expected: declared-resource and fallback tests pass.

- [ ] **Step 5: Build the comparison row with native controls**

In `MappingRowView`, use a 4-point rhythm and a leading icon cluster:

```swift
HStack(spacing: 8) {
    iconPreview(provider.originalIcon(for: mapping.applicationURL), label: "Original icon")
    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
    iconPreview(provider.customIcon(at: mapping.iconURL), label: "Custom icon")
}
```

Place application/ICNS text next, then a derived `Disabled` or repair status label, native `Toggle("Enabled", isOn:)` with a hidden visual label but accessibility label retained, and a borderless trash button using `.foregroundStyle(.red)`, help text `Delete Mapping`, and a minimum native control hit area. Disable row controls while `appState.isBusy(mapping)`.

At list level, keep `mappingPendingDeletion: IconMapping?`, present `confirmationDialog("Delete Mapping?", ...)`, and call `await appState.delete(mapping)` only from the destructive confirmation. Remove `.onDelete` so swipe/keyboard deletion cannot bypass restoration. Present `operationError` in an English alert with retry-safe dismissal.

Intent checkpoint for this component:

- Intent: a Mac owner quickly understands and reverses icon transformations; the row feels precise and native.
- Hierarchy: `original → custom` leads through imagery and position, while controls remain compact.
- Palette: semantic macOS labels/materials; red only for destructive deletion.
- Depth: borderless list rows with system separators, matching the existing native surface strategy.
- Surfaces: system window/list surfaces support light and dark mode without custom fills.
- Typography: system headline weight for app name, secondary caption for filename/status.
- Spacing: 4-point base; 8/12-point component gaps and standard list vertical padding.

- [ ] **Step 6: Compile and visually inspect both appearances**

Build signed Debug, launch the app, and inspect a populated row in light and dark appearances. Verify the two icons are distinct, the arrow is centered, long names truncate before controls, the toggle and trash button remain reachable, busy controls disable, confirmation copy is English, and the row does not clip at the current minimum window size.

- [ ] **Step 7: Commit the main-window controls**

```bash
git add MacICNS/Services/ApplicationIconProvider.swift \
  MacICNSTests/ApplicationIconProviderTests.swift MacICNS/UI/MappingListView.swift \
  MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: add reversible mapping controls"
```

---

### Task 5: Generate and Bundle the MacICNS Application Icon

**Files:**
- Create: `Resources/AppIconSource.png`
- Create: `MacICNS/App/AppIcon.icns`
- Modify: `MacICNS/App/Info.plist`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: bundled `AppIcon.icns` referenced by `CFBundleIconFile`.
- Consumes: `/Users/guigx/Downloads/macicnslogo.png`, supplied at 1254×1254 RGB.

- [ ] **Step 1: Preserve source artwork and generate the iconset**

Use a task-scoped temporary directory and generate all required macOS representations:

```bash
sips -s format png /Users/guigx/Downloads/macicnslogo.png --out Resources/AppIconSource.png
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_512x512.png"
sips -z 1024 1024 Resources/AppIconSource.png --out "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o MacICNS/App/AppIcon.icns
```

- [ ] **Step 2: Add the icon to the application bundle**

Set `<key>CFBundleIconFile</key><string>AppIcon</string>` in `MacICNS/App/Info.plist`. Add `AppIcon.icns` to a standard `PBXResourcesBuildPhase` for the MacICNS target, not the helper or test targets.

- [ ] **Step 3: Verify the built icon resource**

```bash
xcodebuild build -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-app-icon
test -f /private/tmp/macicns-app-icon/Build/Products/Debug/MacICNS.app/Contents/Resources/AppIcon.icns
plutil -extract CFBundleIconFile raw \
  /private/tmp/macicns-app-icon/Build/Products/Debug/MacICNS.app/Contents/Info.plist
```

Expected: the file exists and the extracted value is `AppIcon`.

- [ ] **Step 4: Inspect the rendered app icon**

Launch the signed Debug app and verify the supplied red icon appears in the Dock and app switcher without cropping, stretching, or a stale generic icon. If Finder/Dock caches the previous icon, restart the Debug app from the fresh derived-data bundle before judging the asset.

- [ ] **Step 5: Commit the application icon**

```bash
git add Resources/AppIconSource.png MacICNS/App/AppIcon.icns \
  MacICNS/App/Info.plist MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: add MacICNS application icon"
```

---

### Task 6: Final Regression, Signing, and Remote Delivery

**Files:**
- Verify all modified files.

**Interfaces:**
- Consumes: Tasks 1–5 complete on `feature/macicns-v1`.
- Produces: clean, tested, signed, pushed branch.

- [ ] **Step 1: Run the complete test suite fresh**

```bash
xcodebuild test -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-controls-final-tests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: every test target passes with zero failures.

- [ ] **Step 2: Build and verify signed app/helper identities**

```bash
xcodebuild build -quiet -project MacICNS.xcodeproj -scheme MacICNS \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-controls-final-signed
codesign --verify --deep --strict --verbose=2 \
  /private/tmp/macicns-controls-final-signed/Build/Products/Debug/MacICNS.app
codesign --verify --strict --verbose=2 \
  --test-requirement '=identifier "com.guigx.macicns.helper" and anchor apple generic and certificate leaf[subject.OU] = "DHAFYHA4FG"' \
  /private/tmp/macicns-controls-final-signed/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
```

Expected: the bundle is valid and the helper satisfies the explicit requirement.

- [ ] **Step 3: Run structural checks**

```bash
git diff --check
plutil -lint MacICNS.xcodeproj/project.pbxproj MacICNS/App/Info.plist \
  MacICNSHelper/Info.plist Resources/LaunchDaemons/com.guigx.macicns.helper.plist
git status --short
```

Expected: no whitespace errors, all plists valid, and only intended task changes present before final commits.

- [ ] **Step 4: Perform the user-visible acceptance flow**

With one protected application mapping:

1. Confirm the row shows the bundled original icon, arrow, and selected custom icon.
2. Disable the toggle and confirm Finder/Dock returns to the original icon.
3. Relaunch MacICNS and confirm the mapping remains disabled and is not reapplied.
4. Re-enable and confirm the custom icon returns.
5. Delete, confirm the dialog, and confirm the original icon remains while the mapping disappears.
6. Update or replace a mapped test application and confirm an enabled mapping is repaired automatically.

- [ ] **Step 5: Push the completed branch**

```bash
git push origin feature/macicns-v1
```

Expected: remote `feature/macicns-v1` points to the locally verified final commit.
