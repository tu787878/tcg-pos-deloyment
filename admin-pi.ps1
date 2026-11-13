#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$PiHost,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$User,

    [ValidateSet('SetupKey', 'Install', 'Status', 'Logs', 'Update', 'Backup', 'RegistryLogin', 'Shell', 'ConnectSetup', 'ConnectStatus')]
    [string]$Action = 'Status',

    [ValidateRange(1, 65535)]
    [int]$Port = 22,

    [string]$IdentityFile,

    [switch]$SkipKeySetup,

    [ValidateSet('New', 'Import')]
    [string]$DataMode = 'New',
    [string]$BackupPath,
    [switch]$ReplaceExistingData,

    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]*$')]
    [string]$RegistryUser
)

$ErrorActionPreference = 'Stop'
if ($DataMode -eq 'Import') {
    if ($Action -ne 'Install') { throw 'Import is supported with -Action Install only.' }
    if (-not $ReplaceExistingData) { throw 'Import replaces target data. Specify -ReplaceExistingData after checking the target Pi.' }
    if (-not $BackupPath) { throw 'Import requires -BackupPath (backup directory or PostgreSQL custom-format dump).' }
    $resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
    $dumpPath = $resolvedBackup
    if (Test-Path -LiteralPath $resolvedBackup -PathType Container) {
        $dumpPath = Join-Path $resolvedBackup 'database.dump'
    }
    $dumpStream = [IO.File]::OpenRead($dumpPath)
    try {
        $header = New-Object byte[] 5
        if ($dumpStream.Read($header, 0, 5) -ne 5 -or [Text.Encoding]::ASCII.GetString($header) -ne 'PGDMP') {
            throw 'Expected a PostgreSQL custom-format dump (pg_dump -Fc), not SQL text or another database type.'
        }
    } finally { $dumpStream.Dispose() }
} elseif ($BackupPath -or $ReplaceExistingData) { throw 'BackupPath and ReplaceExistingData require -DataMode Import.' }
if ($Action -eq 'SetupKey' -and $SkipKeySetup) { throw 'SetupKey cannot be combined with -SkipKeySetup.' }
Get-Command ssh -ErrorAction Stop | Out-Null
$sshArguments = @('-p', "$Port", '-o', 'ConnectTimeout=15')
$scpArguments = @('-P', "$Port", '-o', 'ConnectTimeout=15')
$destination = "$User@$PiHost"
if (-not $SkipKeySetup -and -not $IdentityFile) {
    $IdentityFile = Join-Path $env:USERPROFILE '.ssh/tcg_pos_admin_ed25519'
}
if ($IdentityFile -and -not (Test-Path -LiteralPath $IdentityFile)) {
    if ($SkipKeySetup) { throw "Identity file not found: $IdentityFile" }
    Get-Command ssh-keygen -ErrorAction Stop | Out-Null
    $IdentityFile = [IO.Path]::GetFullPath($IdentityFile)
    $keyDirectory = Split-Path -Parent $IdentityFile
    New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
    Write-Host 'Creating an admin SSH key. Choose a passphrase, or press Enter for no passphrase.'
    & ssh-keygen -t ed25519 -f $IdentityFile -C 'tcg-pos-admin'
    if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
}
if ($IdentityFile) {
    $keyPath = (Resolve-Path -LiteralPath $IdentityFile -ErrorAction Stop).Path
    $sshArguments += @('-i', $keyPath, '-o', 'IdentitiesOnly=yes')
    $scpArguments += @('-i', $keyPath, '-o', 'IdentitiesOnly=yes')
}

if (-not $SkipKeySetup) {
    # Cache encrypted keys when the user's SSH agent is already available.
    $agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -eq 'Running') {
        & ssh-add $keyPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not load the SSH key into ssh-agent.' }
    }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & ssh @sshArguments -o BatchMode=yes -o StrictHostKeyChecking=yes $destination true 2>$null
        $keyWorks = $LASTEXITCODE -eq 0
    }
    finally { $ErrorActionPreference = $savedPreference }
    if (-not $keyWorks) {
        $publicKeyPath = $keyPath + '.pub'
        if (-not (Test-Path -LiteralPath $publicKeyPath)) {
            throw "Public key missing: $publicKeyPath. Restore it before key setup, or use -SkipKeySetup."
        }
        $publicKey = [IO.File]::ReadAllText($publicKeyPath).Trim()
        if ($publicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) [A-Za-z0-9+/=]+(?: [^\r\n]*)?$') {
            throw 'Public key file must contain one OpenSSH public key.'
        }
        $encodedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey))
        $setupCommand = 'set -eu; umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; key=$(printf %s ''__KEY__'' | base64 -d); if ! grep -qxF -- "$key" ~/.ssh/authorized_keys; then printf ''\n%s\n'' "$key" >> ~/.ssh/authorized_keys; fi'
        $setupCommand = $setupCommand.Replace('__KEY__', $encodedKey)
        # Windows PowerShell's native argument handling can strip embedded double
        # quotes. Encode the entire remote script so SSH receives no quoted shell
        # variables and the remote sh gets the original script unchanged.
        $encodedSetup = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($setupCommand))
        $setupTransport = "printf %s $encodedSetup | base64 -d | sh"
        Write-Host 'Setting up your public key on the Pi. Enter the Pi login password if requested.'
        & ssh @sshArguments -tt $destination $setupTransport
        if ($LASTEXITCODE -ne 0) { throw 'Public-key setup failed. No deployment was started.' }
        & ssh @sshArguments -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no $destination true
        if ($LASTEXITCODE -ne 0) { throw 'Key login verification failed. No deployment was started.' }
    }
    # Fail rather than repeatedly asking for the Pi login password after setup.
    $sshArguments += @('-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no')
    $scpArguments += @('-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no')
    Write-Host 'SSH key ready. The private key stays on this computer; sudo may still request your Pi password.'
}

