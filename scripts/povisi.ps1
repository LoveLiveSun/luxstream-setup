<#
    povisi.ps1

    Pokrece zadani program s povisenim ovlastima BEZ UAC dijaloga - tako da se
    povisenje da koristiti i preko Moonlighta.

    ZASTO OVO POSTOJI
      UAC dijalog crta consent.exe, koji radi na razini integriteta *System*.
      Sunshine ubacuje unos preko SendInput i radi na razini *High*, pa mu UIPI
      ne da slati unos u taj prozor. Posljedica: dijalog se vidi, ali se gumbi
      Da/Ne ne mogu kliknuti ni tipkovnicom doseci.

      Iskljucivanje sigurnog desktopa (PromptOnSecureDesktop = 0) rjesava samo
      pola problema - slika se vise ne zamrzava, ali unos i dalje ne prolazi.
      Jedini pravi popravak bio bi da Sunshine unos salje kroz virtualni HID
      driver (unos tada ulazi kroz raw input stog i UIPI ga ne dira), ali taj
      driver nije ni u MSI-ju ni u paketu.

    KAKO OVO ZAOBILAZI PROBLEM
      Zakazani zadatak s RunLevel = Highest pokrece program povisen, a pokretanje
      zadatka NE trazi potvrdu. Dijalog se dakle nikad ne pojavi.

      Sam zadatak se registrira JEDNOM, i za to treba potvrda - taj jedan put
      napravi s konzole ili preko RDP-a.

    CIJENA - procitaj ovo
      Program registriran ovako dize se povisen bez ikakvog pitanja, dokle god
      zadatak postoji. Registriraj samo ono cemu vjerujes. UAC za sve ostalo
      ostaje netaknut.

    UPOTREBA
      # jednom, iz povisenog PowerShella (trazi potvrdu):
      .\povisi.ps1 -Registriraj -Program 'C:\Windows\regedit.exe'

      # poslije, bilo kad i preko Moonlighta, bez potvrde:
      .\povisi.ps1 -Program 'C:\Windows\regedit.exe'

      .\povisi.ps1 -Popis                 # sto je sve registrirano
      .\povisi.ps1 -Ukloni -Program '...' # makni
#>
[CmdletBinding()]
param(
  [string]$Program,
  [string]$Argumenti = '',
  [switch]$Registriraj,
  [switch]$Ukloni,
  [switch]$Popis
)

$prefiks = 'Povisi_'

function Test-Elevirano {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ime-Zadatka([string]$put) {
  $prefiks + ([IO.Path]::GetFileNameWithoutExtension($put) -replace '[^A-Za-z0-9_-]', '_')
}

# ---------------------------------------------------------------------- POPIS
if ($Popis) {
  $z = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$prefiks*" })
  if (-not $z.Count) { Write-Host 'Nista nije registrirano.'; return }
  Write-Host ''
  foreach ($t in $z) {
    '  {0,-28} -> {1} {2}' -f $t.TaskName, $t.Actions[0].Execute, $t.Actions[0].Arguments
  }
  Write-Host ''
  return
}

if (-not $Program) { throw 'Zadaj -Program "C:\putanja\program.exe".' }

# -------------------------------------------------------------------- UKLONI
if ($Ukloni) {
  if (-not (Test-Elevirano)) { throw 'Za uklanjanje zadatka treba povisen PowerShell.' }
  $ime = Ime-Zadatka $Program
  Unregister-ScheduledTask -TaskName $ime -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Uklonjeno: $ime" -ForegroundColor Green
  return
}

# --------------------------------------------------------------- REGISTRIRAJ
if ($Registriraj) {
  if (-not (Test-Elevirano)) { throw 'Registracija trazi povisen PowerShell - napravi to s konzole ili preko RDP-a.' }
  if (-not (Test-Path $Program)) { throw "Nema $Program" }

  $ime = Ime-Zadatka $Program
  $akcija = if ($Argumenti) {
    New-ScheduledTaskAction -Execute $Program -Argument $Argumenti -WorkingDirectory (Split-Path $Program -Parent)
  } else {
    New-ScheduledTaskAction -Execute $Program -WorkingDirectory (Split-Path $Program -Parent)
  }
  # Bez okidaca - pokrece se iskljucivo rucno, preko -Program bez -Registriraj.
  $princ = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Highest
  $post  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel

  Register-ScheduledTask -TaskName $ime -Action $akcija -Principal $princ -Settings $post -Force | Out-Null
  Write-Host "Registrirano: $ime  ->  $Program $Argumenti" -ForegroundColor Green
  Write-Host 'Od sada ga pokreces bez potvrde:' -ForegroundColor Cyan
  Write-Host "  .\povisi.ps1 -Program '$Program'"
  return
}

# -------------------------------------------------------------------- POKRENI
$ime = Ime-Zadatka $Program
if (-not (Get-ScheduledTask -TaskName $ime -ErrorAction SilentlyContinue)) {
  throw "Nije registrirano. Jednom pokreni: .\povisi.ps1 -Registriraj -Program '$Program'"
}
Start-ScheduledTask -TaskName $ime
Write-Host "Pokrenuto poviseno, bez potvrde: $Program" -ForegroundColor Green
