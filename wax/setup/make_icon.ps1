#requires -Version 7
<#
.SYNOPSIS
  Draws the program's icon, wax\setup\app.ico: the Wax mark at eight sizes.
.DESCRIPTION
  The same shapes as wax\vscode\media\make_icon.py draws for the editor extension. Run it again when the mark changes.
#>
[CmdletBinding()]
param([string]$Out = (Join-Path $PSScriptRoot 'app.ico'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-Hexagon([double]$Radius) {
    0..5 | ForEach-Object { [System.Drawing.PointF]::new(64 + $Radius * [math]::Sin([math]::PI / 3 * $_), 64 - $Radius * [math]::Cos([math]::PI / 3 * $_)) }
}

function New-Mark([int]$Size) {
    $picture = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($picture)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.ScaleTransform($Size / 128, $Size / 128)
    $back = [System.Drawing.Color]::FromArgb(20, 23, 31)
    $amber = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(242, 163, 27))
    $light = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 205, 96))

    $square = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = 52
    $square.AddArc(0, 0, $d, $d, 180, 90); $square.AddArc(128 - $d, 0, $d, $d, 270, 90)
    $square.AddArc(128 - $d, 128 - $d, $d, $d, 0, 90); $square.AddArc(0, 128 - $d, $d, $d, 90, 90)
    $square.CloseFigure()
    $g.FillPath([System.Drawing.SolidBrush]::new($back), $square)

    $outer = @(Get-Hexagon 50)
    $g.FillPolygon($amber, [System.Drawing.PointF[]]$outer)
    $g.FillPolygon($light, [System.Drawing.PointF[]]@($outer[5], $outer[0], $outer[1], [System.Drawing.PointF]::new(64, 64)))
    $g.FillPolygon($amber, [System.Drawing.PointF[]]@(Get-Hexagon 41))
    $pen = [System.Drawing.Pen]::new($back, 9)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(38, 50), [System.Drawing.PointF]::new(49, 82), [System.Drawing.PointF]::new(64, 56),
        [System.Drawing.PointF]::new(79, 82), [System.Drawing.PointF]::new(90, 50)))
    $g.Dispose()
    $stream = [System.IO.MemoryStream]::new()
    $picture.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $picture.Dispose()
    , $stream.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = @($sizes | ForEach-Object { , (New-Mark $_) })
$file = [System.IO.File]::Create($Out)
$writer = [System.IO.BinaryWriter]::new($file)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $side = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $writer.Write([byte]$side); $writer.Write([byte]$side); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($image in $images) { $writer.Write([byte[]]$image) }
$writer.Dispose()
Write-Host "Wrote $Out ($((Get-Item $Out).Length) bytes, sizes $($sizes -join ', '))"
