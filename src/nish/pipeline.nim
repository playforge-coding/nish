## Runs parsed command lines: expands their words and starts the processes.
##
## Processes are started with `fork` and `execvp` through `std/posix`, with
## pipes between the commands of a pipeline and the shell's own terminal for
## everything else.

import std/[os, posix, strutils, tables]
import ./[commands, jobs]

type ShellError* = object of CatchableError

var aliases* = initTable[string, string]() ## name to the command line it stands for

proc fail(msg: string) =
  raise newException(ShellError, msg)

# Aliases

proc aliasName(cmd: Command): string =
  ## The alias a command starts with, or "".
  if cmd.words.len > 0 and cmd.words[0].len == 1 and cmd.words[0][0].quote == qNone and
      aliases.hasKey(cmd.words[0][0].text):
    cmd.words[0][0].text
  else:
    ""

proc resolveAliases(cmd: Command): Command =
  ## Replaces a first word that names an alias with the alias's words, again
  ## if the result starts with another alias. `alias "ls", "ls -G"` stops
  ## after one round.
  result = cmd
  var rounds = 0
  while rounds < 10:
    let name = result.aliasName
    if name.len == 0:
      return
    let steps =
      try:
        parseCommandLine(aliases[name])
      except ValueError as e:
        fail "alias " & name & ": " & e.msg
        @[]
    if steps.len != 1 or steps[0].pipeline.len != 1:
      fail "alias " & name & " must be a single command"
    let target = steps[0].pipeline[0]
    result.words = target.words & result.words[1 .. ^1]
    result.redirects = target.redirects & result.redirects
    inc rounds
    if result.aliasName == name:
      return

# Expansion

proc expandVars(text: string): string =
  ## `$NAME` and `${NAME}`; an unset variable expands to nothing.
  result = ""
  var i = 0
  while i < text.len:
    if text[i] == '$' and i + 1 < text.len and
        (text[i + 1] in IdentStartChars or text[i + 1] == '{'):
      inc i
      var name: string
      if text[i] == '{':
        let close = text.find('}', i)
        if close < 0:
          fail "missing '}' in " & text
        name = text[i + 1 ..< close]
        i = close + 1
      else:
        var stop = i
        while stop < text.len and text[stop] in IdentChars:
          inc stop
        name = text[i ..< stop]
        i = stop
      result.add getEnv(name)
    else:
      result.add text[i]
      inc i

proc takeSplice(splices: seq[seq[string]], next: var int): seq[string] =
  if next >= splices.len:
    fail "more @(...) splices than values"
  result = splices[next]
  inc next

proc expandWord*(w: Word, splices: seq[seq[string]], next: var int): seq[string] =
  ## One word can become several arguments through a glob or a spliced
  ## sequence, or none through an empty sequence.
  if w.len == 1 and w[0].quote == qNone and w[0].text == $splice:
    return takeSplice(splices, next)
  var text = ""
  var globbing = false
  for seg in w:
    var t =
      if seg.quote == qSingle:
        seg.text
      else:
        expandVars(seg.text)
    while true:
      let k = t.find(splice)
      if k < 0:
        break
      let value = takeSplice(splices, next)
      if value.len != 1:
        fail "a value spliced into the middle of a word must be one string"
      t = t[0 ..< k] & value[0] & t[k + 1 .. ^1]
    if seg.quote == qNone and t.contains({'*', '?', '['}):
      globbing = true
    text.add t
  if w[0].quote == qNone and w[0].text.len > 0 and w[0].text[0] == '~' and
      (w[0].text.len == 1 or w[0].text[1] == '/'):
    text = getHomeDir().strip(leading = false, chars = {'/'}) & text[1 .. ^1]
  if globbing:
    var matches: seq[string] = @[]
    for path in walkPattern(text):
      matches.add path
    if matches.len > 0:
      return matches
  @[text]

proc expandOne(w: Word, splices: seq[seq[string]], next: var int): string =
  let ws = expandWord(w, splices, next)
  if ws.len != 1:
    fail "expected one word, got " & $ws.len
  ws[0]

# Processes

type Expanded = object
  argv: seq[string]
  redirects: seq[tuple[fd: cint, kind: RedirectKind, target: string]]

proc writeStderr(msg: string) =
  discard posix.write(2, msg.cstring, msg.len)

proc childRedirect(fd: cint, kind: RedirectKind, target: string) =
  if kind == rdDup:
    discard dup2(cint parseInt(target), fd)
    return
  let flags: cint =
    case kind
    of rdRead:
      O_RDONLY
    of rdWrite:
      O_WRONLY or O_CREAT or O_TRUNC
    of rdAppend:
      O_WRONLY or O_CREAT or O_APPEND
    of rdDup:
      0
  let f = posix.open(target.cstring, flags, 0o644)
  if f < 0:
    writeStderr "nish: " & target & ": " & $strerror(errno) & "\n"
    exitnow(1)
  discard dup2(f, fd)
  discard close(f)

