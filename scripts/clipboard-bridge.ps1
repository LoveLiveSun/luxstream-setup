<#
    clipboard-bridge.ps1
    Dvosmjerna sinkronizacija TEKSTUALNOG meduspremnika izmedu VM-a i klijenta.

    Sunshine i Moonlight nemaju dijeljenje meduspremnika - to nije postavka koja
    nedostaje, nego funkcija koje u protokolu nema. Ova skripta je popunjava.

    POKRETANJE
      Na VM-u (posluzitelj):
        .\clipboard-bridge.ps1 -Mode Server -Secret 'nekatajna'

      Na klijentu (onaj s kojeg se spajas Moonlightom):
        .\clipboard-bridge.ps1 -Mode Client -Server 192.168.6.220 -Secret 'nekatajna'

    VAZNO
      * Mora se pokretati u INTERAKTIVNOJ sesiji. Windows servis u sesiji 0 nema
        pristup meduspremniku korisnika.
      * Prenosi SAMO tekst, najvise 1 MB.
      * Promet NIJE kriptiran. Namijenjeno povjerljivom LAN-u. Ne kopiraj lozinke.
      * -Secret je zajednicka tajna; posluzitelj odbija vezu bez nje.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Server','Client')] [string]$Mode,
  [string]$Server,                                   # samo za Client
  [int]$Port = 51888,
  [Parameter(Mandatory)][string]$Secret,
  [string[]]$AllowedClients = @('192.168.'),         # prefiksi dopustenih IP-ova (Server)
  [int]$PollMs = 400,
  [int]$MaxBytes = 1MB
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms | Out-Null

# ---------- pristup meduspremniku (STA) --------------------------------------
# Windows clipboard API radi samo iz STA niti. PowerShell jobovi i neki zakazani
# zadaci rade u MTA, pa se ondje meduspremnik TIHO ne procita ni ne postavi.
# Zato drzimo jedan trajni STA runspace i sve ide kroz njega.
$script:StaRs = [RunspaceFactory]::CreateRunspace()
$script:StaRs.ApartmentState = 'STA'
$script:StaRs.ThreadOptions  = 'ReuseThread'
$script:StaRs.Open()
$init = [PowerShell]::Create(); $init.Runspace = $script:StaRs
$null = $init.AddScript('Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing')
$null = $init.Invoke(); $init.Dispose()

function Invoke-Sta([string]$code, [hashtable]$vars) {
  $ps = [PowerShell]::Create(); $ps.Runspace = $script:StaRs
  if ($vars) { foreach ($k in $vars.Keys) { $script:StaRs.SessionStateProxy.SetVariable($k, $vars[$k]) } }
  $null = $ps.AddScript($code)
  try { $out = $ps.Invoke() } finally { $ps.Dispose() }
  if ($out -and $out.Count -gt 0) { [string]$out[0] } else { '' }
}

function Get-ClipText {
  try {
    Invoke-Sta 'if ([System.Windows.Forms.Clipboard]::ContainsText()) { [System.Windows.Forms.Clipboard]::GetText() } else { "" }' $null
  } catch { '' }
}

function Set-ClipText([string]$t) {
  if ([string]::IsNullOrEmpty($t)) { return }
  try { $null = Invoke-Sta '[System.Windows.Forms.Clipboard]::SetText($ClipPayload); ""' @{ ClipPayload = $t } }
  catch { Write-Host "  [!] ne mogu postaviti meduspremnik: $($_.Exception.Message)" -ForegroundColor Yellow }
}
function Hash([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return '' }
  $md5 = [System.Security.Cryptography.MD5]::Create()
  [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','')
}
function Send-Frame($stream, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text)
  if ($b.Length -gt $MaxBytes) { Write-Host '  [!] preskacem, preveliko' -ForegroundColor Yellow; return }
  $len = [BitConverter]::GetBytes([int]$b.Length)
  $stream.Write($len, 0, 4); $stream.Write($b, 0, $b.Length); $stream.Flush()
}
function Receive-Frame($stream) {
  # vraca $null ako nema cijelog okvira
  $lenBuf = New-Object byte[] 4
  $read = 0
  while ($read -lt 4) {
    $n = $stream.Read($lenBuf, $read, 4 - $read)
    if ($n -le 0) { throw 'veza zatvorena' }
    $read += $n
  }
  $len = [BitConverter]::ToInt32($lenBuf, 0)
  if ($len -lt 0 -or $len -gt $MaxBytes) { throw "neispravna duljina okvira: $len" }
  $buf = New-Object byte[] $len
  $read = 0
  while ($read -lt $len) {
    $n = $stream.Read($buf, $read, $len - $read)
    if ($n -le 0) { throw 'veza zatvorena' }
    $read += $n
  }
  [Text.Encoding]::UTF8.GetString($buf)
}

