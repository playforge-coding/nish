## nish: a terminal shell whose language is NimScript.

import std/[linenoise, monotimes, os, posix, strutils, times]
import nish/[commands, input, session]

const usage = """
Usage:
  nish                 start an interactive shell
  nish <script>        run a script
  nish -c <code>       run code
Options:
  --timing             print how long the VM took to start"""

proc promptReader(): LineReader =
  result = proc(continuation: bool, line: var string): bool =
    while true:
      errno = 0 # linenoise only sets it for Ctrl-C, not for Ctrl-D
      let buf = linenoise.readLine(
        if continuation:
          cstring"  ... "
        else:
          cstring"nish> "
      )
      if buf != nil:
        line = $buf
        if line.len > 0:
          historyAdd(buf)
        linenoise.free(buf)
        return true
      if errno != EAGAIN: # EAGAIN means Ctrl-C, which only clears the line
        return false

proc isCommand(s: Session): proc(line: string): bool =
  let r = s.resolver
  result = proc(line: string): bool =
    isCommandLine(line, r)

proc interact(s: Session) =
  var chunk = ""
  while readChunk(promptReader(), s.isCommand, chunk):
    discard s.eval(chunk)

proc runScript(s: Session, lines: seq[string]): bool =
  ## Evaluates a script one top-level statement at a time, so commands see
  ## the symbols defined above them. Stops at the first error.
  for chunk in splitChunks(lines, s.isCommand):
    if not s.eval(chunk.code, chunk.line):
      return false
  true

proc main() =
  var timing = false
  var script, code = ""
  var interactive = true
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--timing":
      timing = true
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
    # A handler, unlike ignoring the signal, resets to the default in child
    # processes, so Ctrl-C stops the running program but not the shell.
    signal(
      SIGINT,
      proc(sig: cint) {.noconv.} =
        discard,
    )
    s.interact()
  else:
    var lines =
      if code.len > 0:
        code.splitLines
      else:
        readFile(script).splitLines
    if lines.len > 0 and lines[0].startsWith("#!"):
      lines[0] = ""
    if not s.runScript(lines):
      quit(QuitFailure)

main()
