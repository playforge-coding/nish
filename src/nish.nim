## nish: a terminal shell whose language is NimScript.

import std/[monotimes, os, posix, strutils, times]
import nish/[commands, editor, host, input, jobs, session]

const usage = """
Usage:
  nish                 start an interactive shell
  nish <script>        run a script
  nish -c <code>       run code
Options:
  --no-init            don't run ~/.config/nish/init.nims
  --timing             print how long the VM took to start"""

proc initFile(): string =
  getConfigDir() / "nish" / "init.nims"

proc historyFile(): string =
  getDataDir() / "nish" / "history"

proc isCommand(s: Session): proc(line: string): bool =
  let r = s.resolver
  result = proc(line: string): bool =
    isCommandLine(line, r)

proc currentDir(fallback: string): string =
  try:
    getCurrentDir()
  except OSError:
    fallback

proc newEditor(s: Session): Editor =
  result = newEditor(historyFile())
  let isCommand = s.isCommand
  result.needsMore = proc(text: string): bool =
    needsMoreInput(text, isCommand)
  result.complete = proc(line: string): seq[string] =
    s.complete(line)
  result.userKey = proc(key: string): bool =
    s.hookBool("nishKeyPressed", strNode(key))

proc stdinReader(): LineReader =
  ## Lines from a pipe or file on standard input, with no editing.
  result = proc(continuation: bool, line: var string): bool =
    stdin.readLine(line)

proc interact(s: Session) =
  let interactive = isatty(0) != 0
  let editor = if interactive: s.newEditor else: nil
  let reader = stdinReader()
  var chunk = ""
  var dir = currentDir("")
  while true:
    notify()
    let now = currentDir(dir)
    if now != dir:
      dir = now
      s.runHook("nishDirChanged", strNode(now))
    if interactive:
      let prompt = s.hookString("nishPrompt", "nish> ")
      let continuation = s.hookString("nishContinuationPrompt", "  ... ")
      if not editor.readInput(prompt, continuation, chunk):
        break
      editor.addHistory(chunk)
    elif not readChunk(reader, s.isCommand, chunk):
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
