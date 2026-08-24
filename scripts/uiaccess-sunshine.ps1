<#
    uiaccess-sunshine.ps1

    Daje Sunshineu UIAccess, da moze upravljati UAC dijalogom preko Moonlighta.

    PROBLEM
      UAC dijalog crta consent.exe na razini integriteta *System*. Sunshine radi
      kao korisnik na razini *High* i unos ubacuje preko SendInput. UIPI ne da
      procesu nize razine slati unos prozoru vise razine, pa se gumbi Da/Ne ne
      mogu ni kliknuti ni doseci tipkovnicom.

      Dok je Sunshine isao kao servis (SYSTEM) toga nije bilo - System razina
      smije slati unos svugdje. Ali kao SYSTEM ne moze aktivirati WGC, pa je
      podizanje razine integriteta zatvoren put.

    RJESENJE
      Windows za tocno ovu potrebu ima UIAccess - zastavicu `uiAccess="true"` u
      manifestu. Proces s njom zaobilazi UIPI i smije slati unos prozorima vise
      razine. Tako to rade citaci ekrana i alati za daljinsko upravljanje.

      Dokazano na ovom stroju: `osk.exe` (zaslonska tipkovnica) ima
      `<requestedExecutionLevel level="asInvoker" uiAccess="true"/>`, potpisan je,
      i preko Moonlighta MOZE potvrditi UAC dijalog.

    TRI UVJETA
      1. sigurna lokacija       - C:\Program Files\Sunshine  (vec zadovoljeno)
      2. uiAccess u manifestu   - ovaj skript upisuje
      3. Authenticode potpis    - ovaj skript potpisuje

    ZAMKA KOJA JE VEC POJEDENA
      Manifest u Sunshine.exe stoji pod jezicnim identifikatorom 0 (neutralno).
      Upis pod 1033 "uspije", ali FindResource i dalje nalazi izvorni pod 0 -
      promjena naizgled nestane. Zato se cita stvarni jezik i pise pod njim.

      I: citanje manifesta u ISTOM procesu koji ga je upravo mijenjao vraca
      kesiranu staru vrijednost. Provjera zato ide iz djeteta.

    UPOTREBA (iz POVISENOG PowerShella)
      .\uiaccess-sunshine.ps1              # primijeni
      .\uiaccess-sunshine.ps1 -Provjeri    # samo ispisi stanje, ne mijenjaj
      .\uiaccess-sunshine.ps1 -Vrati       # vrati izvornu binarnu datoteku
#>
[CmdletBinding()]
param(
  [string]$Exe = 'C:\Program Files\Sunshine\Sunshine.exe',
  [switch]$Provjeri,
  [switch]$Vrati,
  [string]$ImeCertifikata = 'Luxstream Code Signing'
)

$ErrorActionPreference = 'Stop'
function Ok  ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Inf ($m) { Write-Host "  [..]   $m" }
function Bad ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn($m) { Write-Host "  [!]    $m" -ForegroundColor Yellow }

