param(
  [Parameter(Mandatory = $true)][string]$UpdaterExe,
  [Parameter(Mandatory = $true)][string]$FakeAppDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Join-Path $env:RUNNER_TEMP ("homi-updater-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null

function New-TestPackage([string]$directory, [string]$fileName, [string]$contents) {
  $payload = Join-Path $directory "payload"
  New-Item -ItemType Directory -Path $payload -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $payload $fileName) -Value $contents -NoNewline
  $zip = Join-Path $directory "update.zip"
  [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
  return $zip
}

try {
  # اختبار الاستبدال الناجح مع الاحتفاظ بنسخة مجلد التطبيق السابق.
  $install = Join-Path $root "Homi Grocery"
  New-Item -ItemType Directory -Path $install | Out-Null
  Copy-Item -Path (Join-Path $FakeAppDir "*") -Destination $install -Recurse -Force
  Set-Content -LiteralPath (Join-Path $install "old-version.txt") -Value "old"
  $package = New-TestPackage $root "homi_grocery.exe" "new executable payload"
  $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()

  $app = Start-Process -FilePath (Join-Path $install "homi_grocery.exe") -WorkingDirectory $install -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 500
  & $UpdaterExe --pid $app.Id --install-dir $install --package $package --sha256 $hash
  if ($LASTEXITCODE -ne 0) { throw "Updater failed during successful replacement test." }
  if ((Get-Content -LiteralPath (Join-Path $install "homi_grocery.exe") -Raw) -ne "new executable payload") {
    throw "New application payload was not installed."
  }
  if (Test-Path (Join-Path $install "old-version.txt")) {
    throw "Old application files were not replaced."
  }
  $backup = Get-ChildItem -LiteralPath $root -Directory -Filter ".Homi Grocery.homi-backup-*" | Select-Object -First 1
  if (-not $backup -or -not (Test-Path (Join-Path $backup.FullName "old-version.txt"))) {
    throw "Previous application directory was not preserved."
  }

  # رفض بصمة غير مطابقة دون تعديل مجلد التطبيق.
  $badHash = Join-Path $root "bad-hash"
  New-Item -ItemType Directory -Path $badHash | Out-Null
  $badInstall = Join-Path $badHash "Homi Grocery"
  New-Item -ItemType Directory -Path $badInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $badInstall "keep.txt") -Value "keep"
  $badPackage = New-TestPackage $badHash "homi_grocery.exe" "tampered"
  & $UpdaterExe --pid 999999 --install-dir $badInstall --package $badPackage --sha256 ("0" * 64)
  if ($LASTEXITCODE -eq 0) { throw "Updater accepted an invalid SHA-256." }
  if ((Get-Content -LiteralPath (Join-Path $badInstall "keep.txt") -Raw) -ne "keep") {
    throw "Invalid hash attempt modified the installation."
  }

  Write-Host "Windows updater smoke tests passed."
}
finally {
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
