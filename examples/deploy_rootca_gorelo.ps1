<#
    Gorelo paste-ready: deploy the Salient code-signing Root CA to the local
    machine trust stores. Paste this whole body into a Gorelo PowerShell task
    and run it as SYSTEM. No parameters - Gorelo substitutes the file variable
    token below with the attached certificate's local path at runtime.

    Imports the PUBLIC root certificate into:
      - LocalMachine\Root             (chain trust)
      - LocalMachine\TrustedPublisher (silent execution of signed binaries)

    Idempotent (safe to re-run every cycle) and refuses anything with a private
    key. Deploy only the PUBLIC root certificate (.cer / .crt) - never a .pfx.
#>

# Gorelo replaces this token with the attached file's local path before running.
$CertSource = '$gorelo:file.SalientCodeSigningRootCACert'

# Gorelo backtick-escapes spaces (and similar) when substituting the path; those
# escapes are literal inside the single-quoted value above, so strip stray
# backticks (never part of these cert paths) and trim whitespace before using it.
$CertSource = ($CertSource -replace '`', '').Trim()

# Root = chain trust; TrustedPublisher = silent signed-exe execution (AppLocker/SmartScreen).
$StoreNames = @('Root', 'TrustedPublisher')

# Thumbprints of superseded certificates to remove from the stores first (e.g. an
# old root with the wrong EKU). Matched by exact thumbprint; spaces are ignored.
$RemoveThumbprints = @()

# Optional safety gate: the SHA1 thumbprint the file variable's certificate must
# match before anything is trusted. Guards against a wrong/swapped file variable
# being deployed fleet-wide. Empty skips the check.
$ExpectedRootThumbprint = ''

$ErrorActionPreference = 'Stop'

# Resolve the source to a local file (accepts a staged path or an https URL).
if ($CertSource -match '^https?://') {
    $certPath = Join-Path -Path $env:TEMP -ChildPath ('SalientRootCA_{0}.cer' -f [guid]::NewGuid().ToString('N'))
    Invoke-WebRequest -Uri $CertSource -OutFile $certPath -UseBasicParsing
    $temporary = $true
}
elseif (Test-Path -LiteralPath $CertSource) {
    $certPath = (Resolve-Path -LiteralPath $CertSource).Path
    $temporary = $false
}
else {
    throw "Certificate source '$CertSource' is not an https URL or an existing file path. (Did Gorelo substitute the file variable?)"
}

try {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)

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
    if ($temporary) {
        Remove-Item -LiteralPath $certPath -Force -ErrorAction SilentlyContinue
    }
}
