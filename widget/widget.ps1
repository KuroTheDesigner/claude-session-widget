# Always-on-top widget for Claude sessions. Reads <Base>\sessions\*.json
# (written by the session-widget mod) and <Base>\app-sessions.json (the app's
# list, for sessions the mod does not run in). Writes answers to
# <Base>\replies, new prompts to <Base>\prompts, and messages for app-list
# sessions to <Base>\outbox. One copy runs at a time.
param([string]$Base)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeSessionWidget')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  // Win+H opens Windows voice typing into the focused field.
  public static void Dictate() {
    keybd_event(0x5B, 0, 0, UIntPtr.Zero); keybd_event(0x48, 0, 0, UIntPtr.Zero);
    keybd_event(0x48, 0, 2, UIntPtr.Zero); keybd_event(0x5B, 0, 2, UIntPtr.Zero);
  }
  public static void Front(IntPtr h) { if (IsIconic(h)) ShowWindow(h, 9); SetForegroundWindow(h); }
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  // WS_EX_TRANSPARENT: clicks fall through to whatever is beneath.
  public static void ClickThrough(IntPtr h, bool on) { int s = GetWindowLong(h, -20); SetWindowLong(h, -20, on ? s | 0x20 : s & ~0x20); }
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  struct POINT { public int X, Y; }
  public static int[] Pointer() { POINT p; GetCursorPos(out p); return new[] { p.X, p.Y }; }
}

// Raises Changed the moment the Claude app gains or loses the foreground.
// The hook is out of context, so it calls back on the thread that started it.
public static class FocusWatch {
  delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  const uint EVENT_SYSTEM_FOREGROUND = 3;
  static WinEventProc proc;
  public static bool AppFocused;
  public static event Action<bool> Changed;
  public static void Start() {
    proc = (hook, ev, hwnd, obj, child, thread, time) => Update(hwnd);
    SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, 0);
    Update(GetForegroundWindow());
  }
  static void Update(IntPtr hwnd) {
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    bool focused = false;
    try { focused = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase); } catch {}
    if (focused == AppFocused) return;
    AppFocused = focused;
    var changed = Changed; if (changed != null) changed(focused);
  }
}
"@

$Inv = [Globalization.CultureInfo]::InvariantCulture
function Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
$C = @{
  Bg = Brush '#F21F1E1D'; Surface = Brush '#2B2A27'; Line = Brush '#3D3B37'
  Text = Brush '#F5F4EF'; Dim = Brush '#A8A59B'; Accent = Brush '#D97757'; Ink = Brush '#1F1E1D'
  Cream = Brush '#FAF9F5'
  # Rings, as the app's sidebar dots: working, finished and unseen, needs you, finished and seen.
  Working = Brush '#A3A099'; Unseen = Brush '#4C8DF6'; Needs = Brush '#E5B93A'; Idle = Brush '#4A4843'
  # Trays holding a session and the sessions it started, and one nested inside.
  Tray = Brush '#3A3834'; TrayInner = Brush '#4E4B45'
  # Surface with no alpha, for hover fades.
  Clear = Brush '#002B2A27'
}
$Tints = '#5B4A6E', '#3F5E5A', '#6E4A3F', '#4A5A6E', '#5E5A3F', '#6E3F55' | ForEach-Object { Brush $_ }
$Glyphs = New-Object Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'

$statePath = Join-Path $Base 'widget.json'
$ui = @{ mode = 'strip'; left = $null; top = $null; groups = @('local', 'remote', 'cloud'); children = $true }
try { (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ui[$_.Name] = $_.Value } } catch {}
function SaveUi { [IO.File]::WriteAllText($statePath, ($ui | ConvertTo-Json -Compress)) }

# Sessions marked read here: key -> the turn end marked. The app keeps its own read state in memory only.
$readPath = Join-Path $Base 'read.json'
$script:read = @{}
try { (Get-Content -LiteralPath $readPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:read[$_.Name] = $_.Value } } catch {}

$script:sessions = @()
$script:open = $null        # id of the session whose card is shown
$script:answered = @{}      # request ids answered here, hidden until the session drops them
$script:picks = @{}         # "<request>|<question>" -> chosen labels
$script:sends = @{}         # session id -> its last outbox message, until it is reported
$script:sig = ''
$script:kids = @{}          # app id -> the shown sessions it started
# What the last draw showed, so motion only plays for what actually changed.
$script:seen = @{}; $script:was = @{}   # session id -> ring state, this draw and the one before
$script:cued = @{}          # sessions whose attention cue has played, until they stop needing you
$script:cardShown = $null; $script:cardKey = ''; $script:openWas = $null
$script:mode = 'icon'; $script:badgeN = 0; $script:drawn = $false; $script:tipHiding = $false
$script:t0 = [DateTime]::UtcNow

function Log($text) { Add-Content -LiteralPath (Join-Path $Base 'widget.log') "$(Get-Date -Format s) $text" }

function Put($dir, $name, $obj) {
  $path = Join-Path (Join-Path $Base $dir) $name
  [IO.File]::WriteAllText("$path.tmp", ($obj | ConvertTo-Json -Depth 6 -Compress))
  Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}

# ---- motion ---------------------------------------------------------------
# Every tween is a WPF animation on a dependency property, so the render thread
# does the work. With Windows' "Show animations" off, values are set outright.

