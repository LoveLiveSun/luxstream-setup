<#
    00-preflight.ps1
    Provjerava sve preduvjete prije postavljanja Sunshinea na GPU-P gostu.
    Ne mijenja nista. Ako nesto ne prodje, popravi to prije nastavka.
#>
[CmdletBinding()]
param()

$script:fail = 0
function Ok   ($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn ($m){ Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Bad  ($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Head ($m){ Write-Host "`n== $m" -ForegroundColor Cyan }

Head 'Elevacija'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if ((New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Ok 'PowerShell je pokrenut kao administrator'
} else {
  Bad 'Nije elevated. Pokreni PowerShell kao administrator.'
}

Head 'Sesija'
$qu = (query user) 2>&1 | Out-String
if ($qu -match 'console') {
  Ok 'Konzolna sesija je aktivna'
} else {
  Bad 'Nema konzolne sesije. RDP preseli sesiju sebi i VDD tada nije vidljiv. Vrati je: tscon <id> /dest:console'
}
Write-Host ($qu.TrimEnd())

Head 'Operativni sustav'
$os = Get-CimInstance Win32_OperatingSystem
$ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
Ok "$($os.Caption) build $($os.BuildNumber) UBR $ubr"

Head 'CPU i RAM'
$cs = Get-CimInstance Win32_ComputerSystem
$ramGB = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
Ok "$($cs.NumberOfLogicalProcessors) logickih jezgri, $ramGB GB RAM"
if ($cs.NumberOfLogicalProcessors -lt 8) {
  Warn 'Manje od 8 jezgri. Softversko enkodiranje na visokim rezolucijama nece stizati.'
}

Head 'GPU-P particija'
$gpus = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
          Where-Object { $_.FriendlyName -notmatch 'Virtual Display|Hyper-V|Basic|基本显示' }
if ($gpus) {
  foreach ($g in $gpus) { Ok "Prisutan: $($g.FriendlyName)  [$($g.Status)]" }
} else {
  Bad 'Nema GPU-a. Provjeri na hostu: Get-VMGpuPartitionAdapter -VMName <ime>'
}

$phantom = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
             Where-Object { $_.Problem -eq 'CM_PROB_PHANTOM' -and $_.FriendlyName -notmatch 'Virtual Display|Hyper-V|Basic|基本显示' }
if ($phantom) {
  Warn "$($phantom.Count) fantomskih GPU zapisa (CM_PROB_PHANTOM). Bezopasno, ali znak da je particija ranije nestajala."
}

Head 'Driver GPU-P particije u gostu'
$repo = 'C:\Windows\System32\HostDriverStore\FileRepository'
if (Test-Path $repo) {
  $dirs = Get-ChildItem $repo -Directory -ErrorAction SilentlyContinue
  if ($dirs) {
    foreach ($d in $dirs) {
      $sys = Get-ChildItem $d.FullName -Filter 'nvlddmkm.sys' -ErrorAction SilentlyContinue | Select-Object -First 1
      $ver = if ($sys) { $sys.VersionInfo.FileVersion } else { 'n/a' }
      Ok "$($d.Name)  ->  $ver"
    }
    Write-Host '         Ova verzija mora biti IDENTICNA driveru na hostu, inace Code 43.'
  } else { Bad 'HostDriverStore je prazan' }
} else {
  Bad 'HostDriverStore ne postoji. GPU-P driver nije kopiran u gosta.'
}

Head 'Virtual Display Driver'
$vdd = Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -ErrorAction SilentlyContinue
if ($vdd) {
  Ok "$($vdd.FriendlyName)  [$($vdd.Status)]"
  $p = Get-PnpDeviceProperty -InstanceId 'ROOT\DISPLAY\0000' -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
  if ($p) { Ok "Verzija drivera: $($p.Data)" }
} else {
  Bad 'VDD nije instaliran. Instaliraj ga u C:\VirtualDisplayDriver\ prije nastavka.'
}

Head 'Sunshine'
$sx = 'C:\Program Files\Sunshine\sunshine.exe'
if (Test-Path $sx) {
  Ok "Verzija: $((Get-Item $sx).VersionInfo.FileVersion)"
  $svc = Get-Service SunshineService -ErrorAction SilentlyContinue
  if ($svc) { Ok "Servis: $($svc.Status)" } else { Warn 'SunshineService ne postoji. Instaliraj Sunshine kao servis.' }
} else {
  Bad 'Sunshine nije instaliran u C:\Program Files\Sunshine\'
}

Write-Host ''
if ($script:fail -eq 0) {
  Write-Host '== SVE PROVJERE PROSLE. Nastavi s 01-vdd-configure.ps1' -ForegroundColor Green
  exit 0
} else {
  Write-Host "== $($script:fail) PROVJERA NIJE PROSLA. Popravi prije nastavka." -ForegroundColor Red
  exit 1
}
