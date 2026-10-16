#requires -Version 5.0
<#
  Minecraft Java multi-version text UI launcher (Windows PowerShell 5.1)
  Run in a normal powershell.exe console (not the ISE):
      powershell -ExecutionPolicy Bypass -File .\MCLauncher-TUI-multi.ps1
  Keys: Up/Down or W/S move, PgUp/PgDn/Home/End jump, Enter select, Esc back.

  Layout (shared like the official launcher):
      <Root>\libraries, <Root>\assets            shared by all versions
      <Root>\versions\<id>\<id>.json/.jar/natives
      <Root>\instances\<id>                      per-version game dir (worlds, options)
#>
[CmdletBinding()]
param([string]$InstallDir)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
if ($Host.Name -match 'ISE') { throw 'The TUI needs a real console. Run it with powershell.exe, not the ISE.' }

# ------------------------------------------------------------------ paths / platform
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
    $InstallDir = Join-Path $here 'Minecraft'
}
$Root         = [IO.Path]::GetFullPath($InstallDir)
$LibraryRoot  = Join-Path $Root 'libraries'
$AssetRoot    = Join-Path $Root 'assets'
$AssetIdxRoot = Join-Path $AssetRoot 'indexes'
$AssetObjRoot = Join-Path $AssetRoot 'objects'
$VersionsRoot = Join-Path $Root 'versions'
$InstancesRoot = Join-Path $Root 'instances'
$ConfigPath   = Join-Path $Root 'launcher.json'
$ManifestUrl  = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'

$Script:Arch = 'x86'
if ([Environment]::Is64BitOperatingSystem) { $Script:Arch = 'x86_64' }
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $Script:Arch = 'arm64' }
$Script:OsVersion = [Environment]::OSVersion.Version.ToString()
$Script:Manifest = $null
$Script:JavaCache = $null

function VerDir([string]$Id)      { Join-Path $VersionsRoot $Id }
function VerJsonPath([string]$Id) { Join-Path (VerDir $Id) "$Id.json" }
function VerJarPath([string]$Id)  { Join-Path (VerDir $Id) "$Id.jar" }
function NativesDir([string]$Id)  { Join-Path (VerDir $Id) 'natives' }
function Get-GameDir([string]$Id) {
    if ($Config.sharedGameDir) { return (Join-Path $Root 'game') }
    return (Join-Path $InstancesRoot $Id)
}
function To-Array($x) { if ($null -eq $x) { return @() }; return @($x) }
function Set-Prop($o, [string]$n, $v) { Add-Member -InputObject $o -NotePropertyName $n -NotePropertyValue $v -Force }

# ------------------------------------------------------------------ config
function Load-Config {
    $cfg = @{
        version = '1.8.9'
        listMode = 'release'
        username = 'Player'
        memoryMB = 2048
        javaPath = ''
        server = ''
        extraJvm = ''
        sharedGameDir = $false
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                $prop = $saved.PSObject.Properties[$k]
                if ($prop) { $cfg[$k] = $prop.Value }
            }
        } catch { }
    }
    return $cfg
}
function Save-Config {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $Config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}
$Config = Load-Config

# ------------------------------------------------------------------ host-safe console helpers
function Clear-Screen { try { [Console]::Clear() } catch { try { Clear-Host } catch { } } }
function Set-CursorVisible([bool]$Visible) { try { [Console]::CursorVisible = $Visible } catch { } }
function Get-WindowRows { $h = 30; try { $h = [Console]::WindowHeight } catch { }; return $h }