$Anim = [Windows.SystemParameters]::ClientAreaAnimation
$P = @{
  Opacity = [Windows.UIElement]::OpacityProperty; Stroke = [Windows.Shapes.Shape]::StrokeThicknessProperty
  X = [Windows.Media.TranslateTransform]::XProperty; Y = [Windows.Media.TranslateTransform]::YProperty
  ScaleX = [Windows.Media.ScaleTransform]::ScaleXProperty; ScaleY = [Windows.Media.ScaleTransform]::ScaleYProperty
  Height = [Windows.FrameworkElement]::HeightProperty; Width = [Windows.FrameworkElement]::WidthProperty
}
# Eases $el's property to $to; From lets a fresh element arrive. Bounce goes there and back.
function Tween($el, $prop, $to, $ms = 180, $from = $null, $mode = 'EaseOut', $done = $null, [switch]$Bounce) {
  if (-not $Anim) {
    if (-not $Bounce) { $el.BeginAnimation($script:P[$prop], $null); $el.SetValue($script:P[$prop], [double]$to) }
    if ($done) { & $done }
    return
  }
  $a = New-Object Windows.Media.Animation.DoubleAnimation -Property @{
    To = [double]$to; Duration = [Windows.Duration][TimeSpan]::FromMilliseconds($ms); AutoReverse = [bool]$Bounce
    EasingFunction = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = $mode } }
  if ($null -ne $from) { $a.From = [double]$from }
  if ($done) { $a.Add_Completed($done) }
  $el.BeginAnimation($script:P[$prop], $a)
}
# A brush of the element's own (never one from $C, which many share) cross-fades to another's colour.
function Fresh($brush) { New-Object Windows.Media.SolidColorBrush $brush.Color }
function Recolor($brush, $to, $ms = 220) {
  $p = [Windows.Media.SolidColorBrush]::ColorProperty
  if (-not $Anim -or $ms -le 0) { $brush.BeginAnimation($p, $null); $brush.Color = $to.Color; return }
  $brush.BeginAnimation($p, (New-Object Windows.Media.Animation.ColorAnimation -Property @{
    To = $to.Color; Duration = [Windows.Duration][TimeSpan]::FromMilliseconds($ms)
    EasingFunction = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' } }))
}
# Gives an element a scale and a slide of its own to tween; returns both.
function Movable($el, $origin = '0.5,0.5') {
  $m = @{ Scale = New-Object Windows.Media.ScaleTransform; Slide = New-Object Windows.Media.TranslateTransform }
  $grp = New-Object Windows.Media.TransformGroup
  $grp.Children.Add($m.Scale) | Out-Null; $grp.Children.Add($m.Slide) | Out-Null
  $el.RenderTransform = $grp; $el.RenderTransformOrigin = $origin
  $m
}
function Scale($m, $to, $ms = 180, $from = $null, [switch]$Bounce) { foreach ($axis in 'ScaleX', 'ScaleY') { Tween $m.Scale $axis $to $ms $from -Bounce:$Bounce } }
# A panel fades and settles into place, or lifts away; $done runs once it has gone.
function Enter($el, $m, $ms = 180) { Tween $el Opacity 1 $ms 0; Tween $m.Slide Y 0 $ms (-8); Scale $m 1 $ms 0.97 }
function Leave($el, $m, $done, $ms = 120) { Tween $el Opacity 0 $ms -mode EaseIn -done $done; Tween $m.Slide Y (-6) $ms -mode EaseIn }

# ---- elements -------------------------------------------------------------

# Buttons dim on hover and sink a little while pressed.
$xaml = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8"
          Padding="{TemplateBinding Padding}" BorderBrush="{TemplateBinding BorderBrush}"
          BorderThickness="{TemplateBinding BorderThickness}" RenderTransformOrigin="0.5,0.5">
    <Border.RenderTransform><ScaleTransform/></Border.RenderTransform>
    <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Trigger.EnterActions><BeginStoryboard><Storyboard>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="0.82" Duration="0:0:0.12"/>
      </Storyboard></BeginStoryboard></Trigger.EnterActions>
      <Trigger.ExitActions><BeginStoryboard><Storyboard>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.2"/>
      </Storyboard></BeginStoryboard></Trigger.ExitActions>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Trigger.EnterActions><BeginStoryboard><Storyboard>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="0.65" Duration="0:0:0.06"/>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.95" Duration="0:0:0.08"/>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.95" Duration="0:0:0.08"/>
      </Storyboard></BeginStoryboard></Trigger.EnterActions>
      <Trigger.ExitActions><BeginStoryboard><Storyboard>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="0.82" Duration="0:0:0.15"/>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.18">
          <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
        </DoubleAnimation>
        <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.18">
          <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
        </DoubleAnimation>
      </Storyboard></BeginStoryboard></Trigger.ExitActions>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@
if (-not $Anim) { $xaml = $xaml -replace 'Duration="[^"]+"', 'Duration="0"' }
$buttonTemplate = [Windows.Markup.XamlReader]::Parse($xaml)

function Text($value, $size = 12.5, $brush = $C.Text, [switch]$Bold, [switch]$Mono) {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $value; $t.FontSize = $size; $t.Foreground = $brush; $t.TextWrapping = 'Wrap'; $t.LineHeight = [Math]::Round($size * 1.45)
  if ($Bold) { $t.FontWeight = 'SemiBold' }
  if ($Mono) { $t.FontFamily = 'Cascadia Mono, Consolas' }
  $t
}

function Btn($content, $tag, $bg = $C.Surface, $fg = $C.Text, [switch]$Icon, [switch]$Wide) {
  $b = New-Object Windows.Controls.Button
  $b.Template = $buttonTemplate; $b.Background = $bg; $b.Foreground = $fg; $b.BorderThickness = 0
  $b.Padding = '14,9'; $b.Margin = '0,8,8,0'; $b.Cursor = 'Hand'; $b.FontSize = 12.5; $b.Tag = $tag
  if ($Icon) { $b.FontFamily = $Glyphs; $b.FontSize = 14; $b.Padding = '9,8'; $b.Margin = '8,0,0,0' }
  if ($Wide) { $b.HorizontalContentAlignment = 'Left'; $b.HorizontalAlignment = 'Stretch'; $b.Margin = '0,8,0,0'; $b.Padding = '14,11' }
  $b.Content = $content
  $b.Add_Click({ Act $this.Tag })
  $b
}

function Initials($name) {
  $parts = @($name -split '[-_ .]+' | Where-Object { $_ })
  if ($parts.Count -ge 2) { return "$($parts[0][0])$($parts[1][0])".ToUpper() }
  return $name.Substring(0, [Math]::Min(2, $name.Length)).ToUpper()
}

function Tint($id) { $h = 0; foreach ($ch in $id.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 65521 }; $Tints[$h % $Tints.Count] }

function Spark($size, $brush) {
  $c = $size / 2; $parts = @()
  for ($i = 0; $i -lt 12; $i++) {
    $a = $i * [Math]::PI / 6; $r2 = if ($i % 2) { $size * 0.27 } else { $size * 0.36 }
    # Every ray starts at the centre, so the spark's middle is solid.
    $parts += 'M {0} {0} L {1} {2}' -f $c.ToString('F2', $Inv),
      ($c + [Math]::Cos($a) * $r2).ToString('F2', $Inv), ($c + [Math]::Sin($a) * $r2).ToString('F2', $Inv)
  }
  $p = New-Object Windows.Shapes.Path
  $p.Data = [Windows.Media.Geometry]::Parse($parts -join ' ')
  $p.Stroke = $brush; $p.StrokeThickness = $size * 0.07; $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'
  $p.Width = $size; $p.Height = $size; $p.IsHitTestVisible = $false
  $p
}

# Parents are named by app id, which mod sessions carry as appId and app-list rows as id.
function Key($s) { if ($s.appId) { $s.appId } else { $s.id } }

# Needs you: a request here, one handed to the app, or a turn that stopped on a question.
function NeedsYou($s) { (@(Pending $s).Count -gt 0) -or $s.inApp -or (Waits $s) }
# Finished since you last looked at it in the app, as the app's own blue dot.
function Unseen($s) { $s.state -ne 'working' -and [int64]$s.doneAt -gt [int64]$s.focusedAt -and [int64]$s.doneAt -gt [int64]$script:read[(Key $s)] }
# A turn's question lapses once you have looked at the session since, as in the app.
function Waits($s) { $s.waiting -and (Unseen $s) }
function Pending($s) { @($s.requests) | Where-Object { $_ -and -not $script:answered[$_.id] } }
# The shown sessions this one started, and theirs in turn.
function Descendants($s) { foreach ($child in @($script:kids[(Key $s)])) { if ($child) { $child; Descendants $child } } }

# ---- window ---------------------------------------------------------------

$win = New-Object Windows.Window
$win.WindowStyle = 'None'; $win.AllowsTransparency = $true; $win.Background = [Windows.Media.Brushes]::Transparent
$win.Topmost = $true; $win.ShowInTaskbar = $false; $win.SizeToContent = 'WidthAndHeight'; $win.ResizeMode = 'NoResize'
$win.Title = 'Claude sessions'; $win.FontFamily = 'Segoe UI Variable Text, Segoe UI'
$area = [Windows.SystemParameters]::WorkArea
# The widget hugs the right, left or top edge of the screen; pos is how far along that edge it sits.
if (-not $ui.edge) { $ui.edge = 'right' }
if ($null -eq $ui.pos) { $ui.pos = if ($null -ne $ui.top) { $ui.top } else { $area.Top + 120 } }
$ui.Remove('left'); $ui.Remove('top')
# Puts the window on its edge at pos. Growing slides it back on screen; shrinking returns it to pos.
function Snap {
  $w = $win.ActualWidth; $h = $win.ActualHeight
  if ($ui.edge -eq 'top') { $win.Top = $area.Top; $win.Left = [Math]::Max($area.Left, [Math]::Min($ui.pos, $area.Right - $w)); return }
  $win.Left = if ($ui.edge -eq 'left') { $area.Left } else { $area.Right - $w }
  $win.Top = [Math]::Max($area.Top, [Math]::Min($ui.pos, $area.Bottom - $h))
}
$win.Add_SizeChanged({ Snap })
# A window shown without a position takes Windows' default size, wider than the notch.
Snap

$root = New-Object Windows.Controls.StackPanel -Property @{ UseLayoutRounding = $true }
$win.Content = $root

# The notch: a hill rising from the edge. Each end is one S-curve, running $F
# along the edge and leaving it and meeting the notch's face without a corner.
# The orb starts $Pad along, where the slope is nearly at full height.
$F = 48; $Pad = 34
function Reshape {
  if (-not $bar.ActualWidth) { return }
  # Drawn for the right edge, then mirrored or turned onto the others.
  $across, $along = if ($ui.edge -eq 'top') { $bar.ActualHeight, $bar.ActualWidth } else { $bar.ActualWidth, $bar.ActualHeight }
  $g = [Windows.Media.PathGeometry]::CreateFromGeometry([Windows.Media.Geometry]::Parse([string]::Format($Inv,
    'M {0},0 C {0},{1} 0,{1} 0,{2} L 0,{3} C 0,{4} {0},{4} {0},{5}',
    $across, ($F / 2), $F, ($along - $F), ($along - $F / 2), $along)))
  $g.Transform = New-Object Windows.Media.MatrixTransform $(switch ($ui.edge) {
    'left' { [Windows.Media.Matrix]::new(-1, 0, 0, 1, $across, 0) }
    'top' { [Windows.Media.Matrix]::new(0, -1, 1, 0, 0, $across) }
    default { [Windows.Media.Matrix]::Identity } })
  $shade.Data = $notch.Data = $g
}
# The shadow is a cached layer of its own, so the rings' pulse never redraws the blur.
$shade = New-Object Windows.Shapes.Path -Property @{ Fill = $C.Bg; Effect = (New-Object Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 14; ShadowDepth = 2; Opacity = 0.35 }) }
$shadeLayer = New-Object Windows.Controls.Canvas -Property @{ CacheMode = (New-Object Windows.Media.BitmapCache); IsHitTestVisible = $false }
$shadeLayer.Children.Add($shade) | Out-Null
# No stroke runs down the screen edge: the outline is left open there.
$notch = New-Object Windows.Shapes.Path -Property @{ Fill = $C.Bg; Stroke = $C.Line; StrokeThickness = 1 }
$notchLayer = New-Object Windows.Controls.Canvas
$notchLayer.Children.Add($notch) | Out-Null
$bar = New-Object Windows.Controls.Grid -Property @{ HorizontalAlignment = 'Left'; VerticalAlignment = 'Top' }
$bar.Children.Add($shadeLayer) | Out-Null; $bar.Children.Add($notchLayer) | Out-Null
$bar.Add_SizeChanged({ Reshape })
$root.Children.Add($bar) | Out-Null

$row = New-Object Windows.Controls.StackPanel
$bar.Children.Add($row) | Out-Null
# Picks the value for a notch running down a side edge, or the one for the top edge.
function Along($side, $top) { if ($script:vert) { $side } else { $top } }

$orb = New-Object Windows.Controls.Grid
$orb.Width = 44; $orb.Height = 44; $orb.Tag = 'orb'; $orb.Cursor = 'Hand'
$orbFill = New-Object Windows.Shapes.Ellipse
$orbFill.Fill = $C.Accent; $orbFill.Margin = 4
# In icon mode the orb's ring sums up the sessions: yellow if any needs you, else blue if any is unseen.
$ring = New-Object Windows.Shapes.Ellipse
$ring.StrokeThickness = 2.5; $ring.Visibility = 'Collapsed'; $ring.Stroke = Fresh $C.Unseen
$badge = New-Object Windows.Controls.Border
$badge.Background = $C.Cream; $badge.CornerRadius = 8; $badge.MinWidth = 16; $badge.Height = 16; $badge.Padding = '4,0'
$badge.HorizontalAlignment = 'Right'; $badge.VerticalAlignment = 'Top'; $badge.Margin = '0,-1,-1,0'; $badge.Visibility = 'Collapsed'
$badgeText = Text '' 10.5 $C.Ink -Bold
$badgeText.HorizontalAlignment = 'Center'; $badgeText.VerticalAlignment = 'Center'
$badge.Child = $badgeText
$badgeMove = Movable $badge
$orb.Children.Add($orbFill) | Out-Null; $orb.Children.Add((Spark 36 $C.Cream)) | Out-Null
$orb.Children.Add($ring) | Out-Null; $orb.Children.Add($badge) | Out-Null
$row.Children.Add($orb) | Out-Null

# The working ring's slow breath, like the app's grey working dot.
$breathe = New-Object Windows.Media.Animation.DoubleAnimation -Property @{
  From = 0.3; To = 1; Duration = [Windows.Duration][TimeSpan]::FromMilliseconds(1100)
  AutoReverse = $true; RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  EasingFunction = New-Object Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
}
# Working rings breathe in step, each joining mid-cycle so a redraw never restarts the breath.
# The slow breath needs no more than 24 frames a second.
function Breathe($el) {
  $a = $breathe.Clone()
  $a.BeginTime = [TimeSpan]::FromMilliseconds(-(([DateTime]::UtcNow - $script:t0).TotalMilliseconds % 2200))
  [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 24)
  $el.BeginAnimation($script:P.Opacity, $a)
}

$avatars = New-Object Windows.Controls.StackPanel -Property @{ HorizontalAlignment = 'Center'; ClipToBounds = $true }
$avatarsMove = Movable $avatars '0.5,0'
$row.Children.Add($avatars) | Out-Null

$card = New-Object Windows.Controls.Border
$card.CornerRadius = 18; $card.Background = $C.Bg; $card.BorderBrush = $C.Line; $card.BorderThickness = 1
$card.Padding = 20; $card.Width = 400; $card.HorizontalAlignment = 'Left'; $card.VerticalAlignment = 'Top'; $card.Visibility = 'Collapsed'
$card.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 18; ShadowDepth = 3; Opacity = 0.4 }
$cardMove = Movable $card '0.5,0'

# Lays the widget out for its edge: which way the notch runs, and the card opening
# beside it, level with its start. Margins leave room for the shadows.
function Dock {
  $script:vert = $ui.edge -ne 'top'
  $root.Orientation = Along 'Horizontal' 'Vertical'
  $row.Orientation = $avatars.Orientation = Along 'Vertical' 'Horizontal'
  $row.Margin = Along "5,$Pad,5,$Pad" "$Pad,5,$Pad,5"
  $root.Children.Remove($card)
  switch ($ui.edge) {
    'right' { $bar.Margin = '16,0,0,16'; $card.Margin = "18,$Pad,0,18"; $root.Children.Insert(0, $card) }
    'left' { $bar.Margin = '0,0,16,16'; $card.Margin = "0,$Pad,18,18"; $root.Children.Add($card) | Out-Null }
    'top' { $bar.Margin = '16,0,16,16'; $card.Margin = "$(16 + $Pad),-8,18,18"; $root.Children.Add($card) | Out-Null }
  }
  $root.RenderTransformOrigin = if ($ui.edge -eq 'right') { '1,0' } else { '0,0' }
  Reshape
}
Dock

# One input field, kept across redraws so typing and dictation survive them.
$inputBox = New-Object Windows.Controls.TextBox
$inputBox.Background = $C.Surface; $inputBox.Foreground = $C.Text; $inputBox.CaretBrush = $C.Text
$inputBox.BorderThickness = 0; $inputBox.Padding = '12,10'; $inputBox.FontSize = 13
$inputBox.TextWrapping = 'Wrap'; $inputBox.AcceptsReturn = $true; $inputBox.MaxHeight = 130; $inputBox.VerticalContentAlignment = 'Center'
$hint = Text '' 13 $C.Dim
$hint.Margin = '14,10'; $hint.IsHitTestVisible = $false; $hint.VerticalAlignment = 'Center'
$inputBox.Add_TextChanged({ $hint.Visibility = if ($inputBox.Text) { 'Collapsed' } else { 'Visible' } })
$inputBox.Add_PreviewKeyDown({
  if ($_.Key -eq 'Return' -and -not ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)) {
    $_.Handled = $true; Act @{ act = 'send' }
  }
})
$field = New-Object Windows.Controls.Border
$field.CornerRadius = 10; $field.Background = $C.Surface; $field.ClipToBounds = $true
$fieldGrid = New-Object Windows.Controls.Grid
$fieldGrid.Children.Add($inputBox) | Out-Null; $fieldGrid.Children.Add($hint) | Out-Null
$field.Child = $fieldGrid
$inputRow = New-Object Windows.Controls.DockPanel
$inputRow.Margin = '0,20,0,0'; $inputRow.LastChildFill = $true
# Claude's send mark: an up arrow on the accent square.
$arrow = New-Object Windows.Shapes.Path
$arrow.Data = [Windows.Media.Geometry]::Parse('M 7,12.6 L 7,1.8 M 2.2,6.5 L 7,1.7 L 11.8,6.5')
$arrow.Stroke = $C.Cream; $arrow.StrokeThickness = 1.9; $arrow.Width = 14; $arrow.Height = 14
$arrow.StrokeStartLineCap = 'Round'; $arrow.StrokeEndLineCap = 'Round'; $arrow.StrokeLineJoin = 'Round'
$sendBtn = Btn $arrow @{ act = 'send' } $C.Accent $C.Cream -Icon
$sendBtn.Padding = 9
$micBtn = Btn ([string][char]0xE720) @{ act = 'mic' } $C.Surface $C.Text -Icon
[Windows.Controls.DockPanel]::SetDock($sendBtn, 'Right'); [Windows.Controls.DockPanel]::SetDock($micBtn, 'Right')
$inputRow.Children.Add($sendBtn) | Out-Null; $inputRow.Children.Add($micBtn) | Out-Null; $inputRow.Children.Add($field) | Out-Null

