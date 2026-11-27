vim9script
# Unit tests for the "rootDir" and "configForRoot" language server settings
# (a language server instance per workspace root, with a per-root
# configuration)

source common.vim

import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/origin.vim'
import '../autoload/lsp/symbol.vim'
import '../autoload/lsp/util.vim' as util

const GOPLS = exepath('gopls')

# The "rootDir" and "configForRoot" functions of the registered servers call
# the functions in g:TestHooks[<server name>], which each test sets.  Without
# a "rootDir" test function, a server declines all the buffers, so that it
# doesn't interfere with the other tests.  Without a "configForRoot" test
# function, a server uses the registration as is.
g:TestHooks = {}

def RootDir(name: string, bnr: number, OnRoot: func)
  var hooks = g:TestHooks->get(name, {})
  if hooks->has_key('rootDir')
    var F = hooks.rootDir
    F(bnr, OnRoot)
  endif
enddef

def ConfigForRoot(name: string, root: string, Done: func)
  var hooks = g:TestHooks->get(name, {})
  if hooks->has_key('configForRoot')
    var F = hooks.configForRoot
    F(root, Done)
  else
    Done({})
  endif
enddef

var lspServers: list<dict<any>> = []
for name in ['gopls-a', 'gopls-b']
  lspServers->add({
    name: name,
    filetype: ['go'],
    path: GOPLS,
    args: ['serve'],
    rootDir: function(RootDir, [name]),
    configForRoot: function(ConfigForRoot, [name])
  })
endfor
# Without a path: the "configForRoot" function provides it
lspServers->add({
  name: 'gopls-c',
  filetype: ['go'],
  rootDir: function(RootDir, ['gopls-c']),
  configForRoot: function(ConfigForRoot, ['gopls-c'])
})
g:LspAddServer(lspServers)

# Returns the nearest directory above the file in buffer "bnr" that contains
# "marker"
def FindRoot(bnr: number, marker: string): string
  var found = findfile(marker, bnr->bufname()->fnamemodify(':p:h') .. ';')
  return found->empty() ? '' : found->fnamemodify(':p:h')
enddef

