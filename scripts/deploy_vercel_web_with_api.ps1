param(
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $root

if (-not $SkipBuild) {
  flutter build web --release
}

if (-not (Test-Path ".\build\web\index.html")) {
  throw "build/web/index.html tidak ditemukan. Jalankan flutter build web --release dulu."
}

if (-not (Test-Path ".\api\upload-drive.js")) {
  throw "api/upload-drive.js tidak ditemukan."
}

if (-not (Test-Path ".\.vercel\project.json")) {
  throw ".vercel/project.json tidak ditemukan. Jalankan vercel link dulu."
}

$deployDir = ".\.vercel_deploy"

Remove-Item $deployDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $deployDir | Out-Null

Copy-Item ".\build\web\*" $deployDir -Recurse -Force

New-Item -ItemType Directory "$deployDir\api" -Force | Out-Null
Copy-Item ".\api\upload-drive.js" "$deployDir\api\upload-drive.js" -Force

New-Item -ItemType Directory "$deployDir\.vercel" -Force | Out-Null
Copy-Item ".\.vercel\project.json" "$deployDir\.vercel\project.json" -Force

$deployVercelJson = @"
{
  "rewrites": [
    {
      "source": "/marketplace-connected",
      "destination": "/marketplace-connected.html"
    },
    {
      "source": "/marketplace-connected.html",
      "destination": "/marketplace-connected.html"
    },
    {
      "source": "/",
      "destination": "/index.html"
    },
    {
      "source": "/((?!api/).*)",
      "destination": "/index.html"
    }
  ]
}
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Resolve-Path $deployDir).Path + "\vercel.json", $deployVercelJson, $utf8NoBom)

Push-Location $deployDir
try {
  vercel --prod --force
} finally {
  Pop-Location
}

$siteUrl = "https://operational-management-app-two.vercel.app/"
$proxyUrl = "https://operational-management-app-two.vercel.app/api/upload-drive"

foreach ($u in @($siteUrl, $proxyUrl)) {
  Write-Host ""
  Write-Host "TEST $u"
  $res = Invoke-WebRequest -Uri $u -Method GET -UseBasicParsing -TimeoutSec 30
  Write-Host "STATUS=$($res.StatusCode)"
  Write-Host "BODY_PREVIEW=$($res.Content.Substring(0, [Math]::Min(200, $res.Content.Length)))"
}