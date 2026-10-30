## Native implementations of the procs declared in `script/nishapi.nim`.

import std/[os, sets, strutils, tables]
import compiler/[ast, vm, vmdef]
import ./[editor, jobs, pipeline]

var lastStatus* = 0 ## of the last command line run through the host

proc toStrings(n: PNode): seq[string] =
  result = @[]
  for x in n:
    result.add x.strVal

proc toSplices(n: PNode): seq[seq[string]] =
  result = @[]
  for x in n:
    result.add toStrings(x)

proc report(e: ref ShellError) =
  stderr.writeLine "nish: ", e.msg

proc commandsOnPath(prefix: string): seq[string] =
  ## Executables on `PATH` whose names start with `prefix`.
  var seen = initHashSet[string]()
  for dir in getEnv("PATH").split(PathSep):
    for kind, path in walkDir(dir, checkDir = false):
      let name = path.extractFilename
      if name.startsWith(prefix) and name notin seen:
        try:
          if fpUserExec in getFilePermissions(path):
            seen.incl name
        except OSError:
          discard "a broken link, say"
  result = @[]
  for name in seen:
    result.add name

proc filesMatching(prefix: string): seq[string] =
  ## Paths starting with `prefix`, directories with a `/` after them.
  let (dir, _) = splitPath(prefix)
  let listed = if dir.len > 0: dir else: "."
  result = @[]
  for kind, path in walkDir(listed, relative = dir.len == 0, checkDir = false):
    if path.startsWith(prefix):
      result.add(
        if kind in {pcDir, pcLinkToDir}:
          path & "/"
        else:
          path
      )

proc registerHostProcs*(
    vm: PCtx, pkg: string, symbols: proc(prefix: string): seq[string]
) =
  ## `pkg` is the package the compiler assigned to `nishapi`, which is part
  ## of the name the VM matches callbacks by. `symbols` lists the Nim
  ## symbols in scope, which only the session knows.
  template callback(name: string, body: untyped) =
    vm.registerCallback(
      pkg & ".nishapi." & name,
      proc(a {.inject.}: VmArgs) =
        body,
    )

  callback "shellRun":
    try:
      lastStatus = execute(a.getString(0), toSplices(a.getNode(1)), false).status
    except ShellError as e:
      report e
      lastStatus = 2
    a.setResult(BiggestInt lastStatus)

  callback "shellCapture":
    try:
      let (status, output) = execute(a.getString(0), toSplices(a.getNode(1)), true)
      lastStatus = status
      a.setResult(output.strip(leading = false, chars = {'\n'}))
    except ShellError as e:
      report e
      lastStatus = 2
      a.setResult("")

  callback "shellLastStatus":
    a.setResult(BiggestInt lastStatus)

  callback "shellWords":
    try:
      a.setResult(expandLine(a.getString(0), toSplices(a.getNode(1))))
    except ShellError as e:
      report e
      a.setResult(newSeq[string]())

  callback "shellJobs":
    listJobs()

  callback "shellFg":
    a.setResult(BiggestInt foreground(int a.getInt(0)))

  callback "shellBg":
    background(int a.getInt(0))

  callback "shellAlias":
    aliases[a.getString(0)] = a.getString(1)

  callback "shellCommands":
    a.setResult(commandsOnPath(a.getString(0)))

  callback "shellSymbols":
    a.setResult(symbols(a.getString(0)))

  callback "shellFiles":
    a.setResult(filesMatching(a.getString(0)))

  # The editor being used right now, if a key binding is running.
  callback "editorGetText":
    a.setResult(if active != nil: active.text else: "")

  callback "editorGetCursor":
    a.setResult(BiggestInt(if active != nil: active.cursor else: 0))

  callback "editorSetText":
    if active != nil:
      active.setText(a.getString(0), int a.getInt(1))

  callback "editorInsert":
    if active != nil:
      active.insertText(a.getString(0))
