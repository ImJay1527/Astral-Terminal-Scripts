#Requires -Version 5.1
<#
.SYNOPSIS
    Astral Terminal — Authkey URL Extractor
.DESCRIPTION
    Finds the Genshin Impact wish history authkey URL using three strategies,
    validates it against the live API, copies it to your clipboard, and exits.
    The website then handles all banner fetching in the browser — no PowerShell
    job hangs, no rate-limit surprises.
#>

Add-Type -AssemblyName System.Web
$ErrorActionPreference = 'Stop'

# ─── HELPERS ──────────────────────────────────────────────────────────────────
function Write-Step { param($Msg) Write-Host ('  -> ' + $Msg) -ForegroundColor DarkGray }
function Write-OK   { param($Msg) Write-Host ('  OK  ' + $Msg) -ForegroundColor Green }
function Write-Warn { param($Msg) Write-Host ('  !!  ' + $Msg) -ForegroundColor Yellow }
function Write-Fail { param($Msg) Write-Host ('  XX  ' + $Msg) -ForegroundColor Red; exit 1 }

function Read-LockedFile {
    param([string]$Path, [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8)
    $Stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $Reader = New-Object System.IO.StreamReader($Stream, $Encoding)
    $Content = $Reader.ReadToEnd()
    $Reader.Close(); $Stream.Close()
    return $Content
}

function Copy-LockedFile {
    param([string]$Source, [string]$Destination)
    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    } catch {
        $Src  = [System.IO.File]::Open($Source, 'Open', 'Read', 'ReadWrite')
        $Dest = [System.IO.File]::Open($Destination, 'Create', 'Write', 'None')
        $Src.CopyTo($Dest); $Src.Close(); $Dest.Close()
    }
}

