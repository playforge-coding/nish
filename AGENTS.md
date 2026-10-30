# nish

## Overview

nish is a terminal shell whose language is [NimScript](https://nim-lang.org/docs/nims.html), the subset of Nim that runs in the compiler's VM. It is written in Nim and embeds that VM through the compiler's API. License: 0BSD. The toolchain is pinned in `mise.toml` (Nim 2.4.0), and Nimble, which ships with Nim, handles the build, tasks and dependencies.

Input is Nim first. A line is a command only when its first word is not a Nim keyword or a symbol in scope but does name a program, so `ls -la` runs `ls` while `echo x` is Nim's `echo`. Command lines are rewritten into Nim (`run("ls -la")`) before the VM sees them, which lets them sit inside Nim blocks. The line keeps its shell syntax (pipes, redirects, `&&`, `||`, `;`, globs, `~`, `$VAR`) and the host parses it when `run` is called, so the same parser also serves `sh"..."`, which captures output. `@(expr)` puts a Nim value into a command: the rewriter replaces it with a NUL placeholder and passes the expression as an extra argument. The builtins `cd`, `exit`, `jobs`, `fg` and `bg` are rewritten to Nim calls (`cd(word(...))`, `quit(...)`, `fg(2)`). Three exceptions to "Nim wins": a part containing `&&`, `||`, `>>`, `>&` or `2>` outside quotes is a command whatever its first word is (those are never Nim); a line starting with `!` is one command line as a whole; and a line is first split at `;` outside quotes and brackets, each part classified on its own, since `;` separates statements in Nim too.

Modules in `src/`:

- `nish.nim`: the entry point. Parses arguments, then runs the prompt (linenoise through `std/linenoise`) or a script.
- `nish/session.nim`: the embedded VM. One long-lived module whose scope carries over between inputs. It drives parsing, `semWithPContext` and `interpreterCode` itself instead of calling `processPipelineModule`, because that raises out on the first error and loses the scope. Defines `nimconfig`, so `system/nimscript` (`cd`, `getEnv`, `exec`, `listFiles` and the rest of the `.nims` API) is there, implemented by the compiler's `setupVM`.
- `nish/commands.nim`: decides which lines are commands, rewrites them, and parses command lines into pipelines (`parseCommandLine`). Pure: it asks a `Resolver` about symbols and programs and never touches the file system, so tests need no VM.
- `nish/input.nim`: groups lines into chunks the VM evaluates on its own. At the prompt it follows the compiler REPL's rules (a blank line ends a block); for scripts it looks ahead and splits at top-level statements.
- `nish/pipeline.nim`: expands words (splices, `$VAR`, `~`, globs) and runs parsed lines with `fork`, `pipe` and `execvp` from `std/posix`. Between `fork` and `execvp` only async-signal-safe calls are allowed; failures there write with `posix.write` and leave with `exitnow`.
- `nish/jobs.nim`: jobs and job control. Each pipeline is a job; at an interactive terminal it gets its own process group and the foreground job owns the terminal (`tcsetpgrp`) until it exits or stops. The shell survives Ctrl-Z and the terminal signals through no-op handlers, which, unlike `SIG_IGN`, reset to the default in children at `exec`. Without a terminal, job control is off and jobs share the shell's group, like other shells. `notify()` runs before each prompt to report finished background jobs.
- `nish/host.nim`: native implementations of the procs scripts call, registered as VM callbacks. Arguments arrive as literal AST through `getNode`, so a `seq[seq[string]]` is an `nkBracket` of `nkBracket`s.
- `nish/script/nishapi.nim`: the Nim side of that API, imported into every session. The VM loads it from source at runtime.
- `nish/embedded.nim`: the standard library and `nishapi.nim` built into the binary, since the VM compiles both from source at runtime. They are unpacked into the user's cache directory (`getCacheDir("nish")`) on the first run of a nish build, into `lib-<Nim version>` with a stamp file, and `nishapi.nim` is rewritten whenever the embedded copy differs. Delete that cache directory to test a first run.

Things about the compiler API that are easy to get wrong:

- The VM matches a callback by `<package>.<module>.<proc>`, where the package is the name of the nearest `.nimble` file above the module (or `unknown`). `session.nim` asks the compiler for `nishapi`'s package instead of hard-coding it.
- The compiler modules import as `compiler/...` through `--path:"$nim"` in `config.nims`. Some, like `packagehandling`, are include files and can't be imported on their own.
- The embedded stdlib includes `stdlib.nimble` on purpose: it makes the package name `stdlib`, and the compiler's own VM callbacks are registered under names like `stdlib.system.getEnv`. Without it nothing in the NimScript API would work.

## Building and testing

- Nim comes from mise through the vfox-nim plugin. Register the plugin once with `mise plugin install nim https://github.com/elijahr/vfox-nim`, then run `mise install`. Do not install Nim another way (choosenim, Homebrew) alongside it.
- Keep the package manifest in `nish.nimble` at the root, and put build and test commands in it as Nimble tasks so `nimble build` and `nimble test` are the only commands anyone needs to remember. Pin dependencies in `nimble.lock` (`nimble lock`) and commit it.
- Tests live in `tests/`, one `t*.nim` file per area, using `std/unittest`. `nimble test` runs them all. Add a test with every behavior change.
- Run `nim check` on a file for fast type errors without a full build.
- Check behavior with the real binary: `./nish -c '<code>'` runs code and exits with 1 on the first error, and `--timing` prints how long the VM took to start. Keep an eye on that number, since every shell start pays it. To test the prompt without a terminal, drive it through a pseudo-terminal and answer linenoise's cursor position query (`ESC[6n`) with something like `ESC[1;7R`, or it swallows the input.
- Compiler settings that apply to the whole project go in `config.nims` at the root, not in flags scattered across scripts.

## Searching the Codebase

Use fast, modern tools instead of the slow defaults:

- [`rg`](https://github.com/BurntSushi/ripgrep) (ripgrep) for text search, not `grep`. It respects `.gitignore` for you.
- [`fd`](https://github.com/sharkdp/fd) for finding files by name, not `find`.
- [`ast-grep`](https://ast-grep.github.io) for structural searches and rewrites in languages it supports. It has no built-in Nim grammar, so use `rg` for Nim sources. Call it as `ast-grep`. The `sg` alias is deprecated, so don't use it.
- `jq` for reading and querying JSON.

If your harness has dedicated search or file tools that already wrap these, those are fine too.

## Code Quality

Always lint and format:

- Format with [`nph`](https://github.com/arnetheduck/nph), not `nimpretty`. Run `nph src tests` before committing.
- Build with `--styleCheck:error` (set it in `config.nims`) so identifiers keep one spelling across the codebase. Nim's style insensitivity is not an excuse for `fooBar` in one file and `foo_bar` in another.
- Treat compiler warnings and hints about unused imports or variables as things to fix, not noise.

Use modern code practices:

- Nim 2 defaults: ORC memory management, `strictDefs`, and `std/` prefixed imports (`import std/[os, strutils]`).
- Prefer `func` for procs without side effects, `Result`-style or exception-tracked error handling with `{.raises: [].}` where it matters, and `distinct` types over bare primitives for things that should not mix.
- Reach for the standard library before adding a dependency.

## Docs (IMPORTANT!!!)

Always update the docs if necessary when changing or adding code. If the docs already contain outdated information, expand your scope to cover that info too. That includes this file: when the layout, build or tooling changes, update the overview and the build section here.

## Diagrams as Mermaid, not ASCII art

Never draw a flow, pipeline or architecture picture out of characters in a code block. Make a Mermaid diagram instead.

## Outdated packages

PLEASE, PLEASE do not use a package that is old or deprecated. EVEN IF IT IS "INDUSTRY STANDARD" THAT DOES NOT MEAN IT IS GOOD!!! USE THE BEST PACKAGE AND LATEST VERSION LIKE A NORMAL PERSON WOULD!

Check the package's repository for its latest release tag (and whether it is still maintained) before adding it to or bumping it in `nish.nimble`. The Nimble package list (`nimble search <name>`) points to the repository.

## Keep things human

Do not use em dashes or other special symbols not normally found in writing. Do not word things in a weird way. Keep it looking human. If you need to use, for example, an arrow icon, use an SVG instead.

Replacing an em dash with a hyphen is NOT a fix. A spaced hyphen doing an em dash's job ("the limit - 4 bytes", "fast - but wrong") is the same tic with a different character. Reword the sentence instead: use a comma, a colon, parentheses, or the actual word ("minus", "to", "through"). Plain hyphens in compound words and numeric ranges like 0-1 are fine.

## Use American spelling

It's fine to be British in the chat if the person is actually in a region where it's spelled like that. But if not, just use American spelling. The thing itself MUST use American spelling.
