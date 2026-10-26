import type { EngineInterface, Register } from 'claude-code'

// Each session writes its state to <base>\sessions\<id>.json. The widget
// (widget\widget.ps1) reads those, and writes answers to
// <base>\replies\<id>.<request>.json and new prompts to <base>\prompts\<id>.json.
//
// Sessions the mod does not run in (cloud, remote, or local ones started
// before it loaded) come from the app's session list: one session writes
// <base>\app-sessions.json, and sends what the widget leaves in <base>\outbox
// with the app's send_message, reporting each in <base>\sent.

type Question = {
  question: string
  header: string
  multiSelect: boolean
  options: { label: string; description?: string }[]
}

type Request = {
  id: string
  questions: Question[]
}

type Group = 'local' | 'remote' | 'cloud'

// How the last turn ended: its recap (or the start of its last message), and
// any question it left you, with its reply buttons. `waiting` is the app's
// yellow: the turn stopped until you answer.
type TurnEnd = {
  summary: string
  ask: string
  waiting: boolean
  actions: { label: string; message: string }[]
}
const NO_END: TurnEnd = { summary: '', ask: '', waiting: false, actions: [] }

type Info = TurnEnd & {
  id: string
  // The app's id for this session, so the widget can drop its app-list row.
  appId: string
  // The mod writes to this computer's disk, so every session it reports runs here.
  group: 'local'
  name: string
  title: string
  state: 'working' | 'idle'
  requests: Request[]
  inApp: boolean
  last: string
  // When the last turn ended, and when the app last showed this session.
  doneAt: number
  focusedAt: number
  // The app id of the session that started this one, or '' for a top-level session.
  parent: string
}

type AppRow = TurnEnd & {
  id: string
  group: Group
  name: string
  title: string
  state: 'working' | 'idle'
  doneAt: number
  focusedAt: number
  parent: string
  // Opens the session in the app.
  link: string
  // A local session's own id, which names its prompt file once the mod runs in it.
  cli: string
}

type WrapUp = { recap?: unknown; ask?: unknown; blocked?: unknown; actions?: unknown }

type ListedSession = {
  sessionId: string
  title?: string
  cwd?: string
  isRunning?: boolean
  lastActivityAt?: string
  startedBy?: string
  link?: string
}

type Reply = {
  kind: 'answer' | 'defer' | 'timeout'
  answers?: Record<string, string>
}

const POWERSHELL = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass']

// App sessions idle longer than this are left off the widget.
const RECENT_MS = 24 * 60 * 60 * 1000

let base = ''
let appSessions = ''
let presetsFile = ''
let projects = ''
let info: Info | undefined
const envOf = new Map<string, string | undefined>()
// Turn endings already read, kept until the session finishes another turn.
const endings = new Map<string, { doneAt: number; end: TurnEnd }>()

function quote(s: string) {
  return `'${s.replaceAll("'", "''")}'`
}

function folderName(path: string) {
  const cwd = path.replaceAll('/', '\\').replace(/\\+$/, '')
  // A worktree session is named after its repository, not the worktree.
  const repo = cwd.match(/([^\\]+)\\\.claude\\worktrees\\/)
  return repo?.[1] ?? cwd.slice(cwd.lastIndexOf('\\') + 1)
}

// The app's summary of a finished turn. `blocked` is what turns its sidebar dot yellow.
type PostTurn = { status_category?: string; status_detail?: string; needs_action?: string }

