vim9script
# Unit tests for the "perRoot" language server setting and the "serverPerRoot"
# option (one language server instance per workspace root directory)

source common.vim

import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/util.vim' as util

# The language server "gopls" is used for the files below the current
# directory.  Each other language server is used for the files below a
# directory with a file named like the server, and "gopls" is not used for
# them.  The "perRoot" setting of a server without it is decided when its
# first buffer is opened, so each server is used by one test only.
const OTHER_SERVERS: dict<dict<any>> = {
  'gopls-on': {},
  'gopls-true': {perRoot: true},
  'gopls-false': {perRoot: false},
  'gopls-toggle': {},
  'gopls-late': {}
}
var lspServers = [{
      filetype: ['go'],
      path: exepath('gopls'),
      args: ['serve'],
      rootSearch: ['go.mod'],
      runUnlessSearch: OTHER_SERVERS->keys()
  }]
for [name, settings] in OTHER_SERVERS->items()
  lspServers->add({
      name: name,
      filetype: ['go'],
      path: exepath('gopls'),
      args: ['serve'],
      rootSearch: ['go.mod'],
      runIfSearch: [name]
    }->extend(settings))
endfor
call LspAddServer(lspServers)

# Create two Go modules (workspace roots) "Xroot1" and "Xroot2" in the
# directory "parent".  When "server" is not empty, the files in "parent" use
# the language server "server" (see OTHER_SERVERS).
def CreateRoots(parent: string = '.', server: string = '')
  for dir in ['Xroot1', 'Xroot2']
    mkdir($'{parent}/{dir}', 'p')
    writefile([$'module example.com/{dir}', '', 'go 1.21'],
	      $'{parent}/{dir}/go.mod')
    writefile(['package main', '', 'func main() {', '}'],
	      $'{parent}/{dir}/main.go')
    writefile(['package main'], $'{parent}/{dir}/util.go')
  endfor
  if !server->empty()
    writefile([], $'{parent}/{server}')
  endif
enddef

def DeleteRoots()
  delete('Xroot1', 'rf')
  delete('Xroot2', 'rf')
enddef

# Stop the language servers of all the buffers, and remove the buffers
def StopServersAndWipe()
  for binfo in getbufinfo()
    for lspserver in buf.BufLspServersGet(binfo.bufnr)
      if !lspserver->empty() && lspserver.running
	lspserver.stopServer()
      endif
    endfor
  endfor
  :%bw!
enddef

# Edit file "fname" and return the language server attached to it after the
# server is ready.
def EditAndGetServer(fname: string): dict<any>
  exe $'silent! edit {fname}'
  var lspservers = buf.BufLspServersGet(bufnr())
  assert_equal(1, lspservers->len())
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

# Test for the default behavior: a single server instance for all the roots
def g:Test_ServerPerRoot_Disabled()
  CreateRoots()
  g:LspOptionsSet({serverPerRoot: false})

  var srv1 = EditAndGetServer('Xroot1/main.go')
  var srv2 = EditAndGetServer('Xroot2/main.go')
  assert_equal(srv1.id, srv2.id)
  # The server runs in the current directory
  AssertServerCwd(srv1, getcwd())

  StopServersAndWipe()
  DeleteRoots()
enddef

