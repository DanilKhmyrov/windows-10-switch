# Signs the driver catalog made by Inf2Cat on the console itself. Called by w64.cmd.
#   powershell -NoProfile -ExecutionPolicy Bypass -File wifi_sign.ps1 CATALOG
#
# The console makes its own test certificates the first time: a root limited to code signing
# (trusted in LocalMachine\Root) and a code-signing certificate issued by it (trusted in
# TrustedPublisher). Their private keys are created here, are not exportable and never leave
# the console, so no signing key is shipped with the project. Both are valid from 2015
# because the console's clock starts in 2022 after every boot.
param([string]$Catalog)
$ErrorActionPreference = 'Stop'
$from = [datetime]::new(2015, 1, 1)
$to = [datetime]::new(2045, 12, 31)
$rootName = 'CN=Switch Windows Local Test Root'
$signerName = 'CN=Switch Windows Local Test Driver'

$codeSigning = '1.3.6.1.5.5.7.3.3'

# A root made by the first version of this script carried New-SelfSignedCertificate's default
# TLS usages, so it could not vouch for code signing: remove it and its signer everywhere.
$root = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq $rootName | Select-Object -First 1
if ($root -and -not ($root.EnhancedKeyUsageList.ObjectId -contains $codeSigning)) {
    foreach ($store in 'My', 'Root', 'TrustedPublisher') {
        $old = Get-ChildItem "Cert:\LocalMachine\$store" |
            Where-Object { $_.Subject -eq $rootName -or $_.Subject -eq $signerName }
        foreach ($cert in $old) {
            # -DeleteKey is a certificate-provider parameter: it needs an explicit Cert: path,
            # and fails for certificates without a private key (the Root and TrustedPublisher copies).
            $path = "Cert:\LocalMachine\$store\$($cert.Thumbprint)"
            try { Remove-Item -Path $path -DeleteKey -ErrorAction Stop }
            catch { Remove-Item -Path $path -ErrorAction SilentlyContinue }
        }
    }
    "removed the old test certificates (no code-signing usage)"
    $root = $null
}
if (-not $root) {
    $root = New-SelfSignedCertificate -Type Custom -Subject $rootName -CertStoreLocation Cert:\LocalMachine\My `
        -KeyUsage CertSign, CRLSign, DigitalSignature -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 `
        -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=0', "2.5.29.37={text}$codeSigning") `
        -NotBefore $from -NotAfter $to
    "created $rootName"
}
$signer = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq $signerName | Select-Object -First 1
if (-not $signer) {
    $signer = New-SelfSignedCertificate -Type Custom -Subject $signerName -CertStoreLocation Cert:\LocalMachine\My `
        -Signer $root -KeyUsage DigitalSignature -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 `
        -TextExtension @('2.5.29.19={critical}{text}ca=0', "2.5.29.37={text}$codeSigning") `
        -NotBefore $from -NotAfter $to
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
