## Native implementations of the procs declared in `script/nishapi.nim`.

import std/strutils
import compiler/[ast, vm, vmdef]
import ./[jobs, pipeline]

var lastStatus = 0 ## of the last capture, read back by `shellLastStatus`

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

proc registerHostProcs*(vm: PCtx, pkg: string) =
  ## `pkg` is the package the compiler assigned to `nishapi`, which is part
  ## of the name the VM matches callbacks by.
  template callback(name: string, body: untyped) =
    vm.registerCallback(
      pkg & ".nishapi." & name,
      proc(a {.inject.}: VmArgs) =
        body,
    )

  callback "shellRun":
    try:
      a.setResult(
        BiggestInt execute(a.getString(0), toSplices(a.getNode(1)), false).status
      )
    except ShellError as e:
      report e
      a.setResult(BiggestInt 2)

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

  callback "shellJobs":
    listJobs()

  callback "shellFg":
    a.setResult(BiggestInt foreground(int a.getInt(0)))

  callback "shellBg":
    background(int a.getInt(0))

  callback "shellWords":
    try:
      a.setResult(expandLine(a.getString(0), toSplices(a.getNode(1))))
    except ShellError as e:
      report e
      a.setResult(newSeq[string]())
