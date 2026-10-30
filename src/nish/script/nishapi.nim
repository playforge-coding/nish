## The API nish gives every script, imported before the first input.
##
## Procs whose body is `discard "implemented by nish"` are placeholders: the
## VM calls the native implementation registered in `host.nim` instead.
## Procs named `nish*` are entry points nish calls from the outside: they run
## the hooks that `init.nims` and plugins register.

import std/[algorithm, strutils]

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

# Implemented by nish

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

proc shellAlias(name, line: string) =
  discard "implemented by nish"

proc shellCommands(prefix: string): seq[string] =
  discard "implemented by nish"

proc shellSymbols(prefix: string): seq[string] =
  discard "implemented by nish"

proc shellFiles(prefix: string): seq[string] =
  discard "implemented by nish"

proc editorGetText(): string =
  discard "implemented by nish"

proc editorGetCursor(): int =
  discard "implemented by nish"

proc editorSetText*(text: string, cursor: int) =
  ## Replaces the input being edited. Only meaningful inside a key binding.
  discard "implemented by nish"

proc editorInsert*(s: string) =
  ## Inserts at the cursor. Only meaningful inside a key binding.
  discard "implemented by nish"

proc editorText*(): string =
  ## The input being edited. Only meaningful inside a key binding.
  editorGetText()

proc editorCursor*(): int =
  ## The cursor's byte offset in `editorText()`.
  editorGetCursor()

# Running commands

proc run*(line: string, splices: varargs[seq[string], toArgs]): int {.discardable.} =
  ## Runs a command line attached to the shell's terminal and returns the
  ## exit status of its last command. The line has shell syntax: pipes,
  ## redirects, `&&`, `||`, `;` and `&`, with globs, `~` and `$VAR` expanded
  ## in unquoted words. A NUL character in `line` takes the next splice; that
  ## is how `ls @(dir)` at the prompt reaches here.
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

proc alias*(name, line: string) =
  ## Makes `name` stand for the start of a command line: after
  ## `alias "ll", "ls -la"`, `ll src` runs `ls -la src`.
  shellAlias(name, line)

# Jobs

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

# Hooks: set or add to these in `init.nims` or a plugin

type Completer* = proc(line, word: string): seq[string]
  ## Gets the whole line and the word being completed; returns replacements
  ## for that word.

proc tildePath*(path: string): string =
  ## `path` with the home directory written as `~`.
  let home = getEnv("HOME")
  if home.len > 0 and (path == home or path.startsWith(home & "/")):
    "~" & path[home.len .. ^1]
  else:
    path

proc defaultPrompt(): string =
  tildePath(getCurrentDir()) & "> "

proc defaultContinuationPrompt(): string =
  "  ... "

const builtins = ["cd", "exit", "jobs", "fg", "bg"]

proc defaultCompleter(line, word: string): seq[string] =
  ## Programs, Nim symbols and builtins for the first word; files after it.
  if line.strip(trailing = false).len == word.len:
    result = shellCommands(word) & shellSymbols(word)
    for b in builtins:
      if b.startsWith(word):
        result.add b
  else:
    result = shellFiles(word)

var
  prompt*: proc(): string = defaultPrompt
    ## Returns the prompt. Plain text only for now: the line editor counts
    ## every character, so color codes misplace the cursor.
  continuationPrompt*: proc(): string = defaultContinuationPrompt
  onPreCommand*: seq[proc(line: string)] =
    @[] ## Run with each line before it is evaluated.
  onCommandDone*: seq[proc(line: string, status: int)] =
    @[] ## Run after each line with the status of the last command it ran.
  onDirChange*: seq[proc(dir: string)] =
    @[] ## Run before a prompt when the current directory changed.
  completers*: seq[Completer] = @[Completer(defaultCompleter)]
    ## All of these are asked on Tab; their answers are joined.

var keyBindings*: seq[tuple[key: string, action: proc()]] = @[]
  ## Set with `bindKey`. Key names are like "ctrl-t", "alt-x", "f5", "up",
  ## "ctrl-right". Printable characters can't be bound.

proc bindKey*(key: string, action: proc()) =
  ## Runs `action` when `key` is pressed at the prompt, instead of what the
  ## editor would do. The action works on the input through `editorText`,
  ## `editorCursor`, `editorSetText` and `editorInsert`.
  for i, binding in keyBindings:
    if binding.key == key:
      keyBindings[i].action = action
      return
  keyBindings.add (key, action)

# Entry points nish calls

proc nishKeyPressed*(key: string): bool =
  for binding in keyBindings:
    if binding.key == key:
      binding.action()
      return true
  false

proc nishPrompt*(): string =
  prompt()

proc nishContinuationPrompt*(): string =
  continuationPrompt()

proc nishPreCommand*(line: string) =
  for hook in onPreCommand:
    hook(line)

proc nishCommandDone*(line: string, status: int) =
  for hook in onCommandDone:
    hook(line, status)

proc nishDirChanged*(dir: string) =
  for hook in onDirChange:
    hook(dir)

proc nishComplete*(line: string): seq[string] =
  ## Whole-line replacements for `line`, which is what the line editor
  ## wants back.
  let start = line.rfind(' ') + 1
  let word = line[start .. ^1]
  result = @[]
  for completer in completers:
    for candidate in completer(line, word):
      let full = line[0 ..< start] & candidate
      if full notin result:
        result.add full
  result.sort()
