## The embedded NimScript VM.
##
## A session is one long-lived module, like the compiler's REPL (`nim
## secret`), but nish drives the parse, check and eval steps itself instead
## of calling `processPipelineModule`. That way an error in one input is
## reported and skipped while the module's scope, and everything defined in
## it, carries on to the next input.

import std/[os, sets, strutils, tables]
import
  compiler/[
    ast, astalgo, condsyms, idents, lineinfos, llstream, lookups, modulegraphs, modules,
    msgs, options, parser, pathutils, pipelines, scriptconfig, sem, semdata, syntaxes,
    vm, vmdef,
  ]
import ./[commands, embedded, host, pipeline]

type Session* = ref object
  graph: ModuleGraph
  module: PSym
  ctx: PContext
  backend: PPassContext
  apiDir: string ## where `nishapi.nim` was unpacked

proc errorCount(s: Session): int =
  s.graph.config.errorCounter

proc vm(s: Session): PCtx =
  PCtx(s.graph.vm)

proc recover(s: Session, mark: StackMark) =
  ## After the VM raised out of a call it still holds the exception and the
  ## call's frames, and the next call would trip over both.
  s.vm.currentExceptionA = 0
  s.vm.currentExceptionB = 0
  s.vm.mem.popFrames(mark)
  # `interpreterCode` skips the next statement when errors were reported
  # since it last ran, which is right for a script but not for a hook that
  # failed between two inputs.
  s.vm.oldErrorCount = s.graph.config.errorCounter

proc strNode*(s: string): PNode =
  newStrNode(nkStrLit, s)

proc intNode*(i: int): PNode =
  newIntNode(nkIntLit, i)

proc evalNim*(s: Session, code: string, line = 1): bool =
  ## Evaluates Nim code in the session's module. Errors are printed by the
  ## compiler; the result says whether there were any. `line` is where the
  ## code starts in its script, for error messages.
  let before = s.errorCount
  var p: Parser = default(Parser)
  # The parser numbers lines from the start of the stream, so pad it.
  syntaxes.openParser(
    p,
    s.module.fileIdx,
    llStreamOpen(repeat('\n', line - 1) & code),
    s.graph.cache,
    s.graph.config,
  )
  var stmts = newNode(nkStmtList)
  while true:
    let n = parseTopLevelStmt(p)
    if n.kind == nkEmpty:
      break
    stmts.add n
  closeParser(p)
  if s.errorCount == before and stmts.len > 0:
    prePass(s.ctx, stmts)
    let checked = semWithPContext(s.ctx, stmts)
    let mark = s.vm.mem.stackMark
    try:
      discard interpreterCode(s.backend, checked)
    except ERecoverableError:
      s.recover(mark) # the VM already reported it
  s.errorCount == before

proc isNimSymbol*(s: Session, name: string): bool =
  let ident = getIdent(s.graph.cache, name)
  var ambiguous = false
  searchInScopes(s.ctx, ident, ambiguous) != nil or
    someSymFromImportTable(s.ctx, ident, ambiguous) != nil

proc resolver*(s: Session): Resolver =
  Resolver(
    isNimSymbol: proc(name: string): bool =
      s.isNimSymbol(name),
    isProgram: proc(name: string): bool =
      if '/' in name:
        fileExists(name)
      else:
        aliases.hasKey(name) or findExe(name).len > 0,
  )

proc eval*(s: Session, input: string, line = 1): bool =
  ## Evaluates shell input: Nim with command lines mixed in.
  s.evalNim(translate(input, s.resolver), line)

# Calling into the VM

proc apiSym(s: Session, name: string): PSym =
  let idx = fileInfoIdx(s.graph.config, AbsoluteFile(s.apiDir / "nishapi.nim"))
  let module = s.graph.getModule(idx)
  if module == nil:
    return nil
  someSym(s.graph, module, getIdent(s.graph.cache, name))

