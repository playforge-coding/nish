## Groups input lines into chunks the VM can evaluate on their own.
##
## At the prompt the rules follow the compiler's own REPL
## (`llstream.continueLine`): a line that opens a block, ends in an operator,
## or is indented keeps the chunk going, and a blank line ends it. Scripts
## can look ahead, so there a chunk ends where the next top-level statement
## starts. Command lines always end a chunk, so `rm *` doesn't wait for more
## input because it ends in an operator.

import std/strutils

type
  LineReader* = proc(continuation: bool, line: var string): bool
    ## Reads the next line, returning false at end of input.
  Chunk* = object
    code*: string
    line*: int ## 1-based line in the script where the chunk starts

const
  continuationChars = {
    '+',
    '-',
    '*',
    '/',
    '\\',
    '<',
    '>',
    '!',
    '?',
    '^',
    '|',
    '%',
    '&',
    '$',
    '@',
    '~',
    ',',
    ':',
    '=', # not '#': comments are stripped first, and `]#` ends one
  }
  continuationWords = [
    "let", "var", "const", "type", "object", "tuple", "div", "mod", "shl", "shr", "in",
    "notin", "is", "isnot", "not", "of", "as", "from", "..", "and", "or", "xor",
  ]
  # Unindented lines that still belong to the statement before them.
  branchWords = ["elif", "else", "except", "finally", "of"]

proc endsWithWord(line, word: string): bool =
  line.endsWith(word) and (
    word[0] notin IdentChars or line.len == word.len or
    line[^(word.len + 1)] notin IdentChars
  )

proc withoutComment(line: string): string =
  ## `line` up to a `#` that starts a comment, outside quotes.
  var quote = ' '
  var i = 0
  while i < line.len:
    let c = line[i]
    if quote != ' ':
      if c == '\\':
        inc i
      elif c == quote:
        quote = ' '
    elif c in {'"', '\''}:
      quote = c
    elif c == '#' and (i == 0 or line[i - 1] in Whitespace):
      return line[0 ..< i]
    inc i
  line

proc endsOpen(line: string): bool =
  ## The statement on this line goes on to the next one.
  let line = line.withoutComment.strip(leading = false)
  if line.len == 0:
    return false
  if line[^1] in continuationChars:
    return true
  for word in continuationWords:
    if line.endsWithWord(word):
      return true
  false

proc opens(line: string): int =
  ## How many `#[ ]#` comments the line leaves open (negative: closes).
  line.count("#[") - line.count("]#")

proc continues(line: string, inTriple: bool): bool =
  ## At the prompt, an indented line also keeps the block open. A line of
  ## only whitespace is a blank line, which ends it.
  inTriple or (line.strip.len > 0 and line[0] in Whitespace) or endsOpen(line)

proc isTopLevelCommand(
    line: string, inTriple: bool, isCommand: proc(line: string): bool
): bool =
  not inTriple and line.len > 0 and line[0] notin Whitespace and isCommand(line)

proc readChunk*(
    readLine: LineReader, isCommand: proc(line: string): bool, chunk: var string
): bool =
  ## Reads lines into `chunk` until it is complete. Returns false only when
  ## input ended before any line was read.
  chunk = ""
  var line = ""
  var triples = 0
  var comments = 0 ## open `#[ ]#` comments, which keep going like strings
  while readLine(chunk.len > 0, line):
    if chunk.len > 0:
      chunk.add '\n'
    chunk.add line
    triples += line.count("\"\"\"")
    comments = max(comments + line.opens, 0)
    let inTriple = triples mod 2 == 1 or comments > 0
    if isTopLevelCommand(line, inTriple, isCommand) or not continues(line, inTriple):
      return true
  chunk.len > 0

proc needsMoreInput*(text: string, isCommand: proc(line: string): bool): bool =
  ## The prompt rule for a whole input the editor holds: whether Enter should
  ## add a line rather than accept it. The last line decides, as in
  ## `readChunk`.
  let lines = text.split('\n')
  let inTriple = text.count("\"\"\"") mod 2 == 1 or text.opens > 0
  if lines.len == 1 and isTopLevelCommand(lines[0], inTriple, isCommand):
    return false
  continues(lines[^1], inTriple)

proc startsBranch(line: string): bool =
  for word in branchWords:
    if line.startsWith(word) and
        (line.len == word.len or line[word.len] notin IdentChars):
      return true
  false

proc splitChunks*(
    lines: openArray[string], isCommand: proc(line: string): bool
): seq[Chunk] =
  ## Splits a whole script into top-level statements.
  result = @[]
  var current = Chunk(line: 1)
  var lineCount = 0
  var triples = 0
  var comments = 0 ## open `#[ ]#` comments, which keep going like strings
  for i, line in lines:
    if lineCount == 0:
      if line.strip.len == 0:
        continue
      current = Chunk(line: i + 1)
    else:
      current.code.add '\n'
    current.code.add line
    inc lineCount
    triples += line.count("\"\"\"")
    comments = max(comments + line.opens, 0)
    let inTriple = triples mod 2 == 1 or comments > 0
    var next = i + 1
    while next < lines.len and lines[next].strip.len == 0:
      inc next
    let nextStartsStatement =
      next >= lines.len or
      (lines[next][0] notin Whitespace and not startsBranch(lines[next]))
    if isTopLevelCommand(line, inTriple, isCommand) or
        (nextStartsStatement and not inTriple and not endsOpen(line)):
      result.add current
      lineCount = 0
  if lineCount > 0:
    result.add current
