param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$VpsHost,

    [switch]$Fresh
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install-buzz-codex-vps.sh'
$remoteInstaller = '/root/install-buzz-codex-vps.sh'
$target = "root@$VpsHost"

if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Installer not found: $installer"
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "'ssh' is not available. Install or enable Windows OpenSSH Client first."
}

$installerBytes = [System.IO.File]::ReadAllBytes($installer)
$compressedStream = [System.IO.MemoryStream]::new()
$gzipStream = [System.IO.Compression.GZipStream]::new(
    $compressedStream,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true
)
$gzipStream.Write($installerBytes, 0, $installerBytes.Length)
$gzipStream.Dispose()
$installerBase64 = [Convert]::ToBase64String($compressedStream.ToArray())
$compressedStream.Dispose()

# Compress before embedding so the single SSH invocation remains well below
# Windows' process command-line limit while retaining an interactive terminal.
$installerArgument = if ($Fresh) { ' --fresh' } else { '' }
$remoteCommand = "printf '%s' '$installerBase64' | base64 -d | gzip -d > '$remoteInstaller' && chmod 700 '$remoteInstaller' && '$remoteInstaller'$installerArgument"

Write-Host "Uploading and starting the installer through one SSH connection to $target..." -ForegroundColor Cyan
if ($Fresh) {
    Write-Host 'Fresh mode: the four exact outreach-agent containers and their dedicated volumes will be removed first.' -ForegroundColor Yellow
}
Write-Host 'Keep this window open and follow the prompts shown by the installer.' -ForegroundColor Yellow
& ssh -tt `
    -o StrictHostKeyChecking=accept-new `
    -o ServerAliveInterval=20 `
    -o ServerAliveCountMax=90 `
    -o TCPKeepAlive=yes `
    $target $remoteCommand
if ($LASTEXITCODE -ne 0) {
    throw "The remote installer exited with code $LASTEXITCODE."
}

Write-Host 'The remote installer finished successfully.' -ForegroundColor Green
