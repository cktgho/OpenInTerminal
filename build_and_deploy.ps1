
$Scheme = "OpenInTerminal"
$Configuration = "Release"
$BuildOutputDir = Join-Path $PSScriptRoot "build_output"
$AppSourcePath = Join-Path $BuildOutputDir "Build/Products/$Configuration/$Scheme.app"
$AppDestPath = "/Applications/$Scheme.app"


Write-Host "Starting Build Process for $Scheme ($Configuration)..."

Write-Host "Running xcodebuild..."
xcodebuild -scheme $Scheme `
           -configuration $Configuration `
           -derivedDataPath $BuildOutputDir `
           -allowProvisioningUpdates
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
if (-not (Test-Path $AppSourcePath)) {
    Write-Error "Build successful, but app not found at: $AppSourcePath"
    exit 1
}
Write-Host "Build succesfully completed at: $AppSourcePath"

Write-Host "Deploying to Applications Directory..."
if (Test-Path $AppDestPath) {
    Write-Host "Removing existing version at $AppDestPath..."
    try {
        Remove-Item -Path $AppDestPath -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to remove existing app. You may need sudo permissions."
        Write-Error $_
        exit 1
    }
}
Write-Host "Copying app to $AppDestPath..."
try {
    Copy-Item -Path $AppSourcePath -Destination "/Applications/" -Recurse -Force -ErrorAction Stop
    Write-Host "Successfully installed $Scheme to /Applications"
}
catch {
    Write-Error "Failed to copy app to /Applications. You may need sudo permissions."
    Write-Error $_
    exit 1
}

if (Test-Path $BuildOutputDir) {
    Write-Host "Cleaning build artifacts..."
    Remove-Item -Path $BuildOutputDir -Recurse -Force
}

Write-Host "Complete!"
