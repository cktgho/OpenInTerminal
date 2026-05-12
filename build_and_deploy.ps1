#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build OpenInTerminal with Xcode (project signing), copy to /Applications, optional cache cleanup.

.DESCRIPTION
    Multi-platform PowerShell: on macOS runs xcodebuild, copy, and cleanup.
    On other OSes, exits with a clear message (Xcode builds require macOS).

    Signing follows the Xcode project (Automatic + Apple Development). Ad-hoc signing (identity -)
    cannot satisfy App Group / Apple Events entitlements used by this app.

    Before building: detects OpenInTerminal / OpenInTerminalHelper. Unless -AbortIfRunning,
    either prompts to kill them or abort (empty or Y = kill, default), or with -NonInteractive
    kills without prompting. Then removes any existing app under -ApplicationsPath.

    After a successful copy to Applications (unless -KeepDerivedData), removes:
    the -DerivedDataPath folder, the whole repo `build/` tree (Debug, Release, SPM
    checkouts, etc.), and a root `DerivedData/` folder next to the project if present.

.PARAMETER Configuration
    Xcode build configuration (Debug or Release). Default: Release.

.PARAMETER DerivedDataPath
    Xcode -derivedDataPath. Default: <repo>/build/DerivedData

.PARAMETER ApplicationsPath
    Destination folder for the .app bundle. Default: /Applications

.PARAMETER SkipCodesign
    Skip post-build signature verification and extended-attribute cleanup on the built bundle.

.PARAMETER Scheme
    Xcode scheme name. Default: OpenInTerminal. Required with -DerivedDataPath (Xcode rule).

.PARAMETER KeepDerivedData
    Do not run post-install cleanup (see .DESCRIPTION).

.PARAMETER NonInteractive
    If OpenInTerminal or its helper is running, stop them without prompting.

.PARAMETER AbortIfRunning
    Exit with an error if either process is running (no kill, no prompt).

.EXAMPLE
    ./build_and_deploy.ps1

.EXAMPLE
    ./build_and_deploy.ps1 -Configuration Debug
#>
#requires -Version 7.0
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$DerivedDataPath = '',

    [string]$ApplicationsPath = '/Applications',

    [string]$Scheme = 'OpenInTerminal',

    [switch]$SkipCodesign,

    [switch]$KeepDerivedData,

    [switch]$NonInteractive,

    [switch]$AbortIfRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsMacOS {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX)
    }
    return $false
}