# Hover tips and the menu are the widget's own panels, not Windows' stock ones.
function Floating {
  $p = New-Object Windows.Controls.Primitives.Popup
  $p.AllowsTransparency = $true
  $panel = New-Object Windows.Controls.Border
  $panel.Background = $C.Bg; $panel.BorderBrush = $C.Line; $panel.BorderThickness = 1; $panel.CornerRadius = 10
  $panel.Margin = 10
  $panel.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 14; ShadowDepth = 2; Opacity = 0.4 }
  $panel.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, $win.FontFamily)
  $p.Child = $panel
  $p
}

$tip = Floating
$tip.Placement = 'Bottom'; $tip.VerticalOffset = 6; $tip.HorizontalOffset = -10; $tip.IsHitTestVisible = $false
$tip.Child.Padding = '10,7'
$tipMove = Movable $tip.Child '0.5,0'
$tipDelay = New-Object Windows.Threading.DispatcherTimer
$tipDelay.Interval = [TimeSpan]::FromMilliseconds(450)
$tipDelay.Add_Tick({ $tipDelay.Stop(); $script:tipHiding = $false; $tip.IsOpen = $true; Enter $tip.Child $tipMove 150 })
# Leaving lets the tip fade out, unless another opens meanwhile.
function HideTip { if ($tip.IsOpen) { $script:tipHiding = $true; Leave $tip.Child $tipMove { if ($script:tipHiding) { $tip.IsOpen = $false } } 100 } }
# The tip's words ride on the element's DataContext, which nothing else here uses.
function Tip($el, $title, $sub) {
  $el.DataContext = @($title, $sub)
  $el.Add_MouseEnter({
    $stack = New-Object Windows.Controls.StackPanel
    $stack.Children.Add((Text $this.DataContext[0] 12 -Bold)) | Out-Null
    if ($this.DataContext[1]) { $sub = Text $this.DataContext[1] 11.5 $C.Dim; $sub.MaxWidth = 260; $stack.Children.Add($sub) | Out-Null }
    # Tips on a side notch open away from the screen edge.
    if ($this.IsDescendantOf($bar) -and $script:vert) { $tip.Placement = if ($ui.edge -eq 'left') { 'Right' } else { 'Left' }; $tip.HorizontalOffset = 0; $tip.VerticalOffset = -10 }
    else { $tip.Placement = 'Bottom'; $tip.HorizontalOffset = -10; $tip.VerticalOffset = 6 }
    $tip.Child.Child = $stack; $tip.PlacementTarget = $this; $tipDelay.Start()
  })
  $el.Add_MouseLeave({ $tipDelay.Stop(); HideTip })
}
Tip $orb 'Claude sessions' 'Click to switch views. Right-click for options.'
Tip $sendBtn 'Send'
Tip $micBtn 'Dictate' 'Windows voice typing'

