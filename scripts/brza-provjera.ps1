<#
    brza-provjera.ps1

    Brzi pregled stanja Luxstream postave. Ne mijenja nista.

    Postoji zato sto su jednolinijske naredbe kroz razne ljuske krhke - navodnici,
    `%` i `$_` znaju stradati pri kopiranju. Ovo se pokrene i s mreznog mjesta:

      powershell -ExecutionPolicy Bypass -File \\lux1\Programi\brza-provjera.ps1

    Za punu provjeru po svim kategorijama koristi PROVJERA-prompt.md s Claudeom.
#>
[CmdletBinding()]
param([string]$Dom = 'C:\Program Files\Luxstream')

Add-Type -AssemblyName System.Windows.Forms
function Naslov($m) { Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }
function Red($k, $v, $ok) {
  $boja = if ($null -eq $ok) { 'Gray' } elseif ($ok) { 'Green' } else { 'Red' }
  Write-Host ("    {0,-30} {1}" -f $k, $v) -ForegroundColor $boja
}

Write-Host ''
Write-Host "  Luxstream - quick check   ($env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm'))" -ForegroundColor White
Write-Host '  ============================================================'

# ------------------------------------------------------------------ ZASLONI
Naslov 'Displays'
$svi = [System.Windows.Forms.Screen]::AllScreens
foreach ($s in $svi) {
  Write-Host ("    {0,-14} {1,-9} {2}x{3} @ {4},{5}" -f $s.DeviceName,
    $(if ($s.Primary) { 'PRIMARY' } else { 'secondary' }), $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y)
}
$v = [System.Windows.Forms.SystemInformation]::VirtualScreen
$glavni = $svi | Where-Object { $_.Primary } | Select-Object -First 1
$spor   = @($svi | Where-Object { -not $_.Primary })

Red 'display count' $svi.Count ($svi.Count -eq 2)
Red 'virtual desktop origin' ("({0},{1})  {2}x{3}" -f $v.X, $v.Y, $v.Width, $v.Height) ($v.X -eq 0 -and $v.Y -eq 0)

# Dolje-desno znaci: sporedni pocinje tocno na desnom i donjem rubu glavnog.
# Tada se dodiruju samo u tocki, mis ne moze prijeci, a ishodiste ostaje (0,0).
if ($spor.Count) {
  # Ne trazi tocnu tocku - ciljna se mijenja s rezolucijom glavnog. Dovoljno je
  # da je sporedni desno I ispod: ishodiste ostaje (0,0), a rubovi se ne dijele.
  $ciljX = $glavni.Bounds.Right; $ciljY = $glavni.Bounds.Bottom
  $dobro = ($spor[0].Bounds.X -ge $ciljX -and $spor[0].Bounds.Y -ge $ciljY)
  Red 'secondary right and below' ("({0},{1}); primary ends at ({2},{3})" -f $spor[0].Bounds.X, $spor[0].Bounds.Y, $ciljX, $ciljY) $dobro
} else {
  Red 'secondary display' 'MISSING - Vulkan/OpenGL will not survive' $false
}

# ------------------------------------------------------------------ GRAFIKA
Naslov 'Graphics'
$sk = Join-Path $Dom 'scripts'
function Pokreni($ime, $uzorak) {
  $p = Join-Path $sk $ime
  if (-not (Test-Path $p)) { return 'script missing' }
  $tmp = Join-Path $env:TEMP "bp-$PID.txt"
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$p`"") `
    -RedirectStandardOutput $tmp -NoNewWindow -Wait
  $t = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
  Remove-Item $tmp -ErrorAction SilentlyContinue
  $m = [regex]::Match("$t", $uzorak)
  if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '?' }
}
$vk = Pokreni 'vulkantest.ps1' 'uredaja:\s*(\d+)'
Red 'Vulkan devices' $vk ($vk -eq '1')
$gl = Pokreni 'gltest.ps1' 'GL_VERSION\s*:\s*(.+)'
Red 'OpenGL' $gl ($gl -match 'NVIDIA|AMD')

