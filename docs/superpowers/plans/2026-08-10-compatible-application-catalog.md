# Compatible Application Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace privileged icon writing with a compatibility-aware application catalog that only creates and retains mappings for user-writable applications.

**Architecture:** A synchronous eligibility service classifies resolved application bundles without modifying them. A catalog presents compatibility before selection, while AppState uses the same classifier to reject stale selections and silently prune unsupported mappings. `DirectIconApplier` becomes the only writer and all LaunchDaemon/XPC helper code is removed.

**Tech Stack:** Swift 6, SwiftUI, AppKit, UniformTypeIdentifiers, XCTest, Xcode 17, macOS 14+.

## Global Constraints

- All interface copy remains English.
- No process runs as root; request neither App Management nor Full Disk Access.
- Remove unsupported mappings silently; retain missing mappings for relocation.
- Preserve Launch at Login and the menu-bar extra.
- Add no third-party dependency.
- Use red-green-refactor, create a professional commit per task, and push every task commit immediately.

---

### Task 1: Application Eligibility Boundary

**Files:**
- Create: `MacICNS/Services/ApplicationEligibilityService.swift`
- Create: `MacICNSTests/ApplicationEligibilityServiceTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ApplicationEligibility` with `compatible`, `protected`, `systemApplication`, `missing`, and `invalid`.
- Produces: `ApplicationEligibilityChecking.eligibility(for:)`.
- Produces: `ApplicationEligibilityService` using read-only filesystem inspection.

- [ ] **Step 1: Write failing classification tests**

Use an injected inspection closure. Cover writable, unwritable, system, missing, invalid, broken-link, and resolved writable-link cases.

```swift
func testWritableApplicationIsCompatible() {
    let service = ApplicationEligibilityService(inspect: { url in
        .init(resolvedURL: url, exists: true, isDirectory: true,
              volumeIsReadOnly: false, isWritable: true)
    })
    XCTAssertEqual(service.eligibility(for: URL(filePath: "/Applications/Example.app")), .compatible)
}

func testSystemApplicationIsNeverCompatible() {
    let service = ApplicationEligibilityService(inspect: { url in
        .init(resolvedURL: url, exists: true, isDirectory: true,
              volumeIsReadOnly: false, isWritable: true)
    })
    XCTAssertEqual(service.eligibility(for: URL(filePath: "/System/Applications/FindMy.app")), .systemApplication)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-eligibility-derived \
  -allowProvisioningUpdates \
  -only-testing:MacICNSTests/ApplicationEligibilityServiceTests
```

Expected: compile failure because the eligibility types do not exist.

- [ ] **Step 3: Implement the conservative classifier**

```swift
enum ApplicationEligibility: Equatable, Sendable {
    case compatible, protected, systemApplication, missing, invalid
}

protocol ApplicationEligibilityChecking: Sendable {
    func eligibility(for applicationURL: URL) -> ApplicationEligibility
}

struct ApplicationInspection: Sendable {
    let resolvedURL: URL
    let exists: Bool
    let isDirectory: Bool
    let volumeIsReadOnly: Bool
    let isWritable: Bool
}
```

Production inspection uses `resolvingSymlinksInPath()`, URL resource values, and `FileManager.isWritableFile(atPath:)`. Reject non-`.app` URLs. Classify `/System/Applications` and `/System/Library/CoreServices` before considering writability. Inspection errors and broken links are `.invalid`.

- [ ] **Step 4: Verify GREEN and project integrity**

Run Step 2 again, followed by:

```bash
plutil -lint MacICNS.xcodeproj/project.pbxproj
git diff --check
```

Expected: focused tests and both checks pass.

- [ ] **Step 5: Commit**

```bash
git add MacICNS/Services/ApplicationEligibilityService.swift \
  MacICNSTests/ApplicationEligibilityServiceTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: classify application icon compatibility"
git push origin feature/macicns-v1
```

---

### Task 2: Compatibility-Aware Application Catalog

