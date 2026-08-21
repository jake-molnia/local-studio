# Repository workflow

## Branches

`main` is the only long-lived branch. Create one feature branch for each body
of work and open a pull request directly into `main`. Never push commits
directly to `main`.

Keep `upstream` pointed at `sybil-solutions/local-studio` and `origin` pointed
at `jake-molnia/local-studio`. Bring upstream changes into a feature branch,
validate them, and merge them through a pull request.

## Commits and gates

Use conventional commit subjects. Before pushing, run:

```bash
npm run check
```

GitHub CI repeats the repository gates and creates an unsigned exact-commit
desktop artifact. Required CI checks must pass before a pull request is merged.

## Releases

Merging to `main` never releases automatically. To release the current `main`
commit, choose the next semantic version and push an exact `vX.Y.Z` tag:

```bash
git checkout main
git pull --ff-only origin main
git tag v2.16.0
git push origin v2.16.0
```

The release workflow rejects malformed tags and tags that do not point to the
current `origin/main`. It builds the app, signs it with the fork's Developer ID,
notarizes it with Apple, publishes the GitHub release assets, and updates the
stable download alias used by the app.

The `release-signing` GitHub environment must provide
`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, and either the Apple API
key credential trio or the Apple ID notarization credential trio expected by
the release workflow.

The first fork-signed build must be installed manually over the upstream-signed
application. Later fork releases update in place from
`jake-molnia/local-studio`.