// The app's own record of a session: its title, environment, when it was last
// shown, the session that started it, where its transcript is, and its own
// summary of the last turn.
async function appRecord($: EngineInterface, appId: string) {
  try {
    const record = JSON.parse(await $.fs.read(`${appSessions}\\${appId}.json`)) as {
      title?: string
      envScopeId?: string
      lastFocusedAt?: number | string
      spawnedFrom?: { sessionId?: string }
      cwd?: string
      cliSessionId?: string
      postTurnSummary?: PostTurn | null
      postTurnSummaryFor?: string
      lastAssistantUuid?: string
      isArchived?: boolean
    }
    // A summary of an older turn says nothing about this one.
    const current = record.postTurnSummaryFor === record.lastAssistantUuid
    return {
      title: record.title ?? '',
      env: record.envScopeId,
      focusedAt: new Date(record.lastFocusedAt ?? 0).getTime() || 0,
      parent: record.spawnedFrom?.sessionId ?? '',
      transcript: record.cwd && record.cliSessionId
        ? `${projects}\\${record.cwd.replace(/[^A-Za-z0-9]/g, '-')}\\${record.cliSessionId}.jsonl`
        : '',
      post: current ? record.postTurnSummary ?? undefined : undefined,
      archived: record.isArchived === true,
      cli: record.cliSessionId ?? '',
    }
  } catch {
    return { title: '', env: undefined, focusedAt: 0, parent: '', transcript: '', post: undefined, archived: false, cli: '' }
  }
}

// The app's own summary of the last turn says whether it waits on you, and for
// what, in one short line (a parent's line covers its children's requests too).
// That line leads, as in the app; turns started by another session often end
// without a wrap-up and have nothing else.
function withPost(end: TurnEnd, post: PostTurn | undefined): TurnEnd {
  if (!post) return end
  const blocked = post.status_category === 'blocked'
  return {
    ...end,
    summary: end.summary || post.status_detail || '',
    ask: post.needs_action || (blocked && post.status_detail) || end.ask,
    waiting: end.waiting || blocked,
  }
}

