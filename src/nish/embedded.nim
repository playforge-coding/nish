## The Nim standard library and `nishapi.nim`, built into the binary.
##
## The VM compiles both from source at runtime, so a nish binary has to carry
## them to run anywhere but the machine that built it. They are unpacked into
## the user's cache directory the first time a version of nish runs.

import std/[compilesettings, os, staticos]

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
  libStamp = block:
    var bytes = 0
    for f in embeddedLib:
      bytes += f.content.len
    NimVersion & " " & $embeddedLib.len & " files " & $bytes & " bytes"
  nishapiSource = staticRead("script/nishapi.nim")

proc writeIfChanged(path, content: string) =
  if not fileExists(path) or readFile(path) != content:
    createDir(path.parentDir)
    writeFile(path, content)

proc stdlibDir*(): string =
  ## The unpacked standard library, unpacking it first if this version of
  ## nish hasn't yet.
  result = getCacheDir("nish") / "lib-" & NimVersion
  let stampFile = result / ".nish-stamp"
  if fileExists(stampFile) and readFile(stampFile) == libStamp:
    return
  # Build next to the final place and move it there, so another nish starting
  # at the same time never sees a half-written library.
  let staging = result & ".unpacking-" & $getCurrentProcessId()
  removeDir(staging)
  for f in embeddedLib:
    createDir(staging / f.path.parentDir)
    writeFile(staging / f.path, f.content)
  writeFile(staging / ".nish-stamp", libStamp)
  removeDir(result)
  moveDir(staging, result)

proc nishapiDir*(): string =
  ## The directory holding `nishapi.nim`, kept current with the binary.
  result = getCacheDir("nish") / "api"
  writeIfChanged(result / "nishapi.nim", nishapiSource)
