<#
.SYNOPSIS
    Updates index.xml from the JSFX in this repository and from the latest GitHub
    release of the configured package sources.

.DESCRIPTION
    JSFX: every file in jsfx/ (recursively) is a package. Its ReaPack header is read
    from the top of the file:

        desc:Package description
        // @author Name
        // @version 1.0
        // @changelog What changed
        //   (further lines indented by two or more spaces continue a tag)
        // @about Longer description

    The category is the folder relative to the repository root (e.g. "jsfx").
    Sources point at the file in the commit that last changed it, so the file must
    be committed (and pushed, for the URL to resolve); files with uncommitted
    changes are skipped. Versions already in the index are skipped unless -Force.

    Releases: sources are defined in tools/sources.json. For each source the script fetches
    the latest (or a given) GitHub release, downloads the configured assets to
    compute their SHA-256 hashes, and adds a new <version> to the package in
    index.xml that points at the release download URLs. Binaries are not copied
    into this repository. Versions already in the index are skipped unless -Force
    is given.

    Set $env:GITHUB_TOKEN to avoid GitHub API rate limits.

.EXAMPLE
    ./tools/Update-Index.ps1
.EXAMPLE
    ./tools/Update-Index.ps1 Noteholder -Force
.EXAMPLE
    ./tools/Update-Index.ps1 ReapletonLink -Tag v1.0.0 -Force
.EXAMPLE
    ./tools/Update-Index.ps1 -DryRun