function Invoke-PiCommand {
    param([Parameter(Mandatory = $true)][string]$Command)
    # A terminal allows SSH, sudo, and registry credentials to be entered interactively.
    & ssh @sshArguments -tt $destination $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Pi command failed (exit $LASTEXITCODE). Review the output above."
    }
}

switch ($Action) {
    'ConnectSetup' {
        $connectScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'setup-pi-connect.sh')).Replace("`r`n", "`n")
        $connectPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($connectScript))
        Write-Host 'Setting up Raspberry Pi Connect. Complete account linking at the verification URL shown by the Pi.'
        Invoke-PiCommand "printf %s $connectPayload | base64 -d | sh"
    }
    'ConnectStatus' {
        Invoke-PiCommand 'rpi-connect status'
    }
    'SetupKey' { Write-Host 'Key setup complete; no application changes requested.' }
    'Install' {
        Get-Command scp, tar -ErrorAction Stop | Out-Null
        $bundleName = '.tcg-pos-admin-' + [guid]::NewGuid().ToString('N')
        $stagePath = Join-Path ([IO.Path]::GetTempPath()) $bundleName
        New-Item -ItemType Directory -Path $stagePath | Out-Null
        try {
            # Only deployment inputs are uploaded: no Git metadata, .env, keys, or backups.
            $files = @('compose.yaml', 'install.sh', 'update.sh', 'backup.sh',
                'restore.sh', 'boot-update.sh', 'wifi-agent.py')
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            foreach ($file in $files) {
                $sourcePath = Join-Path $PSScriptRoot $file
                $content = [IO.File]::ReadAllText($sourcePath).Replace("`r`n", "`n")
                [IO.File]::WriteAllText((Join-Path $stagePath $file), $content, $utf8)
            }
            $archivePath = Join-Path $stagePath 'deployment.tar'
            if ($DataMode -eq 'Import') {
                $importDirectory = Join-Path $stagePath 'import'
                New-Item -ItemType Directory -Path $importDirectory | Out-Null
                Copy-Item -LiteralPath $dumpPath -Destination (Join-Path $importDirectory 'database.dump')
                if (Test-Path -LiteralPath $resolvedBackup -PathType Container) {
                    $assetBackup = Join-Path $resolvedBackup 'assets.tar.gz'
                    if (Test-Path -LiteralPath $assetBackup) {
                        Copy-Item -LiteralPath $assetBackup -Destination $importDirectory
                    }
                }
                $files += 'import'
            }
            & tar -cf $archivePath -C $stagePath @files
            if ($LASTEXITCODE -ne 0) { throw 'Could not create deployment archive.' }

            Invoke-PiCommand "umask 077; mkdir ~/$bundleName"
            & scp @scpArguments $archivePath "${destination}:$bundleName/deployment.tar"
            if ($LASTEXITCODE -ne 0) { throw 'Upload failed; installer was not started.' }

            Write-Host 'Running the installer. Keep this window open until it finishes.'
            if ($DataMode -eq 'Import') {
                Invoke-PiCommand "cd ~/$bundleName && tar -xf deployment.tar && sudo env TCG_POS_DATABASE_ONLY=1 sh ./install.sh && sudo /opt/tcg-pos/backup.sh && sudo env CONFIRM_RESTORE=YES /opt/tcg-pos/restore.sh ~/$bundleName/import && sudo docker compose --project-directory /opt/tcg-pos up -d --wait --wait-timeout 180 && curl --fail --silent --show-error http://localhost/actuator/health/readiness && sudo systemctl enable tcg-pos-update.service"
            } else {
                Invoke-PiCommand "cd ~/$bundleName && tar -xf deployment.tar && sudo sh ./install.sh && sudo docker compose --project-directory /opt/tcg-pos up -d --wait --wait-timeout 180 && curl --fail --silent --show-error http://localhost/actuator/health/readiness"
            }
            Write-Host "Installation and readiness check completed. Open http://$PiHost in your browser."
            Write-Host "Uploaded deployment files remain on the Pi in ~/$bundleName."
        }
        finally {
            # The only recursive cleanup is this script's unique local staging directory.
            if (Test-Path -LiteralPath $stagePath) {
                Remove-Item -LiteralPath $stagePath -Recurse -Force
            }
        }
    }
    'Status' {
        Invoke-PiCommand 'sudo docker compose --project-directory /opt/tcg-pos ps && sudo systemctl show tcg-pos-update.service -p UnitFileState -p ActiveState -p Result && sudo journalctl -u tcg-pos-update.service -n 20 --no-pager'
    }
    'Logs' {
        Invoke-PiCommand 'sudo docker compose --project-directory /opt/tcg-pos logs --tail=100 api web'
    }
    'Update' {
        Invoke-PiCommand 'sudo systemctl start tcg-pos-update.service; result=$?; sudo journalctl -u tcg-pos-update.service -n 50 --no-pager; exit "$result"'
    }
    'Backup' {
        Invoke-PiCommand 'sudo /opt/tcg-pos/backup.sh'
    }
    'RegistryLogin' {
        if (-not $RegistryUser) { throw 'RegistryLogin requires -RegistryUser YOUR_GITHUB_USERNAME.' }
        Invoke-PiCommand "sudo docker login ghcr.io --username $RegistryUser"
    }
    'Shell' {
        & ssh @sshArguments -tt $destination
        if ($LASTEXITCODE -ne 0) { throw "SSH exited with code $LASTEXITCODE." }
    }
}
