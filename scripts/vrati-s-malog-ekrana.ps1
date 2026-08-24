<#
    vrati-s-malog-ekrana.ps1

    Vrati PROZORE i IKONE RADNE POVRSINE sa sporednog (Hyper-V) zaslona na glavni.

    ZASTO
      Od 23.8.2026. Hyper-V display OSTAJE aktivan, jer izvorni Vulkan i OpenGL
      bez njega ne prezive (izmjereno: padnu 13-32 s nakon deaktivacije).
      Cijena je sicusni drugi zaslon 640x480 na koji zna odlutati poneki prozor.

      A ikone odlutaju iz posebnog razloga: Windows ih slaze od gornjeg LIJEVOG
      kuta VIRTUALNOG desktopa. Kad je sporedni zaslon lijevo od glavnog,
      ishodiste virtualnog desktopa je NA NJEMU - pa nova mapa zavrsi ondje.

    KAKO IKONE
      Ikone su stavke ListViewa koji pripada Exploreru. Pozicija se ne da
      procitati obicnim SendMessage - LVM_GETITEMPOSITION ocekuje POINT u
      adresnom prostoru VLASNIKA prozora. Zato VirtualAllocEx u Exploreru,
      ReadProcessMemory natrag.
      Postavljanje je lakse: LVM_SETITEMPOSITION nosi x i y spakirane u lParam.

      Koordinate stavki su u klijentskim koordinatama ListViewa, a on pokriva
      cijeli virtualni desktop. Zato se na njih dodaje ishodiste virtualnog
      desktopa da se dobiju zaslonske koordinate.

    UPOTREBA
      .\vrati-s-malog-ekrana.ps1              # prozori + ikone
      .\vrati-s-malog-ekrana.ps1 -Popis       # samo ispisi sto bi premjestio
      .\vrati-s-malog-ekrana.ps1 -SamoIkone
      .\vrati-s-malog-ekrana.ps1 -SamoProzori
      .\vrati-s-malog-ekrana.ps1 -Quiet       # bez ispisa (za zakazani zadatak)
#>
[CmdletBinding()]
param(
  [switch]$Popis,
  [switch]$SamoIkone,
  [switch]$SamoProzori,
  [switch]$Quiet
)

Add-Type -AssemblyName System.Windows.Forms
function Reci($m) { if (-not $Quiet) { Write-Host $m } }