# A "rootDir" function: the root is the nearest directory with a "go.mod"
def GoModRoot(bnr: number, OnRoot: func)
  OnRoot(lsp#lsp#DefaultRootDir(bnr, ['go.mod']))
enddef

# Create a Go module in directory "dir" with the files "fnames"
def CreateModule(dir: string, fnames: list<string> = ['main.go', 'util.go'])
  mkdir(dir, 'p')
  writefile([$'module example.com/{dir->fnamemodify(':t')}', '', 'go 1.21'],
	    $'{dir}/go.mod')
  for fname in fnames
    writefile(['package main'], $'{dir}/{fname}')
  endfor
enddef

# Returns the language servers attached to buffer "bnr"
def Servers(bnr: number = bufnr()): list<dict<any>>
  return buf.BufLspServersGet(bnr)->copy()->filter((_, s) => !s->empty())
enddef

# Stop the language servers of all the buffers, and remove the buffers, the
# test directories and the test hooks
def Cleanup(dirs: list<string>)
  for binfo in getbufinfo()
    for lspserver in Servers(binfo.bufnr)
      if lspserver.running
	lspserver.stopServer()
      endif
    endfor
  endfor
  :%bw!
  g:TestHooks = {}
  for dir in dirs
    delete(dir, 'rf')
  endfor
enddef

# Edit file "fname" and return the language server attached to it after the
# server is ready.
def EditAndGetServer(fname: string): dict<any>
  exe $'silent! edit {fname}'
  var lspservers = Servers()
  assert_equal(1, lspservers->len())
  if lspservers->empty()
    return {}
  endif
  var lspserver = lspservers[0]
  g:WaitForAssert(() => assert_true(lspserver.ready), 10000)
  return lspserver
enddef

# Assert that "lspserver" was started with "dir" as the workspace root
def AssertServerRoot(lspserver: dict<any>, dir: string)
  var rootPath = dir->fnamemodify(':p')
  assert_equal([rootPath], lspserver.workspaceFolders)
  var initReq = lspserver.rpcInitializeRequest
  assert_equal(util.LspFileToUri(rootPath), initReq.rootUri)
  assert_equal([util.LspFileToUri(rootPath)],
	       initReq.workspaceFolders->mapnew((_, f) => f.uri))
enddef

# Assert that the process of "lspserver" is running in the directory "dir"
def AssertServerCwd(lspserver: dict<any>, dir: string)
  var procCwd = $'/proc/{lspserver.job->job_info().process}/cwd'
  if !isdirectory(procCwd)
    # Not supported on this system
    return
  endif
  assert_equal(dir->fnamemodify(':p')->resolve()->trim('/', 2),
	       procCwd->resolve()->trim('/', 2))
enddef

# U2, U3: a separate server instance for each root.  The roots are two
# worktrees with the same module name.
def g:Test_RootDir_InstancePerRoot()
  for dir in ['XU2a', 'XU2b']
    CreateModule(dir)
    writefile(['module example.com/worktree', '', 'go 1.21'], $'{dir}/go.mod')
  endfor
  g:TestHooks['gopls-a'] = {rootDir: GoModRoot}

  var srv1 = EditAndGetServer('XU2a/main.go')
  var srv2 = EditAndGetServer('XU2b/main.go')
  assert_equal('gopls-a', srv1.name)
  assert_equal('gopls-a', srv2.name)
  assert_notequal(srv1.id, srv2.id)
  AssertServerRoot(srv1, 'XU2a')
  AssertServerRoot(srv2, 'XU2b')
  AssertServerCwd(srv1, 'XU2a')
  AssertServerCwd(srv2, 'XU2b')

  # Another file in the same root uses the same server instance
  assert_equal(srv1.id, EditAndGetServer('XU2a/util.go').id)
  assert_equal(srv2.id, EditAndGetServer('XU2b/util.go').id)

  Cleanup(['XU2a', 'XU2b'])
enddef

# U4: the values returned by "configForRoot" override the registration.  The
# path can come from "configForRoot" only.
def g:Test_ConfigForRoot_PerRootConfig()
  CreateModule('XU4a')
  CreateModule('XU4b')
  # A wrapper script for gopls, used as the server path for one root
  mkdir('XU4b/bin', 'p')
  writefile(['#!/bin/sh', $'exec "{GOPLS}" "$@"'], 'XU4b/bin/gopls-wrapper')
  setfperm('XU4b/bin/gopls-wrapper', 'rwxr-xr-x')
  var wrapper = 'XU4b/bin/gopls-wrapper'->fnamemodify(':p')

  var roots: list<string> = []
  g:TestHooks['gopls-c'] = {
    rootDir: GoModRoot,
    configForRoot: (root: string, Done: func) => {
      roots->add(root)
      if root =~ 'XU4a'
	Done({path: GOPLS, args: ['serve'],
	      initializationOptions: {hoverKind: 'NoDocumentation'},
	      workspaceConfig: {gopls: {hoverKind: 'NoDocumentation'}}})
      else
	Done({path: wrapper, args: ['serve'],
	      initializationOptions: {hoverKind: 'FullDocumentation'}})
      endif
    }
  }

  var srv1 = EditAndGetServer('XU4a/main.go')
  var srv2 = EditAndGetServer('XU4b/main.go')
  assert_equal(['XU4a'->fnamemodify(':p'), 'XU4b'->fnamemodify(':p')], roots)
  assert_notequal(srv1.id, srv2.id)
  assert_equal('gopls-c', srv1.name)
  assert_equal(GOPLS, srv1.path)
  assert_equal(wrapper, srv2.path)
  assert_equal({hoverKind: 'NoDocumentation'},
	       srv1.rpcInitializeRequest.initializationOptions)
  assert_equal({hoverKind: 'FullDocumentation'},
	       srv2.rpcInitializeRequest.initializationOptions)
  assert_equal({gopls: {hoverKind: 'NoDocumentation'}}, srv1.workspaceConfig)
  assert_equal({}, srv2.workspaceConfig)
  AssertServerRoot(srv1, 'XU4a')
  AssertServerRoot(srv2, 'XU4b')

  Cleanup(['XU4a', 'XU4b'])
enddef

# The values returned by "configForRoot" are normalized like the
# registration.  The values used before a server instance exists cannot be
# overridden.
def g:Test_ConfigForRoot_Normalization()
  for dir in ['XNorm1', 'XNorm2', 'XNorm3', 'XNorm4']
    CreateModule(dir)
  endfor
  g:TestHooks['gopls-c'] = {
    rootDir: GoModRoot,
    configForRoot: (root: string, Done: func) => {
      if root =~ 'XNorm1'
	Done({path: GOPLS, traceLevel: 'verbose', name: 'other',
	      filetype: ['c'], clientCapabilities: {experimental: {x: true}}})
      elseif root =~ 'XNorm2'
	Done({path: GOPLS, traceLevel: 'messages', args: 'serve'})
      elseif root =~ 'XNorm3'
	# No path
	Done({args: ['serve']})
      else
	Done('not a dict')
      endif
    }
  }

  :edit XNorm1/main.go
  var srv = Servers()[0]
  assert_equal('gopls-c', srv.name)
  assert_equal('verbose', srv.traceLevel)
  assert_equal([], srv.args)
  assert_equal({experimental: {x: true}}, srv.clientCapabilities)
  assert_equal({}, srv.initializationOptions)

  # An invalid value: no server instance
  :messages clear
  :edit XNorm2/main.go
  assert_equal([], Servers())
  assert_match('Arguments for LSP server serve is not a List',
	       execute('messages'))

  :messages clear
  :edit XNorm3/main.go
  assert_equal([], Servers())
  assert_match('configForRoot of LSP server "gopls-c" did not return a path',
	       execute('messages'))

  :messages clear
  :edit XNorm4/main.go
  assert_equal([], Servers())
  assert_match('configForRoot of LSP server "gopls-c" returned a value that is not a Dict',
	       execute('messages'))

  Cleanup(['XNorm1', 'XNorm2', 'XNorm3', 'XNorm4'])
enddef

# U5: a server declines the buffers by not calling back.  "gopls-a" is used
# for the roots with a "PROVIDES" file, "gopls-b" for the other roots.
def g:Test_RootDir_Decline()
  for dir in ['XU5c', 'XU5w1', 'XU5w3']
    CreateModule(dir)
  endfor
  writefile([], 'XU5w1/PROVIDES')
  g:TestHooks['gopls-a'] = {
    rootDir: (bnr: number, OnRoot: func) => {
      var root = FindRoot(bnr, 'go.mod')
      if filereadable($'{root}/PROVIDES')
	OnRoot(root)
      endif
    }
  }
  g:TestHooks['gopls-b'] = {
    rootDir: (bnr: number, OnRoot: func) => {
      var root = FindRoot(bnr, 'go.mod')
      if !filereadable($'{root}/PROVIDES')
	OnRoot(root)
      endif
    }
  }

  # The order of opening doesn't matter
  var srvc = EditAndGetServer('XU5c/main.go')
  var srvw1 = EditAndGetServer('XU5w1/main.go')
  var srvw3 = EditAndGetServer('XU5w3/main.go')
  assert_equal('gopls-b', srvc.name)
  assert_equal('gopls-a', srvw1.name)
  assert_equal('gopls-b', srvw3.name)
  AssertServerRoot(srvc, 'XU5c')
  AssertServerRoot(srvw1, 'XU5w1')
  AssertServerRoot(srvw3, 'XU5w3')

  Cleanup(['XU5c', 'XU5w1', 'XU5w3'])
enddef

# U6: "Done(v:null)" doesn't start a server, and is not cached: the next
# buffer with the same root calls "configForRoot" again.
def g:Test_ConfigForRoot_NotNow()
  CreateModule('XU6')
  var calls = 0
  var built = false
  g:TestHooks['gopls-a'] = {
    rootDir: GoModRoot,
    configForRoot: (root: string, Done: func) => {
      calls += 1
      Done(built ? {} : v:null)
    }
  }

  # Called once, although both BufReadPost and FileType add the buffer
  :edit XU6/main.go
  assert_equal(1, calls)
  assert_equal([], Servers())
  # Setting the file type asks again
  :setlocal filetype=go
  assert_equal(2, calls)
  assert_equal([], Servers())

  built = true
  var srv = EditAndGetServer('XU6/util.go')
  assert_equal(3, calls)
  assert_equal('gopls-a', srv.name)
  AssertServerRoot(srv, 'XU6')

  # The server instance is reused
  :edit XU6/main.go
  assert_equal(3, calls)
  assert_equal([srv.id], Servers()->mapnew((_, s) => s.id))

  Cleanup(['XU6'])
enddef

# U8: the root is not the nearest marker: one server instance for a Go
# workspace with several modules.
def g:Test_RootDir_WorkspaceRoot()
  CreateModule('XU8/m1')
  CreateModule('XU8/m2')
  writefile(['go 1.21', '', 'use (', '  ./m1', '  ./m2', ')'], 'XU8/go.work')
  g:TestHooks['gopls-a'] = {
    rootDir: (bnr: number, OnRoot: func) => OnRoot(FindRoot(bnr, 'go.work'))
  }

  var srv1 = EditAndGetServer('XU8/m1/main.go')
  var srv2 = EditAndGetServer('XU8/m2/main.go')
  assert_equal(srv1.id, srv2.id)
  AssertServerRoot(srv1, 'XU8')
  AssertServerCwd(srv1, 'XU8')

  Cleanup(['XU8'])
enddef

# U9: a file without a root
def g:Test_RootDir_NoRoot()
  mkdir('XU9', 'p')
  writefile(['package main'], 'XU9/scratch.go')
  g:TestHooks['gopls-a'] = {
    rootDir: (bnr: number, OnRoot: func) => OnRoot('')
  }

  :edit XU9/scratch.go
  var lspservers = Servers()
  assert_equal(1, lspservers->len())
  assert_equal([], lspservers[0].workspaceFolders)
  assert_equal(v:null, lspservers[0].rpcInitializeRequest.rootUri)

  Cleanup(['XU9'])
enddef

# U13: the buffers opened while "configForRoot" is in progress are attached to
# the single server instance created for their root.
def g:Test_ConfigForRoot_ConcurrentOpens()
  CreateModule('XU13', ['a.go', 'b.go', 'c.go'])
  var calls = 0
  g:TestHooks['gopls-a'] = {
    rootDir: GoModRoot,
    configForRoot: (root: string, Done: func) => {
      calls += 1
      timer_start(300, (_) => Done({}))
    }
  }

  :set hidden
  for fname in ['a.go', 'b.go', 'c.go']
    exe $'edit XU13/{fname}'
    assert_equal([], Servers())
  endfor
  assert_equal(1, calls)

  var bnrs = ['a.go', 'b.go', 'c.go']->mapnew((_, f) => bufnr($'XU13/{f}'))
  g:WaitForAssert(() => assert_equal(1, Servers(bnrs[0])->len()))
  var srv = Servers(bnrs[0])[0]
  for bnr in bnrs
    assert_equal([srv.id], Servers(bnr)->mapnew((_, s) => s.id))
  endfor
  assert_equal(1, calls)
  g:WaitForAssert(() => assert_true(srv.ready), 10000)
  AssertServerRoot(srv, 'XU13')

  :set hidden&
  Cleanup(['XU13'])
enddef

# A late "rootDir" callback for a buffer that was wiped out, or whose file
# type changed, is ignored.
def g:Test_RootDir_LateCallback()
  CreateModule('XLate')
  var calls = 0
  g:TestHooks['gopls-a'] = {
    rootDir: (bnr: number, OnRoot: func) => {
      timer_start(100, (_) => OnRoot(FindRoot(bnr, 'go.mod')))
    },
    configForRoot: (root: string, Done: func) => {
      calls += 1
      Done({})
    }
  }

  :edit XLate/main.go
  :bwipe!
  :edit XLate/util.go
  :setlocal filetype=text
  sleep 300m
  assert_equal(0, calls)
  assert_equal([], Servers())

  Cleanup(['XLate'])
enddef

# Returns the ids of the language servers attached to the file "fname"
def ServerIds(fname: string): list<number>
  return Servers(bufnr(fname))->mapnew((_, s) => s.id)
enddef

# U10: ":LspServer restart", "stop" and "start" act only on the server
# instances for the root of the current buffer.
def g:Test_RootDir_PerRootLifecycle()
  CreateModule('XU10a')
  CreateModule('XU10b')
  g:TestHooks['gopls-a'] = {rootDir: GoModRoot}

  :set hidden
  var srv1 = EditAndGetServer('XU10a/main.go')
  var srv1b = EditAndGetServer('XU10a/util.go')
  assert_equal(srv1.id, srv1b.id)
  var srv2 = EditAndGetServer('XU10b/main.go')
  EditAndGetServer('XU10b/util.go')
  var pid1 = srv1.job->job_info().process

  # Restart in root "b": a new server instance for "b", with the same root,
  # attached to all the buffers of "b".  The server for "a" is not changed.
  :LspServer restart
  var newSrv2 = Servers()[0]
  assert_notequal(srv2.id, newSrv2.id)
  assert_false(srv2.running)
  g:WaitForAssert(() => assert_true(newSrv2.ready), 10000)
  AssertServerRoot(newSrv2, 'XU10b')
  AssertServerCwd(newSrv2, 'XU10b')
  assert_equal([newSrv2.id], ServerIds('XU10b/main.go'))
  assert_equal([newSrv2.id], ServerIds('XU10b/util.go'))
  assert_equal(pid1, srv1.job->job_info().process)
  assert_equal('run', srv1.job->job_status())
  assert_equal([srv1.id], ServerIds('XU10a/main.go'))
  assert_equal([srv1.id], ServerIds('XU10a/util.go'))

  # Stop in root "a": only the server for "a" is stopped
  :edit XU10a/main.go
  :LspServer stop
  assert_false(srv1.running)
  assert_equal([], ServerIds('XU10a/main.go'))
  assert_equal([], ServerIds('XU10a/util.go'))
  assert_true(newSrv2.running)
  assert_equal([newSrv2.id], ServerIds('XU10b/main.go'))
  # A stopped server is not started for a new buffer
  :edit XU10a/other.go
  assert_equal([], Servers())

  # Start in root "a": the same server instance is started again
  :edit XU10a/main.go
  :LspServer start
  assert_true(srv1.running)
  g:WaitForAssert(() => assert_true(srv1.ready), 10000)
  assert_equal([srv1.id], ServerIds('XU10a/main.go'))
  assert_equal([srv1.id], ServerIds('XU10a/util.go'))
  assert_equal([srv1.id], ServerIds('XU10a/other.go'))
  assert_equal([newSrv2.id], ServerIds('XU10b/main.go'))

  # ":LspShowAllServers" lists each server instance with its root
  :LspShowAllServers
  var lines = getline(1, '$')
  :close
  for [dir, status] in [['XU10a', 'Running'], ['XU10b', 'Running']]
    var idx = lines->index($"Server Root: '{dir->fnamemodify(':p')}'")
    assert_notequal(-1, idx)
    assert_equal("Server Name: 'gopls-a'", lines[idx - 2])
    assert_equal($'Status: {status}', lines[idx + 1])
  endfor

  :set hidden&
  Cleanup(['XU10a', 'XU10b'])
enddef

# U11: ":LspServer restart" computes the configuration again
def g:Test_ConfigForRoot_RestartRecomputes()
  CreateModule('XU11')
  var calls = 0
  g:TestHooks['gopls-a'] = {
    rootDir: GoModRoot,
    configForRoot: (root: string, Done: func) => {
      calls += 1
      Done({initializationOptions:
		{hoverKind: calls == 1 ? 'NoDocumentation' : 'FullDocumentation'}})
    }
  }

  var srv = EditAndGetServer('XU11/main.go')
  assert_equal(1, calls)
  assert_equal({hoverKind: 'NoDocumentation'},
	       srv.rpcInitializeRequest.initializationOptions)

  :LspServer restart
  assert_equal(2, calls)
  var newSrv = Servers()[0]
  assert_notequal(srv.id, newSrv.id)
  g:WaitForAssert(() => assert_true(newSrv.ready), 10000)
  assert_equal({hoverKind: 'FullDocumentation'},
	       newSrv.rpcInitializeRequest.initializationOptions)

  # A restart after "not now": no server, until the configuration is
  # available
  calls = 0
  g:TestHooks['gopls-a'].configForRoot = (root: string, Done: func) => {
    calls += 1
    Done(calls == 1 ? v:null : {})
  }
  :LspServer restart
  assert_equal(1, calls)
  assert_false(newSrv.running)
  assert_equal([], Servers())
  :LspServer restart
  assert_equal(2, calls)
  assert_equal(1, Servers()->len())
  g:WaitForAssert(() => assert_true(Servers()[0].ready), 10000)

  Cleanup(['XU11'])
enddef

# While "configForRoot" is in progress, ":LspShowAllServers" shows the root
# as waiting for it.
def g:Test_ConfigForRoot_ShowPending()
  CreateModule('XPending')
  var Callback: func = null_function
  g:TestHooks['gopls-a'] = {
    rootDir: GoModRoot,
    configForRoot: (root: string, Done: func) => {
      Callback = Done
    }
  }

  :edit XPending/main.go
  :LspShowAllServers
  var lines = getline(1, '$')
  :close
  var idx = lines->index($"Server Root: '{'XPending'->fnamemodify(':p')}'")
  assert_notequal(-1, idx)
  assert_equal("Server Name: 'gopls-a'", lines[idx - 1])
  assert_equal('Status: Waiting for configForRoot', lines[idx + 1])

  Callback({})
  assert_equal(1, Servers()->len())
  g:WaitForAssert(() => assert_true(Servers()[0].ready), 10000)
  # A second call is ignored
  Callback({})
  assert_equal(1, Servers()->len())

  Cleanup(['XPending'])
enddef

# Returns the full paths of the directories "dirs"
def FullPaths(dirs: list<string>): list<string>
  return dirs->mapnew((_, dir) => dir->fnamemodify(':p'))
enddef

# The lsp#lsp#ServerRoots() of "gopls-a" for the buffer, when the "rootDir"
# function set by LibraryHooks() was last called for a library file
var libRoots: list<string> = []

# Set the "rootDir" function of "gopls-a": the files below "libDir" get the
# root of their origin, else the most recently used root (U7), with
# lsp#lsp#ServerRoots(), the other files the root of their Go module.
def LibraryHooks(libDir: string)
  var fullLibDir = libDir->fnamemodify(':p')
  libRoots = []
  g:TestHooks['gopls-a'] = {
    rootDir: (bnr: number, OnRoot: func) => {
      if bnr->bufname()->fnamemodify(':p')->stridx(fullLibDir) == 0
	libRoots = lsp#lsp#ServerRoots('gopls-a', bnr)
	if !libRoots->empty()
	  OnRoot(libRoots[-1])
	endif
      else
	GoModRoot(bnr, OnRoot)
      endif
    }
  }
enddef

# U7: a "rootDir" function maps the library files to the root of the most
# recently used server instance, with lsp#lsp#ServerRoots().
def g:Test_RootDir_LibraryFiles()
  CreateModule('XU7a')
  CreateModule('XU7b')
  # A library module, e.g. in the Go module cache
  CreateModule('XU7lib/dep', ['dep.go', 'dep2.go', 'dep3.go'])
  LibraryHooks('XU7lib')

  var srva = EditAndGetServer('XU7a/main.go')
  assert_equal(FullPaths(['XU7a']), lsp#lsp#ServerRoots('gopls-a'))
  :edit XU7lib/dep/dep.go
  assert_equal([srva.id], ServerIds('%'))

  var srvb = EditAndGetServer('XU7b/main.go')
  legacy let g:Roots = lsp#lsp#ServerRoots('gopls-a')
  assert_equal(FullPaths(['XU7a', 'XU7b']), g:Roots)

  # The server instance started first, used last.  The "rootDir" function of
  # the library file is called before the library file is entered: the
  # buffer it is opened from is the most recently used.
  EditAndGetServer('XU7a/util.go')
  assert_equal(FullPaths(['XU7b', 'XU7a']), lsp#lsp#ServerRoots('gopls-a'))
  :edit XU7lib/dep/dep2.go
  assert_equal(FullPaths(['XU7b', 'XU7a']), libRoots)
  assert_equal([srva.id], ServerIds('%'))
  assert_equal(FullPaths(['XU7b', 'XU7a']), lsp#lsp#ServerRoots('gopls-a'))

  # The server instance started last, used last
  EditAndGetServer('XU7b/util.go')
  :edit XU7lib/dep/dep3.go
  assert_equal(FullPaths(['XU7a', 'XU7b']), libRoots)
  assert_equal([srvb.id], ServerIds('%'))

  # Only the running server instances are returned
  :edit XU7a/main.go
  :LspServer stop
  assert_equal(FullPaths(['XU7b']), lsp#lsp#ServerRoots('gopls-a'))
  assert_equal([], lsp#lsp#ServerRoots('no-such-server'))

  unlet g:Roots
  Cleanup(['XU7a', 'XU7b', 'XU7lib'])
enddef

# U7: going to another window uses the server instance of its buffer
def g:Test_RootDir_LibraryFilesWindows()
  CreateModule('XU7wa')
  CreateModule('XU7wb')
  CreateModule('XU7wlib/dep', ['dep.go', 'dep2.go'])
  LibraryHooks('XU7wlib')

  var srva = EditAndGetServer('XU7wa/main.go')
  :split
  var srvb = EditAndGetServer('XU7wb/main.go')
  assert_equal(FullPaths(['XU7wa', 'XU7wb']), lsp#lsp#ServerRoots('gopls-a'))
  :wincmd p
  assert_equal(FullPaths(['XU7wb', 'XU7wa']), lsp#lsp#ServerRoots('gopls-a'))
  :wincmd p
  assert_equal(FullPaths(['XU7wa', 'XU7wb']), lsp#lsp#ServerRoots('gopls-a'))

  :wincmd p
  :edit XU7wlib/dep/dep.go
  assert_equal([srva.id], ServerIds('%'))
  :wincmd p
  :edit XU7wlib/dep/dep2.go
  assert_equal([srvb.id], ServerIds('%'))

  :only
  Cleanup(['XU7wa', 'XU7wb', 'XU7wlib'])
enddef

# U7: the quickfix window is not attached to a server instance.  A file opened
# from it gets the root of the buffer used before it.
def g:Test_RootDir_LibraryFilesQuickfix()
  CreateModule('XU7qa')
  CreateModule('XU7qb')
  CreateModule('XU7qlib/dep', ['dep.go'])
  LibraryHooks('XU7qlib')

  var srva = EditAndGetServer('XU7qa/main.go')
  EditAndGetServer('XU7qb/main.go')
  # The server instance started first, used last
  EditAndGetServer('XU7qa/util.go')
  setqflist([{filename: 'XU7qlib/dep/dep.go', lnum: 1}])
  :copen
  assert_equal('quickfix', &buftype)
  assert_equal(FullPaths(['XU7qb', 'XU7qa']), lsp#lsp#ServerRoots('gopls-a'))
  :cc 1
  assert_equal('XU7qlib/dep/dep.go'->fnamemodify(':p'), expand('%:p'))
  assert_equal([srva.id], ServerIds('%'))

  :cclose
  setqflist([], 'f')
  :only
  Cleanup(['XU7qa', 'XU7qb', 'XU7qlib'])
enddef

# Returns a LSP location at the start of the file "fname"
def Location(fname: string): dict<any>
  var pos = {line: 0, character: 0}
  return {uri: util.LspFileToUri(fname), range: {start: pos, end: pos}}
enddef

# U7: a library file opened from the answer of a server instance (e.g. going
# to a definition) gets the root of that instance, even when another window
# is current (e.g. after going to it while the answer was awaited).
def g:Test_RootDir_LibraryFilesJumpOrigin()
  CreateModule('XU7ja')
  CreateModule('XU7jb')
  CreateModule('XU7jlib/dep', ['dep.go', 'dep2.go'])
  LibraryHooks('XU7jlib')

  :set hidden
  var srva = EditAndGetServer('XU7ja/main.go')
  :split
  var srvb = EditAndGetServer('XU7jb/main.go')
  assert_equal(FullPaths(['XU7ja', 'XU7jb']), lsp#lsp#ServerRoots('gopls-a'))

  # The answer of "srva" opens the file in the window of "XU7jb"
  symbol.GotoSymbol(srva, Location('XU7jlib/dep/dep.go'), false, '')
  assert_equal('XU7jlib/dep/dep.go'->fnamemodify(':p'), expand('%:p'))
  assert_equal(FullPaths(['XU7jb', 'XU7ja']), libRoots)
  assert_equal([srva.id], ServerIds('%'))
  var bnr = bufnr()

  # With the buffer, the root of its origin is last
  :edit XU7jb/main.go
  assert_equal(FullPaths(['XU7ja', 'XU7jb']), lsp#lsp#ServerRoots('gopls-a'))
  assert_equal(FullPaths(['XU7jb', 'XU7ja']),
	       lsp#lsp#ServerRoots('gopls-a', bnr))
  # Without an origin, the order of last use
  assert_equal(FullPaths(['XU7ja', 'XU7jb']),
	       lsp#lsp#ServerRoots('gopls-a', bufnr()))

  # The origin is not used for a file opened later
  :edit XU7jlib/dep/dep2.go
  assert_equal(FullPaths(['XU7ja', 'XU7jb']), libRoots)
  assert_equal([srvb.id], ServerIds('%'))
  exe $'bwipe! {bnr}'
  :edit XU7jb/main.go
  :edit XU7jlib/dep/dep.go
  assert_equal(FullPaths(['XU7ja', 'XU7jb']), libRoots)
  assert_equal([srvb.id], ServerIds('%'))

  :set hidden&
  :only
  Cleanup(['XU7ja', 'XU7jb', 'XU7jlib'])
enddef

# U7: a library file opened from a quickfix or location list filled with the
# answer of a server instance gets the root of that instance, even after
# going to a window of another root.
def g:Test_RootDir_LibraryFilesListOrigin()
  CreateModule('XU7la')
  CreateModule('XU7lb')
  CreateModule('XU7llib/dep',
	       ['dep.go', 'dep2.go', 'dep3.go', 'dep4.go', 'dep5.go'])
  LibraryHooks('XU7llib')
  var savedUseQuickfix = g:LspOptionsGet().useQuickfixForLocations

  :set hidden
  var srva = EditAndGetServer('XU7la/main.go')
  :split
  var srvb = EditAndGetServer('XU7lb/main.go')
  :wincmd p
  assert_equal(FullPaths(['XU7lb', 'XU7la']), lsp#lsp#ServerRoots('gopls-a'))

  # The references from "srva" in the quickfix list, then the window of
  # "XU7lb", then the library file opened from the list
  g:LspOptionsSet({useQuickfixForLocations: true})
  symbol.ShowLocations(srva, [Location('XU7llib/dep/dep.go')], false,
		       'Symbol References')
  :wincmd t
  :edit XU7lb/main.go
  assert_equal(FullPaths(['XU7la', 'XU7lb']), lsp#lsp#ServerRoots('gopls-a'))
  assert_true(origin.Find(bufnr('XU7llib/dep/dep.go')) is srva)
  :cc 1
  assert_equal('XU7llib/dep/dep.go'->fnamemodify(':p'), expand('%:p'))
  assert_equal([srva.id], ServerIds('%'))
  :cclose

  # A file of the list that is loaded when opened from the list
  :edit XU7lb/main.go
  setqflist([], ' ',
	    {context: origin.ListContext(srva, ['XU7llib/dep/dep2.go']),
	     items: [{filename: 'XU7llib/dep/dep2.go', lnum: 1}]})
  assert_false(bufloaded('XU7llib/dep/dep2.go'))
  :cc 1
  assert_equal(FullPaths(['XU7lb', 'XU7la']), libRoots)
  assert_equal([srva.id], ServerIds('%'))
  # Not from a list filled otherwise
  :edit XU7lb/main.go
  setqflist([{filename: 'XU7llib/dep/dep3.go', lnum: 1}])
  :cc 1
  assert_equal([srvb.id], ServerIds('%'))

  # A location list, also when copied to a new window
  :edit XU7lb/main.go
  setloclist(0, [], ' ',
	     {context: origin.ListContext(srva, ['XU7llib/dep/dep4.go']),
	      items: [{filename: 'XU7llib/dep/dep4.go', lnum: 1}]})
  :split
  :ll 1
  assert_equal([srva.id], ServerIds('%'))

  # The references from "srva" in the location list of the window
  g:LspOptionsSet({useQuickfixForLocations: false})
  var winid = win_getid()
  symbol.ShowLocations(srva, [Location('XU7llib/dep/dep5.go')], false,
		       'Symbol References')
  winid->win_gotoid()
  :edit XU7lb/main.go
  assert_true(origin.Find(bufnr('XU7llib/dep/dep5.go')) is srva)
  :lclose

  g:LspOptionsSet({useQuickfixForLocations: savedUseQuickfix})
  setqflist([], 'f')
  :set hidden&
  :only
  Cleanup(['XU7la', 'XU7lb', 'XU7llib'])
enddef

# U7, U10: ":LspServer stop" leaves the library files of the stopped server
# instance without a server, also when their 'filetype' is set again, and
# ":LspServer start" attaches them to it again
def g:Test_RootDir_LibraryFilesStop()
  CreateModule('XU7sa')
  CreateModule('XU7sb')
  CreateModule('XU7slib/dep', ['dep.go'])
  LibraryHooks('XU7slib')

  :set hidden
  var srva = EditAndGetServer('XU7sa/main.go')
  symbol.GotoSymbol(srva, Location('XU7slib/dep/dep.go'), false, '')
  assert_equal([srva.id], ServerIds('%'))
  var srvb = EditAndGetServer('XU7sb/main.go')

  :edit XU7sa/main.go
  :LspServer stop
  assert_false(srva.running)
  assert_equal([], ServerIds('XU7slib/dep/dep.go'))
  :edit XU7slib/dep/dep.go
  :edit
  assert_equal([], Servers())
  assert_equal([srvb.id], ServerIds('XU7sb/main.go'))

  :edit XU7sa/main.go
  :LspServer start
  g:WaitForAssert(() => assert_true(srva.ready), 10000)
  assert_equal([srva.id], ServerIds('XU7slib/dep/dep.go'))
  assert_equal([srvb.id], ServerIds('XU7sb/main.go'))

  # Also from the library file
  :edit XU7slib/dep/dep.go
  :LspServer stop
  assert_false(srva.running)
  assert_equal([], ServerIds('XU7sa/main.go'))
  :edit XU7sb/main.go
  :edit XU7slib/dep/dep.go
  :LspServer start
  g:WaitForAssert(() => assert_true(srva.ready), 10000)
  assert_equal([srva.id], ServerIds('XU7slib/dep/dep.go'))
  assert_equal([srva.id], ServerIds('XU7sa/main.go'))
  assert_equal([srvb.id], ServerIds('XU7sb/main.go'))

  :set hidden&
  Cleanup(['XU7sa', 'XU7sb', 'XU7slib'])
enddef

# The order of lsp#lsp#ServerRoots() after ":LspServer restart", "stop" and
# "start": the instance of the current buffer is the most recently used.
def g:Test_ServerRoots_Lifecycle()
  CreateModule('XOrdA')
  CreateModule('XOrdB')
  g:TestHooks['gopls-a'] = {rootDir: GoModRoot}

  :set hidden
  EditAndGetServer('XOrdA/main.go')
  EditAndGetServer('XOrdB/main.go')
  EditAndGetServer('XOrdA/util.go')
  assert_equal(FullPaths(['XOrdB', 'XOrdA']), lsp#lsp#ServerRoots('gopls-a'))

  # The new server instance replaces the old one in the order
  :LspServer restart
  assert_equal(FullPaths(['XOrdB', 'XOrdA']), lsp#lsp#ServerRoots('gopls-a'))
  g:WaitForAssert(() => assert_true(Servers()[0].ready), 10000)
  :edit XOrdB/main.go
  assert_equal(FullPaths(['XOrdA', 'XOrdB']), lsp#lsp#ServerRoots('gopls-a'))
  :LspServer restart
  assert_equal(FullPaths(['XOrdA', 'XOrdB']), lsp#lsp#ServerRoots('gopls-a'))
  g:WaitForAssert(() => assert_true(Servers()[0].ready), 10000)

  # A stopped instance is not returned, and is the most recently used when
  # started again
  :LspServer stop
  assert_equal(FullPaths(['XOrdA']), lsp#lsp#ServerRoots('gopls-a'))
  :LspServer start
  assert_equal(FullPaths(['XOrdA', 'XOrdB']), lsp#lsp#ServerRoots('gopls-a'))
  :edit XOrdA/main.go
  :LspServer stop
  :LspServer start
  assert_equal(FullPaths(['XOrdB', 'XOrdA']), lsp#lsp#ServerRoots('gopls-a'))

  :set hidden&
  Cleanup(['XOrdA', 'XOrdB'])
enddef

# lsp#lsp#DefaultRootDir() computes the root like a language server without a
# "rootDir" function
def g:Test_DefaultRootDir()
  CreateModule('XDefRoot')
  mkdir('XDefRoot/sub', 'p')
  writefile(['package sub'], 'XDefRoot/sub/sub.go')

  :edit XDefRoot/sub/sub.go
  assert_equal('XDefRoot'->fnamemodify(':p'),
	       lsp#lsp#DefaultRootDir(bufnr(), ['go.mod']))
  # Without a marker, the current directory (the file is below it)
  assert_equal(getcwd()->fnamemodify(':p'), lsp#lsp#DefaultRootDir(bufnr()))
  legacy let g:Root = lsp#lsp#DefaultRootDir(bufnr(), ['go.mod'])
  assert_equal('XDefRoot'->fnamemodify(':p'), g:Root)

  unlet g:Root
  Cleanup(['XDefRoot'])
enddef

# The language servers are started by the tests
def g:StartLangServer(): bool
  return true
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
