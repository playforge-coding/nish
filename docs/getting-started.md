# Getting started

## Building

nish uses the Nim compiler's internal API, so it is pinned to one Nim release, 2.4.0, through [mise](https://mise.jdx.dev). From a clone of the repository:

```sh
mise plugin install nim https://github.com/elijahr/vfox-nim
mise install
nimble build   # produces ./nish
```

The binary carries the Nim standard library with it. The first time a build of nish runs, it unpacks the library into your cache directory (`~/Library/Caches/nish` on macOS, `~/.cache/nish` on Linux), which takes a moment. After that a shell starts in well under a tenth of a second.

## A first session

Start the shell with `./nish`. The prompt shows the current directory:

```nim
~/src/nish> echo 6 * 7
42
~/src/nish> ls -1 src
nish
nish.nim
```

`echo` is Nim's, because it means something in Nim. `ls` is a program and isn't a Nim name, so that line runs it. [The language](language.md) explains the rules in full.

Variables stay around, and commands can use them:

```nim
~/src/nish> let dir = "src/nish"
~/src/nish> ls -d @(dir)
src/nish
~/src/nish> let year = sh"date +%Y"
~/src/nish> echo "it is ", year
it is 2026
```

Only `system` and nish's own [API](api.md) are in scope at the start. Import the rest of the standard library as you need it, for example `import std/strutils`.

Blocks span several lines. Enter after a line ending in `:` starts the next line indented, and Enter on an empty line runs the block:

```nim
~/src/nish> for f in ["a.txt", "b.txt"]:
  ...   touch @(f)
  ...
```

Quit with Ctrl-D or `exit`.

## Scripts

A script is a file of the same input you'd type at the prompt:

```nim
#!/usr/bin/env nish
let target = "build"
mkdir -p @(target)
for f in listFiles("src"):
  echo "copying ", f
  cp @(f) @(target)
```

Run it with `nish script.nims`, or make it executable and put `nish` on your `PATH`. There are two other ways to run code:

```sh
nish -c 'for i in 1..3: echo i'
cat script.nims | nish
```

A script stops at its first error. nish then exits with 1, or with 127 if a command wasn't found. A script that finishes exits with the status of its last command, as other shells do.

!!! note
    `~/.config/nish/init.nims` only runs for interactive sessions, not for scripts, `-c` or piped input.

## Options

`nish --help` lists them:

`--no-init`
:   Start without running `~/.config/nish/init.nims`.

`--timing`
:   Print how long the VM took to start.