proc callHook*(s: Session, name: string, args: varargs[PNode]): PNode =
  ## Calls an entry point of `nishapi`. Returns nil when the call failed; the
  ## VM has printed why, and the session goes on.
  let sym = s.apiSym(name)
  if sym == nil:
    return nil
  let before = s.errorCount
  let mark = s.vm.mem.stackMark
  try:
    result = execProc(s.vm, sym, args)
  except ERecoverableError:
    s.recover(mark)
    result = nil
  if s.errorCount != before:
    result = nil

proc runHook*(s: Session, name: string, args: varargs[PNode]) =
  discard s.callHook(name, args)

proc hookString*(s: Session, name, fallback: string): string =
  let n = s.callHook(name)
  if n != nil and n.kind in {nkStrLit .. nkTripleStrLit}: n.strVal else: fallback

proc hookBool*(s: Session, name: string, args: varargs[PNode]): bool =
  let n = s.callHook(name, args)
  n != nil and n.kind == nkIntLit and n.intVal != 0

proc complete*(s: Session, line: string): seq[string] =
  ## Whole-line completions for `line`.
  result = @[]
  let n = s.callHook("nishComplete", strNode(line))
  if n != nil and n.kind == nkBracket:
    for x in n:
      result.add x.strVal

proc symbolNames*(s: Session, prefix: string): seq[string] =
  ## Nim symbols in scope starting with `prefix`, for completion.
  const kinds = {
    skProc, skFunc, skTemplate, skMacro, skIterator, skConverter, skVar, skLet, skConst,
    skType, skEnumField,
  }
  var seen = initHashSet[string]()
  proc consider(sym: PSym) =
    if sym.kind in kinds and sym.name.s.startsWith(prefix):
      seen.incl sym.name.s

  for scope in allScopes(s.ctx.currentScope):
    for sym in items(scope.symbols):
      consider sym
  for imported in s.ctx.imports:
    for sym in allSyms(s.graph, imported.m):
      consider sym
  for sym in allSyms(s.graph, s.graph.systemModule):
    consider sym
  result = @[]
  for name in seen:
    result.add name

proc pluginDirs(): seq[string] =
  ## Plugins are Nim modules under these roots, directly or one directory
  ## down, so a cloned repository works as it is.
  result = @[]
  for root in [getConfigDir() / "nish" / "plugins", getDataDir() / "nish" / "plugins"]:
    if dirExists(root):
      result.add root
      for kind, path in walkDir(root):
        if kind == pcDir:
          result.add path

proc newSession*(): Session =
  let conf = newConfigRef()
  let cache = newIdentCache()
  let graph = newModuleGraph(cache, conf)
  connectPipelineCallbacks(graph)
  initDefines(conf.symbols)
  defineSymbol(conf.symbols, "nimscript")
  # Includes `system/nimscript`: `cd`, `getEnv`, `exec`, `listFiles` and the
  # rest of the API `.nims` files have, implemented by `setupVM`.
  defineSymbol(conf.symbols, "nimconfig")
  let lib = stdlibDir()
  let api = nishapiDir()
  conf.libpath = AbsoluteDir lib
  for dir in ["", "pure", "core", "pure/collections", "impure", "std"]:
    conf.searchPaths.add AbsoluteDir(lib / dir)
  conf.searchPaths.add AbsoluteDir api
  for dir in pluginDirs():
    conf.searchPaths.add AbsoluteDir dir
  conf.errorMax = high(int)
  conf.spellSuggestMax = 0
  conf.notes.excl hintQuitCalled # `exit` at the prompt is not news

  let module = graph.makeStdinModule()
  module.incl sfMainModule
  let idgen = idGeneratorFromModule(module)
  let vm = setupVM(module, cache, "nish", graph, idgen)
  vm.features.incl allowInfiniteLoops
  let session = Session(graph: graph, module: module, apiDir: api)
  registerHostProcs(
    vm,
    getPackageName(conf, api / "nishapi.nim"),
    proc(prefix: string): seq[string] =
      session.symbolNames(prefix),
  )
  graph.vm = vm
  graph.setPipeLinePass(EvalPass)
  graph.compilePipelineSystemModule()

  session.ctx = preparePContext(graph, module, idgen)
  session.backend = setupEvalGen(graph, module, idgen)
  doAssert session.evalNim("import nishapi"), "nish could not load its API"
  session
