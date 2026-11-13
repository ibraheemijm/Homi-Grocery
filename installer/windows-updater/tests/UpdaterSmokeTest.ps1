param(
  [Parameter(Mandatory = $true)][string]$UpdaterExe,
  [Parameter(Mandatory = $true)][string]$FakeAppDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Join-Path $env:RUNNER_TEMP ("homi-updater-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null

$registrySubKey = "SOFTWARE\Homi Grocery"
$registryBefore = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($registrySubKey, $false)
$hadOriginalInstallDir = $false
$originalInstallDir = $null
if ($registryBefore) {
  $hadOriginalInstallDir = $registryBefore.GetValueNames() -contains "InstallDir"
  if ($hadOriginalInstallDir) { $originalInstallDir = $registryBefore.GetValue("InstallDir") }
  $registryBefore.Dispose()
}

function Set-RegisteredInstallDirectory([string]$Path) {
  $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($registrySubKey)
  try {
    $key.SetValue("InstallDir", [System.IO.Path]::GetFullPath($Path), [Microsoft.Win32.RegistryValueKind]::String)
  } finally {
    $key.Dispose()
  }
}

function New-TestPackage([string]$directory, [string]$fileName, [string]$contents) {
  $payload = Join-Path $directory "payload"
  New-Item -ItemType Directory -Path $payload -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $payload $fileName) -Value $contents -NoNewline
  $zip = Join-Path $directory "update.zip"
  [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
  return $zip
}

function Invoke-UpdaterDecisionTest(
  [string]$InstallDir,
  [string]$PackagePath,
  [string]$PackageHash,
  [ValidateSet("commit", "rollback", "disconnect")][string]$Decision
) {
  $pipeName = "homi-update-" + [guid]::NewGuid().ToString("N")
  $nonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
    $pipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::Asynchronous
  )
  $start = [System.Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $UpdaterExe
  $start.UseShellExecute = $false
  foreach ($argument in @(
    "--pid", "999999",
    "--install-dir", $InstallDir,
    "--package", $PackagePath,
    "--sha256", $PackageHash,
    "--pipe-name", $pipeName,
    "--nonce", $nonce
  )) { [void]$start.ArgumentList.Add($argument) }

  Set-RegisteredInstallDirectory $InstallDir
  $process = [System.Diagnostics.Process]::Start($start)
  try {
    $pipe.WaitForConnection()
    $reader = [System.IO.BinaryReader]::new($pipe, [System.Text.Encoding]::UTF8, $true)
    $writer = [System.IO.BinaryWriter]::new($pipe, [System.Text.Encoding]::UTF8, $true)
    $length = $reader.ReadInt32()
    if ($length -le 0 -or $length -gt 4096) { throw "Updater sent invalid protocol message length." }
    $payload = $reader.ReadBytes($length)
    $message = [System.Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json
    if ($message.Version -ne 1 -or $message.Type -ne "installed" -or $message.Nonce -ne $nonce) {
      throw "Updater sent an invalid installed handshake."
    }

    if ($Decision -ne "disconnect") {
      $response = [pscustomobject]@{
        Version = 1
        Type = $Decision
        Nonce = $nonce
      } | ConvertTo-Json -Compress
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($response)
      $writer.Write([int]$bytes.Length)
      $writer.Write($bytes)
      $writer.Flush()
    } else {
      # إغلاق القناة مباشرة لمحاكاة انهيار المنسق بعد تبديل الملفات.
      $pipe.Dispose()
    }
    $process.WaitForExit(30000) | Out-Null
    if (-not $process.HasExited) { throw "Updater did not exit after receiving the health decision." }
    return $process.ExitCode
  }
  finally {
    $pipe.Dispose()
    $process.Dispose()
  }
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
  Set-RegisteredInstallDirectory $install
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

  # رفض PID لعملية Homi تعمل من مجلد مختلف عن مجلد التثبيت المستهدف.
  $wrongProcessRoot = Join-Path $root "wrong-process"
  New-Item -ItemType Directory -Path $wrongProcessRoot | Out-Null
  $wrongProcessInstall = Join-Path $wrongProcessRoot "Homi Grocery"
  New-Item -ItemType Directory -Path $wrongProcessInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $wrongProcessInstall "keep.txt") -Value "untouched" -NoNewline
  $wrongProcessPackage = New-TestPackage $wrongProcessRoot "homi_grocery.exe" "must not install"
  $wrongProcessHash = (Get-FileHash -LiteralPath $wrongProcessPackage -Algorithm SHA256).Hash.ToLowerInvariant()
  $wrongProcess = Start-Process -FilePath (Join-Path $FakeAppDir "homi_grocery.exe") -WorkingDirectory $FakeAppDir -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 300
  Set-RegisteredInstallDirectory $wrongProcessInstall
  & $UpdaterExe --pid $wrongProcess.Id --install-dir $wrongProcessInstall --package $wrongProcessPackage --sha256 $wrongProcessHash
  if ($LASTEXITCODE -eq 0) { throw "Updater accepted a Homi process running from another installation directory." }
  if ((Get-Content -LiteralPath (Join-Path $wrongProcessInstall "keep.txt") -Raw) -ne "untouched") {
    throw "Wrong-process attempt modified the target installation."
  }
  if (-not $wrongProcess.HasExited) { Stop-Process -Id $wrongProcess.Id -Force }

  # رفض بصمة غير مطابقة دون تعديل مجلد التطبيق.
  $badHash = Join-Path $root "bad-hash"
  New-Item -ItemType Directory -Path $badHash | Out-Null
  $badInstall = Join-Path $badHash "Homi Grocery"
  New-Item -ItemType Directory -Path $badInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $badInstall "keep.txt") -Value "keep" -NoNewline
  $badPackage = New-TestPackage $badHash "homi_grocery.exe" "tampered"
  Set-RegisteredInstallDirectory $badInstall
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
  Set-RegisteredInstallDirectory $missingExeInstall
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
  Set-RegisteredInstallDirectory $slipInstall
  & $UpdaterExe --pid 999999 --install-dir $slipInstall --package $slipZip --sha256 $slipHash
  if ($LASTEXITCODE -eq 0) { throw "Updater accepted a path traversal archive." }
  if (Test-Path (Join-Path $slipRoot "escaped.txt")) { throw "ZIP traversal wrote outside the staging directory." }
  if ((Get-Content -LiteralPath (Join-Path $slipInstall "keep.txt") -Raw) -ne "safe") {
    throw "ZIP traversal attempt modified the installation."
  }

  # قرار rollback يعيد مجلد الإصدار السابق بعد رسالة installed.
  $rollbackRoot = Join-Path $root "protocol-rollback"
  New-Item -ItemType Directory -Path $rollbackRoot | Out-Null
  $rollbackInstall = Join-Path $rollbackRoot "Homi Grocery"
  New-Item -ItemType Directory -Path $rollbackInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $rollbackInstall "old-version.txt") -Value "restore-me" -NoNewline
  $rollbackPackage = New-TestPackage $rollbackRoot "homi_grocery.exe" "candidate-build"
  $rollbackHash = (Get-FileHash -LiteralPath $rollbackPackage -Algorithm SHA256).Hash.ToLowerInvariant()
  $rollbackExit = Invoke-UpdaterDecisionTest $rollbackInstall $rollbackPackage $rollbackHash "rollback"
  if ($rollbackExit -ne 0) { throw "Updater did not complete the explicit rollback decision." }
  if ((Get-Content -LiteralPath (Join-Path $rollbackInstall "old-version.txt") -Raw) -ne "restore-me") {
    throw "Explicit rollback did not restore the previous application files."
  }
  if (Test-Path (Join-Path $rollbackInstall "homi_grocery.exe")) {
    throw "Explicit rollback left the candidate executable installed."
  }

  # قرار commit يبقي الإصدار الجديد مع نسخة احتياطية قابلة للاسترجاع.
  $commitRoot = Join-Path $root "protocol-commit"
  New-Item -ItemType Directory -Path $commitRoot | Out-Null
  $commitInstall = Join-Path $commitRoot "Homi Grocery"
  New-Item -ItemType Directory -Path $commitInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $commitInstall "old-version.txt") -Value "keep-backup" -NoNewline
  $commitPackage = New-TestPackage $commitRoot "homi_grocery.exe" "committed-build"
  $commitHash = (Get-FileHash -LiteralPath $commitPackage -Algorithm SHA256).Hash.ToLowerInvariant()
  $commitExit = Invoke-UpdaterDecisionTest $commitInstall $commitPackage $commitHash "commit"
  if ($commitExit -ne 0) { throw "Updater did not accept the explicit commit decision." }
  if ((Get-Content -LiteralPath (Join-Path $commitInstall "homi_grocery.exe") -Raw) -ne "committed-build") {
    throw "Commit decision did not preserve the candidate application."
  }
  $commitBackup = Get-ChildItem -LiteralPath $commitRoot -Directory -Filter ".Homi Grocery.homi-backup-*" | Select-Object -First 1
  if (-not $commitBackup -or -not (Test-Path (Join-Path $commitBackup.FullName "old-version.txt"))) {
    throw "Committed update did not preserve the previous version backup."
  }

  # انقطاع قناة الاتصال بعد التبديل يجب أن يؤدي إلى rollback تلقائي.
  $disconnectRoot = Join-Path $root "protocol-disconnect"
  New-Item -ItemType Directory -Path $disconnectRoot | Out-Null
  $disconnectInstall = Join-Path $disconnectRoot "Homi Grocery"
  New-Item -ItemType Directory -Path $disconnectInstall | Out-Null
  Set-Content -LiteralPath (Join-Path $disconnectInstall "old-version.txt") -Value "disconnect-restore" -NoNewline
  $disconnectPackage = New-TestPackage $disconnectRoot "homi_grocery.exe" "unconfirmed-build"
  $disconnectHash = (Get-FileHash -LiteralPath $disconnectPackage -Algorithm SHA256).Hash.ToLowerInvariant()
  $disconnectExit = Invoke-UpdaterDecisionTest $disconnectInstall $disconnectPackage $disconnectHash "disconnect"
  if ($disconnectExit -eq 0) { throw "Updater treated a disconnected health channel as a successful update." }
  if ((Get-Content -LiteralPath (Join-Path $disconnectInstall "old-version.txt") -Raw) -ne "disconnect-restore") {
    throw "Updater did not automatically restore the previous version after pipe disconnection."
  }

  Write-Host "Windows updater smoke tests passed."
}
finally {
  $registryAfter = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($registrySubKey)
  try {
    if ($hadOriginalInstallDir) {
      $registryAfter.SetValue("InstallDir", $originalInstallDir, [Microsoft.Win32.RegistryValueKind]::String)
    } else {
      $registryAfter.DeleteValue("InstallDir", $false)
    }
  } finally {
    $registryAfter.Dispose()
  }
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

# أوامر الرفض أعلاه متوقعة؛ لا نسمح لرمز خروج آخر تشغيل للمساعد بتحديد نتيجة السكربت.
exit 0
