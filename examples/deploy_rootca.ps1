<#
.SYNOPSIS
    Deploy the Salient code-signing Root CA certificate to a machine's trust
    stores so Salient-signed binaries (e.g. TED) are trusted without prompts.

.DESCRIPTION
    Imports the PUBLIC root CA certificate into:
      - LocalMachine\Root             (Trusted Root Certification Authorities) - establishes chain trust
      - LocalMachine\TrustedPublisher (silent execution of signed binaries; AppLocker / SmartScreen)

    The operation is idempotent: the certificate is only added to a store if a
    certificate with the same thumbprint is not already present there, so it is
    safe to run on every RMM cycle.

    -CertSource accepts either a local file path or an https URL. Under Gorelo,
    pass the file variable token so it is substituted at runtime, e.g.:

        powershell -ExecutionPolicy Bypass -File deploy_rootca.ps1 `
            -CertSource '$gorelo:file.SalientCodeSigningRootCACert'

    Must run elevated / as SYSTEM (writing to LocalMachine stores requires admin).

.NOTES
    Deploy only the PUBLIC root certificate (.cer / .crt, DER or Base64) - never
    a .pfx / private key. Installing a root CA establishes fleet-wide trust, so
    the source file must be one you control.
#>

[CmdletBinding()]
param(
    # Path or https URL to the PUBLIC root CA certificate.
    [Parameter(Mandatory)]
    [string]$CertSource,

    # Trust stores to import into. Root is required for chain trust;
    # TrustedPublisher enables silent execution of signed binaries.
    [ValidateNotNullOrEmpty()]
    [string[]]$StoreNames = @('Root', 'TrustedPublisher'),

    # Thumbprints of superseded certificates to remove from the stores first
    # (e.g. an old root with the wrong EKU). Matched exactly, case-insensitive;
    # spaces are ignored so a thumbprint copied from the certificate GUI works.
    [string[]]$RemoveThumbprints = @(),

    # Optional safety gate: the SHA1 thumbprint the resolved certificate must
    # match before anything is trusted. Guards against a wrong or swapped file
    # variable being deployed fleet-wide. Empty skips the check.
    [string]$ExpectedRootThumbprint = ''
)

$ErrorActionPreference = 'Stop'

# Some RMMs (e.g. Gorelo) backtick-escape spaces when injecting the path into the
# invocation; strip stray backticks (never part of these cert paths) so the path
# resolves correctly.
$CertSource = ($CertSource -replace '`', '').Trim()

function Resolve-CertFile {
    param([Parameter(Mandatory)][string]$Source)

    if ($Source -match '^https?://') {
        $dest = Join-Path -Path $env:TEMP -ChildPath ('SalientRootCA_{0}.cer' -f [guid]::NewGuid().ToString('N'))
        Invoke-WebRequest -Uri $Source -OutFile $dest -UseBasicParsing
        return [pscustomobject]@{ Path = $dest; Temporary = $true }
    }

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Certificate source '$Source' is not an https URL or an existing file path."
    }

    return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Source).Path; Temporary = $false }
}

$resolved = Resolve-CertFile -Source $CertSource

try {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($resolved.Path)

    # Never push a private key into a machine trust store.
    if ($cert.HasPrivateKey) {
        throw 'The supplied certificate contains a private key. Deploy only the PUBLIC root certificate.'
    }

    # Verify the certificate is the one we expect before trusting it fleet-wide.
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRootThumbprint)) {
        $expected = ($ExpectedRootThumbprint -replace '[^0-9A-Fa-f]', '')
        if ($cert.Thumbprint -ne $expected) {
            throw "Certificate thumbprint $($cert.Thumbprint) does not match expected $expected. Refusing to deploy."
        }
        Write-Host "Verified certificate thumbprint $($cert.Thumbprint)."
    }

    Write-Host "Root CA subject : $($cert.Subject)"
    Write-Host "Thumbprint      : $($cert.Thumbprint)"
    Write-Host "Valid until     : $($cert.NotAfter)"

    foreach ($storeName in $StoreNames) {
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            $storeName,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try {
            # Remove explicitly superseded certificates (e.g. an old root with the
            # wrong EKU), matched by exact thumbprint so nothing else is touched.
            foreach ($bad in $RemoveThumbprints) {
                $badClean = ($bad -replace '[^0-9A-Fa-f]', '')
                if ([string]::IsNullOrWhiteSpace($badClean)) { continue }
                foreach ($found in $store.Certificates.Find(
                        [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                        $badClean, $false)) {
                    $store.Remove($found)
                    Write-Host "[$storeName] removed superseded $($found.Thumbprint)."
                }
            }

            $match = $store.Certificates.Find(
                [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $cert.Thumbprint,
                $false)

            if ($match.Count -gt 0) {
                Write-Host "[$storeName] already trusts $($cert.Thumbprint); skipping."
            }
            else {
                $store.Add($cert)
                Write-Host "[$storeName] imported $($cert.Thumbprint)."
            }
        }
        finally {
            $store.Close()
        }
    }
}
finally {
    if ($resolved.Temporary) {
        Remove-Item -LiteralPath $resolved.Path -Force -ErrorAction SilentlyContinue
    }
}