# ---------------------------------------------------------------------- VDD
Naslov 'VDD configuration'
$x = 'C:\VirtualDisplayDriver\vdd_settings.xml'
if (Test-Path $x) {
  $c = Get-Content $x -Raw
  $gpu = [regex]::Match($c, '<friendlyname>(.*?)</friendlyname>').Groups[1].Value
  $rez = ([regex]::Matches($c, '<resolution>')).Count
  Red 'GPU' $gpu ($gpu -match 'NVIDIA|Radeon')
  Red 'resolutions' $rez ($rez -eq 11)
} else { Red 'vdd_settings.xml' 'MISSING - VDD runs with defaults' $false }

# ----------------------------------------------------------------- SUNSHINE
Naslov 'Sunshine'
$p = Get-Process sunshine -ErrorAction SilentlyContinue
if ($p) {
  Red 'process' ("PID " + (($p | ForEach-Object Id) -join ', ')) (@($p).Count -eq 1)
  Red 'window hidden' $p[0].MainWindowHandle ($p[0].MainWindowHandle -eq 0)
} else { Red 'process' 'NOT RUNNING' $false }
$exe = 'C:\Program Files\Sunshine\Sunshine.exe'
if (Test-Path $exe) {
  $sig = (Get-AuthenticodeSignature $exe).Status
  Red 'signature (for UIAccess)' $sig ($sig -eq 'Valid')
}
$konf = 'C:\Program Files\Sunshine\config\sunshine.conf'
if (Test-Path $konf) {
  $b = [System.IO.File]::ReadAllBytes($konf)
  $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  Red 'sunshine.conf without BOM' $(if ($bom) { 'HAS BOM - bad' } else { 'ok' }) (-not $bom)
}

# ------------------------------------------------------------------ ZADACI
Naslov 'Scheduled tasks'
foreach ($n in 'SunshineUser','StreamReady','VerifyAfterBoot') {
  $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
  if ($t) { Red $n ("{0}, preko {1}" -f $t.State, $t.Actions[0].Execute) ($t.Actions[0].Execute -eq 'wscript.exe') }
  else { Red $n 'MISSING' $false }
}
$rc = Get-ScheduledTask -TaskName 'RestoreConsoleSession' -ErrorAction SilentlyContinue
if ($rc) { Red 'RestoreConsoleSession' $rc.State $true }
else { Red 'RestoreConsoleSession' 'cannot see it (runs as SYSTEM - needs an elevated session)' $null }

# ------------------------------------------------------------- SKRIPTE PAKETA
Naslov 'Package'
foreach ($n in 'pozicioniraj-sporedni.ps1','vrati-s-malog-ekrana.ps1','uiaccess-sunshine.ps1','streamready-hidden.vbs') {
  Red $n $(if (Test-Path (Join-Path $sk $n)) { 'present' } else { 'MISSING' }) (Test-Path (Join-Path $sk $n))
}
$w = Join-Path $sk 'ensure-streaming-ready.ps1'
if (Test-Path $w) {
  $t = Get-Content $w -Raw
  Red 'watchdog: positions display' $(if ($t -match 'pozicioniraj-sporedni') { 'yes' } else { 'NO' }) ($t -match 'pozicioniraj-sporedni')
  Red 'watchdog: recovers strays' $(if ($t -match 'vrati-s-malog-ekrana') { 'yes' } else { 'NO' }) ($t -match 'vrati-s-malog-ekrana')
  Red 'watchdog: does NOT deactivate' $(if ($t -match 'Dva displaya - tako i ostaje') { 'yes' } else { 'NO - old version' }) ($t -match 'Dva displaya - tako i ostaje')
}

Write-Host ''
Write-Host '  Red = differs from expected. Grey = cannot be measured from this session.' -ForegroundColor Gray
Write-Host ''
