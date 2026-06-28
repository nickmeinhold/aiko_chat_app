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

Zero-cost stand-in for the GitHub Actions workflow (`.github/workflows/ci.yml`),
which is billing-blocked (we don't pay for Actions minutes). It runs the **same**
`flutter analyze --no-fatal-infos` + `flutter test` checks before every push, so
red code never reaches origin — the enforced merge gate for this solo-author repo.

- Errors + warnings are fatal; the intentional `prefer_initializing_formals` infos are not.
- `flutter test` runs `test/` only (fast, device-free). `integration_test/` needs a
  real device and is exercised separately as on-device e2e.
- Branch-deletion pushes are skipped (nothing to test).
- Emergency bypass: `git push --no-verify`.

If automated CI is ever restored cheaply (self-hosted runner / free tier), `ci.yml`
remains the canonical spec and this hook becomes defense-in-depth.