$sig = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class VME {
  public delegate bool EnumProc(IntPtr h, IntPtr p);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct WINDOWPLACEMENT {
    public int length, flags, showCmd;
    public POINT ptMinPosition, ptMaxPosition;
    public RECT rcNormalPosition;
  }

  // --- prozori ---
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

  // --- ikone radne povrsine ---
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string win);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string win);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint acc, bool inh, uint pid);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, IntPtr size, uint typ, uint prot);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, IntPtr size, uint typ);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, IntPtr n, out IntPtr got);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);

  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_TOOLWINDOW = 0x00000080;
  public const int DWMWA_CLOAKED = 14;
  public const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
  public const int SW_RESTORE = 9, SW_MAXIMIZE = 3, SW_SHOWMAXIMIZED = 3;

  public const uint LVM_GETITEMCOUNT    = 0x1004;
  public const uint LVM_GETITEMPOSITION = 0x1010;
  public const uint LVM_SETITEMPOSITION = 0x100F;

  const uint PROCESS_VM_OPERATION = 0x0008, PROCESS_VM_READ = 0x0010,
             PROCESS_VM_WRITE = 0x0020, PROCESS_QUERY_INFORMATION = 0x0400;
  const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000;
  const uint PAGE_READWRITE = 0x04;

  public static bool Cloaked(IntPtr h) {
    int v;
    if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out v, 4) != 0) return false;
    return v != 0;
  }
  public static string Naslov(IntPtr h) {
    int n = GetWindowTextLengthW(h);
    if (n <= 0) return "";
    var sb = new StringBuilder(n + 1);
    GetWindowTextW(h, sb, sb.Capacity);
    return sb.ToString();
  }

  // ListView radne povrsine. Zna biti pod Progmanom ili pod nekim WorkerW -
  // ovisno o tome je li aktivna pozadina koja se mijenja.
  public static IntPtr NadiDesktopListView() {
    IntPtr progman = FindWindowW("Progman", null);
    IntPtr def = FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
    if (def != IntPtr.Zero) {
      IntPtr lv = FindWindowExW(def, IntPtr.Zero, "SysListView32", null);
      if (lv != IntPtr.Zero) return lv;
    }
    IntPtr worker = IntPtr.Zero;
    while ((worker = FindWindowExW(IntPtr.Zero, worker, "WorkerW", null)) != IntPtr.Zero) {
      def = FindWindowExW(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
      if (def != IntPtr.Zero) {
        IntPtr lv = FindWindowExW(def, IntPtr.Zero, "SysListView32", null);
        if (lv != IntPtr.Zero) return lv;
      }
    }
    return IntPtr.Zero;
  }

  public static int BrojIkona(IntPtr lv) {
    return (int)SendMessageW(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
  }

  // Vraca pozicije svih ikona. Trazi memoriju u Explorerovu procesu jer
  // LVM_GETITEMPOSITION pise POINT u adresni prostor vlasnika prozora.
  public static POINT[] PozicijeIkona(IntPtr lv, int broj) {
    uint pid;
    GetWindowThreadProcessId(lv, out pid);
    IntPtr proc = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION, false, pid);
    if (proc == IntPtr.Zero) return null;
    IntPtr udaljeni = VirtualAllocEx(proc, IntPtr.Zero, (IntPtr)8, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (udaljeni == IntPtr.Zero) { CloseHandle(proc); return null; }

    var rez = new POINT[broj];
    var buf = new byte[8];
    for (int i = 0; i < broj; i++) {
      SendMessageW(lv, LVM_GETITEMPOSITION, (IntPtr)i, udaljeni);
      IntPtr got;
      if (ReadProcessMemory(proc, udaljeni, buf, (IntPtr)8, out got)) {
        rez[i].X = BitConverter.ToInt32(buf, 0);
        rez[i].Y = BitConverter.ToInt32(buf, 4);
      }
    }
    VirtualFreeEx(proc, udaljeni, IntPtr.Zero, MEM_RELEASE);
    CloseHandle(proc);
    return rez;
  }

  // Postavljanje ne treba tudju memoriju - x i y stanu u lParam.
  public static void PostaviIkonu(IntPtr lv, int idx, int x, int y) {
    IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
    SendMessageW(lv, LVM_SETITEMPOSITION, (IntPtr)idx, lp);
  }
}
'@
if (-not ('VME' -as [type])) { Add-Type -TypeDefinition $sig }

# ---------------------------------------------------------------- ZASLONI
$svi      = [System.Windows.Forms.Screen]::AllScreens
$glavni   = $svi | Where-Object { $_.Primary } | Select-Object -First 1
$sporedni = @($svi | Where-Object { -not $_.Primary })
$virt     = [System.Windows.Forms.SystemInformation]::VirtualScreen

Reci ''
Reci '  Zasloni:'
foreach ($s in $svi) {
  Reci ('    {0,-14} {1,-9} {2}x{3} @ {4},{5}' -f $s.DeviceName,
        $(if ($s.Primary) { 'GLAVNI' } else { 'sporedni' }),
        $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y)
}
Reci ("    virtualni desktop: ishodiste ({0},{1})" -f $virt.X, $virt.Y)
Reci ''

if (-not $sporedni.Count) { Reci '  Nema sporednog zaslona - nema sto vracati.'; return }

function NaSporednom([int]$x, [int]$y) {
  foreach ($s in $script:sporedni) {
    $b = $s.Bounds
    if ($x -ge $b.Left -and $x -lt $b.Right -and $y -ge $b.Top -and $y -lt $b.Bottom) { return $true }
  }
  return $false
}

$ukupno = 0

# ---------------------------------------------------------------- PROZORI
if (-not $SamoIkone) {
  $ga = $glavni.WorkingArea
  $script:brojacP = 0
  $cb = [VME+EnumProc] {
    param($h, $p)
    if (-not [VME]::IsWindowVisible($h)) { return $true }
    if ([VME]::Cloaked($h)) { return $true }
    $naslov = [VME]::Naslov($h)
    if ([string]::IsNullOrWhiteSpace($naslov)) { return $true }
    if ([VME]::GetWindowLongPtrW($h, [VME]::GWL_EXSTYLE).ToInt64() -band [VME]::WS_EX_TOOLWINDOW) { return $true }

    $r = New-Object VME+RECT
    if (-not [VME]::GetWindowRect($h, [ref]$r)) { return $true }
    $sx = [int](($r.Left + $r.Right) / 2)
    $sy = [int](($r.Top + $r.Bottom) / 2)
    if (-not (NaSporednom $sx $sy)) { return $true }

    # NE koristiti $pid - rezervirano ime u PowerShellu
    $procId = 0
    [void][VME]::GetWindowThreadProcessId($h, [ref]$procId)
    $proc = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '?' }

    $sirina = $r.Right - $r.Left
    $visina = $r.Bottom - $r.Top
    $nx = [Math]::Max($script:gaLeft, [Math]::Min($script:gaLeft + 60, $script:gaRight - $sirina))
    $ny = [Math]::Max($script:gaTop,  [Math]::Min($script:gaTop + 60,  $script:gaBottom - $visina))

    if ($script:samoPopis) {
      Reci ("  [prozor, bi premjestio] {0,-20} '{1}'  s ({2},{3})" -f $proc, $naslov, $r.Left, $r.Top)
    } else {
      $wp = New-Object VME+WINDOWPLACEMENT
      $wp.length = [Runtime.InteropServices.Marshal]::SizeOf($wp)
      [void][VME]::GetWindowPlacement($h, [ref]$wp)
      $bioMaks = ($wp.showCmd -eq [VME]::SW_SHOWMAXIMIZED)
      if ($bioMaks) { [void][VME]::ShowWindow($h, [VME]::SW_RESTORE); Start-Sleep -Milliseconds 150 }
      [void][VME]::SetWindowPos($h, [IntPtr]::Zero, $nx, $ny, 0, 0,
                ([VME]::SWP_NOSIZE -bor [VME]::SWP_NOZORDER -bor [VME]::SWP_NOACTIVATE))
      if ($bioMaks) { Start-Sleep -Milliseconds 150; [void][VME]::ShowWindow($h, [VME]::SW_MAXIMIZE) }
      Reci ("  prozor vracen: {0,-20} '{1}'{2}" -f $proc, $naslov, $(if ($bioMaks) { '  (bio maksimiziran)' } else { '' }))
      $script:brojacP++
    }
    return $true
  }
  $script:samoPopis = [bool]$Popis
  $script:gaLeft = $ga.Left; $script:gaTop = $ga.Top
  $script:gaRight = $ga.Right; $script:gaBottom = $ga.Bottom
  [void][VME]::EnumWindows($cb, [IntPtr]::Zero)
  $ukupno += $script:brojacP
}

