$out='C:\Users\Public\wgc-as-system-result.txt'
function Log($m){ Add-Content -Path $out -Value "$(Get-Date -Format 'HH:mm:ss.fff')  $m" -Encoding UTF8 }
Set-Content -Path $out -Value "=== start ===" -Encoding UTF8
try {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  Log "korisnik : $($id.Name)"
  Log "IsSystem : $($id.IsSystem)"
  Log "sesija   : $((Get-Process -Id $PID).SessionId)"
  Log "TEMP     : $env:TEMP"
} catch { Log "identitet pao: $_" }
try { Add-Type -AssemblyName System.Windows.Forms; Log "System.Windows.Forms ucitan" } catch { Log "Add-Type pao: $_" }
try { Log "displaya : $([System.Windows.Forms.Screen]::AllScreens.Count)" } catch { Log "AllScreens pao: $_" }
Log "--- pokrecem wgctest2 ---"
try {
  $r = & 'C:\Users\Public\sunshine-gpup-setup\scripts\wgctest2.ps1' 2>&1
  foreach($line in $r){ Log "  $line" }
  Log "--- wgctest2 zavrsio ---"
} catch {
  Log "IZNIMKA: $($_.Exception.GetType().FullName)"
  Log "PORUKA : $($_.Exception.Message)"
  if($_.Exception.InnerException){ Log "INNER  : $($_.Exception.InnerException.Message)" }
}
Log "=== kraj ==="