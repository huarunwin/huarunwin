param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('amd64', 'arm64')]
  [string]$Architecture
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location (Join-Path $PSScriptRoot '../..')

$target = if ($Architecture -eq 'amd64') { 'x64' } else { 'arm64' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ine $target) {
  throw 'Windows packages must be built on a runner with the matching architecture'
}
$metadata = Get-Content -LiteralPath 'build/release/metadata.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$output = Join-Path $PWD 'build/release/packages'
$stage = Join-Path $PWD "build/release/windows-$Architecture"
$stem = "$($metadata.asset_stem)-windows-$Architecture"
$nativeVersion = "$($metadata.build_name).$($metadata.build_number)"

$flutterCommand = 'flutter'
$flutterArguments = @()
if ($env:GITHUB_ACTIONS -ne 'true') {
  $flutterCommand = 'fvm'
  $flutterArguments += 'flutter'
}
& $flutterCommand @flutterArguments build windows --release --no-pub `
  --build-name $metadata.app_version --build-number $metadata.build_number `
  "--dart-define=HUARUNWIN_VERSION=$($metadata.app_version)" `
  "--dart-define=HUARUNWIN_UPDATE_CHANNEL=$($metadata.update_channel)"
if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed' }

$bundle = Join-Path $PWD "build/windows/$target/runner/Release"
foreach ($required in @('huarunwin.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets')) {
  if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Missing Flutter bundle entry: $required" }
}
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage, $output -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $bundle 'huarunwin.exe'), (Join-Path $bundle 'data') -Destination $stage -Recurse
Get-ChildItem -LiteralPath $bundle -Filter '*.dll' -File | Copy-Item -Destination $stage

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Redist.14.Latest -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'Visual C++ redistributable files are unavailable' }
$runtime = Get-ChildItem -LiteralPath (Join-Path $visualStudio 'VC/Redist/MSVC') -Directory |
  Where-Object {
    $version = $null
    [Version]::TryParse($_.Name, [ref]$version)
  } |
  Sort-Object { [Version]$_.Name } -Descending |
  ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName "$target/Microsoft.VC*.CRT") -Directory -ErrorAction SilentlyContinue } |
  Select-Object -First 1
if ($null -eq $runtime) { throw "Missing Visual C++ runtime for $target" }

function TestArchitecture([string]$path) {
  $stream = [IO.File]::OpenRead($path)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid PE image: $path" }
    $stream.Position = 0x3C
    $offset = $reader.ReadUInt32()
    $stream.Position = $offset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE header: $path" }
    $machine = $reader.ReadUInt16()
    $expected = if ($Architecture -eq 'amd64') { 0x8664 } else { 0xAA64 }
    # Current Visual C++ ARM64 runtimes can be ARM64X hybrid DLLs.
    $arm64x = $Architecture -eq 'arm64' -and [IO.Path]::GetExtension($path) -ieq '.dll' -and $machine -eq 0xA64E
    return $machine -eq $expected -or $arm64x
  } finally { $reader.Dispose() }
}

Get-ChildItem -LiteralPath $runtime.FullName -Filter '*.dll' -File | ForEach-Object {
  if (TestArchitecture $_.FullName) {
    Copy-Item -LiteralPath $_.FullName -Destination $stage
  } else {
    Write-Host "Skipping incompatible Visual C++ runtime: $($_.Name)"
  }
}
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Missing runtime: $required" }
}

function AssertIdentity([string]$path, [switch]$Installer) {
  $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
  Write-Host ($info | Select-Object CompanyName, ProductName, ProductVersion, OriginalFilename, FileDescription | ConvertTo-Json -Compress)
  # Inno Setup pads its version resource strings with ASCII spaces.
  if (([string]$info.CompanyName).TrimEnd([char]' ') -ne 'win.huarun' -or
      ([string]$info.ProductName).TrimEnd([char]' ') -ne 'huarunwin' -or
      (([string]$info.ProductVersion).TrimEnd([char]' ') -split '\+')[0] -ne $metadata.app_version) {
    throw "Incorrect Windows application identity or version: $path"
  }
  if ($Installer) {
    if (([string]$info.OriginalFilename).TrimEnd([char]' ') -ne 'huarunwin-setup.exe' -or
        ([string]$info.FileDescription).TrimEnd([char]' ') -ne 'HuarunWin Setup') {
      throw 'Incorrect Windows installer identity'
    }
  } elseif ($info.InternalName -ne 'huarunwin') { throw 'Incorrect Windows executable identity' }
}

Get-ChildItem -LiteralPath $stage -File | Where-Object { $_.Extension -in @('.exe', '.dll') } |
  ForEach-Object {
    if (-not (TestArchitecture $_.FullName)) { throw "Wrong architecture in bundle: $($_.Name)" }
  }
$toolsVersion = (Get-Content -LiteralPath (Join-Path $visualStudio 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$dumpbin = Join-Path $visualStudio "VC/Tools/MSVC/$toolsVersion/bin/Host$target/$target/dumpbin.exe"
if (-not (Test-Path -LiteralPath $dumpbin)) { throw 'dumpbin is required to verify runtime dependencies' }
Get-ChildItem -LiteralPath $stage -File | Where-Object { $_.Extension -in @('.exe', '.dll') } |
  ForEach-Object {
    $dependencies = & $dumpbin /nologo /dependents $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect dependencies: $($_.Name)" }
    foreach ($line in $dependencies) {
      $dependency = $line.Trim()
      if ($dependency -match '^(msvcp|vcruntime|concrt|vcomp)\d.*\.dll$' -and
          -not (Test-Path -LiteralPath (Join-Path $stage $dependency))) {
        throw "Missing Visual C++ dependency $dependency for $($_.Name)"
      }
    }
  }
AssertIdentity (Join-Path $stage 'huarunwin.exe')
$license = Get-Content -LiteralPath 'LICENSE' -Raw -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $stage 'LICENSE.txt'), $license, [Text.UTF8Encoding]::new($true))

$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Inno Setup 6 is required' }
$installerArchitecture = if ($Architecture -eq 'amd64') { 'x64compatible' } else { 'arm64' }
$minimumVersion = if ($Architecture -eq 'amd64') { '10.0.17763' } else { '10.0.22000' }
& $compiler "/DBundleDir=$stage" "/DOutputDir=$output" "/DAssetStem=$stem" `
  "/DAppVersion=$($metadata.app_version)" "/DNativeVersion=$nativeVersion" `
  "/DArchitecture=$installerArchitecture" "/DMinimumVersion=$minimumVersion" `
  (Join-Path $PSScriptRoot 'windows_setup.iss') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed' }
$installer = Join-Path $output "$stem-setup.exe"
AssertIdentity $installer -Installer

$archive = Join-Path $output "$stem.zip"
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
foreach ($path in @($installer, $archive)) {
  if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "Empty Windows package: $path" }
  Write-Output "Packaged $([IO.Path]::GetFileName($path))"
}
