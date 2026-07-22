# Turns Script-Package-Studio.png (rounded tile on a white background) into a
# transparent logo.png + multi-resolution logo.ico for the app / installer.
param(
	[string]$Src = (Join-Path $PSScriptRoot 'design\Script-Package-Studio.png'),
	[string]$ImagesDir = (Join-Path $PSScriptRoot 'Images'),
	[string]$QaOut = '',
	[int]$FillT = 205,   # connectivity: pixel is background if min(R,G,B) >= this
	[int]$FeatherLo = 170,
	[int]$FeatherHi = 210
)
Add-Type -AssemblyName System.Drawing

# ---- load into 32bpp ARGB ----
$srcImg = [System.Drawing.Image]::FromFile($Src)
$w = $srcImg.Width; $h = $srcImg.Height
$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.DrawImage($srcImg, 0, 0, $w, $h)
$g.Dispose(); $srcImg.Dispose()

$rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
$buf = New-Object byte[] ($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)

function MinCh([int]$i) {
	$b = $buf[$i]; $gr = $buf[$i+1]; $r = $buf[$i+2]
	$m = $b; if ($gr -lt $m) { $m = $gr }; if ($r -lt $m) { $m = $r }
	return $m
}

# ---- flood fill background (connected near-white from the border) ----
$bg = New-Object bool[] ($w * $h)
$q = New-Object System.Collections.Generic.Queue[int]
function TryPush([int]$x, [int]$y) {
	if ($x -lt 0 -or $y -lt 0 -or $x -ge $w -or $y -ge $h) { return }
	$p = $y * $w + $x
	if ($bg[$p]) { return }
	$i = $y * $stride + $x * 4
	if ((MinCh $i) -ge $FillT) { $bg[$p] = $true; $q.Enqueue($p) }
}
for ($x = 0; $x -lt $w; $x++) { TryPush $x 0; TryPush $x ($h-1) }
for ($y = 0; $y -lt $h; $y++) { TryPush 0 $y; TryPush ($w-1) $y }
while ($q.Count -gt 0) {
	$p = $q.Dequeue(); $x = $p % $w; $y = [int][Math]::Floor($p / $w)
	TryPush ($x-1) $y; TryPush ($x+1) $y; TryPush $x ($y-1); TryPush $x ($y+1)
}
# zero alpha on background
for ($p = 0; $p -lt $bg.Length; $p++) {
	if ($bg[$p]) { $x = $p % $w; $y = [int][Math]::Floor($p / $w); $buf[$y*$stride + $x*4 + 3] = 0 }
}

# ---- feather: soften bright rim pixels that touch transparency ----
$span = [double]($FeatherHi - $FeatherLo)
for ($y = 0; $y -lt $h; $y++) {
	for ($x = 0; $x -lt $w; $x++) {
		$p = $y * $w + $x
		if ($bg[$p]) { continue }
		$i = $y * $stride + $x * 4
		if ($buf[$i+3] -eq 0) { continue }
		$m = MinCh $i
		if ($m -lt $FeatherLo) { continue }
		# touching a transparent/background neighbor?
		$touch = $false
		foreach ($dy in -1..1) { foreach ($dx in -1..1) {
			if ($dx -eq 0 -and $dy -eq 0) { continue }
			$nx = $x+$dx; $ny = $y+$dy
			if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
			if ($bg[$ny*$w+$nx]) { $touch = $true }
		} }
		if (-not $touch) { continue }
		$a = if ($m -ge $FeatherHi) { 0 } else { [int](255 * (1 - ($m - $FeatherLo) / $span)) }
		if ($a -lt $buf[$i+3]) { $buf[$i+3] = [byte]$a }
	}
}

[System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $data.Scan0, $buf.Length)
$bmp.UnlockBits($data)

# ---- helper: high-quality resize to a new 32bpp bitmap ----
function Resize-Bmp($source, [int]$size) {
	$b = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$gg = [System.Drawing.Graphics]::FromImage($b)
	$gg.InterpolationMode = 'HighQualityBicubic'
	$gg.PixelOffsetMode = 'HighQuality'
	$gg.SmoothingMode = 'AntiAlias'
	$gg.DrawImage($source, (New-Object System.Drawing.Rectangle 0, 0, $size, $size))
	$gg.Dispose()
	return $b
}