# ---------- petlja sinkronizacije --------------------------------------------
function Sync-Loop($client) {
  $stream = $client.GetStream()
  $stream.ReadTimeout  = 250
  $stream.WriteTimeout = 5000

  $lastHash = Hash (Get-ClipText)     # ne saljemo ono sto je vec bilo u meduspremniku
  Write-Host '  veza uspostavljena, sinkroniziram...' -ForegroundColor Green

  while ($client.Connected) {
    # 1. dolazni podaci
    try {
      if ($stream.DataAvailable) {
        $text = Receive-Frame $stream
        if ($null -ne $text) {
          Set-ClipText $text
          $lastHash = Hash $text      # sprjecava vracanje istog sadrzaja natrag
          $prev = if ($text.Length -gt 40) { $text.Substring(0,40) + '...' } else { $text }
          Write-Host ("  <- primljeno {0,6} B  {1}" -f ([Text.Encoding]::UTF8.GetByteCount($text)), ($prev -replace '\r?\n',' '))
        }
      }
    } catch [System.IO.IOException] { }   # istek citanja je normalan
      catch { throw }

    # 2. odlazne promjene
    $cur = Get-ClipText
    $h   = Hash $cur
    if ($h -ne $lastHash -and -not [string]::IsNullOrEmpty($cur)) {
      Send-Frame $stream $cur
      $lastHash = $h
      $prev = if ($cur.Length -gt 40) { $cur.Substring(0,40) + '...' } else { $cur }
      Write-Host ("  -> poslano   {0,6} B  {1}" -f ([Text.Encoding]::UTF8.GetByteCount($cur)), ($prev -replace '\r?\n',' '))
    }

    Start-Sleep -Milliseconds $PollMs
  }
}

# ---------- POSLUZITELJ ------------------------------------------------------
if ($Mode -eq 'Server') {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
  $listener.Start()
  Write-Host "Clipboard bridge - POSLUZITELJ na portu $Port" -ForegroundColor Cyan
  Write-Host "Dopusteni prefiksi: $($AllowedClients -join ', ')"
  Write-Host 'Ctrl+C za prekid.'

  try {
    while ($true) {
      Write-Host "`nCekam klijenta..."
      $client = $listener.AcceptTcpClient()
      $peer   = $client.Client.RemoteEndPoint.Address.ToString()

      $allowed = $false
      foreach ($p in $AllowedClients) { if ($peer.StartsWith($p)) { $allowed = $true; break } }
      if (-not $allowed) {
        Write-Host "  ODBIJEN $peer (nije na popisu)" -ForegroundColor Red
        $client.Close(); continue
      }

      Write-Host "  spojen $peer" -ForegroundColor Green
      try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $token = Receive-Frame $stream
        if ($token -ne $Secret) {
          Write-Host '  ODBIJEN: pogresna tajna' -ForegroundColor Red
          $client.Close(); continue
        }
        Send-Frame $stream 'OK'
        Sync-Loop $client
      } catch {
        Write-Host "  veza prekinuta: $($_.Exception.Message)" -ForegroundColor Yellow
      } finally {
        $client.Close()
      }
    }
  } finally { $listener.Stop() }
}

# ---------- KLIJENT ----------------------------------------------------------
else {
  if (-not $Server) { throw 'Uz -Mode Client obavezan je i -Server <ip>' }
  Write-Host "Clipboard bridge - KLIJENT prema ${Server}:$Port" -ForegroundColor Cyan
  Write-Host 'Ctrl+C za prekid.'

  while ($true) {
    try {
      $client = [System.Net.Sockets.TcpClient]::new()
      $client.Connect($Server, $Port)
      $stream = $client.GetStream()
      $stream.ReadTimeout = 5000
      Send-Frame $stream $Secret
      $resp = Receive-Frame $stream
      if ($resp -ne 'OK') { throw 'posluzitelj odbio tajnu' }
      Sync-Loop $client
    } catch {
      Write-Host "  nema veze ($($_.Exception.Message)), pokusavam za 5 s..." -ForegroundColor Yellow
    } finally {
      if ($client) { $client.Close() }
    }
    Start-Sleep -Seconds 5
  }
}
