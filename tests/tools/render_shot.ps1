# Draws the JSON written by pty_shot.py as a PNG (Windows PowerShell or pwsh with System.Drawing; needs the Consolas font).
# usage: render_shot.ps1 -Json shot.json -Png shot.png [-CellW 9] [-CellH 18] [-FontSize 11.5]
param(
  [Parameter(Mandatory)][string]$Json,
  [Parameter(Mandatory)][string]$Png,
  [int]$CellW = 9,
  [int]$CellH = 18,
  [single]$FontSize = 11.5,
  [string]$FontName = 'Consolas'
)
Add-Type -AssemblyName System.Drawing
$data = Get-Content -Raw -Encoding UTF8 -LiteralPath $Json | ConvertFrom-Json
$rows = [int]$data.rows; $cols = [int]$data.cols
$defFg = [System.Drawing.Color]::FromArgb(204, 204, 204)
$defBg = [System.Drawing.Color]::FromArgb(24, 26, 32)
$bmp = New-Object System.Drawing.Bitmap ($cols * $CellW), ($rows * $CellH)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear($defBg)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$fontR = New-Object System.Drawing.Font $FontName, $FontSize, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Point)
$fontB = New-Object System.Drawing.Font $FontName, $FontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Point)
$fmt = [System.Drawing.StringFormat]::GenericTypographic
$brushes = @{}
function Get-Brush($c) {
  $k = "$($c.R),$($c.G),$($c.B)"
  if (-not $brushes.ContainsKey($k)) { $brushes[$k] = New-Object System.Drawing.SolidBrush $c }
  return $brushes[$k]
}
for ($y = 0; $y -lt $rows; $y++) {
  $row = $data.cells[$y]
  # Backgrounds first, merged per run, then the glyphs.
  $x = 0
  while ($x -lt $cols) {
    $cell = $row[$x]
    $fl = [int]$cell[3]
    $bg = if ($cell[2]) { [System.Drawing.Color]::FromArgb($cell[2][0], $cell[2][1], $cell[2][2]) } else { $defBg }
    $fg = if ($cell[1]) { [System.Drawing.Color]::FromArgb($cell[1][0], $cell[1][1], $cell[1][2]) } else { $defFg }
    if ($fl -band 4) { $t = $bg; $bg = $fg; $fg = $t }
    $x2 = $x + 1
    while ($x2 -lt $cols) {
      $c2 = $row[$x2]; $f2 = [int]$c2[3]
      $b2 = if ($c2[2]) { [System.Drawing.Color]::FromArgb($c2[2][0], $c2[2][1], $c2[2][2]) } else { $defBg }
      $g2 = if ($c2[1]) { [System.Drawing.Color]::FromArgb($c2[1][0], $c2[1][1], $c2[1][2]) } else { $defFg }
      if ($f2 -band 4) { $t = $b2; $b2 = $g2 }
      if ($b2 -ne $bg) { break }
      $x2++
    }
    $g.FillRectangle((Get-Brush $bg), $x * $CellW, $y * $CellH, ($x2 - $x) * $CellW, $CellH)
    $x = $x2
  }
  for ($x = 0; $x -lt $cols; $x++) {
    $cell = $row[$x]
    $ch = [string]$cell[0]
    if ($ch -eq ' ') { continue }
    $fl = [int]$cell[3]
    $bg = if ($cell[2]) { [System.Drawing.Color]::FromArgb($cell[2][0], $cell[2][1], $cell[2][2]) } else { $defBg }
    $fg = if ($cell[1]) { [System.Drawing.Color]::FromArgb($cell[1][0], $cell[1][1], $cell[1][2]) } else { $defFg }
    if ($fl -band 4) { $t = $bg; $bg = $fg; $fg = $t }
    if ($fl -band 2) { $fg = [System.Drawing.Color]::FromArgb(($fg.R + $bg.R) / 2, ($fg.G + $bg.G) / 2, ($fg.B + $bg.B) / 2) }
    $font = if ($fl -band 1) { $fontB } else { $fontR }
    $g.DrawString($ch, $font, (Get-Brush $fg), [single]($x * $CellW), [single]($y * $CellH + 1), $fmt)
  }
}
$bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved $Png ($($cols * $CellW)x$($rows * $CellH))"
