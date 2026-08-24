<#
    napravi-ikonu.ps1

    Generira Luxstream.ico s vise velicina.

    ZASTO PROGRAMSKI
      Ikona mora biti citljiva i na 16 px (traka zadataka) i na 256 px (velike
      ikone). Jedna slika skalirana na sve velicine se na 16 px pretvori u mrlju,
      pa se svaka velicina crta zasebno, s manje detalja na manjima.

    ZASTO BMP OKVIRI, A NE PNG
      Od Viste naovamo .ico smije nositi PNG okvire i to je manje. Ali:
        - .NET-ov Icon.ToBitmap() ih ne zna dekodirati ("Requested range extends
          past the end of the array"), pa se ikona ne da ni provjeriti
        - stariji alati, medju njima i SFX moduli, ocekuju klasicni DIB
      Zato se pisu klasicni BMP okviri: BITMAPINFOHEADER s visinom 2*h
      (XOR slika + AND maska), 32 bpp BGRA, retci odozdo prema gore.

    ZAMKA U POWERSHELLU
      U popisu argumenata zarez veze JACE od aritmetike, pa se
      "New-Object RectangleF($a, $a, $r - 2*$a, ...)" protumaci kao
      "($a, $a, $r) - (2*$a)" i padne s op_Multiply na Object[].
      Zato svaki izracunati argument ide u vlastitu varijablu ili zagrade.

    IZGLED
      Tamna zaobljena plocica, na njoj zaslon i svijetla zraka koja iz njega
      izlazi - "lux" (svjetlo) + "stream" (tok).
#>
[CmdletBinding()]
param([string]$Izlaz = 'C:\Users\Public\sunshine-gpup-setup\host\Luxstream.ico')

Add-Type -AssemblyName System.Drawing

$velicine = 16, 24, 32, 48, 64, 128, 256

function Nacrtaj([int]$v) {
  $bmp = New-Object System.Drawing.Bitmap($v, $v, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  $r   = [double]$v
  $rub = [Math]::Max(1.0, $r * 0.05)
  $rad = [Math]::Max(2.0, $r * 0.22)
  $sir = $r - 2*$rub

  # --- tamna zaobljena plocica ---
  $pravokutnik = New-Object System.Drawing.RectangleF([single]$rub, [single]$rub, [single]$sir, [single]$sir)
  $put = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = [single]($rad * 2)
  $put.AddArc([single]$pravokutnik.X, [single]$pravokutnik.Y, $d, $d, 180, 90)
  $put.AddArc([single]($pravokutnik.Right - $d), [single]$pravokutnik.Y, $d, $d, 270, 90)
  $put.AddArc([single]($pravokutnik.Right - $d), [single]($pravokutnik.Bottom - $d), $d, $d, 0, 90)
  $put.AddArc([single]$pravokutnik.X, [single]($pravokutnik.Bottom - $d), $d, $d, 90, 90)
  $put.CloseFigure()

  $kist = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $pravokutnik,
            [System.Drawing.Color]::FromArgb(255, 32, 44, 68),
            [System.Drawing.Color]::FromArgb(255, 10, 14, 24),
            [single]90.0)
  $g.FillPath($kist, $put)
  $kist.Dispose(); $put.Dispose()

  # --- zaslon ---
  $zw  = $r * 0.50
  $zh  = $zw * 0.64
  $zx  = ($r - $zw) / 2.0
  $zy  = $r * 0.28
  $deb = [Math]::Max(1.0, $r * 0.05)
  $pero = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 110, 185, 255), [single]$deb)
  $g.DrawRectangle($pero, [single]$zx, [single]$zy, [single]$zw, [single]$zh)
  $pero.Dispose()

  # --- zraka koja izlazi iz zaslona ---
  $cx = $r / 2.0
  $cy = $zy + $zh / 2.0
  $s  = $r * 0.17
  $t1 = New-Object System.Drawing.PointF([single]($cx - $s*0.5), [single]($cy - $s))
  $t2 = New-Object System.Drawing.PointF([single]($cx + $s*1.0), [single]$cy)
  $t3 = New-Object System.Drawing.PointF([single]($cx - $s*0.5), [single]($cy + $s))
  $zuti = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 198, 64))
  $g.FillPolygon($zuti, @($t1, $t2, $t3))
  $zuti.Dispose()

  # --- podnozje, samo kad ima mjesta ---
  if ($v -ge 32) {
    $plavi = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 110, 185, 255))
    $nw = $zw * 0.36
    $nx = $cx - $nw/2.0
    $ny = $zy + $zh + $r*0.05
    $nh = [Math]::Max(1.0, $r*0.05)
    $g.FillRectangle($plavi, [single]$nx, [single]$ny, [single]$nw, [single]$nh)
    $plavi.Dispose()
  }

  $g.Dispose()
  # zarez sprjecava da PowerShell odmota objekt iz izlaza funkcije
  ,$bmp
}