**Files:**
- Create: `MacICNS/Services/ApplicationCatalog.swift`
- Create: `MacICNSTests/ApplicationCatalogTests.swift`
- Modify: `MacICNS/UI/MappingListView.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ApplicationEligibilityChecking` from Task 1.
- Produces: `ApplicationCatalogEntry` containing URL, display name, and eligibility.
- Produces: `ApplicationCatalog.entries(searchText:)` and `ApplicationCatalogLoader.load()`.

- [ ] **Step 1: Write failing catalog tests**

Use injected roots and directory contents. Prove compatible-first alphabetical ordering, case-insensitive search, deduplication by resolved URL, and ignoring non-`.app` entries.

```swift
func testCompatibleEntriesSortBeforeUnsupportedEntries() {
    let catalog = ApplicationCatalog(entries: [
        .init(url: URL(filePath: "/Applications/Xcode.app"), displayName: "Xcode", eligibility: .protected),
        .init(url: URL(filePath: "/Applications/Discord.app"), displayName: "Discord", eligibility: .compatible),
        .init(url: URL(filePath: "/System/Applications/FindMy.app"), displayName: "Find My", eligibility: .systemApplication),
    ])
    XCTAssertEqual(catalog.entries(searchText: "").map(\.displayName), ["Discord", "Find My", "Xcode"])
}
```

- [ ] **Step 2: Run catalog tests and verify RED**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-catalog-derived \
  -allowProvisioningUpdates -only-testing:MacICNSTests/ApplicationCatalogTests
```

Expected: compile failure because catalog types are absent.

- [ ] **Step 3: Implement discovery and presentation data**

Scan immediate `.app` children of `/Applications`, `~/Applications`, and `/System/Applications`. Resolve duplicates by standardized resolved URL. Use the bundle display name when available and otherwise strip `.app`. Sort compatible entries first, then unsupported entries, each group localized and case-insensitive.

- [ ] **Step 4: Replace Finder-only application selection**

Update `MappingEditorView` with:

- `Search Applications` search field;
- rows showing icon, name, and `Compatible`, `Protected`, or `System App`;
- selection enabled only for compatible rows;
- disabled-row explanation `macOS does not allow this app's icon to be changed safely.`;
- a `Browse…` action validated by the same eligibility service;
- the existing ICNS picker after a compatible selection.

Replace helper copy with:

```swift
Text("MacICNS supports applications that your user account can modify safely.")
```

- [ ] **Step 5: Verify GREEN**

Run Step 2 again plus the existing file-selection test:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-catalog-derived \
  -allowProvisioningUpdates \
  -only-testing:MacICNSTests/ApplicationCatalogTests \
  -only-testing:MacICNSTests/MacICNSTests/testFileSelectionValidatorAcceptsOnlyExpectedExtensions
```

- [ ] **Step 6: Commit**

```bash
git add MacICNS/Services/ApplicationCatalog.swift MacICNS/UI/MappingListView.swift \
  MacICNSTests/ApplicationCatalogTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "feat: add compatible application catalog"
git push origin feature/macicns-v1
```

---

### Task 3: Silent Mapping Pruning and Direct-Only Repair

**Files:**
- Create: `MacICNS/Services/MappingEligibilityPruner.swift`
- Create: `MacICNSTests/MappingEligibilityPrunerTests.swift`
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNS/Services/DirectIconApplier.swift`
- Modify: `MacICNS/Services/RepairCoordinator.swift`
- Modify: `MacICNSTests/DirectIconApplierTests.swift`
- Modify: `MacICNSTests/RepairCoordinatorTests.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ApplicationEligibilityChecking` and existing `ApplicationLocating`.
- Produces: `MappingEligibilityPruner.prune(_:) -> [IconMapping]`.
- Removes: `IconApplierRouter`; production uses `DirectIconApplier` only.

- [ ] **Step 1: Write failing pruning tests**

Cover compatible, protected, system, invalid, and missing mappings. A missing URL that resolves by bundle identifier to a compatible URL must be retained with its URL updated; one resolving to a protected URL must be removed.

