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
  Set-Content -LiteralPath (Join-Path $badInstall "keep.txt") -Value "keep" -NoNewline
  $badPackage = New-TestPackage $badHash "homi_grocery.exe" "tampered"
  & $UpdaterExe --pid 999999 --install-dir $badInstall --package $badPackage --sha256 ("0" * 64)
  if ($LASTEXITCODE -eq 0) { throw "Updater accepted an invalid SHA-256." }
  if ((Get-Content -LiteralPath (Join-Path $badInstall "keep.txt") -Raw) -ne "keep") {
    throw "Invalid hash attempt modified the installation."
  }

  # رفض حزمة سليمة البنية لكنها لا تحتوي الملف التنفيذي الرئيسي، دون المساس بالتثبيت الحالي.
  $missingExeRoot = Join-Path $root "missing-exe"
  New-Item -ItemType Directory -Path $missingExeRoot | Out-Null
  $missingExeInstall = Join-Path $missingExeRoot "Homi Grocery"
  New-Item -ItemType Directory -Path $missingExeInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $missingExeInstall "keep.txt") -Value "preserve" -NoNewline
  $missingExePackage = New-TestPackage $missingExeRoot "readme.txt" "not an application"
  $missingExeHash = (Get-FileHash -LiteralPath $missingExePackage -Algorithm SHA256).Hash.ToLowerInvariant()
  & $UpdaterExe --pid 999999 --install-dir $missingExeInstall --package $missingExePackage --sha256 $missingExeHash
  if ($LASTEXITCODE -eq 0) { throw "Updater accepted a package without homi_grocery.exe." }
  if ((Get-Content -LiteralPath (Join-Path $missingExeInstall "keep.txt") -Raw) -ne "preserve") {
    throw "Package without the main executable modified the installation."
  }
  if (Get-ChildItem -LiteralPath $missingExeRoot -Directory -Filter ".Homi Grocery.homi-stage-*" | Select-Object -First 1) {
    throw "Updater left a staging directory after rejecting an incomplete package."
  }

  # رفض ZIP يحاول الكتابة خارج مجلد التثبيت (Zip Slip).
  $slipRoot = Join-Path $root "zip-slip"
  New-Item -ItemType Directory -Path $slipRoot | Out-Null
  $slipInstall = Join-Path $slipRoot "Homi Grocery"
  New-Item -ItemType Directory -Path $slipInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $slipInstall "keep.txt") -Value "safe" -NoNewline
  $slipZip = Join-Path $slipRoot "malicious.zip"
  $archive = [System.IO.Compression.ZipFile]::Open($slipZip, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $entry = $archive.CreateEntry("../escaped.txt")
    $entryStream = $entry.Open()
    try {
      $writer = [System.IO.StreamWriter]::new($entryStream)
      try { $writer.Write("outside") } finally { $writer.Dispose() }
    } finally { $entryStream.Dispose() }
  } finally { $archive.Dispose() }
  $slipHash = (Get-FileHash -LiteralPath $slipZip -Algorithm SHA256).Hash.ToLowerInvariant()
  & $UpdaterExe --pid 999999 --install-dir $slipInstall --package $slipZip --sha256 $slipHash
  if ($LASTEXITCODE -eq 0) { throw "Updater accepted a path traversal archive." }
  if (Test-Path (Join-Path $slipRoot "escaped.txt")) { throw "ZIP traversal wrote outside the staging directory." }
  if ((Get-Content -LiteralPath (Join-Path $slipInstall "keep.txt") -Raw) -ne "safe") {
    throw "ZIP traversal attempt modified the installation."
  }

  Write-Host "Windows updater smoke tests passed."
}
finally {
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

# أوامر الرفض أعلاه متوقعة؛ لا نسمح لرمز خروج آخر تشغيل للمساعد بتحديد نتيجة السكربت.
exit 0