$sig = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class UIA {
  public delegate bool EnumLangProc(IntPtr h, IntPtr type, IntPtr name, ushort lang, IntPtr param);

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr LoadLibraryExW(string f, IntPtr h, uint flags);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr FindResourceW(IntPtr h, IntPtr name, IntPtr type);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr LoadResource(IntPtr h, IntPtr res);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr LockResource(IntPtr d);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern uint SizeofResource(IntPtr h, IntPtr res);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool FreeLibrary(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool EnumResourceLanguagesW(IntPtr h, IntPtr type, IntPtr name, EnumLangProc cb, IntPtr param);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr BeginUpdateResourceW(string f, bool deleteExisting);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool UpdateResourceW(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint cb);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool EndUpdateResourceW(IntPtr h, bool discard);

  static List<ushort> jezici = new List<ushort>();
  static bool Cb(IntPtr h, IntPtr t, IntPtr n, ushort l, IntPtr p) { jezici.Add(l); return true; }

  // Vraca manifest kao tekst, ili null.
  public static string Citaj(string put) {
    IntPtr h = LoadLibraryExW(put, IntPtr.Zero, 0x22);
    if (h == IntPtr.Zero) return null;
    IntPtr hh = (IntPtr)(h.ToInt64() & ~3L);
    IntPtr r = FindResourceW(hh, (IntPtr)1, (IntPtr)24);
    if (r == IntPtr.Zero) { FreeLibrary(h); return null; }
    uint sz = SizeofResource(hh, r);
    IntPtr d = LockResource(LoadResource(hh, r));
    byte[] b = new byte[sz];
    Marshal.Copy(d, b, 0, (int)sz);
    FreeLibrary(h);
    return Encoding.UTF8.GetString(b);
  }

  // Jezicni identifikatori pod kojima manifest postoji. Bitno: upis pod krivim
  // jezikom "uspije", a promjena se ne vidi.
  public static ushort[] Jezici(string put) {
    IntPtr h = LoadLibraryExW(put, IntPtr.Zero, 0x22);
    if (h == IntPtr.Zero) return new ushort[0];
    IntPtr hh = (IntPtr)(h.ToInt64() & ~3L);
    jezici.Clear();
    EnumResourceLanguagesW(hh, (IntPtr)24, (IntPtr)1, Cb, IntPtr.Zero);
    FreeLibrary(h);
    return jezici.ToArray();
  }

  public static string Pisi(string put, string xml, ushort lang) {
    byte[] d = Encoding.UTF8.GetBytes(xml);
    IntPtr h = BeginUpdateResourceW(put, false);
    if (h == IntPtr.Zero) return "BeginUpdateResource: " + Marshal.GetLastWin32Error();
    if (!UpdateResourceW(h, (IntPtr)24, (IntPtr)1, lang, d, (uint)d.Length)) {
      int e = Marshal.GetLastWin32Error(); EndUpdateResourceW(h, true);
      return "UpdateResource: " + e;
    }
    if (!EndUpdateResourceW(h, false)) return "EndUpdateResource: " + Marshal.GetLastWin32Error();
    return "OK";
  }
}
"@
if (-not ('UIA' -as [type])) { Add-Type -TypeDefinition $sig }

# Citanje iz DJETETA - isti proces vraca kesirano staro stanje.
function Citaj-Svjeze([string]$put) {
  $kod = '$s=@"' + "`n" + $sig + "`n" + '"@' + @'

if (-not ('UIA' -as [type])) { Add-Type -TypeDefinition $s }
$m = [UIA]::Citaj($args[0])
if ($null -eq $m) { 'NEMA-MANIFESTA' } else { $m }
'@
  $tmp = Join-Path $env:TEMP "uia-citaj-$PID.ps1"
  [System.IO.File]::WriteAllText($tmp, $kod, (New-Object System.Text.UTF8Encoding($true)))
  $izlaz = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp $put 2>&1 | Out-String
  Remove-Item $tmp -ErrorAction SilentlyContinue
  return $izlaz
}

Write-Host ''
Write-Host '  UIAccess for Sunshine' -ForegroundColor White
Write-Host '  ===================='

if (-not (Test-Path $Exe)) { Bad "No $Exe"; return }
$backup = "$Exe.bez-uiaccess"

# --------------------------------------------------------------------- VRATI
if ($Vrati) {
  if (-not (Test-Path $backup)) { Bad "No backup at $backup"; return }
  Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Copy-Item $backup $Exe -Force
  Ok "Original binary restored from $backup"
  Inf 'Start Sunshine again (task SunshineUser).'
  return
}

# ------------------------------------------------------------------ PROVJERA
$manifest = Citaj-Svjeze $Exe
$imaUiAccess = $manifest -match 'uiAccess\s*=\s*"true"'
$potpis = Get-AuthenticodeSignature $Exe
$jezici = [UIA]::Jezici($Exe)

Write-Host ''
Write-Host '  Status:'
'    location      : {0}  ({1})' -f (Split-Path $Exe -Parent), $(if ((Split-Path $Exe -Parent) -like 'C:\Program Files*') { 'secure' } else { 'NOT secure' })
'    manifest      : {0}' -f $(if ($manifest -eq 'NEMA-MANIFESTA') { 'missing' } else { "present, language $($jezici -join ',')" })
'    uiAccess      : {0}' -f $(if ($imaUiAccess) { 'YES' } else { 'no' })
'    signature     : {0}' -f $potpis.Status
$esup = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableSecureUIAPaths
'    EnableSecureUIAPaths : {0}' -f $(if ($null -ne $esup) { $esup } else { '(zadano 1)' })
Write-Host ''

if ($Provjeri) { return }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Bad 'Needs an elevated PowerShell - it writes to Program Files and the machine certificate store.'
  return
}

