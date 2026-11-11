# Signs the driver catalog made by Inf2Cat on the console itself, with the test certificate
# drivers/test-cert/wifi.pfx (password "switch", a test key only). Called by w64.cmd.
#   powershell -NoProfile -ExecutionPolicy Bypass -File wifi_sign.ps1 CATALOG PFX
param([string]$Catalog, [string]$Pfx)
$ErrorActionPreference = 'Stop'
$password = ConvertTo-SecureString -String 'switch' -Force -AsPlainText
$cert = Import-PfxCertificate -FilePath $Pfx -CertStoreLocation Cert:\LocalMachine\My -Password $password
$result = Set-AuthenticodeSignature -FilePath $Catalog -Certificate $cert -HashAlgorithm SHA256
"catalog signature: $($result.Status) $($result.StatusMessage)"
if ($result.Status -ne 'Valid') { exit 1 }