```swift
func testPruneRemovesUnsupportedButRetainsMissingMappings() {
    let pruner = MappingEligibilityPruner(
        eligibility: EligibilityStub(results: [
            compatibleURL: .compatible,
            protectedURL: .protected,
            missingURL: .missing,
        ]),
        locator: LocatorStub(results: [:])
    )
    XCTAssertEqual(
        pruner.prune([compatibleMapping, protectedMapping, missingMapping]).map(\.id),
        [compatibleMapping.id, missingMapping.id]
    )
}
```

Add `testLaunchSilentlyPersistsOnlySupportedMappings` to `MacICNSTests.swift`. It must assert one repository save, no `operationError`, and only compatible/missing mapping IDs.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-pruning-derived \
  -allowProvisioningUpdates \
  -only-testing:MacICNSTests/MappingEligibilityPrunerTests \
  -only-testing:MacICNSTests/MacICNSTests/testLaunchSilentlyPersistsOnlySupportedMappings
```

Expected: compile failure because `MappingEligibilityPruner` is absent.

- [ ] **Step 3: Implement the pure pruner**

For each mapping, classify its current URL. For `.missing`, try `ApplicationLocating.resolve` using the bundle identifier and reclassify the resolved URL. Keep `.compatible`; keep unresolved `.missing`; remove `.protected`, `.systemApplication`, and `.invalid`. Return values only, with no persistence or UI side effects.

- [ ] **Step 4: Integrate pruning into AppState**

Inject the pruner and apply it:

- after repository load and before monitoring;
- before inserting a new mapping;
- after single repair, bulk refresh, monitor callbacks, and relocation;
- before saving collections produced by those operations.

Persist when pruning changes the collection. Do not set any alert or error string for this removal.

- [ ] **Step 5: Make icon application direct-only**

Delete `IconApplierRouter` and set AppState's production default to:

```swift
repairCoordinator: RepairCoordinator = RepairCoordinator(applier: DirectIconApplier())
```

Delete tests expecting protected apps to route to a helper. Keep tests proving unwritable targets fail before `NSWorkspace.setIcon`.

In `RepairCoordinator`, replace helper-specific failure categories with:

```swift
enum Category: Equatable, Sendable {
    case permission
    case other
}
```

Use `The application is no longer writable.` for direct permission failures. Remove references to privileged path and metadata writer types.

- [ ] **Step 6: Verify GREEN**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-pruning-derived \
  -allowProvisioningUpdates \
  -only-testing:MacICNSTests/MappingEligibilityPrunerTests \
  -only-testing:MacICNSTests/DirectIconApplierTests \
  -only-testing:MacICNSTests/RepairCoordinatorTests \
  -only-testing:MacICNSTests/MacICNSTests
```

Expected: all selected suites pass without helper-routing expectations.

- [ ] **Step 7: Commit**

```bash
git add MacICNS/App/AppState.swift MacICNS/Services/ApplicationEligibilityService.swift \
  MacICNS/Services/MappingEligibilityPruner.swift MacICNS/Services/DirectIconApplier.swift \
  MacICNS/Services/RepairCoordinator.swift MacICNSTests/MappingEligibilityPrunerTests.swift \
  MacICNSTests/DirectIconApplierTests.swift MacICNSTests/RepairCoordinatorTests.swift \
  MacICNSTests/MacICNSTests.swift MacICNS.xcodeproj/project.pbxproj
git commit -m "refactor: limit mappings to writable applications"
git push origin feature/macicns-v1
```

---

### Task 4: Remove Privileged Helper Product and Permissions

