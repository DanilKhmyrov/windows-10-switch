# Installs and configures the OpenSSH server from agent\ssh (Windows 11): Microsoft's
# Win32-OpenSSH ARM64 build (OpenSSH-ARM64.zip, not part of this repository) and the public key
# authorized_keys made on the Mac. Called by w64.cmd on every boot; does nothing once installed
# with the same key. Login by key only, no passwords, port 22 open to the local subnet only.
#   powershell -NoProfile -ExecutionPolicy Bypass -File ssh_setup.ps1 AGENT_DIR
param([string]$Agent)
$ErrorActionPreference = 'Stop'
$src = Join-Path $Agent 'ssh'
$zip = Join-Path $src 'OpenSSH-ARM64.zip'
$key = Join-Path $src 'authorized_keys'
if (-not (Test-Path $zip) -or -not (Test-Path $key)) { 'ssh: no package or key on the card'; exit 0 }
$dest = 'C:\Program Files\OpenSSH'
$data = 'C:\ProgramData\ssh'

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    'ssh: installing OpenSSH'
    $tmp = Join-Path $env:TEMP 'openssh-unpack'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item (Join-Path $tmp 'OpenSSH-ARM64') $dest
    Remove-Item $tmp -Recurse -Force
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'install-sshd.ps1')
}

# Configuration: keys only. The key goes both to the administrators' file and to the user's own
# file, so it works whether or not the "Match Group administrators" block matches (the group
# name is localized on a Russian Windows).
New-Item -ItemType Directory -Force -Path $data | Out-Null
$config = @"
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp sftp-server.exe
Match Group administrators
    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
"@
$changed = $false
$cfgFile = Join-Path $data 'sshd_config'
if (-not (Test-Path $cfgFile) -or (Get-Content $cfgFile -Raw) -ne $config) {
    Set-Content -Path $cfgFile -Value $config -NoNewline -Encoding ascii
    $changed = $true
}
$adminKeys = Join-Path $data 'administrators_authorized_keys'
$user = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
if (-not $user) { $user = 'Player' }
$userSsh = "C:\Users\$user\.ssh"
New-Item -ItemType Directory -Force -Path $userSsh | Out-Null
foreach ($target in @($adminKeys, (Join-Path $userSsh 'authorized_keys'))) {
    if (-not (Test-Path $target) -or (Get-FileHash $target).Hash -ne (Get-FileHash $key).Hash) {
        Copy-Item $key $target -Force
        $changed = $true
    }
}
# sshd refuses key files that others can write: Administrators (S-1-5-32-544) and SYSTEM only
# for the shared file, plus the user for the user's own one.
& icacls $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
& icacls (Join-Path $userSsh 'authorized_keys') /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' /grant "${user}:R" | Out-Null

if (-not (Get-NetFirewallRule -Name 'sshd-local' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'sshd-local' -DisplayName 'OpenSSH Server (local network only)' -Enabled True `
        -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress LocalSubnet -Action Allow | Out-Null
    'ssh: firewall rule added (local subnet)'
}
Set-Service sshd -StartupType Automatic
if ($changed) { Restart-Service sshd -Force; 'ssh: configured, sshd restarted' } else { Start-Service sshd }
"ssh: sshd $((Get-Service sshd).Status), user $user"