$menuPop = Floating
$menuPop.Placement = 'MousePoint'; $menuPop.StaysOpen = $false
$menuPop.Child.Padding = 5
$menuMove = Movable $menuPop.Child '0.5,0'
function MenuRow($label, $tag, $checked) {
  $r = New-Object Windows.Controls.Border
  $r.CornerRadius = 6; $r.Padding = '8,6,18,6'; $r.Background = Fresh $C.Clear; $r.Cursor = 'Hand'; $r.Tag = $tag
  $line = New-Object Windows.Controls.StackPanel
  $line.Orientation = 'Horizontal'
  $mark = Text $(if ($checked) { [string][char]0xE73E } else { '' }) 11 $C.Accent
  $mark.FontFamily = $Glyphs; $mark.Width = 22; $mark.VerticalAlignment = 'Center'
  $line.Children.Add($mark) | Out-Null; $line.Children.Add((Text $label 12.5)) | Out-Null
  $r.Child = $line
  $r.Add_MouseEnter({ Recolor $this.Background $C.Surface 100 })
  $r.Add_MouseLeave({ Recolor $this.Background $C.Clear 150 })
  $r.Add_MouseLeftButtonUp({ MenuPick $this.Tag })
  $r
}
function MenuLabel($text) { $t = Text $text.ToUpper() 10 $C.Dim -Bold; $t.Margin = '8,7,8,3'; $t }
function MenuLine { $l = New-Object Windows.Controls.Border; $l.Height = 1; $l.Background = $C.Line; $l.Margin = '6,5'; $l }
function OpenMenu {
  $stack = New-Object Windows.Controls.StackPanel
  $stack.MinWidth = 190
  $items = @(
    (MenuLabel 'View'),
    (MenuRow 'Claude icon only' @{ act = 'mode'; mode = 'icon' } ($ui.mode -eq 'icon')),
    (MenuRow 'Icon strip' @{ act = 'mode'; mode = 'strip' } ($ui.mode -eq 'strip')),
    (MenuLine), (MenuLabel 'Show sessions from'))
  foreach ($g in @(@('Local', 'local'), @('Remote', 'remote'), @('Cloud', 'cloud'))) {
    $items += MenuRow $g[0] @{ act = 'group'; group = $g[1] } (@($ui.groups) -contains $g[1])
  }
  $items += MenuRow 'Child sessions' @{ act = 'children' } ([bool]$ui.children)
  $items += MenuLine
  $items += MenuRow 'Quit' @{ act = 'mode'; mode = 'quit' } $false
  foreach ($i in $items) { $stack.Children.Add($i) | Out-Null }
  $menuPop.Child.Child = $stack
  if (-not $menuPop.IsOpen) { $menuPop.IsOpen = $true; Enter $menuPop.Child $menuMove 150 }
}
# The filter stays open to tick several; anything else closes the menu.
function MenuPick($tag) { Act $tag; if ($tag.act -in 'group', 'children') { OpenMenu } else { $menuPop.IsOpen = $false } }
$bar.Add_MouseRightButtonUp({ $_.Handled = $true; $tipDelay.Stop(); $tip.IsOpen = $false; OpenMenu })

