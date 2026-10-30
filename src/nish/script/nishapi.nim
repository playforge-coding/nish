## The API nish gives every script, imported before the first input.
##
## Procs whose body is `discard "implemented by nish"` are placeholders: the
## VM calls the native implementation registered in `host.nim` instead.

var lastStatus* = 0 ## Exit status of the last command `run` or `sh` finished with.

proc toArgs*(s: string): seq[string] =
  @[s]

proc toArgs*(x: SomeNumber | bool | char): seq[string] =
  @[$x]

proc toArgs*[T](xs: openArray[T]): seq[string] =
  ## A sequence spliced into a command becomes one argument per element.
  result = @[]
  for x in xs:
    result.add $x

proc shellRun(line: string, splices: seq[seq[string]]): int =
  discard "implemented by nish"

proc shellCapture(line: string, splices: seq[seq[string]]): string =
  discard "implemented by nish"

proc shellLastStatus(): int =
  discard "implemented by nish"

proc shellWords(line: string, splices: seq[seq[string]]): seq[string] =
  discard "implemented by nish"

proc shellJobs() =
  discard "implemented by nish"

proc shellFg(id: int): int =
  discard "implemented by nish"

proc shellBg(id: int) =
  discard "implemented by nish"

proc jobs*() =
  ## Lists the background and stopped jobs.
  shellJobs()

proc fg*(id = 0): int {.discardable.} =
  ## Brings a job to the foreground and waits for it. Without an id, the
  ## most recent job, stopped ones first.
  result = shellFg(id)
  lastStatus = result

proc bg*(id = 0) =
  ## Lets a stopped job go on in the background.
  shellBg(id)

proc run*(line: string, splices: varargs[seq[string], toArgs]): int {.discardable.} =
  ## Runs a command line attached to the shell's terminal and returns the
  ## exit status of its last command. The line has shell syntax: pipes,
  ## redirects, `&&`, `||` and `;`, with globs, `~` and `$VAR` expanded in
  ## unquoted words. A NUL character in `line` takes the next splice; that is
  ## how `ls @(dir)` at the prompt reaches here.
  result = shellRun(line, @splices)
  lastStatus = result

proc sh*(line: string, splices: varargs[seq[string], toArgs]): string =
  ## Runs a command line like `run` but returns what it wrote to standard
  ## output, without trailing newlines: `let branch = sh"git branch --show-current"`.
  result = shellCapture(line, @splices)
  lastStatus = shellLastStatus()

proc words*(line: string, splices: varargs[seq[string], toArgs]): seq[string] =
  ## The words of a command line after quoting and expansion, without running
  ## anything.
  shellWords(line, @splices)

proc word*(line: string, splices: varargs[seq[string], toArgs]): string =
  ## Like `words`, for a line that must expand to exactly one word.
  let ws = words(line, splices)
  if ws.len != 1:
    raise newException(ValueError, "expected one word, got " & $ws.len & ": " & line)
  ws[0]
