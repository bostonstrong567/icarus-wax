param([string]$Out, [switch]$Full)
# Captures the Icarus game window with PrintWindow (works even when the window is covered or not focused).
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WaxWindowCapture {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
[WaxWindowCapture]::SetProcessDPIAware() | Out-Null
$p = Get-Process -Name 'Icarus-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { throw 'game window not found' }
$h = $p.MainWindowHandle
$wr = New-Object WaxWindowCapture+RECT; [WaxWindowCapture]::GetWindowRect($h, [ref]$wr) | Out-Null
$cr = New-Object WaxWindowCapture+RECT; [WaxWindowCapture]::GetClientRect($h, [ref]$cr) | Out-Null
$pt = New-Object WaxWindowCapture+POINT; [WaxWindowCapture]::ClientToScreen($h, [ref]$pt) | Out-Null
$w = $wr.R - $wr.L; $hh = $wr.B - $wr.T
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [WaxWindowCapture]::PrintWindow($h, $hdc, 2)   # PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc); $g.Dispose()
# crop to client area
$cx = $pt.X - $wr.L; $cy = $pt.Y - $wr.T
$crop = $bmp.Clone((New-Object System.Drawing.Rectangle $cx, $cy, $cr.R, $cr.B), $bmp.PixelFormat)
$crop.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$fg = [WaxWindowCapture]::GetForegroundWindow()
"ok=$ok window=$w x $hh client=$($cr.R) x $($cr.B) origin=$($pt.X),$($pt.Y) foreground=$($fg -eq $h) -> $Out"