# Drag the notch along its edge, or over to the right, left or top edge,
# whichever the pointer is nearest. A press that does not move is a click.
$script:press = $null
$bar.Add_MouseLeftButtonDown({
  $at = $_.GetPosition($win)
  $script:press = @{ x = $win.Left + $at.X; y = $win.Top + $at.Y; grab = $(if ($ui.edge -eq 'top') { $at.X } else { $at.Y }); source = $_.OriginalSource; moved = $false }
  $bar.CaptureMouse() | Out-Null
})
$bar.Add_MouseMove({
  $press = $script:press
  if (-not $press) { return }
  $at = $_.GetPosition($win); $x = $win.Left + $at.X; $y = $win.Top + $at.Y
  if (-not $press.moved -and [Math]::Abs($x - $press.x) + [Math]::Abs($y - $press.y) -le 3) { return }
  $press.moved = $true
  $gap = @{ right = $area.Right - $x; left = $x - $area.Left; top = $y - $area.Top }
  $edge = ($gap.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
  if ($edge -ne $ui.edge) {
    # On a new edge the pointer holds the orb's middle.
    $ui.edge = $edge; $press.grab = if ($edge -eq 'top') { 16 + $Pad + 22 } else { $Pad + 22 }
    Dock; $script:sig = ''; Refresh
  }
  $ui.pos = $(if ($edge -eq 'top') { $x } else { $y }) - $press.grab
  Snap
})
$bar.Add_MouseLeftButtonUp({
  $press = $script:press; $script:press = $null
  $bar.ReleaseMouseCapture()
  if (-not $press) { return }
  if ($press.moved) { $ui.pos = if ($ui.edge -eq 'top') { $win.Left } else { $win.Top }; SaveUi; return }
  $node = $press.source
  while ($node -and -not ($node.Tag -is [string])) { $node = [Windows.Media.VisualTreeHelper]::GetParent($node) }
  if ($node.Tag -eq 'orb') { Act @{ act = 'mode'; mode = $(if ($ui.mode -eq 'strip') { 'icon' } else { 'strip' }) } }
  elseif ($node.Tag -like 'session:*') { Act @{ act = 'open'; sid = $node.Tag.Substring(8) } }
})

# In strip view, hovering the notch opens it out into the strip.
$script:hover = $false
function Expanded { $ui.mode -eq 'strip' -and ($script:hover -or $script:open) }
$hoverExpand = New-Object Windows.Threading.DispatcherTimer
$hoverExpand.Interval = [TimeSpan]::FromMilliseconds(120)
$hoverExpand.Add_Tick({ $hoverExpand.Stop(); $script:hover = $true; Refresh })

# Hovering a session that wants you opens its card. Leaving the widget closes
# it, unless you have started typing, and folds the notch.
$script:hoverSid = $null
$hoverOpen = New-Object Windows.Threading.DispatcherTimer
$hoverOpen.Interval = [TimeSpan]::FromMilliseconds(250)
$hoverOpen.Add_Tick({
  $hoverOpen.Stop()
  if ($script:hoverSid -and $script:open -ne $script:hoverSid -and -not $inputBox.Text) { Act @{ act = 'show'; sid = $script:hoverSid } }
})
$cardClose = New-Object Windows.Threading.DispatcherTimer
$cardClose.Interval = [TimeSpan]::FromMilliseconds(450)
$cardClose.Add_Tick({
  # Resizing or moving the window can report a leave while the pointer is still
  # on the widget; then keep checking until it really has gone.
  $p = [Win]::Pointer()
  if ($root.IsHitTestVisible -and [Windows.Media.VisualTreeHelper]::HitTest($root, $win.PointFromScreen([Windows.Point]::new($p[0], $p[1])))) { return }
  $cardClose.Stop(); $script:hover = $false
  if ($script:open -and -not $inputBox.Text -and -not $inputBox.IsKeyboardFocusWithin) { $script:open = $null }
  Refresh
})
$root.Add_MouseEnter({ $cardClose.Stop(); if (-not $script:hover) { $hoverExpand.Start() } })
$root.Add_MouseLeave({ $hoverExpand.Stop(); $cardClose.Start() })

# ---- drawing --------------------------------------------------------------

# Child sessions are drawn smaller, one step per generation.
function Avatar($s) {
  $size = @(34, 26, 22)[[Math]::Min([int]$s.depth, 2)]
  $g = New-Object Windows.Controls.Grid
  $g.Width = $size; $g.Height = $size; $g.Margin = Along '3,5,3,0' '5,3,0,3'; $g.HorizontalAlignment = $g.VerticalAlignment = 'Center'; $g.Tag = "session:$($s.id)"; $g.Cursor = 'Hand'
  $m = Movable $g
  $needs = $s.needsAny
  if ($needs -or (Unseen $s)) {
    $g.Add_MouseEnter({ $script:hoverSid = $this.Tag.Substring(8); $hoverOpen.Start() })
    $g.Add_MouseLeave({ $hoverOpen.Stop(); $script:hoverSid = $null })
  } else { Tip $g $s.name $s.title }
  $fill = New-Object Windows.Shapes.Ellipse
  $fill.Fill = Tint $s.id; $fill.Margin = 3
  $ringE = New-Object Windows.Shapes.Ellipse
  $opened = $script:open -eq $s.id
  $ringE.StrokeThickness = if ($opened) { 3.5 } else { 2.4 }
  if ($opened -ne ($script:openWas -eq $s.id)) { Tween $ringE Stroke $ringE.StrokeThickness 150 (5.9 - $ringE.StrokeThickness) }
  $working = -not $needs -and $s.state -eq 'working'
  $state = if ($needs) { 'Needs' } elseif ($working) { 'Working' } elseif (Unseen $s) { 'Unseen' } else { 'Idle' }
  # A ring whose state changed since the last draw cross-fades from its old colour.
  $old = $script:was[$s.id]
  if ($old -and $old -ne $state) { $ringE.Stroke = Fresh $C[$old]; Recolor $ringE.Stroke $C[$state]; if ($old -eq 'Working') { Tween $ringE Opacity 1 200 0.65 } }
  else { $ringE.Stroke = $C[$state] }
  $script:seen[$s.id] = $state
  if ($working) { Breathe $ringE }
  # A session new to the strip grows in; one that newly needs you nods, once.
  $new = $script:drawn -and -not $old
  if ($new) { Tween $g Opacity 1 200 0; Scale $m 1 200 0.6 }
  if (-not $needs) { $script:cued.Remove($s.id) }
  elseif (-not $script:cued[$s.id]) { $script:cued[$s.id] = 1; if ($script:drawn -and -not $new) { Scale $m 1.18 140 -Bounce } }
  $label = Text (Initials $s.name) $(if ($size -lt 34) { 9 } else { 11 }) $C.Text -Bold
  $label.HorizontalAlignment = 'Center'; $label.VerticalAlignment = 'Center'; $label.IsHitTestVisible = $false
  $g.Children.Add($fill) | Out-Null; $g.Children.Add($ringE) | Out-Null; $g.Children.Add($label) | Out-Null
  # Remote and cloud sessions carry a small mark in the corner.
  $mark = @{ cloud = 0xE753; remote = 0xE968 }[$s.group]
  if ($mark) {
    $corner = New-Object Windows.Controls.Border
    $corner.Width = 14; $corner.Height = 14; $corner.CornerRadius = 7; $corner.Background = $C.Surface
    $corner.HorizontalAlignment = 'Right'; $corner.VerticalAlignment = 'Bottom'; $corner.Margin = '0,0,-2,-2'; $corner.IsHitTestVisible = $false
    $glyph = Text ([string][char]$mark) 8 $C.Text
    $glyph.FontFamily = $Glyphs; $glyph.HorizontalAlignment = 'Center'; $glyph.VerticalAlignment = 'Center'
    $corner.Child = $glyph
    $g.Children.Add($corner) | Out-Null
  }
  $g
}

# A session and the sessions it started share a tray, joined by short links.
# A child that started sessions of its own gets a lighter tray inside its parent's.
function Family($s) {
  $a = Avatar $s
  $children = @($script:kids[(Key $s)] | Where-Object { $_ })
  if (-not $children.Count) { return $a }
  $t = New-Object Windows.Controls.Border
  $t.CornerRadius = 20; $t.Padding = Along '0,0,0,5' '0,0,5,0'; $t.HorizontalAlignment = $t.VerticalAlignment = 'Center'
  $t.Background = if ($s.depth -eq 0) { $C.Tray } else { $C.TrayInner }
  $t.Margin = if ($s.depth -eq 0) { Along '1,4,1,0' '4,1,0,1' } else { 0 }
  $row = New-Object Windows.Controls.StackPanel -Property @{ Orientation = $avatars.Orientation }
  # No space where the first link leaves; a nested tray's ring also sits
  # on the tray's edge, where the link arrives.
  $a.Margin = if ($s.depth -eq 0) { Along '2,2,2,0' '2,2,0,2' } else { Along '2,0,2,0' '0,2,0,2' }; $row.Children.Add($a) | Out-Null
  foreach ($child in $children) {
    # The link runs edge to edge, so it meets both rings.
    $link = New-Object Windows.Shapes.Rectangle -Property @{ Width = (Along 2 8); Height = (Along 8 2); Fill = $C.Dim; Opacity = 0.85; HorizontalAlignment = 'Center'; VerticalAlignment = 'Center' }
    $f = Family $child
    if ($f -is [Windows.Controls.Grid]) { $f.Margin = Along '2,0,2,0' '0,2,0,2' }
    $row.Children.Add($link) | Out-Null; $row.Children.Add($f) | Out-Null
  }
  $t.Child = $row
  $t
}

# The question a turn left you, with its reply buttons, each sent to that session.
function AskBlock($stack, $who, [switch]$Open) {
  $q = Text $who.ask 13 -Bold; $q.Margin = '0,16,0,4'
  $stack.Children.Add($q) | Out-Null
  # Once a reply to this turn is on its way, its status replaces the buttons, so one click sends once.
  $send = $script:sends[$who.id]
  if ($send -and -not $send.failed -and $send.doneAt -eq $who.doneAt) { $status = Text $send.status 11.5 $C.Dim; $status.Margin = '0,10,0,0'; $stack.Children.Add($status) | Out-Null; return }
  $buttons = New-Object Windows.Controls.WrapPanel
  foreach ($a in @($who.actions)) {
    if (-not $a) { continue }
    $first = -not $buttons.Children.Count
    $buttons.Children.Add((Btn $a.label @{ act = 'send'; to = $who.id; text = $a.message } $(if ($first) { $C.Accent } else { $C.Surface }) $(if ($first) { $C.Ink } else { $C.Text }))) | Out-Null
  }
  if ($Open) { $buttons.Children.Add((Btn 'Open chat' @{ act = 'open'; sid = $who.id })) | Out-Null }
  if ($buttons.Children.Count) { $stack.Children.Add($buttons) | Out-Null }
}

function Card($s) {
  $outer = New-Object Windows.Controls.StackPanel

  $head = New-Object Windows.Controls.DockPanel
  $close = Btn ([string][char]0xE711) @{ act = 'toggle'; sid = $s.id } ([Windows.Media.Brushes]::Transparent) $C.Dim -Icon
  $close.Padding = '6'; $close.FontSize = 11
  [Windows.Controls.DockPanel]::SetDock($close, 'Right')
  $head.Children.Add($close) | Out-Null
  if (Unseen $s) {
    $mark = Btn ([string][char]0xE8C3) @{ act = 'read'; sid = $s.id } ([Windows.Media.Brushes]::Transparent) $C.Dim -Icon
    $mark.Padding = '6'; $mark.FontSize = 12.5; $mark.Margin = '6,0,0,0'
    Tip $mark 'Mark as read'
    [Windows.Controls.DockPanel]::SetDock($mark, 'Right')
    $head.Children.Add($mark) | Out-Null
  }
  $titles = New-Object Windows.Controls.StackPanel
  $name = Text $s.name 13.5 -Bold
  if ($s.group -ne 'local') { $name.Inlines.Add((New-Object Windows.Documents.Run "  $((Get-Culture).TextInfo.ToTitleCase($s.group))" -Property @{ Foreground = $C.Dim; FontWeight = 'Normal'; FontSize = 11.5 })) }
  $titles.Children.Add($name) | Out-Null
  if ($s.title) { $sub = Text $s.title 11.5 $C.Dim; $sub.Margin = '0,2,0,0'; $sub.TextWrapping = 'NoWrap'; $sub.TextTrimming = 'CharacterEllipsis'; $titles.Children.Add($sub) | Out-Null }
  $head.Children.Add($titles) | Out-Null
  $outer.Children.Add($head) | Out-Null
  $stack = New-Object Windows.Controls.StackPanel

  $pending = @(Pending $s)
  # App-list sessions get your text through the app's send_message, labelled as from another session.
  $hint.Text = if ($s.app) { 'Send this session a message' } else { 'Reply to this session' }
  if ($pending.Count) {
    $r = $pending[0]
    $hint.Text = 'Or type your own answer'
    $questions = @($r.questions)
    foreach ($q in $questions) {
      $chip = Text ($q.header.ToUpper()) 10.5 $C.Accent -Bold
      $chip.Margin = '0,20,0,6'
      $stack.Children.Add($chip) | Out-Null
      $stack.Children.Add((Text $q.question 13)) | Out-Null
      $chosen = @($script:picks["$($r.id)|$($q.question)"])
      foreach ($o in @($q.options)) {
        $content = New-Object Windows.Controls.StackPanel
        $content.Children.Add((Text $o.label 12.5 -Bold)) | Out-Null
        if ($o.description) { $d = Text $o.description 11.5 $C.Dim; $d.Margin = '0,3,0,0'; $content.Children.Add($d) | Out-Null }
        $on = $chosen -contains $o.label
        $tag = @{ act = 'pick'; sid = $s.id; rid = $r.id; q = $q.question; label = $o.label; multi = [bool]$q.multiSelect; single = ($questions.Count -eq 1 -and -not $q.multiSelect) }
        $b = Btn $content $tag $(if ($on) { $C.Accent } else { $C.Surface }) $(if ($on) { $C.Ink } else { $C.Text }) -Wide
        $stack.Children.Add($b) | Out-Null
      }
    }
    if (-not ($questions.Count -eq 1 -and -not $questions[0].multiSelect)) {
      $stack.Children.Add((Btn 'Submit' @{ act = 'submit'; sid = $s.id; rid = $r.id } $C.Accent $C.Ink)) | Out-Null
    }
    if ($pending.Count -gt 1) { $more = Text "+$($pending.Count - 1) more waiting" 11.5 $C.Dim; $more.Margin = '0,12,0,0'; $stack.Children.Add($more) | Out-Null }
  } elseif ($s.inApp) {
    $wait = Text 'Waiting for you in the Claude app.' 12.5 $C.Dim
    $wait.Margin = '0,16,0,0'
    $stack.Children.Add($wait) | Out-Null
    $stack.Children.Add((Btn 'Open Claude' @{ act = 'open'; sid = $s.id } $C.Accent $C.Ink)) | Out-Null
  } elseif ($s.state -eq 'working') {
    $w = Text "Working$([char]0x2026)" 12 $C.Working; $w.Margin = '0,16,0,0'; $stack.Children.Add($w) | Out-Null
  } else {
    # A summary of the latest message: the turn's recap, else the start of the message.
    $said = if ($s.summary) { $s.summary } else { $s.last }
    if ($said) {
      $box = New-Object Windows.Controls.Border
      $box.Background = $C.Surface; $box.CornerRadius = 8; $box.Padding = '14,12,14,14'; $box.Margin = '0,16,0,0'
      $inner = New-Object Windows.Controls.StackPanel
      $label = Text 'LATEST' 10 $C.Dim -Bold; $label.Margin = '0,0,0,8'
      $scroll = New-Object Windows.Controls.ScrollViewer
      $scroll.MaxHeight = 210; $scroll.VerticalScrollBarVisibility = 'Auto'
      $scroll.Content = Text $said 12.5 $C.Text
      $inner.Children.Add($label) | Out-Null; $inner.Children.Add($scroll) | Out-Null
      $box.Child = $inner
      $stack.Children.Add($box) | Out-Null
    }
    if ($s.ask) { AskBlock $stack $s }
  }

  # What the sessions this one started are waiting on, answered from here too.
  $asks = @(Descendants $s | Where-Object { (Waits $_) -and $_.ask })
  foreach ($d in $asks) {
    $rule = New-Object Windows.Controls.Border -Property @{ Height = 1; Background = $C.Line; Margin = '0,22,0,0' }
    $stack.Children.Add($rule) | Out-Null
    $from = Text $(if ($d.title) { $d.title } else { $d.name }) 11.5 $C.Needs -Bold
    $from.Margin = '0,14,0,0'; $from.TextWrapping = 'NoWrap'; $from.TextTrimming = 'CharacterEllipsis'
    $stack.Children.Add($from) | Out-Null
    AskBlock $stack $d -Open
  }

  $send = $script:sends[$s.id]
  $shownAbove = $s.ask -and $s.state -ne 'working' -and $send -and -not $send.failed -and $send.doneAt -eq $s.doneAt
  if ($send -and -not $shownAbove) { $status = Text $send.status 11.5 $(if ($send.failed) { $C.Accent } else { $C.Dim }); $status.Margin = '0,14,0,0'; $stack.Children.Add($status) | Out-Null }

  # The body fades in when what it says changes while the card is up; a fresh card arrives whole.
  $key = "$($s.id)|$($pending.Count)|$($s.inApp)|$($s.state)|$($s.doneAt)|$($s.ask)|$($send.status)|$(($asks | ForEach-Object { "$($_.id)=$($script:sends[$_.id].status)" }) -join ',')"
  if ($script:cardShown -and $key -ne $script:cardKey) { Tween $stack Opacity 1 200 0 }
  $script:cardKey = $key
  $outer.Children.Add($stack) | Out-Null
  if ($inputRow.Parent) { $inputRow.Parent.Children.Remove($inputRow) }
  $outer.Children.Add($inputRow) | Out-Null
  $outer
}

function Draw {
  $tipDelay.Stop(); $tip.IsOpen = $false
  $needs = @($script:sessions | Where-Object { NeedsYou $_ })
  $unseen = @($script:sessions | Where-Object { Unseen $_ })
  $badgeText.Text = "$($needs.Count)"
  $badge.Visibility = if ($needs.Count) { 'Visible' } else { 'Collapsed' }
  # The count pops when it changes; a badge arriving grows in.
  if ($script:drawn -and $needs.Count -and $needs.Count -ne $script:badgeN) { if ($script:badgeN) { Scale $badgeMove 1.3 110 -Bounce } else { Scale $badgeMove 1 160 0.4 } }
  $script:badgeN = $needs.Count
  $strip = Expanded
  $ringOn = -not $strip -and ($needs.Count -or $unseen.Count)
  Recolor $ring.Stroke $(if ($needs.Count) { $C.Needs } else { $C.Unseen }) $(if ($ring.Visibility -eq 'Visible') { 220 } else { 0 })
  if ($ringOn -and $script:drawn -and $ring.Visibility -ne 'Visible') { Tween $ring Opacity 1 200 0 }
  $ring.Visibility = if ($ringOn) { 'Visible' } else { 'Collapsed' }

  if ($strip) {
    $avatars.Visibility = 'Visible'
    $avatars.Children.Clear()
    $script:was = $script:seen; $script:seen = @{}
    foreach ($s in $script:sessions) { if ($s.depth -eq 0) { $avatars.Children.Add((Family $s)) | Out-Null } }
    foreach ($k in @($script:cued.Keys)) { if (-not $script:seen.ContainsKey($k)) { $script:cued.Remove($k) } }
    # Opening, the notch grows along the edge as the avatars arrive.
    if ($script:mode -ne 'strip') {
      Unpin; $avatars.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
      Tween $avatars (Along 'Height' 'Width') (Along $avatars.DesiredSize.Height $avatars.DesiredSize.Width) 200 0 -done { Unpin }
      Tween $avatars Opacity 1 200 0; Tween $avatarsMove.Slide (Along 'Y' 'X') 0 200 (-12)
    }
  } elseif ($script:mode -eq 'strip') {
    # Folding, the avatars fade as the notch shrinks back around the orb.
    Tween $avatars (Along 'Height' 'Width') 0 160 (Along $avatars.ActualHeight $avatars.ActualWidth) -mode EaseIn -done { if (-not (Expanded)) { Fold } }
    Tween $avatars Opacity 0 120 -mode EaseIn
    Tween $avatarsMove.Slide (Along 'Y' 'X') (-8) 120 -mode EaseIn
  } else { Fold }
  $script:mode = if ($strip) { 'strip' } else { 'icon' }

  $s = $script:sessions | Where-Object { $_.id -eq $script:open } | Select-Object -First 1
  if ($strip -and $s) {
    $card.Child = Card $s
    if ($script:cardShown -ne $s.id) { $card.Visibility = 'Visible'; if (-not $script:cardShown) { Enter $card $cardMove }; $script:cardShown = $s.id }
  } else {
    if (-not $s) { $script:open = $null }
    # The card lifts away before the window shrinks around it.
    if ($script:cardShown) { $script:cardShown = $null; Leave $card $cardMove { if (-not $script:cardShown) { $card.Visibility = 'Collapsed'; $card.Child = $null } } }
  }
  $script:openWas = $script:open; $script:drawn = $true
}
function Fold { $avatars.Visibility = 'Collapsed'; $avatars.Children.Clear(); Unpin }
# Hands the avatars' height back to their content once a grow or fold is done with it.
function Unpin { foreach ($p in $script:P.Height, $script:P.Width) { $avatars.BeginAnimation($p, $null); $avatars.ClearValue($p) } }

function Refresh {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $list = @(); $raw = ''
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Base 'sessions') -Filter *.json -ErrorAction SilentlyContinue) {
    try { $text = [IO.File]::ReadAllText($f.FullName); $s = $text | ConvertFrom-Json } catch { continue }
    $age = $now - [int64]$s.beat
    if ($age -gt 600000) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
    if ($age -gt 45000) { continue }
    $group = if ($s.group) { $s.group } else { 'local' }
    if (@($ui.groups) -notcontains $group -or ($s.parent -and -not $ui.children)) { continue }
    $list += $s; $raw += ($text -replace '"beat":\d+|"focusedAt":\d+', '')
  }

  # The app's list fills in sessions the mod does not run in.
  try {
    $app = [IO.File]::ReadAllText((Join-Path $Base 'app-sessions.json')) | ConvertFrom-Json
    if ($now - [int64]$app.at -lt 60000) {
      $mine = @{}; foreach ($s in $list) { if ($s.appId) { $mine[$s.appId] = 1 } }
      foreach ($s in @($app.sessions)) {
        if (-not $s -or $mine[$s.id] -or @($ui.groups) -notcontains $s.group -or ($s.parent -and -not $ui.children)) { continue }
        $s | Add-Member app $true
        $list += $s; $raw += "$($s.id)$($s.state)$($s.doneAt)$($s.title)$($s.parent)$($s.summary)$($s.waiting)$($s.ask)"
      }
    }
  } catch {}

  # Reports on messages sent through the outbox.
  foreach ($sid in @($script:sends.Keys)) {
    $send = $script:sends[$sid]
    $report = Join-Path (Join-Path $Base 'sent') $send.file
    if ($send.cli) {
      # A wake: sent once the woken session's mod empties its prompt file.
      $prompt = Join-Path (Join-Path $Base 'prompts') "$($send.cli).json"
      $r = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw | ConvertFrom-Json; Remove-Item -LiteralPath $report -Force }
      $left = try { [IO.File]::ReadAllText($prompt).Trim() } catch { '' }
      $fail = if ($r -and -not $r.ok) { "Not sent: $($r.note)" } elseif ($left -and $now - $send.at -gt 120000) { 'Not sent: the session did not wake.' }
      if ($fail) { Remove-Item -LiteralPath $prompt -Force -ErrorAction SilentlyContinue; $send.status = $fail; $send.failed = $true; $send.cli = $null }
      elseif (-not $left) { $send.status = 'Sent.'; $send.cli = $null }
    }
    elseif ($send.status -eq "Sending$([char]0x2026)" -and (Test-Path -LiteralPath $report)) {
      $r = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
      Remove-Item -LiteralPath $report -Force
      $send.status = if ($r.ok) { 'Sent.' } else { "Not sent: $($r.note)" }
      $send.failed = -not $r.ok
    }
  }

  # Forget answers the sessions have already dropped.
  $live = @{}; foreach ($s in $list) { foreach ($r in @($s.requests)) { if ($r) { $live[$r.id] = 1 } } }
  foreach ($k in @($script:answered.Keys)) { if (-not $live[$k]) { $script:answered.Remove($k) } }

  $rank = { param($s) if (NeedsYou $s) { 0 } elseif (Unseen $s) { 1 } elseif ($s.state -eq 'working') { 2 } else { 3 } }
  # Each child follows the session that started it, and a family ranks by its most urgent member.
  # A child whose parent is not shown stands alone.
  $shown = @{}; foreach ($s in $list) { $shown[(Key $s)] = 1 }
  $kids = @{}; $roots = @()
  foreach ($s in $list) { if ($s.parent -and $shown[$s.parent]) { $kids[$s.parent] += @($s) } else { $roots += $s } }
  foreach ($k in @($kids.Keys)) { $kids[$k] = @($kids[$k] | Sort-Object { & $rank $_ }, name, id) }
  $best = { param($s) $r = & $rank $s; foreach ($child in @($kids[(Key $s)])) { if ($child) { $r = [Math]::Min($r, (& $best $child)) } }; $r }
  $ordered = New-Object Collections.ArrayList
  # As in the app's sidebar, a session shows yellow when anything it started needs you.
  $emit = { param($s, $depth)
    $s | Add-Member depth $depth -Force; $s | Add-Member needsAny ((& $best $s) -eq 0) -Force; [void]$ordered.Add($s)
    foreach ($child in @($kids[(Key $s)])) { if ($child) { & $emit $child ($depth + 1) } }
  }
  foreach ($s in @($roots | Sort-Object { & $best $_ }, { & $rank $_ }, name, id)) { & $emit $s 0 }
  $script:sessions = @($ordered); $script:kids = $kids
  $marks = ($script:sessions | ForEach-Object { "$($_.id)=$(Unseen $_)" }) -join ','
  $sends = ($script:sends.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value.status)" }) -join ','
  $sig = "$raw|$marks|$sends|$($script:open)|$($ui.mode)|$($script:hover)|$(@($ui.groups) -join ',')|$($ui.children)|$($script:answered.Keys -join ',')|$(($script:picks.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value -join ';')" }) -join ',')"
  if ($sig -ne $script:sig) { $script:sig = $sig; Draw }
}

