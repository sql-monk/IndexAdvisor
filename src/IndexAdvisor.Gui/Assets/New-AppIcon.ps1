#Requires -Version 7.2

<#
.SYNOPSIS
	Малює іконку IndexAdvisor GUI (IndexAdvisor.ico) — база даних і лупа на синій плитці.

.DESCRIPTION
	Векторний малюнок у сітці 256×256 рендериться в кожен розмір окремо (16…256 px), тож дрібні розміри
	не розмиті масштабуванням. ICO містить 32-бітні кадри: до 128 px — BMP, 256 px — PNG.
	Іконку вже покладено в репозиторій; скрипт потрібен лише, щоб змінити малюнок. Потрібна Windows (System.Drawing).

.PARAMETER OutputPath
	Куди записати ICO; за замовчуванням IndexAdvisor.ico поруч зі скриптом.

.PARAMETER PreviewPath
	Необов'язково: PNG з усіма розмірами поруч, щоб переглянути результат.
#>
[CmdletBinding()]
param(
	[string]$OutputPath = (Join-Path $PSScriptRoot 'IndexAdvisor.ico'),
	[string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256

function New-RoundedRectangle([single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius) {
	$path = [System.Drawing.Drawing2D.GraphicsPath]::new()
	$diameter = $Radius * 2
	$path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
	$path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
	$path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
	$path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
	$path.CloseFigure()
	return $path
}

function New-IconBitmap([int]$Size) {
	$bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bitmap)
	try {
		$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
		$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
		$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
		$g.Clear([System.Drawing.Color]::Transparent)
		$scale = $Size / 256.0
		$g.ScaleTransform($scale, $scale)
		# Дрібні розміри: товстіші лінії, щоб малюнок не розсипався.
		$bold = if ($Size -le 24) { 1.6 } elseif ($Size -le 48) { 1.25 } else { 1.0 }

		$deep = [System.Drawing.Color]::FromArgb(255, 29, 78, 216)     # #1D4ED8
		$teal = [System.Drawing.Color]::FromArgb(255, 8, 145, 178)     # #0891B2
		$white = [System.Drawing.Color]::White
		$top = [System.Drawing.Color]::FromArgb(255, 219, 234, 254)    # #DBEAFE
		$band = [System.Drawing.Color]::FromArgb(255, 37, 99, 235)     # #2563EB

		# Плитка з градієнтом.
		$tile = New-RoundedRectangle 8 8 240 240 54
		$gradient = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.PointF]::new(8, 8), [System.Drawing.PointF]::new(248, 248), $deep, $teal)
		$g.FillPath($gradient, $tile)

		# База даних: циліндр з двома смугами.
		$left = 44; $width = 136; $ellipse = 44; $yTop = 52; $yBottom = 176
		$body = [System.Drawing.Drawing2D.GraphicsPath]::new()
		$body.AddArc($left, $yTop, $width, $ellipse, 180, -180)
		$body.AddLine($left + $width, $yTop + $ellipse / 2, $left + $width, $yBottom + $ellipse / 2)
		$body.AddArc($left, $yBottom, $width, $ellipse, 0, 180)
		$body.CloseFigure()
		$whiteBrush = [System.Drawing.SolidBrush]::new($white)
		$g.FillPath($whiteBrush, $body)
		$g.FillEllipse([System.Drawing.SolidBrush]::new($top), $left, $yTop, $width, $ellipse)
		$bandPen = [System.Drawing.Pen]::new($band, 7 * $bold)
		$g.DrawEllipse($bandPen, $left + 3, $yTop + 2, $width - 6, $ellipse - 4)
		foreach ($y in 94, 136) {
			$g.DrawArc($bandPen, $left + 3, $y, $width - 6, $ellipse - 4, 8, 164)
		}

		# Лупа: проміжок кольору плитки, біле кільце, світла лінза, ручка.
		$cx = 176; $cy = 172; $radius = 40
		$gap = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 14, 116, 196))
		$gapRadius = $radius + 14 * $bold
		$g.FillEllipse($gap, $cx - $gapRadius, $cy - $gapRadius, $gapRadius * 2, $gapRadius * 2)
		$lens = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(110, 186, 230, 253))
		$g.FillEllipse($lens, $cx - $radius, $cy - $radius, $radius * 2, $radius * 2)
		$ring = [System.Drawing.Pen]::new($white, 14 * $bold)
		$g.DrawEllipse($ring, $cx - $radius, $cy - $radius, $radius * 2, $radius * 2)
		$handle = [System.Drawing.Pen]::new($white, 22 * $bold)
		$handle.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
		$handle.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
		$g.DrawLine($handle, $cx + $radius * 0.74, $cy + $radius * 0.74, 226, 222)
	}
	finally {
		$g.Dispose()
	}
	return $bitmap
}

