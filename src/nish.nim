## nish: a terminal shell whose language is NimScript.

import std/[linenoise, monotimes, os, posix, strutils, times]
import nish/[commands, host, input, jobs, session]

const usage = """
Usage:
  nish                 start an interactive shell
  nish <script>        run a script
  nish -c <code>       run code
Options:
  --no-init            don't run ~/.config/nish/init.nims
  --timing             print how long the VM took to start"""

var current: Session ## for linenoise's completion callback, which can't be a closure

proc initFile(): string =
  getConfigDir() / "nish" / "init.nims"

proc historyFile(): string =
  getDataDir() / "nish" / "history"

proc completeLine(buf: cstring, completions: ptr Completions) {.cdecl.} =
  # Called from C: an exception escaping here would crash the shell.
  try:
    for candidate in current.complete($buf):
      addCompletion(completions, candidate.cstring)
  except CatchableError as e:
    stderr.writeLine "\nnish: completion failed: ", e.msg

proc promptReader(s: Session): LineReader =
  result = proc(continuation: bool, line: var string): bool =
    let prompt =
      if continuation:
        s.hookString("nishContinuationPrompt", "  ... ")
      else:
        s.hookString("nishPrompt", "nish> ")
    while true:
      errno = 0 # linenoise only sets it for Ctrl-C, not for Ctrl-D
      let buf = linenoise.readLine(prompt.cstring)
      if buf != nil:
        line = $buf
        if line.len > 0:
          historyAdd(buf)
          discard historySave(historyFile().cstring)
        linenoise.free(buf)
        return true
      if errno != EAGAIN: # EAGAIN means Ctrl-C, which only clears the line
        return false

proc isCommand(s: Session): proc(line: string): bool =
  let r = s.resolver
  result = proc(line: string): bool =
    isCommandLine(line, r)

proc currentDir(fallback: string): string =
  try:
    getCurrentDir()
  except OSError:
    fallback

proc interact(s: Session) =
  current = s
  setCompletionCallback(completeLine)
  discard historySetMaxLen(10000)
  createDir(historyFile().parentDir)
  discard historyLoad(historyFile().cstring)
  let read = s.promptReader
  var chunk = ""
  var dir = currentDir("")
  while true:
    notify()
    let now = currentDir(dir)
    if now != dir:
      dir = now
      s.runHook("nishDirChanged", strNode(now))
    if not readChunk(read, s.isCommand, chunk):
      break
    s.runHook("nishPreCommand", strNode(chunk))
    discard s.eval(chunk)
    s.runHook("nishCommandDone", strNode(chunk), intNode(lastStatus))

proc runScript(s: Session, lines: seq[string], stopOnError: bool): bool =
  ## Evaluates a script one top-level statement at a time, so commands see
  ## the symbols defined above them.
  result = true
  for chunk in splitChunks(lines, s.isCommand):
    if not s.eval(chunk.code, chunk.line):
      result = false
      if stopOnError:
        return

proc main() =
  var timing = false
  var noInit = false
  var script, code = ""
  var interactive = true
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--timing":
      timing = true
    of "--no-init":
      noInit = true
    of "-h", "--help":
      quit(usage, QuitSuccess)
    of "-c":
      if i + 1 >= args.len:
        quit(usage, QuitFailure)
      inc i
      code = args[i]
      interactive = false
    else:
      script = args[i]
      interactive = false
    inc i

  let started = getMonoTime()
  let s = newSession()
  if timing:
    stderr.writeLine "nish: VM ready in ",
      (getMonoTime() - started).inMilliseconds, " ms"

  if interactive:
    enableJobControl()
    if not noInit and fileExists(initFile()):
      discard s.runScript(readFile(initFile()).splitLines, stopOnError = false)
    s.interact()
  else:
    var lines =
      if code.len > 0:
        code.splitLines
      else:
        readFile(script).splitLines
    if lines.len > 0 and lines[0].startsWith("#!"):
      lines[0] = ""
    if not s.runScript(lines, stopOnError = true):
      quit(QuitFailure)

main()