# ------------------------------------------------------------------ TUI primitives
function Wait-Key([string]$Msg = 'Press any key to continue...') {
    Write-Host ''
    Write-Host $Msg -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Write-Header([string]$Title) {
    Clear-Screen
    $line = '+' + ('-' * 58) + '+'
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ('| {0,-56} |' -f 'Minecraft Launcher (offline)') -ForegroundColor Cyan
    Write-Host ('| {0,-56} |' -f $Title) -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ''
}

# Returns selected index, or -1 on Esc. Scrolls when the list is taller than the window.
function Show-Menu {
    param([string]$Title, [string[]]$Items, [string[]]$Info = @(), [int]$Selected = 0)
    Set-CursorVisible $false
    $top = 0
    while ($true) {
        $rows = [Math]::Max(5, (Get-WindowRows) - (14 + $Info.Count))
        if ($Selected -lt $top) { $top = $Selected }
        if ($Selected -ge $top + $rows) { $top = $Selected - $rows + 1 }
        Write-Header $Title
        foreach ($l in $Info) { Write-Host "  $l" -ForegroundColor Gray }
        if ($Info.Count -gt 0) { Write-Host '' }
        $scroll = $Items.Count -gt $rows
        if ($scroll) { Write-Host ('    ... {0} more above' -f $top) -ForegroundColor DarkGray }
        $end = [Math]::Min($Items.Count, $top + $rows)
        for ($i = $top; $i -lt $end; $i++) {
            $t = $Items[$i]
            if ($t.Length -gt 52) { $t = $t.Substring(0, 49) + '...' }
            if ($i -eq $Selected) { Write-Host ('  > {0,-52}' -f $t) -ForegroundColor Black -BackgroundColor Cyan }
            else { Write-Host ('    {0}' -f $t) }
        }
        if ($scroll) { Write-Host ('    ... {0} more below' -f ($Items.Count - $end)) -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '  Up/Down: move   Enter: select   Esc: back' -ForegroundColor DarkGray
        $key = [string][Console]::ReadKey($true).Key
        if ($key -eq 'UpArrow' -or $key -eq 'W') { $Selected = ($Selected - 1 + $Items.Count) % $Items.Count }
        elseif ($key -eq 'DownArrow' -or $key -eq 'S') { $Selected = ($Selected + 1) % $Items.Count }
        elseif ($key -eq 'PageUp') { $Selected = [Math]::Max(0, $Selected - $rows) }
        elseif ($key -eq 'PageDown') { $Selected = [Math]::Min($Items.Count - 1, $Selected + $rows) }
        elseif ($key -eq 'Home') { $Selected = 0 }
        elseif ($key -eq 'End') { $Selected = $Items.Count - 1 }
        elseif ($key -eq 'Enter') { return $Selected }
        elseif ($key -eq 'Escape') { return -1 }
    }
}

function Read-Input([string]$Label, [string]$Current) {
    Set-CursorVisible $true
    try {
        $suffix = if ($Current) { " [$Current]" } else { '' }
        $v = Read-Host "$Label$suffix"
    } finally { Set-CursorVisible $false }
    if ([string]::IsNullOrWhiteSpace($v)) { return $Current }
    return $v.Trim()
}

function Write-Bar([string]$Label, [int]$Done, [int]$Total) {
    $w = 30
    $pct = if ($Total -gt 0) { [int](100 * $Done / $Total) } else { 100 }
    $fill = [int]($w * $pct / 100)
    $bar = ('#' * $fill) + ('-' * ($w - $fill))
    Write-Host -NoNewline ("`r  {0,-12} [{1}] {2,3}% ({3}/{4})    " -f $Label, $bar, $pct, $Done, $Total)
}

# ------------------------------------------------------------------ download helpers
function Get-FileSha1([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant() }

function Download-VerifiedFile([string]$Url, [string]$Destination, [string]$Sha1) {
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if (-not $Sha1) { if ((Get-Item -LiteralPath $Destination).Length -gt 0) { return } }
        else { try { if ((Get-FileSha1 $Destination) -eq $Sha1.ToLowerInvariant()) { return } } catch { } }
    }
    $tmp = "$Destination.download"
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    if ($Sha1) {
        $actual = Get-FileSha1 $tmp
        if ($actual -ne $Sha1.ToLowerInvariant()) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            throw "SHA-1 mismatch for $Destination"
        }
    }
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

function Expand-NativeDlls([string]$JarPath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        foreach ($e in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($e.Name) -or $e.Name -notmatch '(?i)\.dll$') { continue }
            $out = Join-Path $Destination $e.Name
            $in = $e.Open()
            try {
                $fs = [IO.File]::Open($out, 'Create', 'Write', 'None')
                try { $in.CopyTo($fs) } finally { $fs.Dispose() }
            } finally { $in.Dispose() }
        }
    } finally { $zip.Dispose() }
}

