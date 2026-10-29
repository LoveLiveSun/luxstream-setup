<#
    postavi-auto-prijavu.ps1

    Ukljuci automatsku prijavu, da se VM digne i sve krene bez covjeka.

    ZASTO JE OBAVEZNA
      Cijeli lanac visi o tome da postoji PRIJAVLJENA interaktivna sesija:
        - WGC (hvatanje slike) ne radi kao SYSTEM, samo u korisnickoj sesiji
        - promjene topologije displaya iz sesije 0 ne diraju korisnikov desktop
        - zadaci SunshineUser i StreamReady okidaju "pri prijavi"
      Bez automatske prijave VM se digne do zaslona za prijavu i nista se ne
      pokrene - Moonlight vidi host, ali se ne moze spojiti.

    LOZINKA
      NE pise se u registry kao obican tekst. Windows za to ima LSA tajne -
      `LsaStorePrivateData` pod imenom "DefaultPassword". Isto radi i
      Sysinternalsov Autologon. Ako u registryju vec stoji `DefaultPassword`
      kao tekst, ovaj skript ga MAKNE.

      Lozinku upisujes ti, ovdje, i nigdje se ne ispisuje ni zapisuje u log.

    PRAZNA LOZINKA
      Podrzana je. Ako racun nema lozinku, na pitanje samo pritisni Enter, ili
      dodaj -PraznaLozinka za neinteraktivnu upotrebu. Tada se ne sprema nikakva
      LSA tajna; umjesto toga se postojeci "DefaultPassword" OBRISE - i iz LSA
      tajni i iz registryja - jer bi Winlogon inace i dalje pokusavao prijavu sa
      starom lozinkom. Uz to se postavi LimitBlankPasswordUse = 0, jer Windows
      inace odbija automatsku prijavu racuna bez lozinke.

      Sigurnosno: racun bez lozinke znaci da svatko tko dodje do konzole moze
      uci. To je prihvatljivo samo na izoliranom VM-u kakav je ovaj.

    UPOTREBA (iz POVISENOG PowerShella)
      .\postavi-auto-prijavu.ps1                    # pita za lozinku (Enter = prazna)
      .\postavi-auto-prijavu.ps1 -PraznaLozinka     # racun bez lozinke
      .\postavi-auto-prijavu.ps1 -Korisnik ime      # drugi korisnik
      .\postavi-auto-prijavu.ps1 -Provjeri          # samo ispisi stanje
      .\postavi-auto-prijavu.ps1 -Iskljuci
#>
[CmdletBinding()]
param(
  [string]$Korisnik = $env:USERNAME,
  [string]$Domena   = $env:USERDOMAIN,
  [switch]$Provjeri,
  [switch]$Iskljuci,
  [switch]$PraznaLozinka,
  [System.Security.SecureString]$Lozinka
)

$ErrorActionPreference = 'Stop'
$kljuc = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Ok  ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Inf ($m) { Write-Host "  [..]   $m" }
function Bad ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn($m) { Write-Host "  [!]    $m" -ForegroundColor Yellow }

# ------------------------------------------------------------------ PROVJERA
function Stanje {
  $p = Get-ItemProperty $kljuc -ErrorAction SilentlyContinue
  $lsa = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
  Write-Host ''
  Write-Host '  Automatic logon:'
  '    AutoAdminLogon    : {0}' -f $(if ($null -ne $p.AutoAdminLogon) { $p.AutoAdminLogon } else { '(not set)' })
  '    DefaultUserName   : {0}' -f $(if ($p.DefaultUserName) { $p.DefaultUserName } else { '(empty)' })
  '    DefaultDomainName : {0}' -f $(if ($p.DefaultDomainName) { $p.DefaultDomainName } else { '(empty)' })
  '    DefaultPassword   : {0}' -f $(if ($p.DefaultPassword) { 'STORED AS PLAIN TEXT IN THE REGISTRY - bad' } else { '(not in the registry, good)' })
  '    LimitBlankPasswordUse : {0}' -f $(if ($null -ne $lsa.LimitBlankPasswordUse) { $lsa.LimitBlankPasswordUse } else { '(not set, Windows default = 1)' })
  Write-Host ''
}

if ($Provjeri) { Stanje; return }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Bad 'Needs an elevated PowerShell - it writes to HKLM and to LSA secrets.'
  return
}

