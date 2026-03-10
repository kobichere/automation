[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $TenantId,
  [Parameter(Mandatory=$true)] [string] $ClientId,
  [Parameter(Mandatory=$true)] [string] $ClientSecret,
  [Parameter(Mandatory=$true)] [string] $PurviewAccountName,

  [string] $CsvFile = "CECO-Azure-Assets-US.csv",

  # Start low to avoid URL length issues; increase once confirmed working
  [int] $BatchSize = 10,

  [double] $ThrottleSeconds = 0.5,

  [switch] $ResumeSafe,

  # Debug: print the first delete URL you generate
  [switch] $PrintFirstUrl,

  # Debug: only delete ONE guid (first in file) to validate endpoint
  [switch] $TestSingle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$base = "https://$PurviewAccountName.purview.azure.com"

# Microsoft-documented Data Map bulk delete endpoint expects repeated guid= parameters [1](https://learn.microsoft.com/en-us/azure/update-manager/tutorial-webhooks-using-runbooks)
$bulkDeleteBase = "$base/datamap/api/atlas/v2/entity/bulk?api-version=2023-09-01"

$CsvPath        = Join-Path (Get-Location) $CsvFile
$FailedGuidsPath = Join-Path (Get-Location) "failed_guids.csv"
$BackupCsvPath   = Join-Path (Get-Location) ("{0}.bak_{1:yyyyMMddHHmmss}.csv" -f $CsvFile, (Get-Date))

function Get-Token {
  $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
  $body = @{
    grant_type    = "client_credentials"
    client_id     = $ClientId
    client_secret = $ClientSecret
    resource      = "https://purview.azure.net"
  }
  (Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType "application/x-www-form-urlencoded").access_token
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory=$true)] [scriptblock] $Operation,
    [int] $MaxRetries = 8,
    [int] $InitialDelaySeconds = 2
  )

  $attempt = 0
  $delay = $InitialDelaySeconds

  while ($true) {
    $attempt++
    try {
      return & $Operation
    } catch {
      $msg = $_.Exception.Message
      $isThrottle  = ($msg -match "429|Too Many Requests|throttl")
      $isTransient = ($msg -match "502|503|504|timeout|temporarily|connection|reset")
      $isAuth      = ($msg -match "401|Unauthorized")

      if ($attempt -ge $MaxRetries -or (-not ($isThrottle -or $isTransient -or $isAuth))) {
        throw
      }

      Write-Warning ("Retry {0}/{1}: {2}" -f $attempt, $MaxRetries, $msg)
      Start-Sleep -Seconds $delay
      $delay = [Math]::Min($delay * 2, 60)
    }
  }
}

function Show-ErrorDetails($err) {
  Write-Warning ("Exception: {0}" -f $err.Exception.Message)
  if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
    Write-Warning ("ErrorDetails: {0}" -f $err.ErrorDetails.Message)
  }
}

# ---- Validate input ----
if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }

Copy-Item -Path $CsvPath -Destination $BackupCsvPath -Force
Write-Host "Backup CSV created: $BackupCsvPath" -ForegroundColor Yellow

$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) { throw "CSV is empty: $CsvPath" }
if (-not ($rows[0].PSObject.Properties.Name -contains "guid")) { throw "CSV must contain a 'guid' column." }

# Map for ResumeSafe rewriting
$rowsByGuid = @{}
foreach ($r in $rows) {
  if ($r.guid -and $r.guid.Trim() -ne "") { $rowsByGuid[$r.guid.Trim()] = $r }
}

$guids = $rows.guid |
  Where-Object { $_ -and $_.Trim() -ne "" } |
  ForEach-Object { $_.Trim() } |
  Select-Object -Unique

Write-Host ("Loaded GUIDs: {0}" -f $guids.Count) -ForegroundColor Cyan

@() | Export-Csv -Path $FailedGuidsPath -NoTypeInformation -Force

# ---- single GUID test ----
if ($TestSingle) {
  $one = $guids | Select-Object -First 1
  if (-not $one) { throw "No GUIDs found to test." }

  $url = "$bulkDeleteBase&guid=$([System.Uri]::EscapeDataString($one))"
  Write-Host "TEST URL: $url" -ForegroundColor Magenta

  Invoke-WithRetry -Operation {
    $token = Get-Token
    Invoke-RestMethod -Method Delete -Uri $url -Headers @{ Authorization = "Bearer $token" }
  }

  Write-Host "Single GUID delete test succeeded." -ForegroundColor Green
  return
}

# ---- Delete loop ----
$printed = $false

while ($guids.Count -gt 0) {
  $batch = $guids | Select-Object -First $BatchSize
  if (-not $batch -or $batch.Count -eq 0) { break }

  # Build URL with repeated guid= params EXACTLY as required [1](https://learn.microsoft.com/en-us/azure/update-manager/tutorial-webhooks-using-runbooks)
  $guidParams = ($batch | ForEach-Object { "guid=$([System.Uri]::EscapeDataString($_))" }) -join "&"
  $url = "$bulkDeleteBase&$guidParams"

  if ($PrintFirstUrl -and -not $printed) {
    Write-Host "FIRST DELETE URL (verify it contains guid=...):" -ForegroundColor Magenta
    Write-Host $url -ForegroundColor Magenta
    $printed = $true
  }

  try {
    Invoke-WithRetry -Operation {
      $token = Get-Token
      Invoke-RestMethod -Method Delete -Uri $url -Headers @{ Authorization = "Bearer $token" }
    }

    Write-Host ("Deleted batch of {0}. Remaining before update: {1}" -f $batch.Count, $guids.Count) -ForegroundColor Green
    $guids = $guids | Where-Object { $_ -notin $batch }

    if ($ResumeSafe) {
      $remainingRows = foreach ($g in $guids) { if ($rowsByGuid.ContainsKey($g)) { $rowsByGuid[$g] } }
      $remainingRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    }
  }
  catch {
    Write-Warning "Batch failed. Logging GUIDs to failed_guids_03.csv"
    Show-ErrorDetails $_

    $batch | ForEach-Object { [pscustomobject]@{ guid = $_ } } |
      Export-Csv -Path $FailedGuidsPath -NoTypeInformation -Append

    $guids = $guids | Where-Object { $_ -notin $batch }
  }

  if ($ThrottleSeconds -gt 0) {
    Start-Sleep -Milliseconds ($ThrottleSeconds * 1000)
  }
}

Write-Host "DONE. Failed GUIDs (if any): $FailedGuidsPath" -ForegroundColor Green