# Git hooks

Repo-managed git hooks. They live here (version-controlled, reviewable) rather than
in the un-tracked `.git/hooks/`.

## Install (one line, from repo root)

```sh
git config core.hooksPath tool/git-hooks
```

That points git at this directory. `core.hooksPath` is local config, so each clone
runs it once. To confirm: `git config core.hooksPath` → `tool/git-hooks`.

## `pre-push` — the local CI gate

A fast, offline-friendly mirror of the GitHub Actions workflow
(`.github/workflows/ci.yml`), which **does run** — the repo is public, so its
ubuntu-runner minutes are free (we still don't pay for billed macOS runners,
which is why the SwiftPM check below is text-only). This hook runs the **same**
`dart run tool/check_swiftpm_lockfile.dart` + `flutter analyze --no-fatal-infos` +
`flutter test` checks locally before every push, so red code never reaches origin
even before CI weighs in — defense-in-depth for this solo-author repo, not a
stand-in for absent CI.

- The SwiftPM lockfile gate (task #1909) catches a committed `Package.resolved` left
  pinning a removed package — a "false green" where tests pass on a stale artifact
  (PR #69). Text-only, so it runs identically on the ubuntu CI runner and here.
- Errors + warnings are fatal; the intentional `prefer_initializing_formals` infos are not.
- `flutter test` runs `test/` only (fast, device-free). `integration_test/` needs a
  real device and is exercised separately as on-device e2e.
- Branch-deletion pushes are skipped (nothing to test).
- Emergency bypass: `git push --no-verify`.

If automated CI is ever restored cheaply (self-hosted runner / free tier), `ci.yml`
remains the canonical spec and this hook becomes defense-in-depth.