# StreamReady svake minute dize Sunshine ako ga nema. Usred izmjene resursa ili
# potpisivanja to bi zakljucalo datoteku i sve palo. Zato ga privremeno gasimo.
$streamReadyBio = (Get-ScheduledTask -TaskName 'StreamReady' -ErrorAction SilentlyContinue).State
if ($streamReadyBio) {
  Disable-ScheduledTask -TaskName 'StreamReady' -ErrorAction SilentlyContinue | Out-Null
  Inf 'StreamReady temporarily disabled'
}

# --------------------------------------------------------------- 1. MANIFEST
if ($imaUiAccess) {
  Ok 'Manifest already has uiAccess - skipping the edit'
} else {
  if ($manifest -eq 'NEMA-MANIFESTA') { Bad 'No embedded manifest - this path does not work'; return }
  if ($manifest -notmatch '<requestedExecutionLevel\s+level="[^"]+"\s*/>') {
    Bad 'Unrecognised requestedExecutionLevel form - stop and look manually'
    return
  }

  if (-not (Test-Path $backup)) {
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Copy-Item $Exe $backup -Force
    Ok "Backup: $backup"
  } else {
    Inf "Backup already exists: $backup"
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
  }

  $novi = [regex]::Replace($manifest.Trim(),
            '<requestedExecutionLevel\s+level="([^"]+)"\s*/>',
            '<requestedExecutionLevel level="$1" uiAccess="true"/>')

  $lang = if ($jezici.Count) { $jezici[0] } else { [uint16]0 }
  Inf "Writing the manifest under language $lang"
  $r = [UIA]::Pisi($Exe, $novi, $lang)
  if ($r -ne 'OK') { Bad "Manifest write: $r"; return }

  $prov = Citaj-Svjeze $Exe
  if ($prov -match 'uiAccess\s*=\s*"true"') { Ok 'Manifest contains uiAccess="true"' }
  else { Bad 'The write reported OK but verification does not find uiAccess - stop'; return }
}

# --------------------------------------------------------------- 2. CERTIFIKAT
# Potpis mora ici POSLIJE izmjene resursa - izmjena bi ga inace ponistila.
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
          Where-Object { $_.Subject -eq "CN=$ImeCertifikata" -and $_.NotAfter -gt (Get-Date) } |
          Select-Object -First 1

if ($cert) {
  Ok "Certificate already exists: $($cert.Thumbprint)"
} else {
  Inf "Creating a code-signing certificate: CN=$ImeCertifikata"
  $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=$ImeCertifikata" `
            -CertStoreLocation Cert:\LocalMachine\My -KeyUsage DigitalSignature `
            -KeyLength 2048 -NotAfter (Get-Date).AddYears(10)
  Ok "Created: $($cert.Thumbprint)"
}

# UIAccess trazi da lanac zavrsi u pouzdanom korijenu STROJA.
foreach ($spremnik in 'Root', 'TrustedPublisher') {
  $st = New-Object Security.Cryptography.X509Certificates.X509Store($spremnik, 'LocalMachine')
  $st.Open('ReadWrite')
  if ($st.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }) {
    Inf "certificate already in $spremnik"
  } else {
    $st.Add($cert)
    Ok "certificate imported into $spremnik"
  }
  $st.Close()
}

# --------------------------------------------------------------- 3. POTPIS
Inf 'Signing the binary'
$rez = Set-AuthenticodeSignature -FilePath $Exe -Certificate $cert -HashAlgorithm SHA256
if ($rez.Status -eq 'Valid') { Ok "Signature: $($rez.Status)" }
else { Bad "Signature: $($rez.Status) - $($rez.StatusMessage)"; return }

# --------------------------------------------------------------- 4. ZAVRSNO
Write-Host ''
if ($streamReadyBio) {
  Enable-ScheduledTask -TaskName 'StreamReady' -ErrorAction SilentlyContinue | Out-Null
  Ok 'StreamReady re-enabled'
}

$konacni = Get-AuthenticodeSignature $Exe
$konMan  = Citaj-Svjeze $Exe
'    uiAccess : {0}' -f $(if ($konMan -match 'uiAccess\s*=\s*"true"') { 'YES' } else { 'NE' })
'    signature: {0}  ({1})' -f $konacni.Status, $konacni.SignerCertificate.Subject
Write-Host ''
Write-Host '  Start Sunshine again for the change to take effect:' -ForegroundColor Cyan
Write-Host '    Start-ScheduledTask -TaskName SunshineUser'
Write-Host ''
Write-Host '  Then trigger a UAC prompt over Moonlight and try clicking Yes.' -ForegroundColor Cyan
Write-Host '  If it fails, revert:  .\uiaccess-sunshine.ps1 -Vrati' -ForegroundColor Yellow
Write-Host ''
