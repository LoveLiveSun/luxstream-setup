<#
    azuriraj-zadatke.ps1

    Prenese izmijenjene skripte iz radne kopije u ugradenu i ponovno registrira
    zakazane zadatke - BEZ pune reinstalacije.

    ZASTO
      INSTALL.cmd odradi sve, ali usput gasi i pali Sunshine, trazi GUID displaya
      i radi priming. Kad je promijenjena samo koja skripta, to je preskupo i
      prekida stream. Ovo je lagana varijanta.

    STO RADI
      1. kopira scripts\ iz radne kopije u C:\Program Files\Luxstream\scripts
      2. ponovno registrira StreamReady, RestoreConsoleSession, VerifyAfterBoot
      3. postavi SunshineUser na skriveni pokretac
      Sunshine NE dira - promjena hvata pri sljedecem pokretanju.

    POKRETANJE (iz POVISENOG PowerShella)
      powershell -ExecutionPolicy Bypass -File .\azuriraj-zadatke.ps1
#>
[CmdletBinding()]
param(
  [string]$Izvor = 'C:\Users\Public\sunshine-gpup-setup',
  [string]$Dom   = 'C:\Program Files\Luxstream'
)

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Pokreni kao administrator - pise se u Program Files i u Task Scheduler.'
}

if (-not (Test-Path (Join-Path $Izvor 'scripts'))) { throw "Nema $Izvor\scripts" }

Write-Host ''
Write-Host '  Azuriranje skripti i zadataka' -ForegroundColor Cyan
Write-Host '  ============================='

# --- 1. skripte ---
robocopy (Join-Path $Izvor 'scripts') (Join-Path $Dom 'scripts') /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -lt 8) {
  Write-Host "  [OK]   skripte prenesene ($((Get-ChildItem (Join-Path $Dom 'scripts') -File).Count) datoteka)" -ForegroundColor Green
} else {
  Write-Host "  [FAIL] robocopy $LASTEXITCODE" -ForegroundColor Red
  return
}

# --- 2. zadaci koji se sami registriraju ---
$sk = Join-Path $Dom 'scripts'
foreach ($s in 'ensure-streaming-ready.ps1', 'restore-console-session.ps1', 'verify-after-boot.ps1') {
  $p = Join-Path $sk $s
  if (Test-Path $p) {
    try { & $p -Install | Out-Null; Write-Host "  [OK]   $s -Install" -ForegroundColor Green }
    catch { Write-Host "  [FAIL] $s : $_" -ForegroundColor Red }
  } else {
    Write-Host "  [!]    nema $s" -ForegroundColor Yellow
  }
}

# --- 3. SunshineUser na skriveni pokretac ---
# Sunshine.exe je konzolna aplikacija, pa mu Windows sam stvara prozor. Zadatak
# ga zato pali kroz wscript i VBS omotac, koji ga stvori sa SW_HIDE.
$vbs = Join-Path $sk 'start-sunshine-hidden.vbs'
$sxe = 'C:\Program Files\Sunshine\Sunshine.exe'
if ((Test-Path $vbs) -and (Get-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue)) {
  $akcija = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`"" `
              -WorkingDirectory (Split-Path $sxe -Parent)
  Set-ScheduledTask -TaskName 'SunshineUser' -Action $akcija | Out-Null
  Write-Host '  [OK]   SunshineUser -> skriveni pokretac' -ForegroundColor Green
}

# --- 4. stanje ---
Write-Host ''
Write-Host '  Zadaci:'
foreach ($n in 'SunshineUser','StreamReady','RestoreConsoleSession','VerifyAfterBoot') {
  $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
  if ($t) {
    $inf = $t | Get-ScheduledTaskInfo
    $okid = ($t.Triggers | ForEach-Object {
              ($_.CimClass.CimClassName -replace 'MSFT_Task','') + $(if ($_.Repetition.Interval) { "/$($_.Repetition.Interval)" })
            }) -join ' + '
    '    {0,-22} {1,-7} {2,-34} sljedeci={3}' -f $n, $t.State, $okid, $inf.NextRunTime
  } else {
    '    {0,-22} NEMA GA' -f $n
  }
}
Write-Host ''
