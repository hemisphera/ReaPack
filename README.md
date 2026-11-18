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

`index.xml` is maintained with [reapack-index](https://github.com/cfillion/reapack-index):

```sh
gem install reapack-index
reapack-index --commit   # scan history, update index.xml and commit it
```

## Packages built from GitHub releases

Binary packages (e.g. REAPER extensions) are not stored here; their index
entries point at the assets of the upstream GitHub release. They are configured
in `tools/sources.json` (repo, category, package name, asset → platform map)
and updated with:

```powershell
./tools/Update-FromRelease.ps1                         # add the latest release of every source
./tools/Update-FromRelease.ps1 ReapletonLink           # just one source
./tools/Update-FromRelease.ps1 ReapletonLink -Tag v1.0.0 -Force   # (re)index a specific tag
./tools/Update-FromRelease.ps1 -DryRun                 # print the resulting index.xml
./tools/Update-FromRelease.ps1 -Commit                 # also commit index.xml
```

Releases already in the index are skipped. Requires PowerShell 7+. Set `$env:GITHUB_TOKEN` to avoid API rate limits.

## Importing in REAPER

Extensions → ReaPack → Import repositories… and paste the raw URL of
`index.xml` (e.g. `https://raw.githubusercontent.com/<user>/<repo>/main/index.xml`).
