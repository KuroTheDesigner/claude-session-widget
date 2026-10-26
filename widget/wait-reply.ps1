# Waits for the widget's answer to one request and prints it as JSON.
# Prints {"kind":"defer"} once the Claude app is in front, so its own card
# takes over, and {"kind":"timeout"} before the caller's time limit.
param([string]$File)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@

function AppInFront {
  $id = 0
  [void][Fg]::GetWindowThreadProcessId([Fg]::GetForegroundWindow(), [ref]$id)
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  return $p -and $p.ProcessName -eq 'claude' -and $p.MainWindowTitle
}

$deadline = (Get-Date).AddSeconds(570)
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $File) {
    $text = Get-Content -LiteralPath $File -Raw
    Remove-Item -LiteralPath $File -Force
    Write-Output $text
    exit
  }
  if (AppInFront) { Write-Output '{"kind":"defer"}'; exit }
  Start-Sleep -Milliseconds 300
}
Write-Output '{"kind":"timeout"}'
