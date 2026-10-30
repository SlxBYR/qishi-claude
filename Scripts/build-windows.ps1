$ErrorActionPreference = 'Stop'
$Project = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $Project 'Windows')
try {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
    npm test
    if ($LASTEXITCODE -ne 0) { throw 'Windows protocol tests failed.' }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw 'Windows package build failed.' }
} finally { Pop-Location }