**Files:**
- Delete: `MacICNSHelper/`
- Delete: `Resources/LaunchDaemons/com.guigx.macicns.helper.plist`
- Delete: `MacICNS/Services/PrivilegedHelperClient.swift`
- Delete: `MacICNS/Services/HelperInstallationService.swift`
- Delete: `Shared/CodeSigningRequirements.swift`
- Delete: `Shared/IconApplyRequest.swift`
- Delete: `Shared/IconDataReader.swift`
- Delete: `Shared/IconHelperXPCProtocol.swift`
- Delete: `Shared/PrivilegedIconOperation.swift`
- Delete: `Shared/PrivilegedPathValidator.swift`
- Delete: `Shared/StableApplicationIconWriter.swift`
- Delete: `MacICNSTests/IconApplyRequestTests.swift`
- Delete: `MacICNSTests/PrivilegedIconWriterTests.swift`
- Modify: `MacICNS/App/MacICNSApp.swift`
- Modify: `MacICNS/App/AppState.swift`
- Modify: `MacICNS/App/Info.plist`
- Modify: `MacICNS/Services/Repairing.swift`
- Modify: `MacICNSTests/MacICNSTests.swift`
- Modify: `MacICNS.xcodeproj/project.pbxproj`

**Interfaces:**
- Removes: helper target, privileged XPC, daemon resources, lifecycle state, and `.helperUpdated`.
- Preserves: app/test targets, `DirectIconApplier`, `LoginItemService`, menu refresh, and Launch settings.

- [ ] **Step 1: Write failing bundle-layout tests**

Replace the daemon association test with:

```swift
func testBuiltApplicationContainsNoPrivilegedHelper() {
    let root = Bundle.main.bundleURL
    XCTAssertFalse(FileManager.default.fileExists(atPath:
        root.appending(path: "Contents/Library/LaunchServices/com.guigx.macicns.helper").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath:
        root.appending(path: "Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist").path))
}

func testApplicationDoesNotDeclareAppManagementUsage() {
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSAppBundlesUsageDescription"))
}
```

- [ ] **Step 2: Run layout tests and verify RED**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-no-helper-derived \
  -allowProvisioningUpdates \
  -only-testing:MacICNSTests/MacICNSTests/testBuiltApplicationContainsNoPrivilegedHelper \
  -only-testing:MacICNSTests/MacICNSTests/testApplicationDoesNotDeclareAppManagementUsage
```

Expected: failure because helper artifacts and App Management copy remain.

- [ ] **Step 3: Remove helper state and settings UI**

Delete helper properties and install/update/open-settings methods from AppState. Remove the entire `Privileged Helper` settings section, retaining Launch settings. Remove `NSAppBundlesUsageDescription` and advance the app build number once.

- [ ] **Step 4: Remove helper files, target, dependency, and copy phases**

Delete all files listed above. In `project.pbxproj`, remove the `MacICNSHelper` target/configurations, the app dependency on it, helper source references, helper/daemon Copy Files entries, and deleted test references. Keep `Apple Development` signing for the app target.

- [ ] **Step 5: Remove remaining helper vocabulary**

Remove `.helperUpdated` from `RepairReason` and update callers to existing reasons. Run:

```bash
rg -n 'PrivilegedHelper|MacICNSHelper|helperUpdated|Set Up Helper|App Management|NSAppBundlesUsageDescription|com\.guigx\.macicns\.helper' \
  . --glob '!docs/**' --glob '!.superpowers/**' --glob '!.git/**'
```

Expected: no matches. Remove empty helper directories.

- [ ] **Step 6: Run full verification**

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-final-derived \
  -allowProvisioningUpdates
xcodebuild build -project MacICNS.xcodeproj -scheme MacICNS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/macicns-final-derived \
  -allowProvisioningUpdates
test ! -e /private/tmp/macicns-final-derived/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchServices/com.guigx.macicns.helper
test ! -e /private/tmp/macicns-final-derived/Build/Products/Debug/MacICNS.app/Contents/Library/LaunchDaemons/com.guigx.macicns.helper.plist
codesign --verify --deep --strict --verbose=4 /private/tmp/macicns-final-derived/Build/Products/Debug/MacICNS.app
plutil -lint MacICNS.xcodeproj/project.pbxproj
git diff --check
```

Expected: tests/build succeed and every subsequent command exits 0.

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "refactor: remove privileged icon helper"
git status --short --branch
git push origin feature/macicns-v1
```

Expected: clean worktree and all four implementation commits on the remote branch.