proc spawn(
    cmd: Expanded,
    stdinFd, stdoutFd: cint,
    closeFds: seq[cint],
    pgid: var Pid,
    foreground: bool,
): Pid =
  ## `pgid` is the job's process group, 0 until its first process exists.
  result = fork()
  if result < 0:
    fail "fork failed: " & $strerror(errno)
  if result > 0:
    parentJobSetup(result, pgid, foreground)
    return
  # The child. Only async-signal-safe calls from here to `execvp`.
  childJobSetup(pgid, foreground)
  if stdinFd >= 0:
    discard dup2(stdinFd, 0)
  if stdoutFd >= 0:
    discard dup2(stdoutFd, 1)
  for fd in closeFds:
    discard close(fd)
  for r in cmd.redirects:
    childRedirect(r.fd, r.kind, r.target)
  discard execvp(cmd.argv[0].cstring, allocCStringArray(cmd.argv))
  let notFound = errno == ENOENT
  writeStderr "nish: " & cmd.argv[0] & ": " &
    (if notFound: "command not found" else: $strerror(errno)) & "\n"
  exitnow(if notFound: 127 else: 126)

proc readAll(fd: cint): string =
  result = ""
  var buf: array[4096, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n > 0:
      result.add buf.toOpenArray(0, n - 1).join("")
    elif n == 0 or errno != EINTR:
      break
  discard close(fd)

proc runPipeline(
    pipeline: Pipeline,
    splices: seq[seq[string]],
    next: var int,
    capture, background: bool,
    output: var string,
): int =
  ## Starts every command as one job, then waits for it unless it runs in
  ## the background. The status is the last command's.
  var cmds: seq[Expanded] = @[]
  for original in pipeline:
    let cmd = resolveAliases(original)
    var e = Expanded()
    for w in cmd.words:
      e.argv.add expandWord(w, splices, next)
    for r in cmd.redirects:
      e.redirects.add (cint r.fd, r.kind, expandOne(r.target, splices, next))
    if e.argv.len == 0:
      fail "missing command"
    cmds.add e
  var pids: seq[Pid] = @[]
  var pgid: Pid = 0
  var prevRead: cint = -1
  var captureRead: cint = -1
  for i, cmd in cmds:
    let last = i == cmds.high
    var fds: array[0 .. 1, cint] = [cint -1, -1]
    if not last or (capture and not background):
      if pipe(fds) != 0:
        fail "pipe failed: " & $strerror(errno)
    var closeInChild: seq[cint] = @[]
    if prevRead >= 0:
      closeInChild.add prevRead
    if fds[0] >= 0:
      closeInChild.add fds[0]
      closeInChild.add fds[1]
    pids.add spawn(cmd, prevRead, fds[1], closeInChild, pgid, not background)
    if prevRead >= 0:
      discard close(prevRead)
    if fds[1] >= 0:
      discard close(fds[1])
    if last:
      captureRead = fds[0]
    else:
      prevRead = fds[0]
  var texts: seq[string] = @[]
  for cmd in cmds:
    texts.add cmd.argv.join(" ")
  let job = addJob(pgid, pids, texts.join(" | "))
  if background:
    startBackground(job)
    return 0
  if captureRead >= 0:
    output.add readAll(captureRead)
  waitForeground(job)

proc execute*(
    line: string, splices: seq[seq[string]], capture: bool
): tuple[status: int, output: string] =
  ## Runs a command line. With `capture`, standard output of every pipeline
  ## is collected into `output` instead of going to the terminal.
  let steps =
    try:
      parseCommandLine(line)
    except ValueError as e:
      fail e.msg
      @[]
  result = (status: 0, output: "")
  var next = 0
  for step in steps:
    let skip =
      case step.chain
      of chAlways:
        false
      of chAnd:
        result.status != 0
      of chOr:
        result.status == 0
    if skip:
      next += countSplices(step.pipeline)
    else:
      result.status = runPipeline(
        step.pipeline, splices, next, capture, step.background, result.output
      )

proc expandLine*(line: string, splices: seq[seq[string]]): seq[string] =
  ## The words of a single command after expansion, without running it.
  let steps =
    try:
      parseCommandLine(line)
    except ValueError as e:
      fail e.msg
      @[]
  if steps.len != 1 or steps[0].pipeline.len != 1 or
      steps[0].pipeline[0].redirects.len > 0:
    fail "expected a single command without pipes or redirects: " & line
  result = @[]
  var next = 0
  for w in resolveAliases(steps[0].pipeline[0]).words:
    result.add expandWord(w, splices, next)
