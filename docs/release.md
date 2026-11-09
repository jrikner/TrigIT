# Signing and notarizing TrigIT

`scripts/sign-and-notarize.sh` builds `build/TrigIT.app` (universal), signs it with your Developer ID under the hardened runtime, sends it to Apple's notary service, staples the ticket, and leaves `build/TrigIT.zip` to hand out. A Mac that opens it shows no Gatekeeper warning.

## One-time setup

1. **Developer ID certificate.** In an Apple Developer Program account (Account Holder role), create a *Developer ID Application* certificate: Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application. Check it is in your login keychain:

   ```sh
   security find-identity -v -p codesigning
   ```

   Note the full name, e.g. `Developer ID Application: Jane Doe (AB12CD34EF)`.

2. **Notary credentials.** Create an app-specific password at <https://account.apple.com> (Sign-In and Security → App-Specific Passwords), then store it in the keychain under the profile name `TrigIT`:

   ```sh
   xcrun notarytool store-credentials TrigIT --apple-id you@example.com --team-id AB12CD34EF
   ```

   It prompts for the app-specific password. Nothing secret goes in the repo or the environment.

3. **Bundle identifier (optional).** The app is `com.ncoab.trigit` unless you set `TRIGIT_BUNDLE_ID`. Keep it: macOS ties microphone permission and saved settings to it.

   Release notes for the first build with `com.ncoab.trigit` must say: builds before it used `com.trigit.TrigIT`, so macOS asks for microphone access again, and the recent Sets list, Learn settings and the sACN source ID start fresh. Rerun `scripts/install-launch-agent.sh` to move the launch agent to the new label; it removes the old one.

## Each release

```sh
export TRIGIT_SIGNING_IDENTITY="Developer ID Application: Jane Doe (AB12CD34EF)"
TRIGIT_VERSION=1.0 scripts/sign-and-notarize.sh
```

`TRIGIT_NOTARY_PROFILE` overrides the keychain profile name (default `TrigIT`). Notarization usually takes a few minutes; if it is rejected, see why with `xcrun notarytool log <submission-id> --keychain-profile TrigIT`.

## Releasing from GitHub

`.github/workflows/release.yml` runs `scripts/sign-and-notarize.sh` on a macOS runner whenever a tag starting with `v` is pushed. It then publishes a GitHub Release with `TrigIT.zip`, `TrigIT.zip.sha256` and generated release notes:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

A tag with a `-` (`v0.9.0-beta.1`) is marked as a pre-release. The app's version is the tag's numbers only (`0.9.0`), because macOS expects digits and dots there.

The workflow needs these repository secrets (Settings → Secrets and variables → Actions). It stops at the start and names each one that is missing. The quickest way to set them is the wizard: it walks you through exporting the certificate and making the app-specific password, checks the password with Apple, and uploads all five with `gh`:

```sh
scripts/setup-release-secrets.sh
```

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The *Developer ID Application* certificate and its private key, exported from Keychain Access as a `.p12`, then base64-encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you gave the `.p12` when exporting it |
| `NOTARY_APPLE_ID` | The Apple ID email of the developer account |
| `NOTARY_TEAM_ID` | The 10-character team ID, e.g. `AB12CD34EF` |
| `NOTARY_APP_PASSWORD` | An app-specific password for that Apple ID (step 2 above) |

## Entitlements

`scripts/TrigIT.entitlements` grants audio input under the hardened runtime, for LTC. TrigIT is not sandboxed, so network and MIDI need no entitlement.
