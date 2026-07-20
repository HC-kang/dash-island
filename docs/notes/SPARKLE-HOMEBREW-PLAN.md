# Sparkle + Homebrew plan (deferred scaffold)

**Status:** not wired in the app yet — inventory R01/R02.  
**When:** before first public install base (friends+ / Product Hunt / brew).  
**DNA:** `codex-island` `docs/SPARKLE.md` + `release.sh` / `Casks/codexisland.rb`.

## Do not rush

Sparkle key mistakes brick auto-update for every existing install. Copy codex-island hard rules:

1. `VERSION` is monotonic semver used as **both** `CFBundleVersion` and short version.
2. EdDSA **public** key in build once; never rotate casually.
3. Private key only in Keychain + CI secret.
4. Never hand-edit appcast XML.
5. Never commit `Vendor/Sparkle` binaries if gitignored — CI re-vendors.

## App pieces (when implementing)

| Piece | Notes |
|-------|--------|
| Bundle id | Locked `dev.dashisland.DashIsland` before first Sparkle ship |
| `build.sh` | Embed Sparkle.framework, inject `SUFeedURL` + `SUPublicEDKey` |
| `UpdaterController` | Thin `SPUStandardUpdaterController` (port from codex-island) |
| Prefs toggle | “Check for updates automatically” |
| `release.sh` | Sign DMG, generate appcast, `gh release` |
| GitHub secrets | `SPARKLE_ED_PRIVATE_KEY`, optional `HOMEBREW_TAP_TOKEN` |
| Cask | `homebrew-tap` mirror with postflight `xattr -dr` quarantine strip |

## Homebrew

- Private/public tap e.g. `user/homebrew-tap`
- Cask installs unsigned app; postflight strips quarantine (Homebrew removed `--no-quarantine`)
- CI rewrites version + sha256 on release — do not hand-bump forever

## Preflight checklist

- [ ] Generate EdDSA keypair once; store private offline + CI
- [ ] Land appcast URL (GitHub Releases asset)
- [ ] Smoke: lower local VERSION, serve appcast, Check Now
- [ ] Document in public `docs/SPARKLE.md` (promote from notes when shipping)

Until then: ship via ad-hoc `build.sh` + drag-to-Applications for dogfood.