# BMP/DIB icon frame (bottom-up 32bpp BGRA + empty AND mask). Windows renders
# these as exe / Explorer icons at small sizes, which PNG-compressed frames
# cannot reliably do.
function Get-DibFrame($source, [int]$size) {
	$rb = Resize-Bmp $source $size
	$r = New-Object System.Drawing.Rectangle 0, 0, $size, $size
	$d = $rb.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$st = $d.Stride
	$tmp = New-Object byte[] ($st * $size)
	[System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $tmp, 0, $tmp.Length)
	$rb.UnlockBits($d); $rb.Dispose()
	$ms = New-Object System.IO.MemoryStream
	$bw = New-Object System.IO.BinaryWriter($ms)
	# BITMAPINFOHEADER (height doubled: colour bitmap + AND mask)
	$bw.Write([Int32]40); $bw.Write([Int32]$size); $bw.Write([Int32]($size * 2))
	$bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([Int32]0)
	$bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([Int32]0)
	for ($y = $size - 1; $y -ge 0; $y--) { $bw.Write($tmp, $y * $st, $size * 4) }  # XOR, bottom-up
	$rowBytes = [int]([Math]::Floor(($size + 31) / 32) * 4)
	$bw.Write((New-Object byte[] ($rowBytes * $size)))                              # AND mask (all opaque)
	$bw.Flush(); $bytes = $ms.ToArray(); $bw.Close(); $ms.Dispose()
	return $bytes
}

New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null

# ---- logo.png (256, transparent) ----
$png256 = Resize-Bmp $bmp 256
$png256.Save((Join-Path $ImagesDir 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# ---- multi-resolution logo.ico (PNG-encoded entries) ----
# 256 stays PNG-compressed (standard, keeps size down); 16-128 are BMP frames.
$sizes = @(256, 128, 64, 48, 32, 16)
$blobs = New-Object System.Collections.Generic.List[byte[]]
foreach ($s in $sizes) {
	if ($s -ge 256) {
		$rb = Resize-Bmp $bmp $s
		$ms = New-Object System.IO.MemoryStream
		$rb.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
		$blobs.Add($ms.ToArray()); $ms.Dispose(); $rb.Dispose()
	} else {
		$blobs.Add((Get-DibFrame $bmp $s))
	}
}
$icoPath = Join-Path $ImagesDir 'logo.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)  # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($k = 0; $k -lt $sizes.Count; $k++) {
	$s = $sizes[$k]; $len = $blobs[$k].Length
	$bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
	$bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
	$bw.Write([byte]0); $bw.Write([byte]0)
	$bw.Write([UInt16]1); $bw.Write([UInt16]32)
	$bw.Write([UInt32]$len); $bw.Write([UInt32]$offset)
	$offset += $len
}
foreach ($blob in $blobs) { $bw.Write($blob) }
$bw.Flush(); $bw.Close(); $fs.Close()

# ---- QA composite over several backgrounds ----
if ($QaOut) {
	$grounds = @(
		@('white', (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White))),
		@('black', (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(15,18,24)))),
		@('gray',  (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(128,128,132)))),
		@('blue',  (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46,107,224))))
	)
	$tile = 220; $pad = 16
	$qa = New-Object System.Drawing.Bitmap((($tile+$pad)*4+$pad), ($tile+$pad*2+20))
	$qg = [System.Drawing.Graphics]::FromImage($qa)
	$qg.InterpolationMode = 'HighQualityBicubic'; $qg.SmoothingMode = 'AntiAlias'
	$qg.Clear([System.Drawing.Color]::FromArgb(58,61,70))
	$font = New-Object System.Drawing.Font('Segoe UI', 9)
	$prev = Resize-Bmp $bmp $tile
	for ($n = 0; $n -lt $grounds.Count; $n++) {
		$gx = $pad + $n*($tile+$pad)
		$qg.FillRectangle($grounds[$n][1], $gx, $pad, $tile, $tile)
		$qg.DrawImage($prev, $gx, $pad, $tile, $tile)
		$qg.DrawString($grounds[$n][0], $font, [System.Drawing.Brushes]::White, [single]$gx, [single]($tile+$pad+2))
	}
	$qg.Dispose(); $qa.Save($QaOut, [System.Drawing.Imaging.ImageFormat]::Png); $qa.Dispose(); $prev.Dispose()
}

$bmp.Dispose(); $png256.Dispose()
"logo.png + logo.ico written to $ImagesDir"
"ico size: $((Get-Item $icoPath).Length) bytes"