# ---- actions --------------------------------------------------------------

function Answer($sid, $rid, $reply) {
  Put 'replies' "$sid.$rid.json" $reply
  $script:answered[$rid] = 1
  $inputBox.Text = ''
}

function Act($tag) {
  try {
    $s = $script:sessions | Where-Object { $_.id -eq $script:open } | Select-Object -First 1
    switch ($tag.act) {
      'mode' {
        if ($tag.mode -eq 'quit') { $win.Close(); return }
        $ui.mode = $tag.mode; SaveUi
      }
      'group' {
        $on = @($ui.groups | Where-Object { $_ })
        $ui.groups = if ($on -contains $tag.group) { @($on | Where-Object { $_ -ne $tag.group }) } else { $on + $tag.group }
        SaveUi
      }
      'children' { $ui.children = -not $ui.children; SaveUi }
      'toggle' {
        $script:open = if ($script:open -eq $tag.sid) { $null } else { $tag.sid }
        $inputBox.Text = ''
      }
      'show' { $script:open = $tag.sid }
      # Clears the blue here and asks a session running the mod to clear the app's dot too.
      'read' {
        $t = $script:sessions | Where-Object { $_.id -eq $tag.sid } | Select-Object -First 1
        if (-not $t) { return }
        $script:read[(Key $t)] = [int64]$t.doneAt
        [IO.File]::WriteAllText($readPath, ($script:read | ConvertTo-Json -Compress))
        Put 'outbox' "$([guid]::NewGuid()).json" @{ read = (Key $t) }
        $script:open = $null; $tipDelay.Stop(); $tip.IsOpen = $false
      }
      # Opens the session's chat in the app; without a link, just brings the app forward.
      'open' {
        $t = $script:sessions | Where-Object { $_.id -eq $tag.sid } | Select-Object -First 1
        $link = if ($t.link) { $t.link } elseif ($t.appId) { "claude://claude.ai/epitaxy/$($t.appId)" }
        if ($link) { Start-Process $link }
        else {
          $p = Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle } | Select-Object -First 1
          if ($p) { [Win]::Front($p.MainWindowHandle) }
        }
      }
      'pick' {
        $key = "$($tag.rid)|$($tag.q)"
        if ($tag.single) { Answer $tag.sid $tag.rid @{ kind = 'answer'; answers = @{ $tag.q = $tag.label } }; break }
        $now = @($script:picks[$key] | Where-Object { $_ })
        $script:picks[$key] = if (-not $tag.multi) { @($tag.label) } elseif ($now -contains $tag.label) { @($now | Where-Object { $_ -ne $tag.label }) } else { $now + $tag.label }
      }
      'submit' { Submit $s }
      'mic' { $win.Activate(); $inputBox.Focus() | Out-Null; [Win]::Dictate() }
      # A reply button sends its own text, to its own session; otherwise the field's.
      'send' {
        if ($tag.to) { $s = $script:sessions | Where-Object { $_.id -eq $tag.to } | Select-Object -First 1 }
        $text = if ($tag.text) { $tag.text } else { $inputBox.Text.Trim() }
        if (-not $s -or -not $text) { return }
        if (-not $tag.text) { $inputBox.Text = '' }
        $r = @(Pending $s)[0]
        # A stopped local session is woken, and the mod there sends your text as your own.
        if ($s.app -and $s.group -eq 'local' -and $s.cli) {
          Put 'prompts' "$($s.cli).json" @{ text = $text }
          $file = "$([guid]::NewGuid()).json"
          Put 'outbox' $file @{ to = $s.id; wake = $true }
          $script:sends[$s.id] = @{ file = $file; status = "Waking the session$([char]0x2026)"; failed = $false; doneAt = $s.doneAt; cli = $s.cli; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        }
        elseif ($s.app) {
          $file = "$([guid]::NewGuid()).json"
          Put 'outbox' $file @{ to = $s.id; text = $text }
          $script:sends[$s.id] = @{ file = $file; status = "Sending$([char]0x2026)"; failed = $false; doneAt = $s.doneAt }
        }
        elseif (-not $r) { Put 'prompts' "$($s.id).json" @{ text = $text } }
        else { Submit $s $text }
      }
    }
    Refresh
  } catch { Log "act $($tag.act): $_" }
}

