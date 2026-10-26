# Prints how a transcript's last turn ended, as JSON: the turn's wrap-up input
# as {"wrapUp":{...}}, or else its last message as {"text":"..."}. Reads back
# no further than the person's last prompt. The mod cannot read files this big.
param([string]$File)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$lines = [IO.File]::ReadAllLines($File)
$last = ''
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
  $line = $lines[$i]
  # Most lines are tool output and request copies; skip them unparsed.
  if (-not ($line.Contains('"type":"user"') -or $line.Contains('"type":"assistant"'))) { continue }
  try { $e = $line | ConvertFrom-Json } catch { continue }
  $content = $e.message.content
  if ($e.type -eq 'user') {
    if (-not $e.isMeta -and ($content -is [string] -or @($content | Where-Object { $_.type -eq 'text' }).Count)) { break }
    continue
  }
  if ($e.type -ne 'assistant') { continue }
  $blocks = @($content); [array]::Reverse($blocks)
  foreach ($b in $blocks) {
    if ($b.type -eq 'tool_use' -and $b.name -eq 'mcp__ccd_turn__wrap_up') { @{ wrapUp = $b.input } | ConvertTo-Json -Compress -Depth 6; exit }
    if ($b.type -eq 'text' -and -not $last -and "$($b.text)".Trim()) { $last = $b.text }
  }
}
@{ text = $last } | ConvertTo-Json -Compress