// The first paragraph of a message, without markdown, cut to a few lines.
function gist(text: string) {
  const plain = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[*_`#>|]/g, '')
  const para = plain.split(/\n\s*\n/).map(p => p.trim()).find(Boolean) ?? ''
  return para.length > 320 ? `${para.slice(0, 319)}…` : para
}

// A wrap-up's reply buttons; app actions (commit, merge...) have no message to send.
function turnEnd(input: WrapUp): TurnEnd {
  const actions = (Array.isArray(input.actions) ? input.actions : []) as { label?: unknown; message?: unknown; action?: unknown }[]
  return {
    summary: String(input.recap ?? ''),
    ask: typeof input.ask === 'string' ? input.ask : '',
    waiting: input.blocked === true,
    actions: actions
      .filter(a => !a.action && typeof a.label === 'string')
      .map(a => ({ label: String(a.label), message: typeof a.message === 'string' && a.message ? a.message : String(a.label) })),
  }
}

// The last turn's wrap-up, or else the start of its last message. Transcripts
// outgrow $.fs.read's 4 MiB, so widget\turn-end.ps1 reads them.
async function transcriptEnd($: EngineInterface, path: string): Promise<TurnEnd | undefined> {
  const reader = `${$.plugin.root}\\widget\\turn-end.ps1`.replaceAll('/', '\\')
  const { stdout, exitCode } = await $.process.run([...POWERSHELL, '-File', reader, path], { timeoutMs: 60_000 })
  if (exitCode !== 0 || !stdout.trim()) return undefined
  const read = JSON.parse(stdout) as { wrapUp?: WrapUp; text?: string }
  return read.wrapUp ? turnEnd(read.wrapUp) : { ...NO_END, summary: gist(read.text ?? '') }
}

// Sessions with no transcript here: the start of their last message, from the app.
async function eventsEnd($: EngineInterface, id: string): Promise<TurnEnd> {
  const tool = 'mcp__ccd_session_mgmt__list_events'
  if (!(await allowed($, tool, { session_id: id, limit: 3 }))) return NO_END
  const said = (await $.tool.call({ tool, session_id: id, limit: 3 })).text ?? ''
  const at = said.lastIndexOf('[assistant] ')
  return { ...NO_END, summary: at < 0 ? '' : gist(said.slice(at + 12).split(/\n\[[a-z][^\]]*\]/)[0] ?? '') }
}

async function endOf($: EngineInterface, id: string, doneAt: number, transcript: string) {
  const known = endings.get(id)
  if (known?.doneAt === doneAt) return known.end
  const end = (transcript && (await transcriptEnd($, transcript))) || (await eventsEnd($, id))
  endings.set(id, { doneAt, end })
  return end
}

let archived = false

async function save($: EngineInterface) {
  if (!info || archived) return
  await $.fs.write(`${base}\\sessions\\${info.id}.json`, JSON.stringify({ ...info, beat: Date.now() }))
}

async function heartbeat($: EngineInterface) {
  if (!info) return
  if (info.appId) {
    const record = await appRecord($, info.appId)
    // Archived in the app: it leaves the widget, which drops sessions that stop reporting.
    archived = record.archived
    if (archived) return
    ;({ focusedAt: info.focusedAt, parent: info.parent } = record)
    // The app's title, once it has one, over the first prompt.
    if (record.title) info.title = record.title
    // A turn that ended without a wrap-up still has the app's own summary.
    if (info.state === 'idle') Object.assign(info, withPost(info, record.post))
  }
  await save($)
}

async function launch($: EngineInterface) {
  const widget = `${$.plugin.root}\\widget\\widget.ps1`.replaceAll('/', '\\')
  const dirs = ['sessions', 'replies', 'prompts', 'outbox', 'sent'].map(d => quote(`${base}\\${d}`)).join(',')
  // Start-Process detaches the widget, so it outlives this call and this session.
  await $.process.run([
    ...POWERSHELL,
    '-Command',
    `New-Item -ItemType Directory -Force ${dirs} | Out-Null; ` +
      `Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ` +
      `'-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',${quote(`"${widget}"`)},${quote(`"${base}"`)}`,
  ])
}

// Blocks until the widget answers, or answers `defer` as soon as the Claude
// app is in front, so its own card takes over.
async function waitReply($: EngineInterface, requestId: string): Promise<Reply> {
  const waiter = `${$.plugin.root}\\widget\\wait-reply.ps1`.replaceAll('/', '\\')
  const file = `${base}\\replies\\${info?.id}.${requestId}.json`
  for (;;) {
    try {
      const { stdout } = await $.process.run([...POWERSHELL, '-File', waiter, file], { timeoutMs: 600_000 })
      const reply = JSON.parse(stdout.trim()) as Reply
      if (reply.kind !== 'timeout') return reply
    } catch {
      return { kind: 'defer' }
    }
  }
}

async function ask($: EngineInterface, request: Request): Promise<Reply> {
  if (!info) return { kind: 'defer' }
  info.requests.push(request)
  info.inApp = false
  await save($)
  let reply: Reply = { kind: 'defer' }
  try {
    reply = await waitReply($, request.id)
  } finally {
    info.requests = info.requests.filter(r => r.id !== request.id)
    info.inApp = reply.kind === 'defer'
    await save($)
  }
  return reply
}

async function pollPrompt($: EngineInterface) {
  if (!info) return
  const file = `${base}\\prompts\\${info.id}.json`
  if (!(await $.fs.exists(file))) return
  const raw = (await $.fs.read(file)).trim()
  if (!raw) return
  await $.fs.write(file, '')
  const { text } = JSON.parse(raw) as { text?: string }
  if (text) await $.prompt.submit({ text, asUser: true })
}

// The app's session tools run without a dialog only where already allowed;
// this mod never raises one from the background.
async function allowed($: EngineInterface, tool: string, input: unknown) {
  return (await $.tool.check({ tool, input })).decision === 'allow'
}

async function groupOf($: EngineInterface, id: string, env: string | undefined): Promise<Group> {
  if (!id.startsWith('local_')) return 'cloud'
  if (!env || env === 'builtin_local') return 'local'
  try {
    const presets = JSON.parse(await $.fs.read(presetsFile)) as {
      byAccount?: Record<string, { presets?: { id: string; target?: { kind?: string } }[] }>
    }
    const kinds = Object.values(presets.byAccount ?? {}).flatMap(a => a.presets ?? [])
    const kind = kinds.find(p => p.id === env)?.target?.kind
    return !kind || kind === 'local' ? 'local' : 'remote'
  } catch {
    return 'local'
  }
}

async function pollApp($: EngineInterface) {
  if (!info) return
  const file = `${base}\\app-sessions.json`
  // Another session refreshed it moments ago.
  const fresh = (await $.fs.list(base)).find(f => f.name === 'app-sessions.json')
  if (fresh && Date.now() - fresh.mtimeMs < 6_000) return
  const tool = 'mcp__ccd_session_mgmt__list_sessions'
  if (!(await allowed($, tool, { limit: 40 }))) return
  const listed = await $.tool.call({ tool, limit: 40 })
  if (listed.deny !== undefined || !listed.text) return
  const now = Date.now()
  const rows: AppRow[] = []
  for (const s of JSON.parse(listed.text) as ListedSession[]) {
    const activity = Date.parse(s.lastActivityAt ?? '') || 0
    const record = s.sessionId.startsWith('local_')
      ? await appRecord($, s.sessionId)
      : { env: undefined, focusedAt: 0, parent: '', transcript: '', post: undefined, cli: '' }
    // One still waiting on you stays, however long ago it stopped.
    if (!s.isRunning && now - activity > RECENT_MS && record.post?.status_category !== 'blocked') continue
    if (!envOf.has(s.sessionId)) envOf.set(s.sessionId, record.env)
    rows.push({
      id: s.sessionId,
      group: await groupOf($, s.sessionId, envOf.get(s.sessionId)),
      name: s.cwd ? folderName(s.cwd) : (s.title ?? 'Session'),
      title: s.title ?? '',
      state: s.isRunning ? 'working' : 'idle',
      doneAt: s.isRunning ? 0 : activity,
      focusedAt: record.focusedAt,
      parent: s.startedBy ?? record.parent,
      ...(s.isRunning ? NO_END : withPost(await endOf($, s.sessionId, activity, record.transcript).catch(() => NO_END), record.post)),
      link: s.link ?? '',
      cli: record.cli,
    })
  }
  await $.fs.write(file, JSON.stringify({ at: now, sessions: rows }))
}

// Sends what the widget left in the outbox, claiming each file first so no
// two sessions send it.
async function pollOutbox($: EngineInterface) {
  if (!info) return
  const waiting = (await $.fs.list(`${base}\\outbox`)).filter(f => f.name.endsWith('.json'))
  for (const entry of waiting) {
    const from = `${base}\\outbox\\${entry.name}`
    const claimed = `${from}.${info.id}`
    const move = await $.process.run([...POWERSHELL, '-Command', `Move-Item -LiteralPath ${quote(from)} ${quote(claimed)} -ErrorAction Stop`])
    if (move.exitCode !== 0) continue
    const { to, text, read, wake } = JSON.parse(await $.fs.read(claimed)) as { to: string; text?: string; read?: string; wake?: boolean }
    // Marked read in the widget: clear the app's dot too. Nothing waits on the outcome.
    if (read) {
      const mark = 'mcp__ccd_sidebar__set_unread'
      if (await allowed($, mark, { session_id: read, unread: false })) await $.tool.call({ tool: mark, session_id: read, unread: false })
      await $.process.run([...POWERSHELL, '-Command', `Remove-Item -LiteralPath ${quote(claimed)} -Force`])
      continue
    }
    const tool = 'mcp__ccd_session_mgmt__send_message'
    // The app labels it as from this session; say whose words they are. A stopped
    // local session only needs waking: the mod, once running there, submits the
    // reply the widget left in its prompt file as the user's own.
    const message = wake
      ? "The user's session widget is waking this session. Their reply follows as their own message; nothing to do until then."
      : `The user typed this reply in their desktop session widget, which relays it through another session:\n\n${text}`
    let note = 'This session cannot send messages without asking first.'
    if (await allowed($, tool, { session_id: to, message })) {
      const sent = await $.tool.call({ tool, session_id: to, message })
      const said = sent.deny ?? sent.text ?? ''
      note = /delivery: (delivered|queued)/.test(said) ? '' : said.slice(0, 300) || 'Not delivered.'
    }
    await $.fs.write(`${base}\\sent\\${entry.name}`, JSON.stringify({ ok: !note, note }))
    await $.process.run([...POWERSHELL, '-Command', `Remove-Item -LiteralPath ${quote(claimed)} -Force`])
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // Desktop app sessions are SDK-hosted, so not interactive, but a person is there.
    if (!e.isInteractive && (await $.env.get('CLAUDE_CODE_ENTRYPOINT')) !== 'claude-desktop') return started
    base = `${await $.env.get('USERPROFILE')}\\.claude\\session-widget`
    const appData = `${await $.env.get('APPDATA')}\\Claude`
    appSessions = `${appData}\\claude-code-sessions\\${await $.env.get('CLAUDE_CODE_ACCOUNT_UUID')}\\${await $.env.get('CLAUDE_CODE_ORGANIZATION_UUID')}`
    presetsFile = `${appData}\\ccd-session-presets.json`
    projects = `${await $.env.get('USERPROFILE')}\\.claude\\projects`
    info = {
      id: await $.session.id(),
      appId: (await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')) ?? '',
      group: 'local',
      name: folderName(e.cwd),
      title: '',
      state: 'idle',
      requests: [],
      inApp: false,
      last: '',
      doneAt: 0,
      focusedAt: 0,
      parent: '',
      ...NO_END,
    }
    await launch($)
    await heartbeat($)
    $.clock.every(5_000, () => void heartbeat($).catch(() => {}))
    $.clock.every(1_500, () => void pollPrompt($).catch(() => {}))
    // Reading transcripts can outlast the interval; one poll at a time.
    let polling = false
    $.clock.every(8_000, () => {
      if (polling) return
      polling = true
      void pollApp($).catch(() => {}).finally(() => { polling = false })
    })
    $.clock.every(2_000, () => void pollOutbox($).catch(() => {}))
    await $.command.register({ name: 'widget', description: 'Opens the session widget again if you closed it.' })
    return started
  })

  on('command.run', { command: 'widget' }, async $ => {
    await launch($)
    return { text: 'Session widget opened.' }
  })

  on('session.end', async ($, e, next) => {
    if (info) {
      const file = `${base}\\sessions\\${info.id}.json`
      await $.process.run([...POWERSHELL, '-Command', `Remove-Item -Force ${quote(file)}`]).catch(() => {})
    }
    info = undefined
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (info && !e.agentId) {
      info.state = 'working'
      info.inApp = false
      Object.assign(info, NO_END)
      if (!info.title) info.title = e.text.replace(/\s+/g, ' ').slice(0, 120)
      await save($)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (info && !e.agentId) {
      info.state = 'idle'
      info.inApp = false
      info.last = done.text.slice(-1500)
      info.summary ||= gist(done.text)
      info.doneAt = Date.now()
      await save($)
    }
    return done
  })

  // Tool permission asks stay in the app, which answers most of them itself.

  // Questions: answered in place of the dialog, or handed back to the app.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const reply = await ask($, {
      id: e.tool_use_id,
      questions: e.questions.map(q => ({ question: q.question, header: q.header, multiSelect: q.multiSelect, options: q.options })),
    })
    if (reply.kind === 'answer') return { result: { questions: e.questions, answers: reply.answers ?? {} } }
    return next(e)
  }).catch(($, e, next) => next(e))

  // The turn's wrap-up is its summary on the widget, with any question it leaves.
  on('tool.call', { tool: 'mcp__ccd_turn__wrap_up' }, async ($, e, next) => {
    if (info) Object.assign(info, turnEnd(e))
    return next(e)
  })

  // A request handed back to the app is settled once its tool call ends.
  on('tool.call', async ($, e, next) => {
    const done = await next(e)
    if (info?.inApp) {
      info.inApp = false
      await save($)
    }
    return done
  })
}