function ConvertTo-IconFrame([System.Drawing.Bitmap]$Bitmap) {
	$size = $Bitmap.Width
	if ($size -ge 256) {
		$stream = [System.IO.MemoryStream]::new()
		$Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
		return , $stream.ToArray()
	}
	# DIB: BITMAPINFOHEADER (висота подвоєна: зображення + маска), BGRA знизу догори, маска AND з нулів.
	$stream = [System.IO.MemoryStream]::new()
	$writer = [System.IO.BinaryWriter]::new($stream)
	$maskStride = [int]([math]::Ceiling($size / 32.0) * 4)
	$writer.Write([int]40); $writer.Write([int]$size); $writer.Write([int]($size * 2))
	$writer.Write([int16]1); $writer.Write([int16]32); $writer.Write([int]0)
	$writer.Write([int]($size * $size * 4 + $maskStride * $size))
	$writer.Write([int]0); $writer.Write([int]0); $writer.Write([int]0); $writer.Write([int]0)
	for ($y = $size - 1; $y -ge 0; $y--) {
		for ($x = 0; $x -lt $size; $x++) {
			$c = $Bitmap.GetPixel($x, $y)
			$writer.Write([byte]$c.B); $writer.Write([byte]$c.G); $writer.Write([byte]$c.R); $writer.Write([byte]$c.A)
		}
	}
	$writer.Write([byte[]]::new($maskStride * $size))
	$writer.Flush()
	return , $stream.ToArray()
}

$bitmaps = foreach ($size in $sizes) { New-IconBitmap $size }
$frames = foreach ($bitmap in $bitmaps) { , (ConvertTo-IconFrame $bitmap) }

# ICONDIR + ICONDIRENTRY для кожного кадру, далі самі кадри.
$output = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($output)
$writer.Write([int16]0); $writer.Write([int16]1); $writer.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
	$dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
	$writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
	$writer.Write([byte]0); $writer.Write([byte]0)
	$writer.Write([int16]1); $writer.Write([int16]32)
	$writer.Write([int]$frames[$i].Length); $writer.Write([int]$offset)
	$offset += $frames[$i].Length
}
foreach ($frame in $frames) {
	$writer.Write([byte[]]$frame)
}
$writer.Flush()
[System.IO.File]::WriteAllBytes($OutputPath, $output.ToArray())
Write-Host "Іконка: $OutputPath ($($sizes -join ', ') px)"

if ($PreviewPath) {
	$width = [int](($sizes | Measure-Object -Sum).Sum + 16 * ($sizes.Count + 1))
	$preview = [System.Drawing.Bitmap]::new($width, [int](256 + 32))
	$g = [System.Drawing.Graphics]::FromImage($preview)
	$g.Clear([System.Drawing.Color]::FromArgb(255, 243, 243, 243))
	$x = 16
	foreach ($bitmap in $bitmaps) {
		$g.DrawImageUnscaled($bitmap, $x, 16 + 256 - $bitmap.Height)
		$x += $bitmap.Width + 16
	}
	$g.Dispose()
	$preview.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
	Write-Host "Перегляд: $PreviewPath"
}
