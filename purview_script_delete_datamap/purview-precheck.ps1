<#
PURPOSE
- Prove the SPN can authenticate and access the Purview account
- List collections via Purview Account Data Plane API
- Run a small Discovery Query as an additional permission check
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $TenantId,
  [Parameter(Mandatory=$true)] [string] $ClientId,
  [Parameter(Mandatory=$true)] [string] $ClientSecret,
  [Parameter(Mandatory=$true)] [string] $PurviewAccountName,

  # Optional: if provided, test searching within this collection
  [string] $TestCollectionName,

  # Optional: show more results in search test
  [int] $TestLimit = 5
)

$ErrorActionPreference = "Stop"

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

function Try-Call {
  param(
    [Parameter(Mandatory=$true)] [scriptblock] $Op,
    [Parameter(Mandatory=$true)] [string] $StepName
  )
  try {
    & $Op
  } catch {
    $msg = $_.Exception.Message
    Write-Host " $StepName failed: $msg" -ForegroundColor Red

    if ($msg -match "401|Unauthorized") {
      Write-Host "Likely causes: wrong tenant/app creds OR SPN not allowed to access Purview APIs." -ForegroundColor Yellow
    }
    elseif ($msg -match "403|Forbidden") {
      Write-Host "Likely cause: SPN authenticated but lacks Purview permissions (collection/domain access)." -ForegroundColor Yellow
    }
    elseif ($msg -match "404|Not Found") {
      Write-Host "Likely cause: wrong endpoint. Ensure you use https://<account>.purview.azure.com" -ForegroundColor Yellow
    }

    throw
  }
}

$base = "https://$PurviewAccountName.purview.azure.com"

# Account endpoint for collections APIs includes /account/ per docs.
$accountEndpoint = "$base/account"
$listCollectionsUrl = "$accountEndpoint/collections?api-version=2019-11-01-preview"

# Discovery query endpoint as documented.
$searchUrl = "$base/datamap/api/search/query?api-version=2023-09-01"

Write-Host "Purview base: $base" -ForegroundColor Cyan
Write-Host "Collections endpoint: $listCollectionsUrl" -ForegroundColor Cyan
Write-Host "Search endpoint: $searchUrl" -ForegroundColor Cyan

$token = Try-Call -StepName "Get OAuth token" -Op { Get-Token }
Write-Host " Token acquired (length=$($token.Length))" -ForegroundColor Green

$headers = @{
  Authorization  = "Bearer $token"
  "Content-Type" = "application/json"
}

# 1) List collections (account data plane)
Try-Call -StepName "List collections" -Op {
  $collections = Invoke-RestMethod -Method Get -Uri $listCollectionsUrl -Headers @{ Authorization = "Bearer $token" }
  if (-not $collections.value) {
    Write-Host "No collections returned (or API returned empty value[])." -ForegroundColor Yellow
  } else {
    Write-Host " Collections returned: $($collections.value.Count)" -ForegroundColor Green
    $collections.value | ForEach-Object {
      # name + friendlyName are in the API response schema
      Write-Host ("- name: {0} | friendlyName: {1}" -f $_.name, $_.friendlyName)
    }
  }
}

# 2) Discovery query quick test (basic). 
Try-Call -StepName "Discovery query test" -Op {
  $filter = $null
  if ($TestCollectionName) {
    # Microsoft example shows collectionId filter by collectionName.
    $filter = @{ collectionId = $TestCollectionName }
  }

  $body = @{
    keywords = "*"
    limit    = $TestLimit
  }
  if ($filter) { $body.filter = $filter }

  $json = $body | ConvertTo-Json -Depth 12
  $result = Invoke-RestMethod -Method Post -Uri $searchUrl -Headers $headers -Body $json

  $count = $result.'@search.count'
  $returned = @($result.value).Count
  Write-Host " Discovery query OK. @search.count=$count returned=$returned" -ForegroundColor Green

  if ($returned -gt 0) {
    Write-Host "Sample IDs:" -ForegroundColor Cyan
    @($result.value) | Select-Object -First 3 | ForEach-Object { Write-Host ("- " + $_.id) }
  } else {
    Write-Host " Search returned 0. If collections list succeeded, likely wrong collectionId OR no assets in that scope OR missing permissions on that collection." -ForegroundColor Yellow
  }
}

Write-Host "Precheck finished successfully." -ForegroundColor Green