# --------------------------------------------------------------------- LSA
$lsaSig = @'
using System;
using System.Runtime.InteropServices;

public class LSA {
  [StructLayout(LayoutKind.Sequential)]
  public struct LSA_UNICODE_STRING {
    public ushort Length, MaximumLength;
    public IntPtr Buffer;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct LSA_OBJECT_ATTRIBUTES {
    public int Length; public IntPtr RootDirectory, ObjectName;
    public int Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService;
  }

  [DllImport("advapi32.dll", SetLastError = true)]
  static extern uint LsaOpenPolicy(IntPtr sys, ref LSA_OBJECT_ATTRIBUTES attr, uint access, out IntPtr policy);
  [DllImport("advapi32.dll", SetLastError = true)]
  static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr data);
  [DllImport("advapi32.dll")]
  static extern uint LsaClose(IntPtr policy);
  [DllImport("advapi32.dll")]
  static extern int LsaNtStatusToWinError(uint status);

  const uint POLICY_CREATE_SECRET = 0x00000020;

  static LSA_UNICODE_STRING Str(IntPtr buf, int znakova) {
    var s = new LSA_UNICODE_STRING();
    s.Buffer = buf;
    s.Length = (ushort)(znakova * 2);
    s.MaximumLength = (ushort)((znakova + 1) * 2);
    return s;
  }

  // lozinkaBstr je BSTR iz SecureString-a; ovdje se samo proslijedi i odmah
  // zaboravi - pozivatelj ga oslobadja.
  public static int Spremi(string imeTajne, IntPtr lozinkaBstr, int duljina) {
    var attr = new LSA_OBJECT_ATTRIBUTES();
    attr.Length = Marshal.SizeOf(attr);
    IntPtr policy;
    uint st = LsaOpenPolicy(IntPtr.Zero, ref attr, POLICY_CREATE_SECRET, out policy);
    if (st != 0) return LsaNtStatusToWinError(st);

    IntPtr imeBuf = Marshal.StringToHGlobalUni(imeTajne);
    try {
      var ime = Str(imeBuf, imeTajne.Length);
      var val = Str(lozinkaBstr, duljina);
      IntPtr pval = Marshal.AllocHGlobal(Marshal.SizeOf(val));
      try {
        Marshal.StructureToPtr(val, pval, false);
        st = LsaStorePrivateData(policy, ref ime, pval);
      } finally { Marshal.FreeHGlobal(pval); }
    } finally {
      Marshal.FreeHGlobal(imeBuf);
      LsaClose(policy);
    }
    return LsaNtStatusToWinError(st);
  }

  // data == NULL brise tajnu (tako LsaStorePrivateData i radi). Koristi se za
  // racun s praznom lozinkom: stara neprazna lozinka NE smije ostati u LSA
  // tajnama, inace bi Winlogon i dalje pokusavao prijavu s njom.
  public static int Obrisi(string imeTajne) {
    var attr = new LSA_OBJECT_ATTRIBUTES();
    attr.Length = Marshal.SizeOf(attr);
    IntPtr policy;
    uint st = LsaOpenPolicy(IntPtr.Zero, ref attr, POLICY_CREATE_SECRET, out policy);
    if (st != 0) return LsaNtStatusToWinError(st);

    IntPtr imeBuf = Marshal.StringToHGlobalUni(imeTajne);
    try {
      var ime = Str(imeBuf, imeTajne.Length);
      st = LsaStorePrivateData(policy, ref ime, IntPtr.Zero);
    } finally {
      Marshal.FreeHGlobal(imeBuf);
      LsaClose(policy);
    }
    return LsaNtStatusToWinError(st);
  }
}
'@
if (-not ('LSA' -as [type])) { Add-Type -TypeDefinition $lsaSig }

# ----------------------------------------------------------------- ISKLJUCI
if ($Iskljuci) {
  Set-ItemProperty $kljuc -Name AutoAdminLogon -Value '0' -Type String
  Remove-ItemProperty $kljuc -Name DefaultPassword -ErrorAction SilentlyContinue
  Ok 'Automatic logon disabled.'
  Inf 'The DefaultPassword LSA secret remains, but is unused without AutoAdminLogon.'

  # Bez automatske prijave nema razloga dopustati prijavu racunima bez lozinke,
  # pa vrati Windowsovu zadanu vrijednost.
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -Value 1 -Type DWord
  Ok 'LimitBlankPasswordUse restored to 1 (Windows default)'

  Stanje
  return
}

