## The API nish gives every script, imported before the first input.
##
## Bodies here are placeholders. The VM calls the native implementation of
## each proc, registered in `host.nim`, instead.

proc run*(args: seq[string]): int {.discardable.} =
  ## Runs a program attached to the shell's terminal and returns its exit
  ## code. Command lines like `ls -la` are rewritten into calls to this.
  discard "implemented by nish"
