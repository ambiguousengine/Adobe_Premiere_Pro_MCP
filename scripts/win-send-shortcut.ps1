# Send a REAL keyboard shortcut to a window, by process name.
#
# WHY THIS EXISTS
# Premiere's scripted undo does not work: qe.project.undo() returns success and does nothing
# on 26.x, and app.findMenuCommandId is an After Effects API that does not exist in Premiere's
# CEP ExtendScript. But a REAL Ctrl+Z does work -- Premiere's undo stack records script-driven
# clip edits fine, it is only the scripted *trigger* that is broken.
#
# So we send genuine hardware-level input. Two things this must do that a naive version misses:
#   1. SendInput always goes to the FOREGROUND window, so the target must be foregrounded first.
#      AttachThreadInput is required -- a background process cannot otherwise steal foreground.
#   2. The INPUT struct must be the full native size (40 bytes on x64). Declaring only the
#      keyboard variant makes SendInput reject every event on its size check (returns 0).
#
# CONSEQUENCE: this is VISIBLE. The target app comes to the front and stays there; focus cannot
# be handed back (the borrowed foreground privilege does not survive the target becoming
# foreground -- tested, it does not work). It also sends real input, so it refuses to fire
# unless it has confirmed the target is actually frontmost.
#
# Usage: powershell -File win-send-shortcut.ps1 -ProcessName "adobe premiere pro" -Key Z -Ctrl
param(
  [Parameter(Mandatory = $true)][string]$ProcessName,
  [Parameter(Mandatory = $true)][string]$Key,
  [switch]$Ctrl,
  [switch]$Shift,
  [switch]$Alt,
  # Foregrounding a window is NOT enough for Premiere: it only acts on a shortcut when a PANEL
  # holds keyboard focus, which only a click provides (measured -- SetForegroundWindow alone
  # leaves the keystroke swallowed). FocusFraction clicks inside the window first, at a
  # fraction of its own rect, so no absolute screen coordinates are hardcoded.
  # 0.5/0.9 lands low-centre = the timeline panel in a default layout. Pass -NoFocusClick to skip.
  [double]$FocusFractionX = 0.5,
  [double]$FocusFractionY = 0.9,
  [switch]$NoFocusClick
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinSend {
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT {
    public uint uMsg; public ushort wParamL; public ushort wParamH;
  }
  // All three variants must be present so sizeof(INPUT) matches the native struct.
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
    [FieldOffset(0)] public HARDWAREINPUT hi;
  }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public INPUTUNION u;
  }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static int Size() { return Marshal.SizeOf(typeof(INPUT)); }
}
"@

$proc = Get-Process | Where-Object {
  $_.ProcessName -like "*$ProcessName*" -and $_.MainWindowHandle -ne 0
} | Select-Object -First 1

if (-not $proc) {
  Write-Output (ConvertTo-Json @{ success = $false; error = "No visible window for process matching '$ProcessName'" } -Compress)
  exit 1
}

$hwnd = $proc.MainWindowHandle

# Foreground it -- required, because SendInput follows foreground, not a window handle.
$myTid  = [WinSend]::GetCurrentThreadId()
$fgWnd  = [WinSend]::GetForegroundWindow()
$fgTid  = [WinSend]::GetWindowThreadProcessId($fgWnd, [IntPtr]::Zero)
$tgtTid = [WinSend]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)

[void][WinSend]::AttachThreadInput($myTid, $fgTid, $true)
[void][WinSend]::AttachThreadInput($myTid, $tgtTid, $true)
[void][WinSend]::ShowWindow($hwnd, 9)          # SW_RESTORE if minimised
[void][WinSend]::BringWindowToTop($hwnd)
[void][WinSend]::SetForegroundWindow($hwnd)
[void][WinSend]::AttachThreadInput($myTid, $fgTid, $false)
[void][WinSend]::AttachThreadInput($myTid, $tgtTid, $false)
Start-Sleep -Milliseconds 120

if ([WinSend]::GetForegroundWindow() -ne $hwnd) {
  # Refuse rather than fire blind: this is real input and would land in whatever IS frontmost.
  Write-Output (ConvertTo-Json @{ success = $false; error = "Could not bring '$($proc.ProcessName)' to the foreground; refused to send input so it cannot land in the wrong window." } -Compress)
  exit 1
}

# Give a PANEL keyboard focus. Without this the shortcut is delivered to the app but acted on
# by nothing. Click position is derived from the window's own rect, never hardcoded.
$clickedAt = $null
if (-not $NoFocusClick) {
  $r = New-Object WinSend+RECT
  if ([WinSend]::GetWindowRect($hwnd, [ref]$r)) {
    $cx = [int]($r.Left + ($r.Right  - $r.Left) * $FocusFractionX)
    $cy = [int]($r.Top  + ($r.Bottom - $r.Top ) * $FocusFractionY)
    [void][WinSend]::SetCursorPos($cx, $cy)
    Start-Sleep -Milliseconds 60
    $down = New-Object WinSend+INPUT; $down.type = 0
    $mid = New-Object WinSend+MOUSEINPUT; $mid.dwFlags = 0x0002   # LEFTDOWN
    $down.u.mi = $mid
    $up = New-Object WinSend+INPUT; $up.type = 0
    $miu = New-Object WinSend+MOUSEINPUT; $miu.dwFlags = 0x0004   # LEFTUP
    $up.u.mi = $miu
    [void][WinSend]::SendInput(2, [WinSend+INPUT[]]@($down, $up), [WinSend]::Size())
    Start-Sleep -Milliseconds 120
    $clickedAt = @{ x = $cx; y = $cy }
  }
}

$VK = @{ CONTROL = 0x11; SHIFT = 0x10; ALT = 0x12 }
$keyVk = [int][char]($Key.ToUpper())   # letters and digits map 1:1 to their VK codes

$mods = @()
if ($Ctrl)  { $mods += $VK.CONTROL }
if ($Alt)   { $mods += $VK.ALT }
if ($Shift) { $mods += $VK.SHIFT }

function New-KeyEvent([int]$vk, [bool]$up) {
  $i = New-Object WinSend+INPUT
  $i.type = 1                                  # INPUT_KEYBOARD
  $ki = New-Object WinSend+KEYBDINPUT
  $ki.wVk = [uint16]$vk
  $ki.dwFlags = $(if ($up) { 0x0002 } else { 0 })   # KEYEVENTF_KEYUP
  $i.u.ki = $ki
  return $i
}

$seq = @()
foreach ($m in $mods)                  { $seq += New-KeyEvent $m   $false }
$seq += New-KeyEvent $keyVk $false
$seq += New-KeyEvent $keyVk $true
foreach ($m in ($mods | Sort-Object -Descending)) { $seq += New-KeyEvent $m $true }

$sent = [WinSend]::SendInput([uint32]$seq.Count, [WinSend+INPUT[]]$seq, [WinSend]::Size())

$combo = (($(if ($Ctrl) { 'Ctrl' }), $(if ($Alt) { 'Alt' }), $(if ($Shift) { 'Shift' }), $Key.ToUpper()) | Where-Object { $_ }) -join '+'
Write-Output (ConvertTo-Json @{
  success    = ($sent -eq $seq.Count)
  sent       = $sent
  expected   = $seq.Count
  combo      = $combo
  key        = $Key.ToUpper()
  window     = $proc.MainWindowTitle
  process    = $proc.ProcessName
  focusClick = $clickedAt
  note       = "Target is now foregrounded and will stay there; focus is not restorable (Windows limitation)."
} -Compress)
