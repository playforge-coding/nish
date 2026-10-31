# Development

## Setup

nish is pinned to Nim 2.4.0 in `mise.toml`, because it uses the compiler's internal API, which changes between releases.

```sh
mise plugin install nim https://github.com/elijahr/vfox-nim
mise install
```

Don't install Nim another way (choosenim, Homebrew) alongside it.

## Building and testing

```sh
nimble build   # ./nish
nimble test    # every tests/t*.nim
```

- `tests/tcommands.nim` covers the parts that need no VM: the command-line parser, the classifier, the rewriter and the input chunking.
- `tests/tsession.nim` runs a real session: evaluation, error recovery, commands, pipes, redirects, expansion, jobs, hooks, completion and key bindings.

Add a test with every behavior change. `nim check <file>` gives fast type errors without a full build.

Check behavior with the binary too. `./nish -c '<code>'` runs code and exits with the status of the last command, and `--timing` prints how long the VM took to start. Keep an eye on that number, since every shell start pays it.

To test the prompt without a person at the keyboard, drive nish through a pseudo-terminal (Python's `pty` module works) and set the window size, since the editor wraps lines by the terminal width. Keep reading the terminal's output while you do: if nobody reads it, nish blocks when the buffer fills.

To see a first run, delete the cache directory (`~/Library/Caches/nish` on macOS, `~/.cache/nish` on Linux).

## Code style

- Format with [nph](https://github.com/arnetheduck/nph): `nph src tests` before committing.
- The build uses `--styleCheck:error`, so identifiers keep one spelling everywhere.
- Fix warnings and hints about unused imports or variables.
- Between `fork` and `execvp`, only async-signal-safe calls: build what the child needs in the parent.

`AGENTS.md` at the root has the full list of conventions and the parts of the compiler API that are easy to get wrong.

## Documentation

The docs are a [Zensical](https://zensical.org) site: `zensical.toml` at the root and the pages in `docs/`. Zensical is a Python tool; install the version the workflows pin (`ZENSICAL_VERSION` in `.github/workflows/docs.yml`) with [uv](https://docs.astral.sh/uv/):

```sh
uv tool install zensical==0.0.72
zensical serve           # live preview at http://localhost:8000
zensical build --strict  # writes site/, which git ignores
```

Update the docs in the same change as the code they describe. On the [roadmap](roadmap.md), check finished items off where they are instead of moving them to another section.

A pull request that touches the docs runs a strict build. A push to `main` that changes `docs/`, `zensical.toml` or the Pages workflow publishes the site to GitHub Pages; other pushes leave it alone.
