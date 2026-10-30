## The embedded NimScript VM.
##
## A session is one long-lived module, like the compiler's REPL (`nim
## secret`), but nish drives the parse, check and eval steps itself instead
## of calling `processPipelineModule`. That way an error in one input is
## reported and skipped while the module's scope, and everything defined in
## it, carries on to the next input.

import std/[compilesettings, os, strutils]
import
  compiler/[
    ast, condsyms, idents, lineinfos, llstream, lookups, modulegraphs, modules, options,
    parser, pathutils, pipelines, scriptconfig, sem, semdata, syntaxes, vm, vmdef,
  ]
import ./[commands, host]

type Session* = ref object
  graph: ModuleGraph
  module: PSym
  ctx: PContext
  backend: PPassContext

const
  # TODO: ship or embed these for installs. The VM compiles the stdlib from
  # source, so it needs the files at runtime, not only when building nish.
  stdlibDir = querySetting(libPath)
  scriptDir = currentSourcePath().parentDir / "script"

proc errorCount(s: Session): int =
  s.graph.config.errorCounter

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
    try:
      discard interpreterCode(s.backend, checked)
    except ERecoverableError:
      discard "the VM already reported it"
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
        findExe(name).len > 0,
  )

proc eval*(s: Session, input: string, line = 1): bool =
  ## Evaluates shell input: Nim with command lines mixed in.
  s.evalNim(translate(input, s.resolver), line)

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
  conf.libpath = AbsoluteDir stdlibDir
  for dir in ["", "pure", "core", "pure/collections", "impure", "std"]:
    conf.searchPaths.add AbsoluteDir(stdlibDir / dir)
  conf.searchPaths.add AbsoluteDir scriptDir
  conf.errorMax = high(int)
  conf.spellSuggestMax = 0

  let module = graph.makeStdinModule()
  module.incl sfMainModule
  let idgen = idGeneratorFromModule(module)
  let vm = setupVM(module, cache, "nish", graph, idgen)
  vm.features.incl allowInfiniteLoops
  registerHostProcs(vm, getPackageName(conf, scriptDir / "nishapi.nim"))
  graph.vm = vm
  graph.setPipeLinePass(EvalPass)
  graph.compilePipelineSystemModule()

  result = Session(
    graph: graph,
    module: module,
    ctx: preparePContext(graph, module, idgen),
    backend: setupEvalGen(graph, module, idgen),
  )
  doAssert result.evalNim("import nishapi"), "nish could not load its API"
