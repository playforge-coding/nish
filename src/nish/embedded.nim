## The Nim standard library and `nishapi.nim`, built into the binary.
##
## The VM compiles both from source at runtime, so a nish binary has to carry
## them to run anywhere but the machine that built it. They are unpacked into
## the user's cache directory the first time a version of nish runs.

import std/[compilesettings, hashes, os, staticos, strutils]

type EmbeddedFile = tuple[path, content: string] ## `path` relative to `lib/`

const
  libSource = querySetting(libPath)
  # Portable parts of the stdlib. Directories for other platforms and the C
  # headers are left out. `stdlib.nimble` gives the modules their package name,
  # which the compiler's own VM callbacks (`stdlib.system.*`) are matched by.
  libDirs = [
    "system", "pure", "core", "std", "impure", "packages", "posix", "wrappers",
    "deprecated", "arch", "experimental",
  ]
  libFiles = ["system.nim", "stdlib.nimble"]
  sourceExts = [".nim", ".nims", ".nimble", ".cfg"]

proc collect(dir: string, into: var seq[string]) {.compileTime.} =
  for entry in staticWalkDir(dir, relative = false):
    case entry.kind
    of staticos.pcFile:
      if entry.path.splitFile.ext in sourceExts:
        into.add entry.path
    of staticos.pcDir:
      collect(entry.path, into)
    else:
      discard

const
  libFileList = block:
    var paths: seq[string] = @[]
    for f in libFiles:
      paths.add libSource / f
    for d in libDirs:
      collect(libSource / d, paths)
    paths
  embeddedLib: seq[EmbeddedFile] = block:
    var files: seq[EmbeddedFile] = @[]
    for path in libFileList:
      files.add (path.relativePath(libSource), staticRead(path))
    files
  libHash = block:
    var h: Hash = 0
    for f in embeddedLib:
      h = h !& hash(f.path) !& hash(f.content)
    toHex(uint64(!$h))
  nishapiSource = staticRead("script/nishapi.nim")
  nishapiHash = toHex(uint64(hash(nishapiSource)))

proc rename(source, dest: cstring): cint {.importc, header: "<stdio.h>".}

proc publish(staging, final: string): string =
  ## Moves a finished `staging` directory to `final` in one `rename`. If
  ## another nish got there first, its copy is just as good: ours goes.
  if rename(staging.cstring, final.cstring) != 0:
    removeDir(staging)
  final

proc stdlibDir*(): string =
  ## The unpacked standard library, unpacking it first if this build of
  ## nish hasn't yet. The directory is named after a hash of its contents,
  ## so once it exists it is complete and never changes, even with several
  ## nish versions running at once.
  result = getCacheDir("nish") / "lib-" & NimVersion & "-" & libHash
  if fileExists(result / "system.nim"):
    return
  let staging = result & ".unpacking-" & $getCurrentProcessId()
  removeDir(staging)
  for f in embeddedLib:
    createDir(staging / f.path.parentDir)
    writeFile(staging / f.path, f.content)
  discard publish(staging, result)

proc nishapiDir*(): string =
  ## The directory holding this build's `nishapi.nim`, named after its hash
  ## for the same reason.
  result = getCacheDir("nish") / "api-" & nishapiHash
  if fileExists(result / "nishapi.nim"):
    return
  let staging = result & ".unpacking-" & $getCurrentProcessId()
  removeDir(staging)
  createDir(staging)
  writeFile(staging / "nishapi.nim", nishapiSource)
  discard publish(staging, result)