# Test for a separate server instance for each root, with the "serverPerRoot"
# option
def g:Test_ServerPerRoot_Enabled()
  CreateRoots('XOn', 'gopls-on')
  g:LspOptionsSet({serverPerRoot: true})

  var srv1 = EditAndGetServer('XOn/Xroot1/main.go')
  var srv2 = EditAndGetServer('XOn/Xroot2/main.go')
  assert_notequal(srv1.id, srv2.id)
  AssertServerRoot(srv1, 'XOn/Xroot1')
  AssertServerRoot(srv2, 'XOn/Xroot2')
  # Each server instance runs in its root directory
  AssertServerCwd(srv1, 'XOn/Xroot1')
  AssertServerCwd(srv2, 'XOn/Xroot2')

  # Another file in the same root uses the same server instance
  var srv3 = EditAndGetServer('XOn/Xroot1/util.go')
  assert_equal(srv1.id, srv3.id)
  var srv4 = EditAndGetServer('XOn/Xroot2/util.go')
  assert_equal(srv2.id, srv4.id)

  assert_true(lsp#lsp#ServerRunning('go'))

  # Restarting the server should restart only the server for the root of the
  # current buffer
  var pid1 = srv1.job->job_info().process
  var pid2 = srv2.job->job_info().process
  :edit XOn/Xroot2/main.go
  :LspServer restart
  # The restart replaces the instance for the root of the current buffer
  var srv2new = EditAndGetServer('XOn/Xroot2/main.go')
  assert_notequal(pid2, srv2new.job->job_info().process)
  AssertServerRoot(srv2new, 'XOn/Xroot2')
  AssertServerCwd(srv2new, 'XOn/Xroot2')
  # Both buffers of the root are attached to the new instance
  assert_equal([srv2new.id],
	       buf.BufLspServersGet(bufnr('XOn/Xroot2/util.go'))->mapnew((_, s) => s.id))
  # The instance of the other root and its buffers are not affected
  assert_equal(pid1, srv1.job->job_info().process)
  assert_equal('run', srv1.job->job_status())
  for fname in ['XOn/Xroot1/main.go', 'XOn/Xroot1/util.go']
    assert_equal([srv1.id],
		 buf.BufLspServersGet(bufnr(fname))->mapnew((_, s) => s.id))
  endfor

  StopServersAndWipe()
  g:LspOptionsSet({serverPerRoot: false})
  delete('XOn', 'rf')
enddef

# Returns the ids of the server instances attached to the buffers of the files
# "fnames"
def ServerIds(fnames: list<string>): list<number>
  return fnames->mapnew((_, fname) => buf.BufLspServersGet(bufnr(fname))
			  ->mapnew((_, s) => s.id))->flattennew()
enddef

# "perRoot" set to true: an instance per root, without the option
def g:Test_PerRoot_True()
  CreateRoots('XTrue', 'gopls-true')
  g:LspOptionsSet({serverPerRoot: false})

  var srv1 = EditAndGetServer('XTrue/Xroot1/main.go')
  var srv2 = EditAndGetServer('XTrue/Xroot2/main.go')
  assert_equal('gopls-true', srv1.name)
  assert_notequal(srv1.id, srv2.id)
  AssertServerRoot(srv1, 'XTrue/Xroot1')
  AssertServerRoot(srv2, 'XTrue/Xroot2')
  assert_equal(srv1.id, EditAndGetServer('XTrue/Xroot1/util.go').id)

  StopServersAndWipe()
  delete('XTrue', 'rf')
enddef

# "perRoot" set to false: a single instance, even with the option
def g:Test_PerRoot_False()
  CreateRoots('XFalse', 'gopls-false')
  g:LspOptionsSet({serverPerRoot: true})

  var srv1 = EditAndGetServer('XFalse/Xroot1/main.go')
  var srv2 = EditAndGetServer('XFalse/Xroot2/main.go')
  assert_equal('gopls-false', srv1.name)
  assert_equal(srv1.id, srv2.id)
  AssertServerCwd(srv1, getcwd())
  # The root is computed from the buffer that starts the server
  AssertServerRoot(srv1, 'XFalse/Xroot1')

  StopServersAndWipe()
  g:LspOptionsSet({serverPerRoot: false})
  delete('XFalse', 'rf')
enddef

# Changing the "serverPerRoot" option does not change a language server that
# was already used: the running single instance stays the only one.  A
# language server that was not used yet uses the new value.
def g:Test_PerRoot_OptionChanged()
  CreateRoots('XToggle', 'gopls-toggle')
  CreateRoots('XLate', 'gopls-late')
  g:LspOptionsSet({serverPerRoot: false})

  :set hidden
  var srv1 = EditAndGetServer('XToggle/Xroot1/main.go')
  g:LspOptionsSet({serverPerRoot: true})
  var srv2 = EditAndGetServer('XToggle/Xroot2/main.go')
  assert_equal(srv1.id, srv2.id)
  AssertServerRoot(srv1, 'XToggle/Xroot1')
  # Also after a restart
  :LspServer restart
  var srv3 = EditAndGetServer('XToggle/Xroot2/util.go')
  assert_notequal(srv1.id, srv3.id)
  assert_equal([srv3.id, srv3.id, srv3.id],
	       ServerIds(['XToggle/Xroot1/main.go', 'XToggle/Xroot2/main.go',
			  'XToggle/Xroot2/util.go']))
  AssertServerRoot(srv3, 'XToggle/Xroot2')

  var late1 = EditAndGetServer('XLate/Xroot1/main.go')
  var late2 = EditAndGetServer('XLate/Xroot2/main.go')
  assert_equal('gopls-late', late1.name)
  assert_notequal(late1.id, late2.id)
  AssertServerRoot(late1, 'XLate/Xroot1')
  AssertServerRoot(late2, 'XLate/Xroot2')
  g:LspOptionsSet({serverPerRoot: false})
  assert_equal(late1.id, EditAndGetServer('XLate/Xroot1/util.go').id)

  :set hidden&
  StopServersAndWipe()
  delete('XToggle', 'rf')
  delete('XLate', 'rf')
enddef

# "perRoot" must be a Boolean, and cannot be false with a "rootDir" or
# "configForRoot" function
def g:Test_PerRoot_Invalid()
  :messages clear
  g:LspAddServer([{name: 'gopls-invalid1', filetype: ['go'],
		   path: exepath('gopls'), perRoot: 1}])
  assert_match('Setting of perRoot 1 is not a Boolean', execute('messages'))
  for key in ['rootDir', 'configForRoot']
    :messages clear
    g:LspAddServer([{name: 'gopls-invalid2', filetype: ['go'],
		     path: exepath('gopls'), perRoot: false,
		     [key]: (_, F) => F({})}])
    assert_match('LSP server gopls-invalid2 with a rootDir or configForRoot function cannot have perRoot set to false',
		 execute('messages'))
  endfor
  :LspShowAllServers
  var lines = getline(1, '$')
  :close
  assert_equal(-1, lines->match('gopls-invalid'))
enddef

# The language servers are started by the tests
def g:StartLangServer(): bool
  return true
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