# Bitmap -> klasicni DIB okvir za .ico
function U-Dib($bmp) {
  $w = $bmp.Width; $h = $bmp.Height
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)

  $bw.Write([uint32]40)
  $bw.Write([int32]$w)
  $bw.Write([int32]($h * 2))     # XOR + AND
  $bw.Write([uint16]1)
  $bw.Write([uint16]32)
  $bw.Write([uint32]0)
  $bw.Write([uint32]0)
  $bw.Write([int32]0); $bw.Write([int32]0)
  $bw.Write([uint32]0); $bw.Write([uint32]0)

  # citanje piksel po piksel je sporo; LockBits je puno brzi i za 256x256 bitan
  $pod = $bmp.LockBits(
           (New-Object System.Drawing.Rectangle(0, 0, $w, $h)),
           [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
           [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $redak = New-Object byte[] ($w * 4)
  for ($y = $h - 1; $y -ge 0; $y--) {
    $izvor = [IntPtr]::Add($pod.Scan0, $y * $pod.Stride)
    [Runtime.InteropServices.Marshal]::Copy($izvor, $redak, 0, $redak.Length)
    $bw.Write($redak)
  }
  $bmp.UnlockBits($pod)

  # AND maska - prozirnost nosi alfa kanal, pa su nule; redak poravnat na 4 B
  $bajtovaPoRetku = [int]([Math]::Floor(($w + 31) / 32) * 4)
  $prazan = New-Object byte[] $bajtovaPoRetku
  for ($y = 0; $y -lt $h; $y++) { $bw.Write($prazan) }

  $bw.Flush()
  $bajtovi = $ms.ToArray()
  $bw.Dispose(); $ms.Dispose()
  # Zarez je OBAVEZAN: bez njega PowerShell odmota byte[] u pojedinacne bajtove,
  # pozivatelj dobije Object[], i BinaryWriter.Write() nema odgovarajucu metodu -
  # datoteka ispadne prazna, a greske nema. Ista zamka kao kod ,$bmp.
  ,$bajtovi
}

$okviri = New-Object System.Collections.Generic.List[object]
foreach ($v in $velicine) {
  $bmp = Nacrtaj $v
  $okviri.Add(@{ V = $v; Bajtovi = (U-Dib $bmp) })
  $bmp.Dispose()
}

$tok = [System.IO.File]::Create($Izlaz)
$bw = New-Object System.IO.BinaryWriter($tok)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$okviri.Count)

$pomak = 6 + 16 * $okviri.Count
foreach ($o in $okviri) {
  $bajt = if ($o.V -ge 256) { 0 } else { $o.V }
  $bw.Write([byte]$bajt); $bw.Write([byte]$bajt)
  $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32)
  $bw.Write([uint32]$o.Bajtovi.Length)
  $bw.Write([uint32]$pomak)
  $pomak += $o.Bajtovi.Length
}
foreach ($o in $okviri) { $bw.Write($o.Bajtovi) }
$bw.Flush(); $bw.Dispose(); $tok.Dispose()

Write-Host ("  Ikona: {0}" -f $Izlaz)
Write-Host ("  {0:N0} KB, velicine: {1}" -f ((Get-Item $Izlaz).Length/1KB), ($velicine -join ', '))

# s BMP okvirima ToBitmap radi, pa se ikona da doista provjeriti
try {
  $prov = New-Object System.Drawing.Icon($Izlaz, 32, 32)
  $b = $prov.ToBitmap()
  Write-Host ("  provjera: ucitana i dekodirana ({0}x{1})" -f $b.Width, $b.Height) -ForegroundColor Green
  $b.Dispose(); $prov.Dispose()
} catch {
  Write-Host ("  provjera PALA: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
