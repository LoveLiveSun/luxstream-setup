<#
    screenshot.ps1
    Snimi trenutni sadrzaj ekrana u PNG.
      .\screenshot.ps1                          -> C:\Users\Public\screen.png
      .\screenshot.ps1 -Out D:\slika.png
      .\screenshot.ps1 -All                     -> svi displayi zajedno
#>
[CmdletBinding()]
param([string]$Out = 'C:\Users\Public\screen.png', [switch]$All)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($All) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
} else {
  $b = ([System.Windows.Forms.Screen]::PrimaryScreen).Bounds
}

$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Host "Snimljeno: $Out  ($($b.Width)x$($b.Height), $([math]::Round((Get-Item $Out).Length/1KB,1)) KB)"
