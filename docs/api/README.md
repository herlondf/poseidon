# Generated API reference

This folder generates a browsable **HTML** API reference from the source
doc-comments of Poseidon's public units, using
[PasDoc](https://pasdoc.github.io/).

## Generate

```powershell
pwsh docs/api/gen-api.ps1
# or, if pasdoc.exe is not on PATH:
pwsh docs/api/gen-api.ps1 -PasDoc "C:\tools\pasdoc\bin\pasdoc.exe"
```

Output lands in `docs/api/html/` (git-ignored — regenerate locally or in CI).

The unit list in `gen-api.ps1` mirrors the public surface documented in
[`docs/API-REFERENCE.md`](../API-REFERENCE.md). When you add or remove a public
unit or middleware, update both.

## Prefer prose?

The hand-maintained, single-page reference at
[`docs/API-REFERENCE.md`](../API-REFERENCE.md) covers the same surface with
usage notes and does not require PasDoc.
