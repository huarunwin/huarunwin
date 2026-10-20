param(
  [string]$Package, [string]$Digest, [string]$CurrentExe,
  [int]$ParentPid, [string]$Version, [string]$Job
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location -LiteralPath $Job
$exited = $false
$moves = [System.Collections.Generic.List[object]]::new()
$prepared = $null
$backup = Join-Path $Job 'backup'
function PlainPath([string]$path) {
  $item = Get-Item -LiteralPath $path
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '更新路径包含符号链接。' }
  $parent = $item.Parent
  if ($item -is [IO.FileInfo]) { $parent = $item.Directory }
  while ($null -ne $parent) {
    if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '更新目录包含符号链接。' }
    $parent = $parent.Parent
  }
}
function CheckSigner([string]$path) {
  $old = Get-AuthenticodeSignature -LiteralPath $CurrentExe
  $new = Get-AuthenticodeSignature -LiteralPath $path
  if ($old.Status -eq 'Valid') {
    if ($new.Status -ne 'Valid' -or $old.SignerCertificate.Thumbprint -ne $new.SignerCertificate.Thumbprint) {
      throw '更新包与当前客户端的签名不兼容。'
    }
  } elseif ($old.Status -ne 'NotSigned' -or ($new.Status -ne 'Valid' -and $new.Status -ne 'NotSigned')) {
    throw '无法验证客户端或更新包的签名。'
  }
}
function CheckVersion([string]$value, [bool]$exact = $false) {
  $value = ($value -split '\+')[0]
  $base = ($Version -split '-')[0]
  if (($exact -and $value -ne $Version) -or
      (-not $exact -and $value -ne $Version -and $value -ne $base -and -not $value.StartsWith($base + '.'))) {
    throw '安装包版本与更新信息不匹配。'
  }
  $current = [Diagnostics.FileVersionInfo]::GetVersionInfo($CurrentExe)
  $installed = [Version]::new($current.FileMajorPart, $current.FileMinorPart, $current.FileBuildPart)
  if ([Version]$base -lt $installed) { throw '该更新包比当前安装的客户端更旧。' }
}
function CheckExe([string]$path) {
  $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
  if ($info.InternalName -ne 'huarunwin' -or $info.CompanyName -ne 'win.huarun' -or $info.ProductName -ne 'huarunwin') {
    throw '安装包不是华润赢客户端。'
  }
  CheckVersion $info.ProductVersion $true
  CheckSigner $path
}
try {
  PlainPath $Package
  PlainPath $CurrentExe
  $currentHash = (Get-FileHash -LiteralPath $CurrentExe -Algorithm SHA256).Hash
  if ((Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash -ne $Digest) { throw '安装包 SHA-256 已变化。' }
  $extension = [IO.Path]::GetExtension($Package).ToLowerInvariant()
  $currentRoot = [IO.Path]::GetDirectoryName($CurrentExe)
  if ($extension -eq '.zip') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Package)
    try {
      [long]$total = 0
      foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if ($name.StartsWith('/') -or $name.Contains(':') -or ($name -split '/') -contains '..' -or
            (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw '压缩包包含无效路径。' }
        $total += $entry.Length
        if ($total -gt 4294967296) { throw '更新包展开后超过 4 GB。' }
      }
    } finally { $archive.Dispose() }
    $unpacked = Join-Path $Job 'unpacked'
    [IO.Compression.ZipFile]::ExtractToDirectory($Package, $unpacked)
    $name = [IO.Path]::GetFileName($CurrentExe)
    $candidates = @(Get-ChildItem -LiteralPath $unpacked -Filter $name -File -Recurse)
    if ($candidates.Count -ne 1) { throw '更新压缩包必须包含唯一的华润赢程序。' }
    $incoming = $candidates[0]
    CheckExe $incoming.FullName
    if (-not (Test-Path -LiteralPath (Join-Path $incoming.DirectoryName 'data\flutter_assets')) -or
        -not (Test-Path -LiteralPath (Join-Path $incoming.DirectoryName 'flutter_windows.dll'))) { throw 'Flutter 更新包不完整。' }
    $prepared = Join-Path $currentRoot ('.huarun-update-' + [Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $prepared | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $incoming.DirectoryName) {
      if ($item.Name -eq $name -or $item.Name -eq 'data' -or $item.Extension -eq '.dll') {
        Copy-Item -LiteralPath $item.FullName -Destination $prepared -Recurse
      }
    }
    CheckExe (Join-Path $prepared $name)
    $backup = Join-Path $currentRoot ('.huarun-backup-' + [Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $backup | Out-Null
    [IO.File]::WriteAllText((Join-Path $Job 'backup-path'), $backup)
  } elseif ($extension -eq '.exe') {
    CheckExe $Package
  } elseif ($extension -eq '.msi') {
    CheckSigner $Package
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Package, 0)
    function MsiProperty([string]$property) {
      $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$property'")
      $view.Execute()
      $record = $view.Fetch()
      if ($null -eq $record) { throw 'MSI 更新信息不完整。' }
      return $record.StringData(1)
    }
    if ((MsiProperty 'ProductName') -ne 'huarunwin' -or (MsiProperty 'Manufacturer') -ne 'win.huarun') { throw 'MSI 应用身份不匹配。' }
    CheckVersion (MsiProperty 'ProductVersion')
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
  } elseif ($extension -eq '.msix') {
    CheckSigner $Package
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Package)
    try {
      $entry = $archive.GetEntry('AppxManifest.xml')
      if ($null -eq $entry -or $entry.Length -gt 1048576) { throw 'MSIX 清单无效。' }
      $reader = [IO.StreamReader]::new($entry.Open())
      try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($manifest.Package.Identity.Name -ne 'win.huarun.huarunwin') { throw 'MSIX 应用身份不匹配。' }
      CheckVersion $manifest.Package.Identity.Version
    } finally { $archive.Dispose() }
  } else { throw '不支持此 Windows 更新格式。' }
  if (Test-Path -LiteralPath (Join-Path $Job 'cancel')) { exit 0 }
  [IO.File]::WriteAllText((Join-Path $Job 'ready'), 'ready')
  $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
  if ($null -ne $parent -and -not $parent.WaitForExit(120000)) { throw '客户端尚未退出，更新已取消。' }
  if (Test-Path -LiteralPath (Join-Path $Job 'cancel')) { exit 0 }
  $exited = $true
  PlainPath $CurrentExe
  if ((Get-FileHash -LiteralPath $CurrentExe -Algorithm SHA256).Hash -ne $currentHash -or
      (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash -ne $Digest) { throw '更新期间文件已变化。' }
  if ($extension -eq '.zip') {
    foreach ($item in Get-ChildItem -LiteralPath $prepared) {
      $target = Join-Path $currentRoot $item.Name
      $saved = Join-Path $backup $item.Name
      $exists = Test-Path -LiteralPath $target
      if ($exists) { PlainPath $target; Move-Item -LiteralPath $target -Destination $saved }
      $moves.Add(@{ target = $target; backup = $saved; existed = $exists })
      Move-Item -LiteralPath $item.FullName -Destination $target
    }
    [IO.File]::WriteAllText((Join-Path $Job 'result'), 'installed')
    Start-Process -FilePath $CurrentExe -WorkingDirectory $currentRoot
  } elseif ($extension -eq '.msi') {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i', ('"' + $Package + '"'))
  } else {
    Start-Process -FilePath $Package
  }
} catch {
  $failureMessage = $_.Exception.Message
  $rollbackFailed = $false
  for ($index = $moves.Count - 1; $index -ge 0; $index--) {
    $move = $moves[$index]
    try {
      if (Test-Path -LiteralPath $move.target) { Remove-Item -LiteralPath $move.target -Recurse -Force }
      if ($move.existed) { Move-Item -LiteralPath $move.backup -Destination $move.target }
    } catch { $rollbackFailed = $true }
  }
  if ($rollbackFailed) { $failureMessage += "`n恢复旧文件未完成，请使用备份目录手动恢复：$backup" }
  [IO.File]::WriteAllText((Join-Path $Job 'error.txt'), $failureMessage)
  if ($exited -and -not $rollbackFailed) { Start-Process -FilePath $CurrentExe -WorkingDirectory ([IO.Path]::GetDirectoryName($CurrentExe)) }
  exit 1
} finally {
  if ($null -ne $prepared -and (Test-Path -LiteralPath $prepared)) { Remove-Item -LiteralPath $prepared -Recurse -Force }
}
