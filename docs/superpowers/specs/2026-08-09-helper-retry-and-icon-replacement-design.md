# Helper Retry and Icon Replacement Design

## Scope

This change addresses two focused behaviors:

1. Updating an installed privileged helper must not leave it uninstalled when macOS temporarily rejects re-registration after removal.
2. An existing mapping must allow its ICNS file to be replaced without deleting and recreating the mapping.

The broader interface redesign remains out of scope.

## Evidence and Root Cause

During a helper update, `SMAppService.unregister` completes and `SMAppService.status` immediately reports `notRegistered`. However, unified system logs show that `backgroundtaskmanagementd` still records the daemon as enabled for a short period. A registration attempt during that interval fails with `SMAppServiceErrorDomain` code `1` (`Operation not permitted`). A separate registration a few seconds later succeeds.

The public status is therefore not a reliable readiness boundary for immediate re-registration on this macOS version.

## Considered Approaches

### Helper update

- **Bounded registration retry (selected):** Retry only the observed transient ServiceManagement error until registration succeeds or a short deadline expires. This preserves a one-click update and responds to the actual readiness condition.
- **Fixed delay:** Wait several seconds before registering. This is simpler but guesses at timing and can remain flaky under load.
- **Two-click update:** Remove the helper and require the user to click Install Helper afterward. This works around the race but creates a confusing and incomplete update flow.

### Icon replacement

- **Direct row action (selected):** Add a compact change-icon button beside refresh. It opens an ICNS-only file picker at the last-used icon directory and updates that mapping in place.
- **Reuse the full mapping editor:** This adds unnecessary application selection for an operation that changes only one field.
- **Context menu only:** This saves horizontal space but makes an important action difficult to discover.

## Helper Update Behavior

The update flow will:

1. Unregister the existing helper and wait for that operation to complete.
2. Attempt registration.
3. If registration fails with the specific transient `SMAppServiceErrorDomain` code `1`, wait briefly and retry until a bounded deadline.
4. Propagate every other error immediately.
5. If the transient condition persists beyond the deadline, return a clear update failure while leaving Install Helper available.
6. After successful registration, refresh helper status and reapply enabled mappings exactly once.

The retry loop will be cancellation-aware and injectable in tests so the suite does not rely on wall-clock delays.

## Icon Replacement Behavior

Each mapping row will show a `Change Icon` button immediately to the right of the refresh action. For mappings that require the helper, the existing helper setup action remains visible and the change-icon button remains independently available.

Selecting a new valid `.icns` file will:

- preserve the mapping ID, application URL, bundle identifier, and enabled state;
- update the stored icon URL;
- clear stale icon fingerprints and success metadata;
- remember the selected file's parent as the next icon-picker directory;
- immediately apply the new icon when the mapping is enabled;
- only persist the new selection when the mapping is disabled, leaving the original application icon untouched;
- keep the previous icon URL if selection is cancelled or the replacement cannot be applied to an enabled mapping.

The row remains disabled while its replacement is being processed, using the existing busy indicator and operation error alert.

## Error Handling

- Invalid or cancelled file selections do not change the mapping.
- A failed enabled replacement keeps the prior mapping and icon selection, then presents the sanitized existing operation error.
- Persistence failures continue to use the existing persistence alert.
- Helper registration diagnostics record retry exhaustion and final failure without exposing sensitive paths.

## Testing

Automated regression coverage will verify:

- helper registration retries after the transient ServiceManagement error and eventually succeeds;
- unrelated registration errors are not retried;
- retry exhaustion returns a stable user-facing error;
- enabled icon replacement applies first and persists only on success;
- failed enabled replacement preserves the previous mapping;
- disabled icon replacement persists the new ICNS without applying it;
- the row exposes a distinct accessible `Change icon` action;
- the full test suite and a fresh signed Debug build succeed.

## Success Criteria

- Repeated Update Helper operations no longer strand the helper in the uninstalled state under the reproduced delayed-removal condition.
- Users can replace an ICNS file from the mapping row without remapping the application.
- Disabled mappings remain disabled after replacement.
- Existing refresh, toggle, delete, monitoring, and persistence behavior remain intact.