function Get-Xcodebuild {
    $candidates = @(
        '/usr/bin/xcodebuild',
        (Join-Path '/Applications/Xcode.app/Contents/Developer/usr/bin' 'xcodebuild')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $fromPath = Get-Command xcodebuild -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    return $null
}

function Get-Codesign {
    $p = '/usr/bin/codesign'
    if (Test-Path -LiteralPath $p) { return $p }
    $cmd = Get-Command codesign -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-OpenInTerminalRelatedProcesses {
    @(
        Get-Process -Name 'OpenInTerminal' -ErrorAction SilentlyContinue
        Get-Process -Name 'OpenInTerminalHelper' -ErrorAction SilentlyContinue
    ) | Where-Object { $_ }
}

function Stop-OpenInTerminalRelatedProcesses {
    param([System.Diagnostics.Process[]]$Processes)
    foreach ($p in $Processes) {
        Write-Host "Stopping: $($p.ProcessName) (PID $($p.Id))" -ForegroundColor Yellow
        Stop-Process -Id $p.Id -Force -ErrorAction Stop
    }
    if ($Processes.Count -gt 0) {
        Start-Sleep -Milliseconds 600
    }
}

if (-not (Test-IsMacOS)) {
    Write-Error 'OpenInTerminal is a macOS app: run this script on macOS with Xcode (or Command Line Tools) installed.'
    exit 1
}

$xcodebuild = Get-Xcodebuild
if (-not $xcodebuild) {
    Write-Error 'xcodebuild not found. Install Xcode or `xcode-select --install`.'
    exit 1
}

$ProjectRoot = $PSScriptRoot
$ProjectFile = Join-Path $ProjectRoot 'OpenInTerminal.xcodeproj'
if (-not (Test-Path -LiteralPath $ProjectFile)) {
    Write-Error "OpenInTerminal.xcodeproj not found at: $ProjectFile"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($DerivedDataPath)) {
    $DerivedDataPath = Join-Path $ProjectRoot 'build' 'DerivedData'
}

$AppName = 'OpenInTerminal.app'
$BuiltApp = Join-Path $DerivedDataPath 'Build' 'Products' $Configuration $AppName
$DestApp = Join-Path $ApplicationsPath $AppName

if (-not (Test-Path -LiteralPath $ApplicationsPath)) {
    Write-Error "Applications folder not found: $ApplicationsPath"
    exit 1
}

$running = @(Get-OpenInTerminalRelatedProcesses)
if ($running.Count -gt 0) {
    $summary = ($running | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
    Write-Host "Running instances detected: $summary" -ForegroundColor Yellow

    if ($AbortIfRunning) {
        Write-Error 'OpenInTerminal or OpenInTerminalHelper is running. Quit them or use -NonInteractive to stop them automatically.'
        exit 1
    }

    if ($NonInteractive) {
        Stop-OpenInTerminalRelatedProcesses -Processes $running
    }
    else {
        $reply = Read-Host 'Kill running instances and continue? [Y/n] (default: Y)'
        if ($reply -eq '' -or $reply.Trim() -match '^(?i)y') {
            Stop-OpenInTerminalRelatedProcesses -Processes $running
        }
        else {
            Write-Host 'Aborted.' -ForegroundColor Yellow
            exit 0
        }
    }
}

if (Test-Path -LiteralPath $DestApp) {
    Write-Host "Removing installed bundle before build: $DestApp" -ForegroundColor Yellow
    Remove-Item -LiteralPath $DestApp -Recurse -Force
}

Write-Host "Project: $ProjectFile"
Write-Host "Scheme: $Scheme"
Write-Host "Configuration: $Configuration"
Write-Host "DerivedData: $DerivedDataPath"
Write-Host "Expected product: $BuiltApp"
Write-Host "Deploy to: $DestApp"
Write-Host ''

# Xcode requires -scheme (or test flags) whenever -derivedDataPath is set.
$buildArgs = @(
    '-project', $ProjectFile,
    '-scheme', $Scheme,
    '-configuration', $Configuration,
    '-derivedDataPath', $DerivedDataPath,
    '-destination', 'platform=macOS'
)

$buildArgs += 'build'

Write-Host "Running: $xcodebuild $($buildArgs -join ' ')" -ForegroundColor Cyan
& $xcodebuild @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "xcodebuild failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $BuiltApp)) {
    Write-Error "Build product not found: $BuiltApp"
    exit 1
}

if (-not $SkipCodesign) {
    $codesign = Get-Codesign
    if (-not $codesign) {
        Write-Error 'codesign not found (needed for --verify).'
        exit 1
    }

    $xattr = '/usr/bin/xattr'
    if (Test-Path -LiteralPath $xattr) {
        Write-Host 'Clearing extended attributes on built bundle...' -ForegroundColor Cyan
        & $xattr -cr $BuiltApp 2>$null
    }

    Write-Host 'Verifying code signature (project / development signing)...' -ForegroundColor Cyan
    & $codesign --verify --verbose $BuiltApp
    if ($LASTEXITCODE -ne 0) {
        Write-Error "codesign verify failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

Write-Host "Copying to $DestApp ..." -ForegroundColor Cyan
Copy-Item -LiteralPath $BuiltApp -Destination $DestApp -Recurse

if (-not (Test-Path -LiteralPath $DestApp)) {
    Write-Error "Copy finished but destination is missing: $DestApp"
    exit 1
}

if (-not $KeepDerivedData) {
    # 1) Custom / explicit DerivedData (may be outside repo `build/`).
    if (Test-Path -LiteralPath $DerivedDataPath) {
        Write-Host "Removing DerivedData: $DerivedDataPath" -ForegroundColor Cyan
        Remove-Item -LiteralPath $DerivedDataPath -Recurse -Force
    }

    # 2) Entire repo `build/` — clears Debug + Release products, SPM, logs, etc.
    $buildDir = Join-Path $ProjectRoot 'build'
    if (Test-Path -LiteralPath $buildDir) {
        Write-Host "Removing repo build folder: $buildDir" -ForegroundColor Cyan
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }

    # 3) Xcode sometimes uses a top-level `DerivedData/` next to the project.
    $rootDerivedData = Join-Path $ProjectRoot 'DerivedData'
    if (Test-Path -LiteralPath $rootDerivedData) {
        Write-Host "Removing repo DerivedData folder: $rootDerivedData" -ForegroundColor Cyan
        Remove-Item -LiteralPath $rootDerivedData -Recurse -Force
    }
}

Write-Host "Done. Installed: $DestApp" -ForegroundColor Green
