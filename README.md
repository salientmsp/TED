[![Health IT Logo](https://healthit.com.au/wp-content/uploads/2019/06/HIT-proper-logo.png)](https://healthit.com.au)

# TED (Tag Every Desktop) - a Health IT Project

TED is a command-line tool, inspired by the classic [BGInfo](https://learn.microsoft.com/en-us/sysinternals/downloads/bginfo), designed for MSPs to be able to display images and text programmatically on the desktop, positioned above the wallpaper but below the icons. It utilizes the bottom right corner of the primary monitor as the drawing area.

TED runs as a lightweight desktop process so it can repaint itself when Windows redraws the desktop. This avoids modifying or replacing the user's wallpaper.

## Features

- Display images and text on the desktop
- Ability to specify different images based on perceived desktop luminance. Font color also adjusts between black or white based on perceived desktop luminance.
- Substitute system values in the text with special tokens
- DPI aware
- Persistent desktop overlay that redraws itself without replacing the user's wallpaper
- Customizable with a variety of command-line switches
- Designed for deployment via an RMM

## Requirements

- Windows 8 or later

## Limitations

In remote desktop environments, Explorer and GPU composition behavior can still vary between Windows versions and client settings.

## Installation

Download the latest compiled binary for TED. You can find the latest downloads for TED below - this ensures your RMM always grabs the latest version!
- [x64](https://github.com/HealthITAU/TED/releases/latest/download/TED-x64.exe)
- [x86](https://github.com/HealthITAU/TED/releases/latest/download/TED-x86.exe)
- [winarm64](https://github.com/HealthITAU/TED/releases/latest/download/TED-winarm64.exe)

We recommend managing and deploying TED via your RMM. 

## Usage

TED supports the following switches:

- `-i` or `-image`: Path or URL to the image to be drawn.
- `-di` or `-darkimage`: Path or URL to the image to be drawn when the perceived desktop luminance is light.
- `-li` or `-lightimage`: Path or URL to the image to be drawn when the perceived desktop luminance is dark.
- `-f` or `-font`: Name of the font to use. Default is **Arial**.
- `-fs` or `-fontsize`: Font size in pixels. Default is **8**.
- `-ls` or `-linespacing`: Space between text lines in pixels. Default is **8**.
- `-hp` or `-hpad`: Horizontal padding amount in pixels. Default is **10**.
- `-vp` or `-vpad`: Vertical padding amount in pixels. Default is **10**.
- `-w` or `-width`: The width of the image when drawn, in pixels. By default this is **-1**. 
  - A value of -1 disables fixed width scaling and instead uses automatic image scaling to resize (respecting aspect ratio) the image to the size of the longest line of text.
- `-a` or `-align`: How the text should be aligned. Default is **Left**. Accepted values are **Left**, **Center** or **Right**. Not case-sensitive.
- `-bg` or `-backdrop`: Render the image *behind* the text as a backdrop/watermark instead of stacking it above the text. This is a switch and takes no value. By default (switch omitted) the image is drawn above the text. When enabled, the image and text share one layout block: the image is drawn first (bottom layer, centered) and the text is drawn last (top layer) so it stays readable over the logo. The `-w`, `-hp`, `-vp` and `-a` arguments apply to the merged block, so the logo and text move together as one unit.
- `-line`: The text to be drawn. This switch can be repeated multiple times to draw multiple lines of text. Lines can contain system tokens and inline rich text formatting, both documented below. If no lines are provided, TED renders the following by default:
  - "USERNAME: @userName"
  - "MACHINE NAME: @machineName"
  - "OS: @osName"

### Line tokens

Tokens can be used inside any `-line` value. TED substitutes them at runtime with values from the current Windows session, machine identity, operating system, and primary network connection.

| Token | Runtime value |
| --- | --- |
| `@userName` | Current Windows user name |
| `@machineName` | Computer name |
| `@machineSerial` | Device serial number |
| `@manufacturer` | Device manufacturer |
| `@model` | Device model |
| `@ipAddress` | Primary IP address |
| `@macAddress` | Primary MAC address |
| `@osName` | Operating system name |
| `@osVersion` | Operating system version |

### Inline formatting

Lines also support a small set of inline rich text tags:

| Tag | Example |
| --- | --- |
| Bold | `<b>text</b>` |
| Italic | `<i>text</i>` |
| Underline | `<u>text</u>` |
| Named color | `<color=green>text</color>` |
| Hex color | `<color=#800080>text</color>` |

Untagged text uses TED's luminance-based black or white text color. Tagged colors are drawn as specified.

## Examples

We've provided an example PowerShell script to make deploying with your RMM quick and easy. You can find the script [here.](https://github.com/HealthITAU/TED/blob/main/examples/rmm_deploy.ps1)

TED is a CLI tool and can be called like so:

```shell
ted -di path/to/dark_image.png -li path/to/light_image.png -f Arial -fs 14 -ls 5 -hp 10 -vp 10 -line "Hello, @userName!" -line "You are using @osName on @machineName."
```

Inline rich text formatting can be used inside lines:

```shell
ted -line "<color=purple>OS: </color><color=green>@osName</color>" -line "<b><u>Device:</u></b> <i>@machineName</i>"
```

In terms of real world usage, we've found this to be a fantastic tool for helping clients quickly identify key information about their machine whilst on the phone with them.

![TED Screenshot 1]( https://healthit.com.au/TEDScreenshot1_res1.png) ![TED Screenshot 2]( https://healthit.com.au/TEDScreenshot2_res1.png)

## Adding tokens

Adding tokens to the text system requires editing the source and compiling your own binary.
Tokens are stored in `TokenLookup` inside [`Tokenizer.cs`](https://github.com/HealthITAU/TED/blob/main/src/TED/TED.Utils/Tokenizer.cs).

Add your token as the dictionary key and the substituted value provider as the value, then compile and use your new token in a `-line` value.

## Building from source

If you would rather not trust the prebuilt binaries, TED builds from source with only the .NET 8 SDK. The build script produces all three architectures in both framework-dependent and self-contained flavours, and writes a `SHA256SUMS.txt` manifest alongside them:

```powershell
pwsh build/Publish.ps1
```

Artifacts (and `SHA256SUMS.txt`) are written to `artifacts/publish`. WinForms apps cross-publish to the `win-*` runtimes from Linux or macOS as well, so this also runs on non-Windows CI.

### Automated release pipeline

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds every architecture, optionally signs the binaries, generates `SHA256SUMS.txt`, and attaches everything to a GitHub release. Standard `windows-latest` runners are free and unlimited on public repositories.

### Code signing

Signing is optional and disabled until you provide a certificate, so the pipeline works before you have one. TED uses a two-tier internal PKI: an offline **root CA** deployed to your endpoints' trust stores, and a **leaf** certificate that CI signs with.

> **Important — the Code Signing EKU.** The whole certificate chain must carry the Code Signing EKU (`1.3.6.1.5.5.7.3.3`). `New-SelfSignedCertificate` **defaults to Client/Server Authentication** when no EKU is given, which silently breaks signing (Windows reports *"The certificate is not valid for the requested usage"*, and `Get-AuthenticodeSignature` never returns `Valid`). Windows intersects EKUs down the chain, so **both the root and the leaf** must set Code Signing explicitly — as below.

**1. Create the root CA** (once; keep its private key offline). On a trusted Windows machine:

```powershell
$ca = New-SelfSignedCertificate `
  -Type Custom `
  -Subject 'CN=SalientMSP Code Signing Root CA' `
  -KeyUsage CertSign, CRLSign `
  -KeyAlgorithm RSA -KeyLength 4096 -HashAlgorithm SHA256 `
  -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(10) `
  -CertStoreLocation Cert:\CurrentUser\My `
  -TextExtension @('2.5.29.19={critical}{text}CA=true', '2.5.29.37={text}1.3.6.1.5.5.7.3.3')
```

**2. Issue the leaf** from that root:

```powershell
$code = New-SelfSignedCertificate `
  -Type Custom `
  -Subject 'CN=SalientMSP Code Signing' `
  -KeyUsage DigitalSignature `
  -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
  -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(3) `
  -CertStoreLocation Cert:\CurrentUser\My -Signer $ca `
  -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
```

**3. Export.** `New-SelfSignedCertificate` stores the keys in your Windows profile (no password prompt); a password only exists once you export a `.pfx`, and **you choose it at export time** — that value becomes `CODESIGN_PW`.

```powershell
$pw = Read-Host -AsSecureString 'PFX export password'
Export-Certificate    -Cert $ca   -FilePath .\RootCA.cer                    # public root -> deploy to the fleet
Export-PfxCertificate -Cert $ca   -FilePath .\RootCA.pfx   -Password $pw    # root key -> keep OFFLINE, secure
Export-PfxCertificate -Cert $code -FilePath .\CodeSign.pfx -Password $pw    # leaf key -> used by CI
[Convert]::ToBase64String([IO.File]::ReadAllBytes('.\CodeSign.pfx')) | Set-Clipboard
```

**4. Wire it up:**

- Add the base64 leaf pfx as the `CODESIGN_PFX_B64` repository secret and the password as `CODESIGN_PW`. Never commit a `.pfx`; keep the **root** `.pfx` offline (only the leaf goes into CI).
- Deploy the public root (`RootCA.cer`) to endpoints — see [Deploying the code-signing root CA](#deploying-the-code-signing-root-ca).
- Set `$ExpectedSignerThumbprint` in `rmm_deploy.ps1` to the leaf thumbprint (`$code.Thumbprint`).

**Verify the chain** before rolling out — Code Signing EKU present, no `NotValidForUsage`:

```powershell
$c = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
$c.ChainPolicy.RevocationMode = 'NoCheck'
[void]$c.ChainPolicy.ApplicationPolicy.Add('1.3.6.1.5.5.7.3.3')
$c.Build($code)   # True once the root is trusted locally (RevocationStatusUnknown alone is fine for self-signed)
```

The signing step timestamps every binary, so signatures remain valid after the certificate expires. When you rotate the certificate, update `CODESIGN_PFX_B64`/`CODESIGN_PW`, the deployed root, and `$ExpectedSignerThumbprint` together.

## Deploying the code-signing root CA

For signed binaries to be trusted silently on managed endpoints, the Salient code-signing **root** certificate must be present in each machine's trust stores. [`deploy_rootca.ps1`](https://github.com/salientmsp/TED/blob/main/examples/deploy_rootca.ps1) imports the public root certificate into `LocalMachine\Root` (chain trust) and `LocalMachine\TrustedPublisher` (silent execution of signed binaries). It is idempotent — safe to run every RMM cycle — and refuses anything carrying a private key.

Run it elevated / as SYSTEM, passing the certificate as a path or https URL. Under Gorelo, pass the file variable token so it is substituted at runtime:

```powershell
powershell -ExecutionPolicy Bypass -File deploy_rootca.ps1 -CertSource '$gorelo:file.SalientCodeSigningRootCACert'
```

For RMMs that only run a pasted script body (no arguments), use [`deploy_rootca_gorelo.ps1`](https://github.com/salientmsp/TED/blob/main/examples/deploy_rootca_gorelo.ps1) instead — it is parameter-free, with the file variable token set inline at the top, so you can paste it straight into a Gorelo PowerShell task (run as SYSTEM).

To replace a superseded root (for example, one issued with the wrong EKU), list its thumbprint in `$RemoveThumbprints` (or the `-RemoveThumbprints` parameter). The script removes those exact thumbprints from the stores before importing the current root, so re-running the task cleans up every endpoint that received the old certificate.

Set `$ExpectedRootThumbprint` (or `-ExpectedRootThumbprint`) to the thumbprint the deployed certificate must match. The script verifies the resolved certificate against it and refuses to trust anything else, guarding against a wrong or swapped source being pushed fleet-wide.

Once the root CA is deployed and releases are signed, set `$ExpectedSignerThumbprint` in `rmm_deploy.ps1` to require that binaries are signed by your certificate.

## Verifying downloads

The example deployment script supports supply-chain hardening. In [`rmm_deploy.ps1`](https://github.com/salientmsp/TED/blob/main/examples/rmm_deploy.ps1) you can:

- Set `$PinnedReleaseTag` to a reviewed release (e.g. `v2.0.1`) instead of always tracking the latest.
- Keep `$VerifyDownloads = $true` to check every downloaded binary against the release's `SHA256SUMS.txt` before it runs; a mismatch or missing manifest aborts the install.
- Set `$ExpectedSignerThumbprint` to require binaries be Authenticode-signed by your own certificate.

## Contributing

Contributions to TED are welcome! If you find any issues or have suggestions for improvement, please feel free to open an issue or submit a pull request.

## Supporting the project

:heart: the project and would like to show your support? Please consider donating to one of our favourite charities:
- [Love Your Sister (Sam's 1000)](https://www.loveyoursister.org/makeadonation)
- [Black Dog](https://donate.blackdoginstitute.org.au/)
- [RedFrogs Australia](https://redfrogs.com.au/support/donate)

Please let us know if you have donated because of this project!

## License

This project is licensed under the [GNU General Public License v3.0](https://github.com/HealthITAU/TED/blob/main/LICENSE)

## Contact

For any inquiries or further information, please contact the developers:
- [dev@healthit.com.au](mailto:dev@healthit.com.au?subject=[GitHub]%20TED%20Query)