# Sends a question's answers: each question's picks, typed text filling the first unanswered one.
function Submit($s, $typed = $inputBox.Text.Trim()) {
  $r = @(Pending $s)[0]
  if (-not $r) { return }
  $answers = @{}
  foreach ($q in @($r.questions)) {
    $chosen = @($script:picks["$($r.id)|$($q.question)"] | Where-Object { $_ })
    if ($chosen.Count) { $answers[$q.question] = $chosen -join ', ' }
    elseif ($typed) { $answers[$q.question] = $typed; $typed = '' }
  }
  if ($answers.Count) { Answer $s.id $r.id @{ kind = 'answer'; answers = $answers } }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({ try { Refresh } catch { Log "refresh: $_" } })
$timer.Start()

# Out of the way while the Claude app itself is focused. The window stays shown:
# Show() on a layered window costs a frame or more, so it is faded, scaled and
# made click-through instead. Starts invisible until the focus hook decides.
$scale = New-Object Windows.Media.ScaleTransform 0.96, 0.96
$root.RenderTransform = $scale; $root.Opacity = 0
$script:shown = $null
function Place($shown) {
  if ($shown -eq $script:shown) { return }
  $script:shown = $shown
  [Win]::ClickThrough($hwnd, -not $shown); $root.IsHitTestVisible = $shown
  $to = if ($shown) { @(1, 1) } else { @(0, 0.96) }
  $props = @(@($root, [Windows.UIElement]::OpacityProperty, $to[0]),
    @($scale, [Windows.Media.ScaleTransform]::ScaleXProperty, $to[1]), @($scale, [Windows.Media.ScaleTransform]::ScaleYProperty, $to[1]))
  if (-not [Windows.SystemParameters]::ClientAreaAnimation) {
    foreach ($p in $props) { $p[0].BeginAnimation($p[1], $null); $p[0].SetValue($p[1], [double]$p[2]) }
    return
  }
  # To only: each tween starts from wherever the last left off, so a flip mid-way reverses in place.
  $ease = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = if ($shown) { 'EaseOut' } else { 'EaseIn' } }
  $ms = if ($shown) { 200 } else { 120 }
  foreach ($p in $props) {
    $p[0].BeginAnimation($p[1], (New-Object Windows.Media.Animation.DoubleAnimation -Property @{
      To = [double]$p[2]; Duration = [Windows.Duration][TimeSpan]::FromMilliseconds($ms); EasingFunction = $ease }))
  }
}
function ShowWidget { Place $true }
function HideWidget { $menuPop.IsOpen = $false; $tipDelay.Stop(); $tip.IsOpen = $false; Place $false }

Refresh
# Show and a plain message loop, not ShowDialog: hiding a dialog would end it.
$win.Add_Closed({ [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$win.Show()
$hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
[FocusWatch]::add_Changed([Action[bool]] { param($appFocused) try { if ($appFocused) { HideWidget } else { ShowWidget } } catch { Log "focus: $_" } })
[FocusWatch]::Start()
Place (-not [FocusWatch]::AppFocused)
[Windows.Threading.Dispatcher]::Run()
$mutex.ReleaseMutex()
