Cask stub is at Casks/camhold.rb. Here's what you need to do to ship it.

  One thing to fix first: the bundle ID in Sources/CamHold/Resources/Info.plist is still com.example.CamHold. That's fine for local use but
   looks unprofessional in a public cask and collides with anyone else who also left the default. Change it to something you own (e.g.
  com.nigelpepper.CamHold or a reverse-DNS of a domain you control), rebuild, re-package, and update the two references in the cask's zap
  stanza to match. Do that before you cut the release so the sha256 is stable.

  Steps to publish:

  1. Create two GitHub repos under your account:
    - CamHold — the source repo (push the contents of this project directory).
    - homebrew-tap — your personal Homebrew tap. The homebrew- prefix is mandatory; Homebrew uses it to resolve brew tap <user>/tap.
  2. In homebrew-tap, place the cask at Casks/camhold.rb (same path/name as here). Replace YOUR_GH_USER with your GitHub username in both
  the url and homepage lines.
  3. Cut a release on the CamHold repo:
    - Tag v1.0.
    - Attach build/CamHold-1.0.dmg as a release asset.
    - The url in the cask already points at releases/download/v1.0/CamHold-1.0.dmg, which is the canonical GitHub Releases asset URL, so
  it'll just work.
  4. Verify locally before telling anyone else:
  brew tap YOUR_GH_USER/tap
  brew install --cask camhold
  brew audit --cask camhold   # catches common lint issues
  5. Users install with:
  brew install --cask YOUR_GH_USER/tap/camhold
  5. (The one-liner auto-taps if needed.)

  Why a personal tap and not the main homebrew-cask repo: homebrew-cask's main repo now requires apps to be signed with a Developer ID
  (i.e., the same $99 cert). Personal taps have no such rule, so your ad-hoc signed app is fine there. Users lose nothing — Homebrew still
  strips the quarantine attribute on install, so Gatekeeper doesn't block launch.

  For future versions: bump version, rebuild, re-run ./package-dmg.sh, shasum -a 256 the new DMG, update both fields in camhold.rb, cut a
  new GitHub release. That's the whole update loop.