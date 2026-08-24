<#
    wgctest.ps1
    Izravan test Windows.Graphics.Capture (WGC) na svakom prikacenom displayu.

    ZASTO
      Sunshine i svi forkovi validiraju izlaze Desktop Duplicationom, koji na
      GPU-P adapteru pada s 0x80070057. WGC ide preko DWM-a. Prije nego se
      gradi vlastiti fork, treba DOKAZATI da WGC ondje radi.

    Interop sucelje je u C#-u (bez winmd reference), WinRT tipovi se koriste
    kroz PowerShellovu ugradenu podrsku.
#>

# --- C# dio: samo ono sto PowerShell ne moze izraziti -----------------------
$src = @'
using System;
using System.Runtime.InteropServices;

public static class WGCI {
  [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"),
   InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
  public interface IGraphicsCaptureItemInterop {
    IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
    IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
  }

  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }

  public static IntPtr MonitorAt(int x, int y) {
    var p = new POINT(); p.x = x; p.y = y;
    return MonitorFromPoint(p, 2);   // MONITOR_DEFAULTTONEAREST
  }

  // vraca IInspectable* na GraphicsCaptureItem, ili 0
  public static IntPtr CreateItemForMonitor(object activationFactory, IntPtr hmon, out string err) {
    err = null;
    try {
      var interop = (IGraphicsCaptureItemInterop)activationFactory;
      Guid iid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760"); // IGraphicsCaptureItem
      return interop.CreateForMonitor(hmon, ref iid);
    } catch (Exception e) { err = e.Message; return IntPtr.Zero; }
  }
}
'@
if (-not ('WGCI' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

Add-Type -AssemblyName System.Windows.Forms

# --- WinRT tipovi kroz PowerShell -------------------------------------------
$itemType = [Windows.Graphics.Capture.GraphicsCaptureItem, Windows.Graphics.Capture, ContentType=WindowsRuntime]
$supported = [Windows.Graphics.Capture.GraphicsCaptureSession, Windows.Graphics.Capture, ContentType=WindowsRuntime]::IsSupported()
Write-Host "GraphicsCaptureSession.IsSupported() = $supported"
Write-Host ''

$factory = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeMarshal]::GetActivationFactory($itemType)

foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  $cx = $s.Bounds.X + [int]($s.Bounds.Width / 2)
  $cy = $s.Bounds.Y + [int]($s.Bounds.Height / 2)
  Write-Host "--- $($s.DeviceName)  $($s.Bounds.Width)x$($s.Bounds.Height)  primary=$($s.Primary) ---"

  $hmon = [WGCI]::MonitorAt($cx, $cy)
  Write-Host ("  HMONITOR : 0x{0:X}" -f $hmon.ToInt64())
  if ($hmon -eq [IntPtr]::Zero) { Write-Host '  nema monitora na toj tocki'; continue }

  $err = $null
  $ptr = [WGCI]::CreateItemForMonitor($factory, $hmon, [ref]$err)
  if ($ptr -eq [IntPtr]::Zero) {
    Write-Host "  CreateForMonitor NEUSPJESAN: $err" -ForegroundColor Red
    continue
  }
  Write-Host "  CreateForMonitor OK  (IInspectable 0x$($ptr.ToInt64().ToString('X')))" -ForegroundColor Green

  try {
    $item = [System.Runtime.InteropServices.Marshal]::GetObjectForIUnknown($ptr)
    $dn = $item.DisplayName
    $sz = $item.Size
    Write-Host "  item.DisplayName = '$dn'   Size = $($sz.Width)x$($sz.Height)" -ForegroundColor Green
  } catch {
    Write-Host "  item ucitan ali svojstva nedostupna: $($_.Exception.Message)" -ForegroundColor Yellow
  }
  Write-Host ''
}
