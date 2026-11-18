# Hemisphera

Private [ReaPack](https://reapack.com) repository.

## Layout

Packages live in category folders (e.g. `Scripts/Category/My script.lua`), each
starting with a ReaPack metadata header:

```lua
-- @description My script
-- @author Your Name
-- @version 1.0
-- @changelog Initial release
```

## Updating the index

`index.xml` is updated with `tools/Update-Index.ps1` (PowerShell 7+), which
handles two kinds of packages:

- **JSFX** in `jsfx/`: each file is a package; its version, author, changelog
  and about text come from the ReaPack header at the top of the file:

  ```
  desc:My effect
  // @author hemisphera
  // @version 1.1
  // @changelog Fixed something
  //   (lines indented by 2+ spaces continue a tag)
  // @about Longer description
  ```

  Sources point at the file in the commit that last changed it, so commit (and
  push) the file before indexing it. Files with uncommitted changes are skipped.
  Bump `@version` for every change; the script warns if a file changed but its
  version is already indexed.

- **Binary packages built from GitHub releases** (e.g. REAPER extensions): not
  stored here; their entries point at the assets of the upstream GitHub release.
  They are configured in `tools/sources.json` (repo, category, package name,
  asset → platform map). Set `$env:GITHUB_TOKEN` to avoid API rate limits.

```powershell
./tools/Update-Index.ps1                          # index all JSFX and the latest release of every source
./tools/Update-Index.ps1 Noteholder,ReapletonLink # just these packages
./tools/Update-Index.ps1 ReapletonLink -Tag v1.0.0 -Force   # (re)index a specific release tag
./tools/Update-Index.ps1 -DryRun                  # print the resulting index.xml
./tools/Update-Index.ps1 -Commit                  # also commit index.xml
```

Versions already in the index are skipped unless `-Force` is given.

## Importing in REAPER

Extensions → ReaPack → Import repositories… and paste the raw URL of
`index.xml` (e.g. `https://raw.githubusercontent.com/<user>/<repo>/main/index.xml`).
