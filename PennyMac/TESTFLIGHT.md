# Penny — Ship to TestFlight / Mac App Store (P5)

Everything the signing pipeline needs is **already in place and verified** (2026-07-18):

| Thing | Value | Status |
|---|---|---|
| Team ID | `P4ANR778GY` (ANIMESH MISHRA) | ✅ |
| Bundle ID | `com.localbankrag.app` | ✅ |
| App Store app | "Penny AI - Confidant" · App ID `6790839403` | ✅ (exists) |
| Distribution cert | `Apple Distribution: ANIMESH MISHRA (P4ANR778GY)` | ✅ in keychain |
| Installer cert | `3rd Party Mac Developer Installer: … (P4ANR778GY)` | ✅ in keychain |
| Provisioning profile | `Penny Mac App Store` → `build/embedded.provisionprofile` | ✅ valid until **2027-07-14** |
| Sandbox | App Sandbox ON, no Hardened Runtime (correct for MAS) | ✅ |
| Version | `CFBundleShortVersionString` 1.1.0 · `CFBundleVersion` 1.1.0 | ✅ (bump build # per upload) |
| Encryption | `ITSAppUsesNonExemptEncryption = false` | ✅ (no compliance prompt) |

Signing is configured **per-config** in `project.yml`:
- **Debug** → Automatic (dev), `Penny.entitlements` — run this day to day.
- **Release** → **Manual**, `Apple Distribution` + `Penny Mac App Store` profile + `Penny-dist.entitlements`.
  Uses the certs/profile already in the keychain, so **no Apple-ID login is required to archive.**

> The provisioning profile must be installed where Xcode looks:
> `cp build/embedded.provisionprofile ~/Library/MobileDevice/Provisioning\ Profiles/` (Xcode 15) or
> just double-click it once. Xcode 16+ also accepts it from the project.

---

## Path A — Xcode GUI (recommended, simplest)

1. `cd PennyMac && xcodegen generate` (only if `project.yml` changed).
2. `open Penny.xcodeproj`. If prompted, **Trust & Enable** the package macros once, and
   `xcodebuild -downloadComponent MetalToolchain` if the Metal compiler isn't installed.
3. Set the active scheme to **Penny**, destination **Any Mac**.
4. **Product ▸ Archive** (this builds the Release config → App Store signing).
5. In the Organizer: **Distribute App ▸ App Store Connect ▸ Upload** → keep defaults → **Upload**.
6. Wait for the build to finish processing in App Store Connect (email arrives), then add it to a
   **TestFlight** group. Testers install via the TestFlight app.

## Path B — Command line (scriptable)

```bash
cd PennyMac
xcodegen generate

# 1. Archive (Release → manual App Store signing)
xcodebuild -project Penny.xcodeproj -scheme Penny -configuration Release \
  -skipMacroValidation -skipPackagePluginValidation \
  -archivePath build/Penny.xcarchive archive

# 2. Export a signed .pkg for the App Store (uses ExportOptions.plist)
xcodebuild -exportArchive \
  -archivePath build/Penny.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export

# 3. Upload to App Store Connect / TestFlight
#    (needs an app-specific password or an API key — see below)
xcrun altool --upload-app -f build/export/Penny.pkg -t macos \
  --apple-id "<your-appstore-connect-email>" --password "<app-specific-password>"
#  …or the modern notary/altool replacement:
#  xcrun altool --validate-app  (dry run first)
```

**App-specific password:** appleid.apple.com ▸ Sign-In & Security ▸ App-Specific Passwords.
Or use an App Store Connect **API key** (`--apiKey`/`--apiIssuer`) for CI.

---

## First-upload gotchas
- **Build number must be unique & increasing** per upload. Bump `CFBundleVersion` in `project.yml`
  (`info.properties.CFBundleVersion`) before each new archive; `CFBundleShortVersionString` only when
  the user-facing version changes.
- If the archive shows up as a **generic Xcode archive** (not a Mac app) in the Organizer, the
  `Skip Install`/product type is off — re-run `xcodegen generate` and archive the **Penny** scheme.
- Mac App Store requires a **.pkg** (the export step produces it) — you can't drag a `.app` to
  App Store Connect.
- If signing fails with "no profile matching", double-click `build/embedded.provisionprofile` to
  install it, and confirm the identity name matches `security find-identity -v -p codesigning`.

## What I could NOT verify here
The **archive/upload** itself needs your machine + Apple ID / app-specific password — it can't run
headless in this environment. I *did* validate that the Release config **compiles and code-signs**
with the manual Apple Distribution identity + profile, which is the part that usually breaks. The
archive → upload should follow straightforwardly from Path A.
