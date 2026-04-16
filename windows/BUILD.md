# Building + signing the Windows installer

## Prereqs

1. **Flutter on Windows** with desktop enabled (`flutter config --enable-windows-desktop`)
2. **Inno Setup 6** installed (https://jrsoftware.org/isdl.php)
3. **Code-signing cert** — any of:
   - EV Authenticode cert (USB token, ~$400/yr): best; SmartScreen reputation immediate.
   - OV Authenticode cert (~$150/yr): good; SmartScreen warns until enough installs build reputation (~2-4 weeks).
   - Self-signed: local testing only; end users will see red SmartScreen warnings forever.

## One-time setup

Register your signtool with Inno Setup so `SignTool=fogged_signtool` resolves.
Open Inno Setup IDE → Tools → Configure Sign Tools… → Add:

- Name: `fogged_signtool`
- Command (Azure Trusted Signing): `azuresigntool sign -kvu "https://..." -kvc fogged-cert -kvi $CLIENT_ID -kvs $CLIENT_SECRET -kvt $TENANT_ID -tr http://timestamp.digicert.com -td sha256 -fd sha256 $f`
- Command (EV USB token with smart-card PIN prompt): `signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /a $f`

The literal `$f` is Inno's placeholder — Inno replaces it with the file path.

## Build + sign (CI-friendly)

```powershell
flutter build windows --release
cd windows
iscc installer.iss
```

Inno Setup runs `fogged_signtool` on both `Fogged-Setup.exe` and the embedded
uninstaller.exe. Verify with:

```powershell
signtool verify /pa /v Fogged-Setup.exe
```

## If your cert fails

If you don't have a cert yet and need to ship, at least **timestamp** the
unsigned installer so its file hash is provable later. Users will still see
SmartScreen warnings. Build reputation by submitting the `.exe` file hash
to Microsoft:
https://www.microsoft.com/en-us/wdsi/filesubmission
