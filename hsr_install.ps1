# ==============================================================================
# ASTRAL TERMINAL - HONKAI: STAR RAIL DATABANK EXTRACTOR
# ==============================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host ">>> [ASTRAL TERMINAL] Initiating HSR Databank Extraction..." -ForegroundColor Magenta

$logPath = Join-Path $env:USERPROFILE "AppData\LocalLow\Cognosphere\Star Rail\Player.log"
if (-not (Test-Path $logPath)) {
    $logPath = Join-Path $env:USERPROFILE "AppData\LocalLow\Cognosphere\Star Rail\Player-prev.log"
}

if (-not (Test-Path $logPath)) {
    Write-Host "[!] Could not find HSR Player.log. Did you run the game?" -ForegroundColor Red
    return
}

$gameDir = $null
foreach ($line in Get-Content $logPath -TotalCount 50) {
    if ($line -match "Loading player data from (.*)data\.unity3d") {
        $gameDir = $matches[1]
        break
    }
}

if (-not $gameDir) {
    Write-Host "[!] Failed to locate the HSR installation directory from logs." -ForegroundColor Red
    return
}

$webCachesPath = Join-Path $gameDir "webCaches"
$latestCacheData = Get-ChildItem -Path $webCachesPath -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName "Cache\Cache_Data\data_2" }

if (-not (Test-Path $latestCacheData)) {
    Write-Host "[!] Cache data not found. Please open the Warp History in-game first!" -ForegroundColor Yellow
    return
}

$tempFile = Join-Path ([IO.Path]::GetTempPath()) "astral_hsr_cache.tmp"
Copy-Item $latestCacheData -Destination $tempFile -Force

$rawCache = Get-Content $tempFile -Encoding UTF8 -Raw
Remove-Item $tempFile -Force

$pattern = "https.+?getGachaLog.*?(?=\0)"
$matches = [regex]::Matches($rawCache, $pattern)

if ($matches.Count -eq 0) {
    Write-Host "[!] No Warp URL found in cache. Open the Warp History window in-game and try again." -ForegroundColor Yellow
    return
}

$latestUrl = $matches[$matches.Count - 1].Value

$uri = [System.Uri]$latestUrl
$queryParams = $uri.Query.TrimStart('?') -split '&'
$keptParams = @()

foreach ($param in $queryParams) {
    if ($param -match "^(authkey|authkey_ver|sign_type|game_biz|lang)=") {
        $keptParams += $param
    }
}

$cleanQuery = $keptParams -join '&'
$finalUrl = $uri.Scheme + "://" + $uri.Host + $uri.AbsolutePath + "?" + $cleanQuery

Write-Host ">>> Warp History AuthKey successfully located!" -ForegroundColor Green
Write-Host $finalUrl -ForegroundColor Cyan
Set-Clipboard -Value $finalUrl

Write-Host ""
Write-Host "[✔] URL copied to clipboard! You can now paste it into the Astral Terminal." -ForegroundColor Green