# ------------------------------------------------------------------ IKONE
if (-not $SamoProzori) {
  $lv = [VME]::NadiDesktopListView()
  if ($lv -eq [IntPtr]::Zero) {
    Reci '  [!] ne mogu naci ListView radne povrsine - ikone preskacem'
  } else {
    $broj = [VME]::BrojIkona($lv)
    $poz  = [VME]::PozicijeIkona($lv, $broj)
    if ($null -eq $poz) {
      Reci '  [!] ne mogu procitati pozicije ikona (Explorer nedostupan)'
    } else {
      # Koordinate stavki su klijentske; ListView pokriva cijeli virtualni
      # desktop, pa se dodaje njegovo ishodiste.
      $zauzeto = New-Object System.Collections.Generic.List[object]
      $lutalice = New-Object System.Collections.Generic.List[object]
      for ($i = 0; $i -lt $broj; $i++) {
        $ex = $poz[$i].X + $virt.X
        $ey = $poz[$i].Y + $virt.Y
        if (NaSporednom $ex $ey) { $lutalice.Add(@{ I = $i; X = $ex; Y = $ey }) }
        else { $zauzeto.Add(@{ X = $poz[$i].X; Y = $poz[$i].Y }) }
      }

      if (-not $lutalice.Count) {
        Reci '  ikone: nijedna nije na sporednom zaslonu'
      } else {
        # razmak mreze prema postavkama sustava
        $korakX = [Math]::Abs([System.Windows.Forms.SystemInformation]::IconHorizontalSpacing)
        $korakY = [Math]::Abs([System.Windows.Forms.SystemInformation]::IconVerticalSpacing)
        if ($korakX -lt 40) { $korakX = 75 }
        if ($korakY -lt 40) { $korakY = 90 }

        # slobodna mjesta trazimo u KLIJENTSKIM koordinatama, na glavnom zaslonu
        $pocX = $glavni.Bounds.Left - $virt.X
        $pocY = $glavni.Bounds.Top  - $virt.Y
        $maxY = $glavni.Bounds.Bottom - $virt.Y - $korakY

        function Slobodno([int]$x, [int]$y) {
          foreach ($z in $script:zauzetoRef) {
            if ([Math]::Abs($z.X - $x) -lt ($script:kx / 2) -and [Math]::Abs($z.Y - $y) -lt ($script:ky / 2)) { return $false }
          }
          return $true
        }
        $script:zauzetoRef = $zauzeto
        $script:kx = $korakX; $script:ky = $korakY

        foreach ($l in $lutalice) {
          $nx = $pocX; $ny = $pocY
          while (-not (Slobodno $nx $ny)) {
            $ny += $korakY
            if ($ny -gt $maxY) { $ny = $pocY; $nx += $korakX }
          }
          if ($Popis) {
            Reci ("  [ikona {0}, bi premjestio] s ({1},{2}) na ({3},{4})" -f $l.I, $l.X, $l.Y, ($nx + $virt.X), ($ny + $virt.Y))
          } else {
            [VME]::PostaviIkonu($lv, $l.I, $nx, $ny)
            Reci ("  ikona vracena: stavka {0}  s ({1},{2}) na ({3},{4})" -f $l.I, $l.X, $l.Y, ($nx + $virt.X), ($ny + $virt.Y))
            $ukupno++
          }
          $zauzeto.Add(@{ X = $nx; Y = $ny })
        }
      }
    }
  }
}

Reci ''
if ($Popis) { Reci '  (samo popis - nista nije premjesteno)' }
else { Reci "  Ukupno vraceno: $ukupno" }
Reci ''
