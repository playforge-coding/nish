## Native implementations of the procs declared in `script/nishapi.nim`.

import std/osproc
import compiler/[ast, vm, vmdef]

proc runCommand*(argv: seq[string]): int =
  try:
    let p = startProcess(
      argv[0], args = argv[1 .. ^1], options = {poParentStreams, poUsePath}
    )
    result = p.waitForExit()
    p.close()
  except OSError as e:
    stderr.writeLine "nish: ", argv[0], ": ", e.msg
    result = 127

proc registerHostProcs*(vm: PCtx, pkg: string) =
  ## `pkg` is the package the compiler assigned to `nishapi`, which is part
  ## of the name the VM matches callbacks by.
  vm.registerCallback(
    pkg & ".nishapi.run",
    proc(a: VmArgs) =
      var argv: seq[string] = @[]
      for n in a.getNode(0):
        argv.add n.strVal
      a.setResult(BiggestInt runCommand(argv)),
  )