# ---------------------------------------------------------------- UKLJUCI
Write-Host ''
Write-Host "  Automatic logon for: $Domena\$Korisnik" -ForegroundColor Cyan
Write-Host '  The password is stored in LSA secrets, not as plain text in the registry.'
Write-Host '  It is never printed and never written to a log.' -ForegroundColor Yellow
Write-Host '  If this account has NO password, just press Enter (or use -PraznaLozinka).' -ForegroundColor Yellow
Write-Host ''

# Prazna lozinka je valjan odabir - racun na ovom VM-u cesto nema lozinku.
if ($PraznaLozinka) {
  $prazna = $true
  Inf 'Blank password requested (-PraznaLozinka) - nothing will be stored.'
} else {
  if ($null -eq $Lozinka) {
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
      Bad 'No interactive console - cannot ask for the password. Run it manually.'
      Inf 'Za neinteraktivni poziv s praznom lozinkom dodaj -PraznaLozinka.'
      return
    }
    $Lozinka = Read-Host "  Password for $Domena\$Korisnik (Enter = blank)" -AsSecureString
  }
  # Prazan unos - ili SecureString bez ijednog znaka - znaci "racun nema lozinku".
  $prazna = ($null -eq $Lozinka) -or ($Lozinka.Length -eq 0)
}

if ($prazna) {
  Warn 'Blank password: no LSA secret will be stored.'

  # Stara lozinka ne smije ostati - ni u LSA tajnama ni kao tekst u registryju -
  # inace bi Winlogon i dalje pokusavao prijavu s njom.
  # 2 = ERROR_FILE_NOT_FOUND, 1168 = ERROR_NOT_FOUND. Tajna koja ionako ne
  # postoji nije greska - na svjezem VM-u je to uobicajen slucaj.
  $rc = [LSA]::Obrisi('DefaultPassword')
  if ($rc -ne 0 -and $rc -ne 2 -and $rc -ne 1168) { Bad "LsaStorePrivateData(delete) failed (Win32 $rc)"; return }
  Remove-ItemProperty $kljuc -Name DefaultPassword -ErrorAction SilentlyContinue
  if ($rc -eq 0) { Ok 'LSA secret "DefaultPassword" deleted; registry DefaultPassword removed' }
  else { Ok 'No LSA secret "DefaultPassword" existed; registry DefaultPassword removed' }

  # Windows inace odbija automatsku prijavu racuna bez lozinke (zadano je 1,
  # sto dopusta prazne lozinke samo na fizickoj konzoli i u praksi blokira
  # AutoAdminLogon). Zato ovdje ide 0.
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -Value 0 -Type DWord
  Ok 'LimitBlankPasswordUse = 0 - blank-password logon allowed'
  Warn 'Anyone with access to the console can sign in. Acceptable only on an isolated VM.'
} else {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Lozinka)
  try {
    $rc = [LSA]::Spremi('DefaultPassword', $bstr, $Lozinka.Length)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($bstr)
  }

  if ($rc -ne 0) { Bad "LsaStorePrivateData failed (Win32 $rc)"; return }
  Ok 'Password stored in LSA secrets'
}

Set-ItemProperty $kljuc -Name AutoAdminLogon    -Value '1'       -Type String
Set-ItemProperty $kljuc -Name DefaultUserName   -Value $Korisnik -Type String
Set-ItemProperty $kljuc -Name DefaultDomainName -Value $Domena   -Type String
Ok "AutoAdminLogon = 1, user $Domena\$Korisnik"

# Ako je netko ranije upisao lozinku kao tekst, makni je - LSA tajna je dovoljna.
if ((Get-ItemProperty $kljuc -ErrorAction SilentlyContinue).DefaultPassword) {
  Remove-ItemProperty $kljuc -Name DefaultPassword -ErrorAction SilentlyContinue
  Ok 'Removed the password that was stored as plain text in the registry'
}

Stanje
Write-Host '  Verify at the next boot.' -ForegroundColor Cyan
Write-Host ''
