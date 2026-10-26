# Claude session widget

A Claude Code mod for the Claude desktop app on Windows. It docks a small notch
to the edge of your screen that shows your Claude sessions, so you can see
which ones need you and answer them without switching to the app.

- **Closed**, the notch shows the Claude orb, with a count of sessions waiting
  on you and a ring: yellow when one needs you, blue when one has finished and
  you haven't looked yet.
- **Hover** it to open the strip of sessions: yellow rings need you, blue ones
  have finished, grey ones are working. A session's child sessions sit in a
  tray with it. The newest change comes first, and idle sessions sink to the
  bottom.
- Sessions you hide in the app's sidebar, in a folded project folder or under
  a folded parent session, are hidden in the widget too.
- **Hover a session that needs you** to open its card: the question it asked,
  with its answers as buttons, or its latest summary and a box to reply.
- **Drag** the notch along the right, left or top edge of the screen.
- **Right-click** for options: icon only or strip, which sessions to show
  (local, remote, cloud, child sessions), and Quit.
- The widget hides while the Claude app is in front. Type `/widget` in a
  session to open it again after quitting it.

## Install

You need Windows and the Claude desktop app. The widget runs on the Windows
PowerShell that comes with Windows.

In the desktop app: click **+** next to the prompt box, then **Plugins**,
**Add marketplace** with `KuroTheDesigner/claude-session-widget`, then
**Add plugin**.

Or, at the prompt of a Claude Code terminal session:

```
/plugin install session-widget --marketplace KuroTheDesigner/claude-session-widget
```

From a shell:

```
claude plugin install session-widget --marketplace KuroTheDesigner/claude-session-widget
```

Answer `y` to add the marketplace, then pick the user scope. The widget starts
with the next desktop session you open.

## What it reads and writes

Everything stays on your computer. The mod writes its state to
`%USERPROFILE%\.claude\session-widget`, and reads the desktop app's own session
list and transcripts to show sessions it is not running in. To show and message
those sessions, it uses the app's session tools only where you have already
allowed them; it never asks for permission from the background.
