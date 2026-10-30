version = "0.1.0"
author = "playforge-coding"
description = "A terminal shell whose language is NimScript"
license = "0BSD"
srcDir = "src"
bin = @["nish"]

# nish embeds the compiler through its unstable internal API, so it is pinned
# to the exact Nim release in mise.toml. Bump both together.
requires "nim == 2.4.0"