# ------------------------------------------------------------------ version metadata
function Get-Manifest([switch]$Refresh) {
    if ($Script:Manifest -and -not $Refresh) { return $Script:Manifest }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $p = Join-Path $Root 'version_manifest_v2.json'
    try { Invoke-WebRequest -Uri $ManifestUrl -OutFile $p -UseBasicParsing -TimeoutSec 20 } catch { }
    if (Test-Path -LiteralPath $p) {
        try { $Script:Manifest = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { }
    }
    return $Script:Manifest
}

# Rule evaluation shared by libraries and arguments (last matching rule wins)
function Test-Rules($Rules, [hashtable]$Features = @{}) {
    if (-not $Rules) { return $true }
    $allowed = $false
    foreach ($r in $Rules) {
        $m = $true
        if ($r.os) {
            if ($r.os.name -and $r.os.name -ne 'windows') { $m = $false }
            if ($r.os.arch -and $r.os.arch -ne $Script:Arch) { $m = $false }
            if ($r.os.version -and ($Script:OsVersion -notmatch [string]$r.os.version)) { $m = $false }
        }
        if ($r.features) {
            foreach ($f in $r.features.PSObject.Properties) {
                $have = $Features.ContainsKey($f.Name) -and [bool]$Features[$f.Name]
                if ([bool]$f.Value -ne $have) { $m = $false }
            }
        }
        if ($m) { $allowed = ($r.action -eq 'allow') }
    }
    return $allowed
}

# Reads versions\<id>\<id>.json, merging "inheritsFrom" parents (Fabric/Forge-style profiles)
function Resolve-VersionJson([string]$Id) {
    $p = VerJsonPath $Id
    if (-not (Test-Path -LiteralPath $p)) { throw "Version JSON for '$Id' not found. Install it first." }
    $vj = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    $jar = $Id
    if ($vj.inheritsFrom) {
        $base = Resolve-VersionJson ([string]$vj.inheritsFrom)
        $jar = $base._jarId
        Set-Prop $base 'libraries' @(@(To-Array $vj.libraries) + @(To-Array $base.libraries))
        if ($vj.mainClass) { Set-Prop $base 'mainClass' $vj.mainClass }
        if ($vj.minecraftArguments) { Set-Prop $base 'minecraftArguments' $vj.minecraftArguments }
        if ($vj.arguments) {
            $newArgs = [PSCustomObject]@{
                jvm  = @(@(To-Array $base.arguments.jvm)  + @(To-Array $vj.arguments.jvm))
                game = @(@(To-Array $base.arguments.game) + @(To-Array $vj.arguments.game))
            }
            Set-Prop $base 'arguments' $newArgs
        }
        if ($vj.assetIndex) { Set-Prop $base 'assetIndex' $vj.assetIndex }
        if ($vj.javaVersion) { Set-Prop $base 'javaVersion' $vj.javaVersion }
        Set-Prop $base 'id' $Id
        $vj = $base
    }
    Set-Prop $vj '_jarId' $jar
    return $vj
}

function Get-LocalVersionIds {
    if (-not (Test-Path -LiteralPath $VersionsRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $VersionsRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$($_.Name).json") } |
        ForEach-Object { $_.Name })
}

function Test-Installed([string]$Id) {
    $ok = $false
    if (Test-Path -LiteralPath (VerJsonPath $Id)) {
        $vj = $null
        try { $vj = Resolve-VersionJson $Id } catch { $vj = $null }
        if ($vj -and (Test-Path -LiteralPath (VerJarPath $vj._jarId))) {
            $n = NativesDir $Id
            if (Test-Path -LiteralPath $n) {
                $ok = (@(Get-ChildItem -LiteralPath $n -Filter *.dll -ErrorAction SilentlyContinue).Count -gt 0)
            }
        }
    }
    return $ok
}

function Get-VersionEntries([string]$Mode, [string]$Filter) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $local = @(Get-LocalVersionIds)
    $manifest = Get-Manifest
    $inManifest = @{}
    if ($manifest) { foreach ($v in $manifest.versions) { $inManifest[$v.id] = $true } }

    foreach ($id in $local) {
        if (-not $inManifest.ContainsKey($id)) {
            $entries.Add([PSCustomObject]@{ Id = $id; Type = 'custom'; Installed = (Test-Installed $id) })
        }
    }
    if ($manifest) {
        foreach ($v in $manifest.versions) {
            if ($v.type -ne 'release' -and $v.type -ne 'snapshot') { continue }
            if ($Mode -eq 'release' -and $v.type -ne 'release') { continue }
            if ($Mode -eq 'installed' -and ($local -notcontains $v.id)) { continue }
            try { if ([datetime]$v.releaseTime -lt [datetime]'2013-06-25') { continue } } catch { }
            $entries.Add([PSCustomObject]@{ Id = [string]$v.id; Type = [string]$v.type; Installed = (Test-Installed $v.id) })
        }
    }
    if ($Filter) { return @($entries | Where-Object { $_.Id -like "*$Filter*" }) }
    return $entries.ToArray()
}

# ------------------------------------------------------------------ libraries
function Get-LibraryWork($vj) {
    $arch = if ([Environment]::Is64BitOperatingSystem) { '64' } else { '32' }
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($lib in $vj.libraries) {
        if (-not (Test-Rules $lib.rules)) { continue }
        $dl = $lib.downloads
        $art = $null
        if ($dl) { $art = $dl.artifact }
        if ($art -and $art.path) {
            $out.Add([PSCustomObject]@{
                Url = [string]$art.url; Dest = (Join-Path $LibraryRoot ($art.path -replace '/', '\')); Sha1 = [string]$art.sha1
                Native = ([string]$lib.name -match ':natives-windows'); OnClasspath = $true })
        } elseif (-not $dl -and $lib.name) {
            # Maven-style entry without a downloads block (Fabric etc.)
            $p = ([string]$lib.name) -split ':'
            if ($p.Count -ge 3) {
                $suffix = if ($p.Count -ge 4) { "-$($p[3])" } else { '' }
                $rel = ($p[0] -replace '\.', '/') + "/$($p[1])/$($p[2])/$($p[1])-$($p[2])$suffix.jar"
                $base = if ($lib.url) { [string]$lib.url } else { 'https://libraries.minecraft.net/' }
                if (-not $base.EndsWith('/')) { $base += '/' }
                $out.Add([PSCustomObject]@{
                    Url = ($base + $rel); Dest = (Join-Path $LibraryRoot ($rel -replace '/', '\')); Sha1 = [string]$lib.sha1
                    Native = $false; OnClasspath = $true })
            }
        }
        if ($lib.natives -and $lib.natives.windows -and $dl -and $dl.classifiers) {
            $cname = ([string]$lib.natives.windows).Replace('${arch}', $arch)
            $cls = $dl.classifiers.PSObject.Properties[$cname]
            if ($cls -and $cls.Value.path) {
                $out.Add([PSCustomObject]@{
                    Url = [string]$cls.Value.url; Dest = (Join-Path $LibraryRoot ($cls.Value.path -replace '/', '\')); Sha1 = [string]$cls.Value.sha1
                    Native = $true; OnClasspath = $false })
            }
        }
    }
    return $out
}

function Get-Classpath($vj) {
    $seen = @{}
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($w in @(Get-LibraryWork $vj)) {
        if ($w.OnClasspath -and -not $seen.ContainsKey($w.Dest)) { $seen[$w.Dest] = $true; $parts.Add($w.Dest) }
    }
    $parts.Add((VerJarPath $vj._jarId))
    return ($parts -join ';')
}

# ------------------------------------------------------------------ assets
function Get-MissingAssets($aij) {
    $todo = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($p in $aij.objects.PSObject.Properties) {
        $h = [string]$p.Value.hash
        if ($seen.ContainsKey($h)) { continue }
        $seen[$h] = $true
        $path = Join-Path (Join-Path $AssetObjRoot $h.Substring(0, 2)) $h
        $ok = (Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-Item -LiteralPath $path).Length -eq [long]$p.Value.size)
        if (-not $ok) { $todo.Add([PSCustomObject]@{ Hash = $h; Size = [long]$p.Value.size }) }
    }
    return $todo
}

$AssetWorker = {
    param($items, $root, $state)
    $wc = New-Object System.Net.WebClient
    try {
        foreach ($a in $items) {
            $sub = $a.Hash.Substring(0, 2)
            $dir = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
            $dest = Join-Path $dir $a.Hash
            $tmp = "$dest.download"
            for ($t = 1; $t -le 3; $t++) {
                try {
                    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
                    $wc.DownloadFile("https://resources.download.minecraft.net/$sub/$($a.Hash)", $tmp)
                    if ((Get-Item -LiteralPath $tmp).Length -ne $a.Size) { throw 'size' }
                    Move-Item -LiteralPath $tmp -Destination $dest -Force
                    break
                } catch { Start-Sleep -Seconds $t }
            }
            [System.Threading.Monitor]::Enter($state.SyncRoot)
            try { $state.Done = $state.Done + 1 } finally { [System.Threading.Monitor]::Exit($state.SyncRoot) }
        }
    } finally { $wc.Dispose() }
}

function Install-Assets($vj, [string]$GameDir) {
    $ai = $vj.assetIndex
    if (-not $ai) { throw 'Version has no asset index.' }
    $aiPath = Join-Path $AssetIdxRoot ("{0}.json" -f $ai.id)
    Download-VerifiedFile $ai.url $aiPath $ai.sha1
    $aij = Get-Content -LiteralPath $aiPath -Raw | ConvertFrom-Json

    $todo = Get-MissingAssets $aij
    Write-Host "  $($todo.Count) assets to download (8 parallel workers)."
    if ($todo.Count -gt 0) {
        $n = 8
        $chunks = @(1..$n | ForEach-Object { New-Object 'System.Collections.Generic.List[object]' })
        $k = 0
        foreach ($a in $todo) { $chunks[$k % $n].Add($a); $k++ }
        $state = [hashtable]::Synchronized(@{ Done = 0 })
        $pool = [runspacefactory]::CreateRunspacePool(1, $n)
        $pool.Open()
        $jobs = @()
        try {
            foreach ($c in $chunks) {
                if ($c.Count -eq 0) { continue }
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($AssetWorker).AddArgument($c).AddArgument($AssetObjRoot).AddArgument($state)
                $jobs += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
                Write-Bar 'Assets' ([int]$state.Done) $todo.Count
                Start-Sleep -Milliseconds 250
            }
            Write-Bar 'Assets' $todo.Count $todo.Count
            Write-Host ''
            foreach ($j in $jobs) { try { [void]$j.PS.EndInvoke($j.Handle) } catch { }; $j.PS.Dispose() }
        } finally { $pool.Close(); $pool.Dispose() }
        $left = Get-MissingAssets $aij
        if ($left.Count -gt 0) { throw "$($left.Count) assets failed to download. Run Install / Repair again." }
    }

    # Very old versions (1.6 - 1.7.2) need real file names instead of hashed objects
    if ($aij.virtual -or $aij.map_to_resources) {
        Write-Host '  Preparing legacy asset layout...' -ForegroundColor Cyan
        $dest = if ($aij.virtual) { Join-Path (Join-Path $AssetRoot 'virtual') $ai.id } else { Join-Path $GameDir 'resources' }
        foreach ($p in $aij.objects.PSObject.Properties) {
            $h = [string]$p.Value.hash
            $src = Join-Path (Join-Path $AssetObjRoot $h.Substring(0, 2)) $h
            $target = Join-Path $dest ($p.Name -replace '/', '\')
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Copy-Item -LiteralPath $src -Destination $target
            }
        }
    }
}

# ------------------------------------------------------------------ install
function Install-Version([string]$Id) {
    New-Item -ItemType Directory -Force -Path (VerDir $Id), $LibraryRoot, $AssetIdxRoot, $AssetObjRoot | Out-Null
    Write-Host "  [$Id] fetching metadata..." -ForegroundColor Cyan
    $manifest = Get-Manifest
    $entry = $null
    if ($manifest) { $entry = $manifest.versions | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
    $jp = VerJsonPath $Id
    if ($entry) { Download-VerifiedFile $entry.url $jp $entry.sha1 }
    elseif (-not (Test-Path -LiteralPath $jp)) { throw "Version '$Id' is not in the manifest and has no local JSON (offline?)." }

    $raw = Get-Content -LiteralPath $jp -Raw | ConvertFrom-Json
    if ($raw.inheritsFrom) { Install-Version ([string]$raw.inheritsFrom) }
    $vj = Resolve-VersionJson $Id

    if ($raw.downloads -and $raw.downloads.client) {
        Write-Host "  [$Id] downloading client JAR..." -ForegroundColor Cyan
        Download-VerifiedFile $raw.downloads.client.url (VerJarPath $Id) $raw.downloads.client.sha1
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead((VerJarPath $Id))
        try { if (-not $zip.GetEntry('net/minecraft/client/main/Main.class')) { throw 'client JAR is missing Main.class.' } }
        finally { $zip.Dispose() }
    }

    $work = @(Get-LibraryWork $vj)
    $nat = NativesDir $Id
    if (Test-Path -LiteralPath $nat) { Remove-Item -LiteralPath $nat -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $nat | Out-Null
    Write-Host "  [$Id] downloading libraries and natives..." -ForegroundColor Cyan
    $i = 0
    foreach ($w in $work) {
        $i++
        if ($w.Url) { Download-VerifiedFile $w.Url $w.Dest $w.Sha1 }
        if ($w.Native -and (Test-Path -LiteralPath $w.Dest)) { Expand-NativeDlls $w.Dest $nat }
        Write-Bar 'Libraries' $i $work.Count
    }
    Write-Host ''

    $gameDir = Get-GameDir $Id
    New-Item -ItemType Directory -Force -Path $gameDir | Out-Null
    Write-Host "  [$Id] checking assets..." -ForegroundColor Cyan
    Install-Assets $vj $gameDir
}

function Invoke-Install {
    Write-Header "Install / Repair: $($Config.version)"
    [void](Get-Manifest -Refresh)
    Install-Version $Config.version
    Write-Host ''
    Write-Host '  Install complete.' -ForegroundColor Green
}

# ------------------------------------------------------------------ java
function Get-JavaMajor([string]$Java) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& $Java -version 2>&1 | ForEach-Object { $_.ToString() }) -join "`n" }
    catch { return 0 }
    finally { $ErrorActionPreference = $old }
    if ($out -match 'version "1\.(\d+)') { return [int]$Matches[1] }
    if ($out -match 'version "(\d+)')    { return [int]$Matches[1] }
    return 0
}

function Get-JavaCandidates {
    if ($Script:JavaCache) { return $Script:JavaCache }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    if ($Config.javaPath -and (Test-Path -LiteralPath $Config.javaPath)) { $paths.Add($Config.javaPath) }
    else {
        if ($env:JAVA_HOME) { $paths.Add((Join-Path $env:JAVA_HOME 'bin\java.exe')) }
        foreach ($c in @(Get-Command java.exe -All -ErrorAction SilentlyContinue)) { $paths.Add($c.Source) }
        $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
        $globs = @(
            "$pf\Java\*\bin\java.exe", "$pf86\Java\*\bin\java.exe", "$pf\Eclipse Adoptium\*\bin\java.exe",
            "$pf\Microsoft\*\bin\java.exe", "$pf\Zulu\*\bin\java.exe", "$pf\Amazon Corretto\*\bin\java.exe",
            "$pf\BellSoft\*\bin\java.exe", "$pf\Semeru\*\bin\java.exe",
            "$env:APPDATA\.minecraft\runtime\*\*\*\bin\java.exe",
            "$env:LOCALAPPDATA\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime\*\*\*\bin\java.exe"
        )
        foreach ($g in $globs) {
            foreach ($f in @(Get-ChildItem -Path $g -ErrorAction SilentlyContinue)) { $paths.Add($f.FullName) }
        }
    }
    $seen = @{}
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in $paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $m = Get-JavaMajor $p
        if ($m -gt 0) { $list.Add([PSCustomObject]@{ Path = $p; Major = $m }) }
    }
    $Script:JavaCache = $list.ToArray()
    return $Script:JavaCache
}

function Select-Java([int]$Required) {
    $c = @(Get-JavaCandidates)
    if ($Config.javaPath) { return ($c | Select-Object -First 1) }
    return ($c | Where-Object { $_.Major -ge $Required } | Sort-Object Major | Select-Object -First 1)
}

# ------------------------------------------------------------------ launch
function Get-OfflineUuid([string]$Name) {
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$Name")) } finally { $md5.Dispose() }
    $b[6] = ($b[6] -band 0x0f) -bor 0x30
    $b[8] = ($b[8] -band 0x3f) -bor 0x80
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Expand-Template([string]$s, [hashtable]$Map) {
    foreach ($k in $Map.Keys) { $s = $s.Replace('${' + $k + '}', [string]$Map[$k]) }
    return $s
}

function Expand-Arguments($List, [hashtable]$Map, [hashtable]$Features) {
    $res = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in @($List)) {
        if ($a -is [string]) { $res.Add((Expand-Template $a $Map)); continue }
        if (-not (Test-Rules $a.rules $Features)) { continue }
        foreach ($v in @($a.value)) { $res.Add((Expand-Template ([string]$v) $Map)) }
    }
    # Drop empty tokens and flags whose value could not be resolved (PS5 also drops empty native args)
    $clean = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in $res) {
        if ([string]::IsNullOrEmpty($t)) { continue }
        if ($t.Contains('${')) {
            if ($clean.Count -gt 0 -and $clean[$clean.Count - 1].StartsWith('--')) { $clean.RemoveAt($clean.Count - 1) }
            continue
        }
        $clean.Add($t)
    }
    return $clean
}

function Start-Game {
    $id = $Config.version
    Write-Header "Launching $id"
    if (-not (Test-Installed $id)) { throw "Version $id is not installed. Choose Install / Repair first." }
    $vj = Resolve-VersionJson $id

    $required = 8
    if ($vj.javaVersion -and $vj.javaVersion.majorVersion) { $required = [int]$vj.javaVersion.majorVersion }
    $java = Select-Java $required
    if (-not $java) {
        throw "No suitable Java found. $id needs Java $required or newer. Install a JDK/JRE $required (e.g. from adoptium.net) or set the Java path in Settings."
    }
    if ($java.Major -lt $required) { Write-Host "  Warning: Java $($java.Major) is older than the required $required." -ForegroundColor Yellow }
    elseif ($required -le 8 -and $java.Major -gt 8) { Write-Host "  Note: using Java $($java.Major); this version targets Java 8 and may be less stable." -ForegroundColor Yellow }

    $gameDir = Get-GameDir $id
    New-Item -ItemType Directory -Force -Path $gameDir | Out-Null
    $natives = NativesDir $id
    $classpath = Get-Classpath $vj
    $name = $Config.username

    $gameAssets = $AssetRoot
    $aiPath = Join-Path $AssetIdxRoot ("{0}.json" -f $vj.assetIndex.id)
    if (Test-Path -LiteralPath $aiPath) {
        $aij = Get-Content -LiteralPath $aiPath -Raw | ConvertFrom-Json
        if ($aij.virtual) { $gameAssets = Join-Path (Join-Path $AssetRoot 'virtual') $vj.assetIndex.id }
    }

    $map = @{
        auth_player_name = $name; version_name = $id; game_directory = $gameDir
        assets_root = $AssetRoot; assets_index_name = $vj.assetIndex.id; game_assets = $gameAssets
        auth_uuid = (Get-OfflineUuid $name); auth_access_token = '0'; auth_session = '0'
        auth_xuid = '0'; clientid = '0'; user_properties = '{}'; user_type = 'legacy'
        version_type = $(if ($vj.type) { [string]$vj.type } else { 'release' })
        natives_directory = $natives; launcher_name = 'MCLauncher-TUI'; launcher_version = '2.0'
        classpath = $classpath; classpath_separator = ';'; library_directory = $LibraryRoot
        quickPlayMultiplayer = $Config.server
    }
    $features = @{ is_quick_play_multiplayer = [bool]$Config.server }

    $jvm = New-Object 'System.Collections.Generic.List[string]'
    $jvm.Add('-Xms512M'); $jvm.Add("-Xmx$($Config.memoryMB)M")
    if ($Config.extraJvm) { foreach ($a in ($Config.extraJvm -split '\s+')) { if ($a) { $jvm.Add($a) } } }

    $game = $null
    if ($vj.arguments) {
        foreach ($a in (Expand-Arguments $vj.arguments.jvm $map $features)) { $jvm.Add($a) }
        $game = Expand-Arguments $vj.arguments.game $map $features
    } else {
        # Legacy format (before 1.13): LWJGL 2, classpath and natives passed manually
        $jvm.Add("-Djava.library.path=$natives")
        $jvm.Add("-Dorg.lwjgl.librarypath=$natives")
        $jvm.Add('-cp'); $jvm.Add($classpath)
        $game = Expand-Arguments (([string]$vj.minecraftArguments) -split ' ') $map $features
    }
    $gameList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($g in $game) { $gameList.Add($g) }
    if ($Config.server -and -not $gameList.Contains('--quickPlayMultiplayer')) {
        $h, $p = $Config.server -split ':', 2
        $gameList.Add('--server'); $gameList.Add($h)
        if ($p) { $gameList.Add('--port'); $gameList.Add($p) }
    }
    $jvm.Add([string]$vj.mainClass)

    Write-Host "  Profile : $name (offline)"
    Write-Host "  Java    : $($java.Path) (Java $($java.Major), needs $required+)"
    Write-Host "  Memory  : $($Config.memoryMB) MB"
    Write-Host "  GameDir : $gameDir"
    if ($Config.server) { Write-Host "  Server  : $($Config.server)" }
    Write-Host ''
    Write-Host '  Game output follows. Close the game to return.' -ForegroundColor DarkGray
    Write-Host ''
    Set-CursorVisible $true
    Push-Location $gameDir
    try {
        & $java.Path @jvm @gameList
        Write-Host ''
        Write-Host "  Game exited with code $LASTEXITCODE." -ForegroundColor $(if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Yellow' })
    } finally { Pop-Location; Set-CursorVisible $false }
}

# ------------------------------------------------------------------ screens
function Select-Version {
    Write-Header 'Select version'
    Write-Host '  Fetching version list...' -ForegroundColor DarkGray
    [void](Get-Manifest -Refresh)
    $filter = ''
    $modes = @('release', 'snapshot', 'installed')
    $labels = @{ release = 'Releases'; snapshot = 'Releases + snapshots'; installed = 'Installed only' }
    $sel = 2
    while ($true) {
        $entries = @(Get-VersionEntries $Config.listMode $filter)
        $items = @(
            ('Filter : {0}' -f $(if ($filter) { $filter } else { '(none)' })),
            ('Show   : {0}  (Enter to change)' -f $labels[$Config.listMode])
        )
        foreach ($e in $entries) {
            $items += ('{0,-22} {1,-9} {2}' -f $e.Id, $e.Type, $(if ($e.Installed) { '[installed]' } else { '' }))
        }
        $info = @("Current: $($Config.version)")
        if (-not $Script:Manifest) { $info += 'Offline: only locally installed versions are listed.' }
        $idx = Show-Menu -Title 'Select version' -Items $items -Info $info -Selected $sel
        if ($idx -eq -1) { return }
        if ($idx -eq 0) {
            $v = Read-Input 'Filter text (type - to clear)' $filter
            $filter = if ($v -eq '-') { '' } else { $v }
            $sel = 0
        } elseif ($idx -eq 1) {
            $Config.listMode = $modes[([Array]::IndexOf($modes, $Config.listMode) + 1) % $modes.Count]
            Save-Config
            $sel = 1
        } else {
            $Config.version = $entries[$idx - 2].Id
            Save-Config
            return
        }
    }
}

function Show-Status {
    Write-Header 'Status'
    $id = $Config.version
    Write-Host "  Root         : $Root"
    Write-Host "  Version      : $id ($(if (Test-Installed $id) { 'installed' } else { 'not installed' }))"
    Write-Host "  Game dir     : $(Get-GameDir $id)"
    Write-Host "  Profile      : $($Config.username)   UUID $(Get-OfflineUuid $Config.username)"
    Write-Host "  Memory       : $($Config.memoryMB) MB"
    Write-Host ("  Server       : {0}" -f $(if ($Config.server) { $Config.server } else { '(none)' }))
    Write-Host ''
    $installed = @(Get-LocalVersionIds | Where-Object { Test-Installed $_ })
    Write-Host ("  Installed    : {0}" -f $(if ($installed.Count) { $installed -join ', ' } else { '(none)' }))
    Write-Host ''
    Write-Host '  Java installations found:'
    $c = @(Get-JavaCandidates)
    if ($c.Count -eq 0) { Write-Host '    (none)' -ForegroundColor Yellow }
    foreach ($j in $c) { Write-Host ("    Java {0,-3} {1}" -f $j.Major, $j.Path) }
    Wait-Key
}

function Show-Settings {
    $sel = 0
    while ($true) {
        $items = @(
            "Profile name     : $($Config.username)",
            "Memory (MB)      : $($Config.memoryMB)",
            "Auto-join server : $(if ($Config.server) { $Config.server } else { '(none)' })",
            "Java path        : $(if ($Config.javaPath) { $Config.javaPath } else { '(auto-detect per version)' })",
            "Extra JVM args   : $(if ($Config.extraJvm) { $Config.extraJvm } else { '(none)' })",
            "Shared game dir  : $(if ($Config.sharedGameDir) { 'yes (one world folder for all versions)' } else { 'no (separate folder per version)' })",
            'Back'
        )
        $sel = Show-Menu -Title 'Settings' -Items $items -Selected $sel -Info @("Root: $Root")
        if ($sel -eq -1 -or $sel -eq 6) { return }
        Write-Host ''
        switch ($sel) {
            0 {
                $v = Read-Input 'Profile name (3-16 letters/digits/_)' $Config.username
                if ($v -match '^[A-Za-z0-9_]{3,16}$') { $Config.username = $v } else { Write-Host '  Invalid name.' -ForegroundColor Red; Wait-Key }
            }
            1 {
                $v = Read-Input 'Max memory in MB (512-32768)' ([string]$Config.memoryMB)
                $n = 0
                if ([int]::TryParse($v, [ref]$n) -and $n -ge 512 -and $n -le 32768) { $Config.memoryMB = $n } else { Write-Host '  Invalid value.' -ForegroundColor Red; Wait-Key }
            }
            2 {
                $v = Read-Input 'Server host[:port] (type - to clear)' $Config.server
                $Config.server = if ($v -eq '-') { '' } else { $v }
            }
            3 {
                $v = Read-Input 'Full path to java.exe (type - for auto)' $Config.javaPath
                if ($v -eq '-') { $Config.javaPath = '' }
                elseif (Test-Path -LiteralPath $v -PathType Leaf) { $Config.javaPath = $v }
                else { Write-Host '  File not found.' -ForegroundColor Red; Wait-Key }
                $Script:JavaCache = $null
            }
            4 {
                $v = Read-Input 'Extra JVM args (type - to clear)' $Config.extraJvm
                $Config.extraJvm = if ($v -eq '-') { '' } else { $v }
            }
            5 { $Config.sharedGameDir = -not [bool]$Config.sharedGameDir }
        }
        Save-Config
    }
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch {
        Write-Host ''
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Wait-Key
}

# ------------------------------------------------------------------ main loop
$failed = $false
try {
    $sel = 0
    $quit = $false
    while (-not $quit) {
        $id = $Config.version
        $state = 'NOT installed - choose Install / Repair'
        if (Test-Installed $id) { $state = 'installed' }
        $info = @("Version : $id ($state)", "Profile : $($Config.username) (offline)", "Memory  : $($Config.memoryMB) MB")
        $items = @('Play', "Version: $id  (change)", 'Install / Repair selected version', 'Settings', 'Status', 'Quit')
        $sel = Show-Menu -Title 'Main menu' -Items $items -Info $info -Selected $sel
        if ($sel -eq 0)     { Invoke-Safely { Start-Game } }
        elseif ($sel -eq 1) { Select-Version }
        elseif ($sel -eq 2) { Invoke-Safely { Invoke-Install } }
        elseif ($sel -eq 3) { Show-Settings }
        elseif ($sel -eq 4) { Show-Status }
        else                { $quit = $true }
    }
} catch {
    $failed = $true
    Set-CursorVisible $true
    Write-Host ''
    Write-Host '=== UNEXPECTED ERROR - copy everything below this line ===' -ForegroundColor Red
    Write-Host ("PowerShell {0} | Host: {1}" -f $PSVersionTable.PSVersion, $Host.Name)
    Write-Host ''
    Write-Host ($_.Exception.ToString())
    Write-Host ''
    Write-Host 'Script stack trace:'
    Write-Host ($_.ScriptStackTrace)
    Write-Host ''
    Write-Host ($_.InvocationInfo.PositionMessage)
    Write-Host '=== end ===' -ForegroundColor Red
    [void](Read-Host 'Press Enter to close')
} finally {
    Set-CursorVisible $true
    if (-not $failed) { Clear-Screen }
}
