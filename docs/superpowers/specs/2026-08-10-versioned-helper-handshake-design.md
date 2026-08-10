# Versioned Privileged Helper Handshake

## Problem

MacICNS currently treats `SMAppService.Status.enabled` as proof that the bundled privileged helper is current and operational. During development, macOS can register a new daemon process while continuing to execute a cached helper whose bundle version is unchanged. The UI then reports “Helper is installed” even though the running helper uses an obsolete protocol and cannot perform the current icon-writing flow.

## Decision

MacICNS will version the helper protocol and verify the running helper over XPC. Registration status alone will no longer mean that the helper is ready.

The app and helper bundle versions will advance from build `1` to build `2`. The XPC protocol will expose a lightweight handshake returning a fixed protocol version. The app will consider the helper operational only when:

1. `SMAppService` reports the daemon as enabled.
2. An authenticated XPC connection succeeds.
3. The helper reports the protocol version expected by the app.

## Components

### Shared protocol contract

`IconHelperXPCProtocol` will add a handshake method that returns an integer protocol version. A shared constant will define the version expected by both targets. The value is independent of marketing version strings and changes only when the XPC contract or required helper behavior changes.

### Helper service

The helper will answer the handshake through the same code-signing-validated XPC connection used for icon operations. No privileged filesystem action occurs during a handshake.

### Helper client and installation service

The app-side helper client will expose an asynchronous health check. `HelperInstallationService` remains responsible for `SMAppService` registration, while `AppState` combines registration status with the health result for presentation and routing.

After install or update, MacICNS will wait until the expected protocol version responds before declaring success or reapplying mappings. A stale or unreachable helper will produce `Update Required` or an actionable update failure, never `Installed`.

### Update flow

The update sequence is:

1. Unregister the existing daemon and await completion.
2. Re-register with bounded retries for the known transient Service Management error.
3. Poll the authenticated handshake for a bounded period.
4. Declare success and reapply enabled mappings only after the expected protocol version responds.

The existing Install action uses the same readiness check after registration. The UI must not rely on a delayed manual status refresh to become correct.

## Error handling

- Enabled registration plus matching handshake: `Helper is installed.`
- Enabled registration plus stale version: `Helper update required.`
- Enabled registration plus unreachable XPC service: helper unavailable with a retry/update action.
- Registration requiring approval: preserve the existing System Settings guidance.
- Update registration timeout: keep the current actionable error, but do not display the helper as operational.

Detailed icon-write errors remain separate from helper readiness errors.

## Testing

Tests will cover:

- Matching, stale, and unreachable handshake results.
- Installed presentation only for a matching helper.
- Install/update waiting for the expected version before success.
- No icon reapply when the handshake is stale or unavailable.
- Successful update reapplies enabled mappings after readiness is confirmed.
- Secure XPC reply completion and connection invalidation.
- Full test suite, signed Debug build, embedded helper layout, and deep code-sign verification.

## Scope boundaries

This change fixes helper lifecycle truthfulness and cached-version replacement. It does not attempt to modify apps on the sealed system volume; apps such as Find My remain unsupported. The final protected-app write verification will use root-owned apps on the writable data volume, including Amphetamine and Xcode.
