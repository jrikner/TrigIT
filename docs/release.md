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

3. **Bundle identifier (optional).** The app is `com.trigit.TrigIT` unless you set `TRIGIT_BUNDLE_ID`. Pick it once and keep it: macOS ties microphone permission and saved settings to it.

## Each release

```sh
export TRIGIT_SIGNING_IDENTITY="Developer ID Application: Jane Doe (AB12CD34EF)"
TRIGIT_VERSION=1.0 scripts/sign-and-notarize.sh
```

`TRIGIT_NOTARY_PROFILE` overrides the keychain profile name (default `TrigIT`). Notarization usually takes a few minutes; if it is rejected, see why with `xcrun notarytool log <submission-id> --keychain-profile TrigIT`.

## Entitlements

`scripts/TrigIT.entitlements` grants audio input under the hardened runtime, for LTC. TrigIT is not sandboxed, so network and MIDI need no entitlement.
