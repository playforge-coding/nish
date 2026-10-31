# nish

## Overview

nish is a terminal shell whose language is [NimScript](https://nim-lang.org/docs/nims.html), the subset of Nim that runs in the compiler's VM. It is written in Nim and embeds that VM through the compiler's API. License: 0BSD. The toolchain is pinned in `mise.toml` (Nim 2.4.0), and Nimble, which ships with Nim, handles the build, tasks and dependencies.

Input is Nim first. A line is a command only when its first word is not a Nim keyword or a symbol in scope but does name a program, so `ls -la` runs `ls` while `echo x` is Nim's `echo`. Command lines are rewritten into Nim (`run("ls -la")`) before the VM sees them, which lets them sit inside Nim blocks. The line keeps its shell syntax (pipes, redirects, `&&`, `||`, `;`, globs, `~`, `$VAR`) and the host parses it when `run` is called, so the same parser also serves `sh"..."`, which captures output. `@(expr)` puts a Nim value into a command: the rewriter replaces it with a NUL placeholder and passes the expression as an extra argument. The builtins `cd`, `exit`, `jobs`, `fg` and `bg` are rewritten to Nim calls (`cd(word(...))`, `quit(...)`, `fg(2)`). Only statement lines are candidates: `commands.lineContexts` tracks Nim blocks so lines in `type`/`const`/`let`/`var` sections, open brackets, continued expressions and `#[ ]#` comments are never commands, and names declared earlier in the input (routine names, parameters of named routines, of anonymous `proc(...) =` and of `do (...):` blocks, `result`, loop variables, `let`/`var`) count as Nim symbols. A routine body opens on a named header at the start of the line, or on the earliest anonymous `proc(` that isn't in a type position (after `:`). Names match style insensitively, as in Nim, except when a name that is also a program is being decided: there `Resolver.isExactNimSymbol` (`Session.isNimSymbol(exact = true)`) asks for the declared spelling, so `mkdir` runs the program while `mkDir` is NimScript's proc. The compiler keeps one identifier object per spelling, so each candidate symbol knows how it was declared. "Command not found" and `cd <name>` use the style-insensitive check, so `sayHi` still calls `say_hi`. Three exceptions to "Nim wins": a part containing `&&`, `||`, `>>` or `>&` outside quotes and comments is a command whatever its first word is (those are never Nim; `2>` is not on the list because `5>x` is a Nim comparison); a line starting with `!` is one command line as a whole; and a line is first split at `;` outside quotes and brackets, each part classified on its own, since `;` separates statements in Nim too.

Modules in `src/`:

- `nish.nim`: the entry point. Parses arguments, then runs the prompt or a script.
- `nish/editor.nim`: the line editor. Raw mode through `std/termios`, switched with `TCSADRAIN` and never `TCSAFLUSH` (linenoise flushed, which lost everything after the first line of a paste). Decodes keys into names like "ctrl-t" and "alt-f", reads bracketed pastes as one key, and redraws the whole multi-line input each time, tracking the cursor's row so it can get back to the top, with full-width lines moved past explicitly so its row count matches the terminal's. Enter accepts when `input.needsMoreInput` says the input is complete. Key bindings from Nim run through `nishKeyPressed`, and the host exposes the active editor to them.
- `nish/session.nim`: the embedded VM. One long-lived module whose scope carries over between inputs. It drives parsing, `semWithPContext` and `interpreterCode` itself instead of calling `processPipelineModule`, because that raises out on the first error and loses the scope. Defines `nimconfig`, so `system/nimscript` (`cd`, `getEnv`, `exec`, `listFiles` and the rest of the `.nims` API) is there, implemented by the compiler's `setupVM`.
- `nish/commands.nim`: decides which lines are commands, rewrites them, and parses command lines into pipelines (`parseCommandLine`). Pure: it asks a `Resolver` about symbols and programs and never touches the file system, so tests need no VM. `unknownCommand` spots lines shaped like a command whose word names no program, which `Session.eval` reports as "command not found" instead of letting the compiler say "undeclared identifier".
- Compiler errors come through `conf.structuredErrorHook`, and `Session.report` passes the first one of each input to `onMessage` with a readable position: none at the prompt, `line N:` past the first line, the script's name in scripts, and no stdlib paths. The compiler's own stderr printing is turned off with `conf.m.errorOutputs = {eStdOut}`, which keeps `echo` from scripts on stdout; don't use `writelnHook`, which also receives `echo` output. Tests set `onMessage` to capture messages.
- There is one exit status, `nishapi.lastStatus`. The session reads and sets it through `nishLastStatus` and `nishSetLastStatus`; a failed input sets 1, a missing command 127. The host's `captureStatus` only carries a capture's status back to `sh`.
- `nish/input.nim`: groups lines into chunks the VM evaluates on its own. At the prompt it follows the compiler REPL's rules (a blank line ends a block); for scripts it looks ahead and splits at top-level statements.
- `nish/pipeline.nim`: expands words (splices, `$VAR`, `~`, globs) and runs parsed lines with `fork`, `pipe` and `execvp` from `std/posix`. Between `fork` and `execvp` only async-signal-safe calls are allowed, so `prepare` builds everything the child needs first (the `argv` array, error messages, parsed descriptors), and failures write those with `posix.write` and leave with `exitnow`. Captured jobs (`sh"..."`) are started with `SIGTSTP` ignored: a stopped one could never close its pipe, and the shell would wait for it forever.
- `nish/jobs.nim`: jobs and job control. Each pipeline is a job; at an interactive terminal it gets its own process group and the foreground job owns the terminal (`tcsetpgrp`) until it exits or stops. The shell keeps `SIGINT` and `SIGQUIT` with no-op handlers, which reset to the default in children at `exec` on their own, and ignores `SIGTSTP`, `SIGTTIN` and `SIGTTOU` with `SIG_IGN`, because `tcsetpgrp` from outside the foreground group fails with `EINTR` when `SIGTTOU` merely has a handler. Ignored signals survive `exec`, so `childJobSetup` resets them in every child. Without a terminal, job control is off and jobs share the shell's group, like other shells. `notify()` runs before each prompt to report finished background jobs.
- `nish/host.nim`: native implementations of the procs scripts call, registered as VM callbacks. Arguments arrive as literal AST through `getNode`, so a `seq[seq[string]]` is an `nkBracket` of `nkBracket`s.
- `nish/script/nishapi.nim`: the Nim side of that API, imported into every session. The VM loads it from source at runtime. It also holds the hook registry (`prompt`, `onPreCommand`, `onCommandDone`, `onDirChange`, `completers`) and the `nish*` entry points nish calls from outside through `Session.callHook`, which uses `vm.execProc` and turns any failure into a fallback so a broken hook can't take the session down. Customization lives in `~/.config/nish/init.nims` and in plugin modules under `~/.config/nish/plugins/` (each subdirectory is on the search path too).
- `nish/embedded.nim`: the standard library and `nishapi.nim` built into the binary, since the VM compiles both from source at runtime. They are unpacked into the user's cache directory (`getCacheDir("nish")`) on the first run of a nish build, into `lib-<Nim version>-<hash>` and `api-<hash>`, named after a hash of their contents. Such a directory is built under a staging name and moved into place with one `rename`, and never changed or removed afterwards, so shells starting at the same time, or of different versions, can't break each other. Delete the cache directory to test a first run.

Things about the compiler API that are easy to get wrong:

- The VM matches a callback by `<package>.<module>.<proc>`, where the package is the name of the nearest `.nimble` file above the module (or `unknown`). `session.nim` asks the compiler for `nishapi`'s package instead of hard-coding it.
- The compiler modules import as `compiler/...` through `--path:"$nim"` in `config.nims`. Some, like `packagehandling`, are include files and can't be imported on their own.
- The embedded stdlib includes `stdlib.nimble` on purpose: it makes the package name `stdlib`, and the compiler's own VM callbacks are registered under names like `stdlib.system.getEnv`. Without it nothing in the NimScript API would work.

## Building and testing

- Nim comes from mise through the vfox-nim plugin. Register the plugin once with `mise plugin install nim https://github.com/elijahr/vfox-nim`, then run `mise install`. Do not install Nim another way (choosenim, Homebrew) alongside it.
- Keep the package manifest in `nish.nimble` at the root, so `nimble build` and `nimble test` are the only commands anyone needs to remember. Nimble's built-in `build` (from `bin`) and `test` (every `tests/t*.nim`) already do what nish needs; add a task only for a step they don't cover. Pin dependencies in `nimble.lock` (`nimble lock`) and commit it.
- Tests live in `tests/`, one `t*.nim` file per area, using `std/unittest`. `nimble test` runs them all. Add a test with every behavior change.
- Run `nim check` on a file for fast type errors without a full build.
- Check behavior with the real binary: `./nish -c '<code>'` runs code and exits with 1 on the first error, and `--timing` prints how long the VM took to start. Keep an eye on that number, since every shell start pays it. To test the prompt without a terminal, drive it through a pseudo-terminal (Python's `pty` module works) and set its window size, since the editor wraps by the terminal width.
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

The docs are a [Zensical](https://zensical.org) site: `zensical.toml` at the root, pages in `docs/`. `zensical build --strict` checks it and writes `site/` (ignored by git), and `zensical serve` previews it. The Docs workflow runs the strict build on pull requests that touch the docs, and the Pages workflow publishes the site on every push to `main` that does. Pages:

- `index.md`: what nish is, with an example.
- `getting-started.md`: building, a first session, scripts and options.
- `language.md`: how lines are classified, the command syntax, splices, `sh`, `lastStatus`, builtins and jobs. Keep it in step with `commands.nim` and `pipeline.nim`.
- `customizing.md`: `init.nims`, aliases, the prompt, hooks, completion, key bindings, the editor's keys and plugins. Keep the key table in step with `editor.handle`.
- `api.md`: everything exported from `nishapi.nim` except the `nish*` entry points. Every new public proc or variable there gets an entry.
- `architecture.md` and `development.md`: for people working on nish.
- `roadmap.md`: what's done and what's planned.

Run the examples you put in the docs through `./nish` before committing them.

When a roadmap item is finished, check it off (`- [x]`) where it is. DO NOT move it into an earlier section like "Done: the MVP". The roadmap shows how each goal is progressing, so finished items stay with the section they belong to.

The README is only an entry point: what nish is, one example, building, and links into the docs. Put details in the docs, not the README.

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
