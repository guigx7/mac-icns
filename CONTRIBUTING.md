# Contributing to MacICNS

Thanks for considering a contribution.

## Local development

MacICNS targets Apple Silicon Macs running macOS 14 or later. Open `MacICNS.xcodeproj` in Xcode, or run the full test suite from the repository root:

```bash
xcodebuild test -project MacICNS.xcodeproj -scheme MacICNS \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/macicns-tests \
  CODE_SIGNING_ALLOWED=NO
```

Use an isolated derived-data directory as shown above. Tests must not read or modify your production MacICNS mappings.

## Making a change

1. Open an issue first for a substantial feature or behavior change.
2. Keep each pull request focused on one outcome.
3. Add or update tests when changing application behavior.
4. Run the relevant tests before opening a pull request.
5. Use a concise conventional commit message, such as `feat: add icon import validation` or `fix: preserve mapping state`.

## Sensitive and personal data

Never commit or attach user mappings, diagnostics, credentials, certificates, signing identities, Apple credentials, or private keys. Do not add third-party `.icns` files unless you have permission to redistribute them.

For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
