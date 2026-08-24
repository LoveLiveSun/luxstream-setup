<#
    ccd-dump.ps1

    Ispis CCD (Connecting and Configuring Displays) stanja sa STRUKTURAMA PO
    SPECIFIKACIJI. Prethodni pokusaj je koristio `ulong` za DISPLAYCONFIG_RATIONAL
    i `ulong[]` za mode union, pa je prevoditelj poravnao polja i sve iza toga se
    pomaknulo - vrijednosti su ispale besmislene.

    Tocne velicine:
      DISPLAYCONFIG_PATH_SOURCE_INFO  20 B
      DISPLAYCONFIG_PATH_TARGET_INFO  48 B
      DISPLAYCONFIG_PATH_INFO         72 B
      DISPLAYCONFIG_MODE_INFO         64 B

    UPOTREBA
      .\ccd-dump.ps1 -Oznaka "s-monitorom"
#>
[CmdletBinding()]
param([string]$Oznaka = 'sada')

$src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CCD2 {
  [StructLayout(LayoutKind.Sequential)]
  public struct LUID { public uint LowPart; public int HighPart; }

  [StructLayout(LayoutKind.Sequential)]
  public struct RATIONAL { public uint Numerator; public uint Denominator; }

  [StructLayout(LayoutKind.Sequential)]
  public struct SOURCE_INFO {          // 20 B
    public LUID adapterId;             //  8
    public uint id;                    //  4
    public uint modeInfoIdx;           //  4
    public uint statusFlags;           //  4
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct TARGET_INFO {          // 48 B
    public LUID adapterId;             //  8
    public uint id;                    //  4
    public uint modeInfoIdx;           //  4
    public uint outputTechnology;      //  4
    public uint rotation;              //  4
    public uint scaling;               //  4
    public RATIONAL refreshRate;       //  8  <- dva UINT32, NE ulong
    public uint scanLineOrdering;      //  4
    [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;  // 4
    public uint statusFlags;           //  4
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct PATH_INFO {            // 72 B
    public SOURCE_INFO sourceInfo;
    public TARGET_INFO targetInfo;
    public uint flags;
  }

  [StructLayout(LayoutKind.Sequential, Size = 64)]
  public struct MODE_INFO {            // 64 B, union se ne raspakirava
    public uint infoType;
    public uint id;
    public LUID adapterId;
    // ostatak (48 B union) je pokriven atributom Size
  }

  [DllImport("user32.dll")]
  public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);

  [DllImport("user32.dll")]
  public static extern int QueryDisplayConfig(uint flags, ref uint numPath,
    [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, IntPtr topologyId);

  public static string Dump(uint flags, string naslov) {
    var sb = new StringBuilder();
    sb.AppendLine("--- " + naslov + " ---");
    sb.AppendLine("  velicine: PATH_INFO=" + Marshal.SizeOf(typeof(PATH_INFO))
                + " (mora 72), MODE_INFO=" + Marshal.SizeOf(typeof(MODE_INFO)) + " (mora 64)");

    uint np, nm;
    int rc = GetDisplayConfigBufferSizes(flags, out np, out nm);
    if (rc != 0) { sb.AppendLine("  GetDisplayConfigBufferSizes rc=" + rc); return sb.ToString(); }

    var paths = new PATH_INFO[np];
    var modes = new MODE_INFO[nm];
    rc = QueryDisplayConfig(flags, ref np, paths, ref nm, modes, IntPtr.Zero);
    if (rc != 0) { sb.AppendLine("  QueryDisplayConfig rc=" + rc); return sb.ToString(); }

    sb.AppendLine("  putova=" + np + "  modova=" + nm);
    for (int i = 0; i < np; i++) {
      var p = paths[i];
      bool active = (p.flags & 0x1) != 0;
      sb.AppendLine(string.Format(
        "  put {0}: aktivan={1,-5} flags=0x{2:X}",
        i, active, p.flags));
      sb.AppendLine(string.Format(
        "      izvor  adapter={0:X}-{1}  id={2}  modeIdx={3}  status=0x{4:X}",
        p.sourceInfo.adapterId.LowPart, p.sourceInfo.adapterId.HighPart,
        p.sourceInfo.id, (int)p.sourceInfo.modeInfoIdx, p.sourceInfo.statusFlags));
      sb.AppendLine(string.Format(
        "      cilj   adapter={0:X}-{1}  id={2}  modeIdx={3}  tech={4}  scaling={5}",
        p.targetInfo.adapterId.LowPart, p.targetInfo.adapterId.HighPart,
        p.targetInfo.id, (int)p.targetInfo.modeInfoIdx,
        p.targetInfo.outputTechnology, p.targetInfo.scaling));
      sb.AppendLine(string.Format(
        "             refresh={0}/{1}  available={2}  status=0x{3:X}",
        p.targetInfo.refreshRate.Numerator, p.targetInfo.refreshRate.Denominator,
        p.targetInfo.targetAvailable, p.targetInfo.statusFlags));
    }
    return sb.ToString();
  }
}
'@
if (-not ('CCD2' -as [type])) { Add-Type -TypeDefinition $src }

$out = "C:\Users\Public\ccd-$Oznaka.txt"
$R = New-Object System.Collections.Generic.List[string]
$R.Add("===== CCD  $Oznaka  $(Get-Date -Format 'HH:mm:ss') =====")
$R.Add('')
# QDC_ALL_PATHS = 1, QDC_ONLY_ACTIVE_PATHS = 2
[CCD2]::Dump(2, 'AKTIVNI PUTEVI') -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $R.Add($_) }
$R.Add('')
[CCD2]::Dump(1, 'SVI PUTEVI')     -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $R.Add($_) }
$R.Add('')

Add-Type -AssemblyName System.Windows.Forms
$R.Add('--- prikaceni displayi ---')
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  $R.Add(("  {0,-14} primary={1,-5} {2}x{3} @ {4},{5}" -f $s.DeviceName,$s.Primary,$s.Bounds.Width,$s.Bounds.Height,$s.Bounds.X,$s.Bounds.Y))
}
$R.Add('')
$R.Add('--- VULKAN ---')
(& 'C:\Users\Public\sunshine-gpup-setup\scripts\vulkantest.ps1' 2>&1) | Select-String 'uredaja:|GeForce' | ForEach-Object { $R.Add("  $_") }

[System.IO.File]::WriteAllLines($out, $R, (New-Object System.Text.UTF8Encoding($false)))
$R | ForEach-Object { Write-Host $_ }
Write-Host "`nzapisano: $out"
