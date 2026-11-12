# Signs the driver catalog made by Inf2Cat on the console itself. Called by w64.cmd.
#   powershell -NoProfile -ExecutionPolicy Bypass -File wifi_sign.ps1 CATALOG
#
# The console makes its own test certificates the first time: a root (trusted in
# LocalMachine\Root) and a code-signing certificate issued by it (trusted in
# TrustedPublisher). Their private keys are created here, are not exportable and never leave
# the console, so no signing key is shipped with the project. Both are valid from 2015
# because the console's clock starts in 2022 after every boot.
param([string]$Catalog)
$ErrorActionPreference = 'Stop'
$from = [datetime]::new(2015, 1, 1)
$to = [datetime]::new(2045, 12, 31)
$rootName = 'CN=Switch Windows Local Test Root'
$signerName = 'CN=Switch Windows Local Test Driver'

$root = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq $rootName | Select-Object -First 1
if (-not $root) {
    $root = New-SelfSignedCertificate -Subject $rootName -CertStoreLocation Cert:\LocalMachine\My `
        -KeyUsage CertSign, CRLSign -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 `
        -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=0') -NotBefore $from -NotAfter $to
    "created $rootName"
}
$signer = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq $signerName | Select-Object -First 1
if (-not $signer) {
    $signer = New-SelfSignedCertificate -Subject $signerName -CertStoreLocation Cert:\LocalMachine\My `
        -Signer $root -Type CodeSigningCert -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 `
        -TextExtension @('2.5.29.19={critical}{text}ca=0') -NotBefore $from -NotAfter $to
    "created $signerName"
}

# Public halves only: the root to the trusted roots, the signer to the trusted publishers.
$tmp = Join-Path $env:TEMP 'switch-wifi-cert.cer'
foreach ($pair in @(@($root, 'Root'), @($signer, 'TrustedPublisher'))) {
    $store = "Cert:\LocalMachine\$($pair[1])"
    if (-not (Get-ChildItem $store | Where-Object Thumbprint -eq $pair[0].Thumbprint)) {
        Export-Certificate -Cert $pair[0] -FilePath $tmp -Force | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation $store | Out-Null
        "trusted $($pair[0].Subject) in $($pair[1])"
    }
}
Remove-Item $tmp -ErrorAction SilentlyContinue

$result = Set-AuthenticodeSignature -FilePath $Catalog -Certificate $signer -HashAlgorithm SHA256 -IncludeChain All
"catalog signature: $($result.Status) $($result.StatusMessage)"
if ($result.Status -ne 'Valid') { exit 1 }
