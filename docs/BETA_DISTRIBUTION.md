# Sawti beta distribution and updates

Sawti beta builds use a direct GitHub DMG and Sparkle for later updates. Beta
releases do not require an Apple Developer ID certificate, provisioning profile,
Apple ID, or notarization credentials. The beta workflow ad-hoc signs the app
without a Developer ID identity, and macOS may show a Gatekeeper warning on
first launch.

## Set up the repository once

Add these GitHub Actions repository secrets before publishing a beta:

- `SPARKLE_PUBLIC_ED_KEY` — the public EdDSA key embedded in Sawti.
- `SPARKLE_ED_PRIVATE_KEY` — the matching private key used by Sparkle to sign
  each update archive and appcast.

These are Sparkle update-signing keys, separate from Apple Developer ID
credentials. Keep the private key only in GitHub Secrets and a secure backup.
The workflow stops if either key is missing.

## Publish a beta

Push a version tag such as `v0.8.2-beta.1`. The release workflow builds an
unnotarized DMG, creates a Sparkle-signed update archive, publishes a GitHub
pre-release, and updates the rolling `beta-feed` branch. Successive beta tags
must increment their numeric suffix (`beta.1`, `beta.2`, and so on); stable
versions sort after beta versions of the same release.

Beta releases use the DMG directly. The Homebrew signing, provisioning-profile,
and cask update gates remain on the stable release path.

## Install and update as a tester

1. Download the DMG from the GitHub beta release and move `Sawti.app` to
   `/Applications`.
2. On first launch, macOS may block the ad-hoc-signed app. After trying to open it,
   use **System Settings → Privacy & Security → Open Anyway** (or Finder's
   **Open** action if macOS offers it).
3. In Sawti's **Settings → About**, leave **Automatic Updates** enabled. Sawti
   checks and downloads updates in the background. Sparkle installs a downloaded
   update when you quit Sawti, then relaunches it. Use **Check Now** and
   **Install & Restart** for a manual update.

Sawti blocks update checks while it is recording or processing audio. An
existing beta installation can move to the stable release through the same
update flow when the stable release is published. A beta build always uses the
rolling beta feed; stable builds use the stable release feed unless
**Include Pre-Releases** is enabled.

## Beta limitations

- The first install needs the manual DMG and may need a one-time Gatekeeper
  override. Sparkle handles later downloads and installation.
- Without Apple's restricted time-sensitive notification entitlement, browser
  meeting consent alerts may be suppressed while Focus is enabled. Stable
  releases retain the existing Developer ID and provisioning-profile gate.
- The feed and archive signatures protect update authenticity; they do not
  Developer ID-sign or notarize the app, or remove the first-install
  Gatekeeper warning.

Before sharing a beta, verify the GitHub Actions release succeeded and the
`beta-feed` branch contains the generated `appcast.xml`. Then test one update
from a previous beta on a Mac with the same install location.
