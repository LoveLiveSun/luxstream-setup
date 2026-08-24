<#
    nvenc-sesije.ps1

    Ispise koliko NVENC sesija GPU trenutno vozi.

    ZASTO
      Otvoreno pitanje: koliko istovremenih NVENC sesija RTX 4090 podnosi kroz
      vise GPU-P particija. Consumer GeForce kartice povijesno imaju ogranicenje,
      a klonirani VM-ovi bi ga mogli probiti.

      Do 22.8.2026. se to smatralo neizmjerivim iz gosta. Nije - nvidia-smi
      u gostu radi djelomicno: baci gresku za "device handle", ali upit
      --query-gpu prode i vrati broj sesija.

    OPREZ
      NIJE provjereno broji li ovo sesije SVIH particija ili samo ove.
      Da se to utvrdi, treba mjeriti na dva VM-a istovremeno:
        - oba mirna            -> ocekuj 0 i 0
        - streamaj samo s VM-a A:
            ako A pokaze 1, a B pokaze 0  -> brojac je po particiji
            ako oba pokazu 1              -> brojac je za cijeli GPU

    UPOTREBA
      .\nvenc-sesije.ps1              jednokratno
      .\nvenc-sesije.ps1 -Prati       svake 2 sekunde dok ne prekines
#>
[CmdletBinding()]
param([switch]$Prati, [int]$Razmak = 2)

$smi = @(
  'C:\Windows\System32\nvidia-smi.exe',
  'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $smi) { Write-Host 'nvidia-smi nije pronaden u gostu.'; return }

function Ocitaj {
  # stderr nosi bezopasnu gresku o "device handle" za fizicki GPU; zanima nas stdout
  $izlaz = & $smi --query-gpu=name,encoder.stats.sessionCount,encoder.stats.averageFps --format=csv,noheader 2>$null
  foreach ($red in @($izlaz)) {
    if ($red -match '^\s*(.+?),\s*(\d+),\s*(.+?)\s*$') {
      [pscustomobject]@{ Gpu = $Matches[1]; Sesija = [int]$Matches[2]; Fps = $Matches[3] }
    }
  }
}

if ($Prati) {
  Write-Host "Pratim NVENC sesije svakih $Razmak s. Ctrl+C za prekid.`n"
  while ($true) {
    foreach ($o in Ocitaj) {
      '{0}  {1}  sesija={2}  fps={3}' -f (Get-Date -Format 'HH:mm:ss'), $o.Gpu, $o.Sesija, $o.Fps
    }
    Start-Sleep -Seconds $Razmak
  }
} else {
  $r = @(Ocitaj)
  if (-not $r) { Write-Host 'nvidia-smi nije vratio ocitanje.'; return }
  foreach ($o in $r) {
    Write-Host "  $($o.Gpu)"
    Write-Host "    NVENC sesija  : $($o.Sesija)"
    Write-Host "    prosjecni fps : $($o.Fps)"
  }
}