#>
[CmdletBinding()]
param(
    # Release source names from sources.json and/or JSFX package names (default: all).
    [Parameter(Position = 0)]
    [string[]] $Source,
    # Use this release tag instead of the latest release (single release source only).
    [string] $Tag,
    # Replace the version if it already exists in the index.
    [switch] $Force,
    # Print the resulting index instead of writing it.
    [switch] $DryRun,
    # git commit index.xml if it changed.
    [switch] $Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$IndexPath = Join-Path $Root 'index.xml'
$SourcesPath = Join-Path $PSScriptRoot 'sources.json'
$JsfxDir = Join-Path $Root 'jsfx'
$Api = 'https://api.github.com'

function Get-GitHubHeaders {
    $headers = @{ 'User-Agent' = 'reapack-release-updater'; 'Accept' = 'application/vnd.github+json' }
    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    $headers
}

function Get-Release([string] $Repo, [string] $Tag) {
    $path = if ($Tag) { "releases/tags/$Tag" } else { 'releases/latest' }
    Invoke-RestMethod -Uri "$Api/repos/$Repo/$path" -Headers (Get-GitHubHeaders)
}

function Get-RemoteSha256([string] $Url) {
    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -Headers @{ 'User-Agent' = 'reapack-release-updater' } -UseBasicParsing | Out-Null
        (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-Version([string] $Tag) {
    if ($Tag -match '^[vV](\d.*)$') { $Matches[1] } else { $Tag }
}

function ConvertTo-Rtf([string] $Text) {
    '{\rtf1\ansi ' + ($Text -replace '([\\{}])', '\$1') + '}'
}

function Get-OrAddChild([System.Xml.XmlElement] $Parent, [string] $Tag, [string] $Name) {
    foreach ($el in $Parent.SelectNodes($Tag)) {
        if ($el.GetAttribute('name') -eq $Name) { return $el }
    }
    $el = $Parent.OwnerDocument.CreateElement($Tag)
    $el.SetAttribute('name', $Name)
    [void] $Parent.AppendChild($el)
    $el
}

function Add-TextElement([System.Xml.XmlElement] $Parent, [string] $Tag, [string] $Text, [switch] $CData) {
    $doc = $Parent.OwnerDocument
    $el = $doc.CreateElement($Tag)
    if ($CData) { [void] $el.AppendChild($doc.CreateCDataSection($Text)) }
    else { $el.InnerText = $Text }
    [void] $Parent.AppendChild($el)
    $el
}

function Update-Source([xml] $Index, [string] $Name, $Cfg) {
    $repo = $Cfg.github
    $release = Get-Release $repo $Tag
    if ($release.draft) { throw "$repo release $($release.tag_name) is a draft" }
    $version = ConvertTo-Version $release.tag_name
    Write-Host "${Name}: $repo release $($release.tag_name) -> version $version"

    $category = Get-OrAddChild $Index.DocumentElement 'category' $Cfg.category
    $pkg = Get-OrAddChild $category 'reapack' $Cfg.package
    $pkg.SetAttribute('type', $(if ($Cfg.PSObject.Properties['type']) { $Cfg.type } else { 'extension' }))
    $pkg.SetAttribute('desc', $(if ($Cfg.PSObject.Properties['description']) { $Cfg.description } else { $Name }))

    # Package metadata: about text + website link, rewritten on every run.
    $meta = $pkg.SelectSingleNode('metadata')
    if ($meta) { [void] $pkg.RemoveChild($meta) }
    $meta = $Index.CreateElement('metadata')
    [void] $pkg.PrependChild($meta)
    if ($Cfg.PSObject.Properties['about']) {
        [void] (Add-TextElement $meta 'description' (ConvertTo-Rtf $Cfg.about) -CData)
    }
    $link = Add-TextElement $meta 'link' "https://github.com/$repo"
    $link.SetAttribute('rel', 'website')

    $existing = @($pkg.SelectNodes('version') | Where-Object { $_.GetAttribute('name') -eq $version })
    if ($existing.Count -and -not $Force) {
        Write-Host "${Name}: version $version already in index, skipping"
        return $false
    }
    $existing | ForEach-Object { [void] $pkg.RemoveChild($_) }

    $assets = @{}
    foreach ($a in $release.assets) { $assets[$a.name] = $a }
    $missing = @($Cfg.assets.PSObject.Properties.Name | Where-Object { -not $assets.ContainsKey($_) })
    if ($missing.Count) { throw "release $($release.tag_name) lacks assets: $($missing -join ', ')" }

    $author = if ($Cfg.PSObject.Properties['author']) { $Cfg.author }
              elseif ($release.author) { $release.author.login }
              else { $repo.Split('/')[0] }
    $published = if ($release.published_at) { $release.published_at } else { $release.created_at }
    if ($published -is [datetime]) { $published = $published.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

    $ver = $Index.CreateElement('version')
    $ver.SetAttribute('name', $version)
    $ver.SetAttribute('author', $author)
    $ver.SetAttribute('time', $published)
    [void] $pkg.AppendChild($ver)

    $changelog = "$($release.body)".Trim()
    if ($changelog) { [void] (Add-TextElement $ver 'changelog' $changelog -CData) }

    foreach ($p in $Cfg.assets.PSObject.Properties) {
        $asset = $assets[$p.Name]
        $url = $asset.browser_download_url
        Write-Host "  downloading $($p.Name) ($($asset.size) bytes) for $($p.Value)"
        $src = Add-TextElement $ver 'source' $url
        $src.SetAttribute('platform', $p.Value)
        $src.SetAttribute('file', $p.Name)
        $src.SetAttribute('hash', '1220' + (Get-RemoteSha256 $url))  # multihash: sha2-256, 32 bytes
    }
    $true
}

# --- JSFX --------------------------------------------------------------------

function Get-JsfxFiles {
    if (-not (Test-Path $JsfxDir)) { return @() }
    @(Get-ChildItem -Path $JsfxDir -File -Recurse | Sort-Object FullName)
}

function Get-RelativePath([string] $Path) {
    [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

# Parses the ReaPack header: desc: line plus "// @tag value" comment lines.
function Read-JsfxHeader([string[]] $Lines) {
    $h = @{}
    $tag = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*desc:\s*(.*)$') {
            if (-not $h.ContainsKey('desc')) { $h['desc'] = $Matches[1].Trim() }
            $tag = $null
        }
        elseif ($line -match '^\s*//\s*@(\w+)\s*(.*)$') {
            $tag = $Matches[1].ToLowerInvariant()
            $h[$tag] = $Matches[2].TrimEnd()
        }
        elseif ($tag -and $line -match '^\s*//\s{2,}(.*)$') {
            $h[$tag] = ($h[$tag] + "`n" + $Matches[1].TrimEnd()).Trim()
        }
        elseif ($line -match '^\s*$' -or $line -match '^\s*//') { $tag = $null }
        elseif ($line -match '^\s*(@|slider\d|in_pin|out_pin|import|options|filename)') { break }
        else { $tag = $null }
    }
    $h
}

function Get-GitHubRepo {
    $url = git -C $Root remote get-url origin
    if ($LASTEXITCODE -ne 0 -or $url -notmatch 'github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$') {
        throw "cannot derive GitHub repository from origin remote '$url'"
    }
    $Matches[1]
}

function Update-Jsfx([xml] $Index, [System.IO.FileInfo] $File, [string] $Repo) {
    $rel = Get-RelativePath $File.FullName
    $name = $File.Name
    $categoryName = Split-Path -Parent $rel

    $status = git -C $Root status --porcelain -- $rel
    if ($status) { Write-Warning "${name}: $rel has uncommitted changes, skipping (commit it first)"; return $false }
    $commit = git -C $Root log -1 --format=%H -- $rel
    if (-not $commit) { Write-Warning "${name}: $rel is not committed, skipping"; return $false }
    $epoch = git -C $Root log -1 --format=%ct -- $rel
    $time = [DateTimeOffset]::FromUnixTimeSeconds([long] $epoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    # Hash the committed blob, not the working copy (line-ending conversion could differ).
    $tmp = New-TemporaryFile
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new('git', @('-C', $Root, 'cat-file', 'blob', "${commit}:$rel"))
        $psi.RedirectStandardOutput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $fs = [System.IO.File]::Create($tmp)
        $proc.StandardOutput.BaseStream.CopyTo($fs)
        $fs.Dispose()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "git cat-file failed for ${commit}:$rel" }
        $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        $header = Read-JsfxHeader (Get-Content -Path $tmp -TotalCount 100)
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    $version = $header['version']
    if (-not $version) { Write-Warning "${name}: no @version in header, skipping"; return $false }
    Write-Host "${name}: $rel @ $($commit.Substring(0, 7)) -> version $version"

    $category = Get-OrAddChild $Index.DocumentElement 'category' $categoryName
    $pkg = Get-OrAddChild $category 'reapack' $name
    $pkg.SetAttribute('type', 'effect')
    $desc = if ($header['description']) { $header['description'] } elseif ($header['desc']) { $header['desc'] } else { $name }
    $pkg.SetAttribute('desc', $desc)

    $meta = $pkg.SelectSingleNode('metadata')
    if ($meta) { [void] $pkg.RemoveChild($meta) }
    if ($header['about']) {
        $meta = $Index.CreateElement('metadata')
        [void] $pkg.PrependChild($meta)
        [void] (Add-TextElement $meta 'description' (ConvertTo-Rtf $header['about']) -CData)
    }

    $existing = @($pkg.SelectNodes('version') | Where-Object { $_.GetAttribute('name') -eq $version })
    if ($existing.Count -and -not $Force) {
        $old = $existing[0].SelectSingleNode('source')
        if ($old -and $old.GetAttribute('hash') -ne "1220$hash") {
            Write-Warning "${name}: file changed but version $version is already indexed; bump @version or use -Force"
        }
        else { Write-Host "${name}: version $version already in index, skipping" }
        return $false
    }
    $existing | ForEach-Object { [void] $pkg.RemoveChild($_) }

    $author = if ($header['author']) { $header['author'] } else { $Repo.Split('/')[0] }
    $ver = $Index.CreateElement('version')
    $ver.SetAttribute('name', $version)
    $ver.SetAttribute('author', $author)
    $ver.SetAttribute('time', $time)
    [void] $pkg.AppendChild($ver)
    if ($header['changelog']) { [void] (Add-TextElement $ver 'changelog' $header['changelog'] -CData) }

    $path = ($rel -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $src = Add-TextElement $ver 'source' "https://github.com/$Repo/raw/$commit/$path"
    $src.SetAttribute('hash', "1220$hash")  # multihash: sha2-256, 32 bytes
    $true
}

function Format-Index([xml] $Index) {
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.Xml.XmlWriter]::Create($stream, $settings)
    $Index.Save($writer)
    $writer.Dispose()
    # Trailing newline to match reapack-index output.
    [System.Text.Encoding]::UTF8.GetString($stream.ToArray()) + "`n"
}

# --- main --------------------------------------------------------------------

$sources = Get-Content -Raw $SourcesPath | ConvertFrom-Json
$releaseNames = @($sources.PSObject.Properties.Name)
$jsfxFiles = Get-JsfxFiles
$jsfxNames = @($jsfxFiles | ForEach-Object Name)
$known = $releaseNames + $jsfxNames
$names = if ($Source) { $Source } else { $known }
$unknown = @($names | Where-Object { $_ -notin $known })
if ($unknown.Count) { throw "unknown source(s): $($unknown -join ', ') (known: $($known -join ', '))" }
$selectedReleases = @($releaseNames | Where-Object { $_ -in $names })
$selectedJsfx = @($jsfxFiles | Where-Object { $_.Name -in $names })
if ($Tag -and ($selectedReleases.Count -ne 1 -or $selectedJsfx.Count)) { throw '-Tag requires exactly one release source' }

$index = [xml]::new()
$index.Load($IndexPath)

$updated = @(
    if ($selectedJsfx.Count) {
        $repo = Get-GitHubRepo
        foreach ($f in $selectedJsfx) { if (Update-Jsfx $index $f $repo) { $f.Name } }
    }
    foreach ($n in $selectedReleases) { if (Update-Source $index $n $sources.$n) { $n } }
)

$output = Format-Index $index
if ($DryRun) {
    Write-Output $output
    return
}
[System.IO.File]::WriteAllText($IndexPath, $output, [System.Text.UTF8Encoding]::new($false))

if ($Commit -and $updated.Count) {
    git -C $Root add index.xml
    git -C $Root diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        git -C $Root commit -m "Update index: $($updated -join ', ')"
    }
}