function Find-DataFile {
    param([string]$DataDir)
    $WebCacheRoot = Join-Path $DataDir 'webCaches'
    if (-not (Test-Path $WebCacheRoot)) { return $null }
    return Get-ChildItem -Path $WebCacheRoot -Filter 'data_2' -Recurse -File `
               -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1
}

function Test-AuthUrl {
    param([string]$Url, [string]$ApiHost)
    try {
        $Uri = [System.UriBuilder]::New($Url)
        $Uri.Host = $ApiHost
        $Uri.Path = 'gacha_info/api/getGachaLog'
        $Uri.Fragment = ''
        $Params = [System.Web.HttpUtility]::ParseQueryString($Uri.Query)
        $Params.Set('lang', 'en')
        $Params.Set('gacha_type', '301')
        $Params.Set('size', '1')
        $Params.Set('page', '0')   # invalid page → empty list, no real data fetched
        $Uri.Query = $Params.ToString()
        $ProgressPreference = 'SilentlyContinue'
        $r = Invoke-WebRequest -Uri $Uri.Uri.AbsoluteUri -UseBasicParsing -TimeoutSec 10 | ConvertFrom-Json
        return ($r.retcode -eq 0)
    } catch {
        return $false
    }
}

Write-Host '==> Astral Terminal — Authkey Extractor' -ForegroundColor Cyan

# ─── STRATEGY 1 : output_log.txt ──────────────────────────────────────────────
Write-Host '==> Strategy 1: Scanning output_log.txt...' -ForegroundColor Cyan

$LogPaths = @(
    ($env:USERPROFILE + '\AppData\LocalLow\miHoYo\Genshin Impact\output_log.txt'),
    ($env:USERPROFILE + '\AppData\LocalLow\miHoYo\HYP\output_log.txt'),
    ($env:USERPROFILE + '\AppData\LocalLow\miHoYo\MiHoYoSDKPC\output_log.txt')
)

$PathRegex = '([A-Za-z]:[/\\].+?(?:GenshinImpact_Data|YuanShen_Data))(?=[^A-Za-z0-9_]|$)'
$CacheFile = $null

foreach ($LogPath in $LogPaths) {
    if (-not (Test-Path $LogPath)) { continue }
    Write-Step ('Checking: ' + $LogPath)
    try { $LogContent = Read-LockedFile -Path $LogPath }
    catch { Write-Warn ('Could not read log: ' + $_.Exception.Message); continue }

    $AllMatches = [regex]::Matches($LogContent, $PathRegex)
    if ($AllMatches.Count -eq 0) { Write-Warn 'No install path found.'; continue }

    $DataDir = $AllMatches[$AllMatches.Count - 1].Groups[1].Value.TrimEnd('/', '\', ' ')
    Write-Step ('Candidate data dir: ' + $DataDir)
    $CacheFile = Find-DataFile -DataDir $DataDir
    if ($CacheFile) { Write-OK ('Found via log: ' + $CacheFile.FullName); break }
    Write-Warn ('webCaches not found inside: ' + $DataDir)
}

# ─── STRATEGY 2 : Windows Registry ────────────────────────────────────────────
if (-not $CacheFile) {
    Write-Host '==> Strategy 2: Scanning Windows Registry...' -ForegroundColor Cyan
    $RegRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($Root in $RegRoots) {
        if (-not (Test-Path $Root)) { continue }
        $Keys = Get-ChildItem -Path $Root -ErrorAction SilentlyContinue |
                Where-Object { ($_.GetValue('DisplayName') -match 'Genshin Impact') }
        foreach ($Key in $Keys) {
            $InstallLocation = $Key.GetValue('InstallLocation')
            if (-not $InstallLocation) { continue }
            Write-Step ('Registry install location: ' + $InstallLocation)
            foreach ($Sub in @('', 'game', 'Genshin Impact game')) {
                $Candidate = if ($Sub) { Join-Path $InstallLocation $Sub } else { $InstallLocation }
                foreach ($DataFolder in @('GenshinImpact_Data', 'YuanShen_Data')) {
                    $DataDir = Join-Path $Candidate $DataFolder
                    if (-not (Test-Path $DataDir)) { continue }
                    $CacheFile = Find-DataFile -DataDir $DataDir
                    if ($CacheFile) { Write-OK ('Found via Registry: ' + $CacheFile.FullName); break }
                }
                if ($CacheFile) { break }
            }
            if ($CacheFile) { break }
        }
        if ($CacheFile) { break }
    }
}

# ─── STRATEGY 3 : Brute-force fixed drives ────────────────────────────────────
if (-not $CacheFile) {
    Write-Host '==> Strategy 3: Scanning all fixed drives...' -ForegroundColor Cyan
    $Drives = [System.IO.DriveInfo]::GetDrives() |
              Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
    foreach ($Drive in $Drives) {
        Write-Step ('Scanning drive: ' + $Drive.RootDirectory.FullName)
        $DataDirs = Get-ChildItem -Path $Drive.RootDirectory.FullName -Recurse -Directory -Depth 6 `
                        -Include @('GenshinImpact_Data', 'YuanShen_Data') `
                        -ErrorAction SilentlyContinue
        foreach ($Dir in $DataDirs) {
            $CacheFile = Find-DataFile -DataDir $Dir.FullName
            if ($CacheFile) { Write-OK ('Found via filesystem scan: ' + $CacheFile.FullName); break }
        }
        if ($CacheFile) { break }
    }
}

if (-not $CacheFile) {
    Write-Fail (
        'Could not find the data_2 cache file.' + [Environment]::NewLine +
        'Please open Wish History in-game, let it fully load, then re-run this script.'
    )
}

# ─── COPY data_2 TO TEMP ──────────────────────────────────────────────────────
$TempFile = $env:TEMP + '\genshin_astral_cache_data_2'
Write-Step ('Copying cache to temp...')
Copy-LockedFile -Source $CacheFile.FullName -Destination $TempFile
Write-OK 'Cache copied.'

# ─── EXTRACT & VALIDATE AUTHKEY URL ───────────────────────────────────────────
Write-Host '==> Finding a valid authkey URL...' -ForegroundColor Cyan

$RawBytes   = [System.IO.File]::ReadAllBytes($TempFile)
$RawContent = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetString($RawBytes)
Remove-Item $TempFile -Force -ErrorAction SilentlyContinue

$ApiHost = 'public-operation-hk4e-sg.hoyoverse.com'
$RegionMatch = [regex]::Match($RawContent, 'region=([^&\s\x00-\x1F]+)')
if ($RegionMatch.Success -and $RegionMatch.Groups[1].Value -match '^cn_') {
    $ApiHost = 'public-operation-hk4e.mihoyo.com'
    Write-Step ('CN account detected — using CN API host.')
}

$Chunks      = $RawContent -split '1/0/'
$GachaChunks = @($Chunks | Where-Object { $_ -match 'webview_gacha' })

if ($GachaChunks.Count -eq 0) {
    Write-Fail (
        'No wish history URL found in cache.' + [Environment]::NewLine +
        'Open Wish History in-game, let it fully load, then re-run.'
    )
}

Write-Step ('Found ' + $GachaChunks.Count + ' candidate chunk(s), testing newest first...')

$AuthUrl  = $null
$UrlRegex = 'https://[^"<>\s\x00-\x1F]+getGachaLog[^"<>\s\x00-\x1F]+'

for ($i = $GachaChunks.Length - 1; $i -ge 0; $i--) {
    $UrlMatch = [regex]::Match($GachaChunks[$i], $UrlRegex)
    if (-not $UrlMatch.Success) { continue }

    Write-Host ('  -> Testing chunk ' + $i + '...') -NoNewline -ForegroundColor DarkGray
    if (Test-AuthUrl -Url $UrlMatch.Value -ApiHost $ApiHost) {
        Write-Host ' VALID' -ForegroundColor Green
        $AuthUrl = $UrlMatch.Value
        break
    }
    Write-Host ' expired' -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
}

if (-not $AuthUrl) {
    Write-Fail (
        'All cached authkeys are expired.' + [Environment]::NewLine +
        'Relaunch Genshin Impact, open Wish History, wait for it to fully load, then re-run.'
    )
}

# ─── DONE — copy URL to clipboard ─────────────────────────────────────────────
Set-Clipboard -Value $AuthUrl
Write-Host ''
Write-OK 'Authkey URL validated and copied to clipboard!'
Write-Host '  -> Paste it into Astral Terminal to import your pulls.' -ForegroundColor Yellow
Write-Host ''