vim9script

# Vim9 LSP client
#
# The functions called by plugin/lsp.vim are in this file.

# Needs Vim 9.0 and higher
if v:version < 900
  finish
endif

import './options.vim' as opt
import './lspserver.vim' as lserver
import './util.vim'
import './buffer.vim' as buf
import './completion.vim'
import './textedit.vim'
import './diag.vim'
import './symbol.vim'
import './outline.vim'
import './signature.vim'
import './codeaction.vim'
import './hover.vim'
import './inlayhints.vim'
import './semantichighlight.vim'
import './ontypeformat.vim'
import './origin.vim'

# The language servers registered for each file type.  A registration is a
# template for its server instances:
#   id:        unique number
#   params:    the language server information passed to AddServer(), as
#              normalized by NormalizeServer()
#   instances: the server instances, keyed by workspace root directory.  When
#              there is no instance per root (see PerRoot()), the single
#              instance is keyed by SHARED_ROOT, and its root is computed from
#              the buffer that starts it.
#   pending:   the roots whose "configForRoot" function has not called back
#              yet, see RequestInstance()
#   perRoot:   true if there is a server instance per root, set by PerRoot()
#              when the first buffer is resolved
# A registration with several file types is in the list of each of them, and
# its instances serve all of them.
var ftypeServerMap: dict<list<dict<any>>> = {}

# Number of registrations, used for their ids
var registrationCount = 0

# Number of times a server instance was used, to order the instances by last
# use.  An instance is used when a buffer attached to it is entered, and when
# the current buffer is attached to it; its "lastUsed" is then set to this
# number (see UseBufServers()).
var useCount = 0

# The key of the single instance of a registration without an instance per
# root.  A root is a full path, or an empty string, so it cannot be equal.
const SHARED_ROOT = '*'

# The root resolved for each buffer by each registration: maps a buffer
# number to a dict of registration id -> key in the "instances" of the
# registration.  Used to find the server instances of a buffer which is not
# attached to them, e.g. after ":LspServer stop".
var bufRoots: dict<dict<string>> = {}

# The registrations that asked for the root of each buffer: maps a buffer
# number to a dict of registration id -> true.  A buffer is added on both
# BufReadPost and FileType, and this avoids calling the "rootDir" and
# "configForRoot" functions twice for a buffer they don't attach a server
# to.  Forgotten on FileType (e.g. after ":edit" or ":set filetype"), when
# the buffer is removed, and by ":LspServer restart" and "start", to ask
# again.
var bufRootRequests: dict<dict<bool>> = {}

# The origin of each buffer: maps a buffer number to the server instance whose
# answer opened it (see origin.Find()).  Set when the root of the buffer is
# resolved with a known origin, and kept until the buffer is wiped out, so
# that the buffer keeps its origin when its root is resolved again (e.g.
# after ":edit" or ":LspServer start").  Used for a buffer whose project is
# not known (see OriginRoot() and ServerRoots()).
var bufOrigins: dict<dict<any>> = {}

# The settings of a registration that a "configForRoot" function cannot
# override: they are used before a server instance exists.
const REGISTRATION_KEYS = ['configForRoot', 'filetype', 'name', 'omnicompl',
  'perRoot', 'rootDir', 'rootSearch', 'runIfSearch', 'runUnlessSearch']

var lspInitializedOnce = false
var lspUserSetupOnce = false
var lspEnabled = false

def LspInitOnce()
  # Define all plugin highlights/proptypes once per Vim session.
  hlset([
    {name: 'LspPopup', default: true, linksto: 'Pmenu'},
    {name: 'LspPopupBorder', default: true, linksto: 'Pmenu'},
    {name: 'LspTextRef', default: true, linksto: 'Search'},
    {name: 'LspReadRef', default: true, linksto: 'DiffChange'},
    {name: 'LspWriteRef', default: true, linksto: 'DiffDelete'}
  ])

  var override = &cursorline
      && &cursorlineopt =~ '\<line\>\|\<screenline\>\|\<both\>'

  prop_type_add('LspTextRef', {highlight: 'LspTextRef', override: override})
  prop_type_add('LspReadRef', {highlight: 'LspReadRef', override: override})
  prop_type_add('LspWriteRef', {highlight: 'LspWriteRef', override: override})

  diag.InitOnce()
  inlayhints.InitOnce()
  signature.InitOnce()
  symbol.InitOnce()
  semantichighlight.InitOnce()
  ontypeformat.InitOnce()

  lspInitializedOnce = true
enddef

def RegisterEvents()
  augroup LspAutoCmds
    autocmd!
    autocmd BufNewFile,BufReadPost * AddFile(expand('<abuf>')->str2nr())
    autocmd FileType * FileTypeSet(expand('<abuf>')->str2nr())
    # Also triggered when entering a window with another buffer
    autocmd BufEnter * UseBufServers(expand('<abuf>')->str2nr())
    # Note that when BufWipeOut is invoked, the current buffer may be different
    # from the buffer getting wiped out.
    autocmd BufWipeOut * BufferWipedOut(expand('<abuf>')->str2nr())
    autocmd BufWinEnter * BufferLoadedInWin(expand('<abuf>')->str2nr())
    # Pull fresh diagnostics when a file is modified outside Vim and reloaded
    autocmd FileChangedShellPost * BufferExternallyChanged(expand('<abuf>')->str2nr())
  augroup END
enddef

def DeregisterEvents()
  augroup LspAutoCmds
    autocmd!
  augroup END
enddef

export def LspEnable()
  if lspEnabled
    return
  endif

  if !lspUserSetupOnce
    # Invoke LspSetup user autocmd once
    if exists('#User#LspSetup')
      :doautocmd <nomodeline> User LspSetup
    endif
    lspUserSetupOnce = true
  endif

  RegisterEvents()

  for binfo in getbufinfo()
    AddFile(binfo.bufnr)
  endfor

  lspEnabled = true
enddef

export def LspDisable()
  if !lspEnabled
    return
  endif

  DeregisterEvents()

  for binfo in getbufinfo()
    RemoveFile(binfo.bufnr)
  endfor

  lspEnabled = false
enddef

# Returns the registrations of the language servers for the file type "ftype"
# that can be used for the buffer "bnr" (see "runIfSearch" and
# "runUnlessSearch").  Returns an empty list if there are none.
def LspGetServers(bnr: number, ftype: string): list<dict<any>>
  if !ftypeServerMap->has_key(ftype)
    return []
  endif

  var bufDir = bnr->bufname()->fnamemodify(':p:h')

  var servermap: list<dict<any>> = ftypeServerMap[ftype]->copy()

  return servermap->filter((key, reg) => {
    # Don't run the server if no path is found
    if !reg.params.runIfSearch->empty()
      var path = util.FindNearestRootDir(bufDir, reg.params.runIfSearch)

      if path->empty()
        return false
      endif
    endif

    # Don't run the server if a path is found
    if !reg.params.runUnlessSearch->empty()
      var path = util.FindNearestRootDir(bufDir, reg.params.runUnlessSearch)

      if !path->empty()
        return false
      endif
    endif

    # Run the server
    return true
  })
enddef

# Add a LSP server registration for a filetype
def LspAddServer(ftype: string, reg: dict<any>)
  var reglst = ftypeServerMap->has_key(ftype) ? ftypeServerMap[ftype] : []
  # Prevent duplicate registration of the same server name per filetype.
  if util.Indexof(reglst, (_, v) => v.params.name == reg.params.name) != -1
      # LSP server already added for this file type
      return
  endif
  reglst->add(reg)
  ftypeServerMap[ftype] = reglst
enddef

# Returns true if the registration "reg" has a server instance per workspace
# root.  This is decided when the first buffer is resolved, and does not change
# afterwards, so that changing the "serverPerRoot" option does not mix shared
# and per-root instances.
def PerRoot(reg: dict<any>): bool
  if !reg->has_key('perRoot')
    reg.perRoot = reg.params->has_key('rootDir')
      || reg.params->has_key('configForRoot')
      || reg.params->get('perRoot', opt.lspOptions.serverPerRoot)
  endif
  return reg.perRoot
enddef

# Returns the server instances of the registrations for the file type "ftype"
# for the roots resolved for the buffer "bnr", whether the buffer is attached
# to them or not.
def BufInstances(bnr: number, ftype: string): list<dict<any>>
  var roots = bufRoots->get(bnr, {})
  var instances: list<dict<any>> = []
  for reg in ftypeServerMap->get(ftype, [])
    if roots->has_key(reg.id) && reg.instances->has_key(roots[reg.id])
      instances->add(reg.instances[roots[reg.id]])
    endif
  endfor
  return instances
enddef

# Returns all the server instances of the registrations for the file type
# "ftype"
def FtypeInstances(ftype: string): list<dict<any>>
  var instances: list<dict<any>> = []
  for reg in ftypeServerMap->get(ftype, [])
    instances->extend(reg.instances->values())
  endfor
  return instances
enddef

# Enable/disable the logging of the language server protocol messages
def ServerDebug(arg: string)
  if ['errors', 'messages', 'off', 'on']->index(arg) == -1
    util.ErrMsg($'Unsupported argument "{arg}"')
    return
  endif

  var lspservers: list<dict<any>> = buf.CurbufGetServers()
  if lspservers->empty()
    util.WarnMsg($'No Lsp servers found for "{@%}"')
    return
  endif

  for lspserver in lspservers
    if arg == 'on'
      util.ClearTraceLogs(lspserver.logfile)
      util.ClearTraceLogs(lspserver.errfile)
      lspserver.debug = true
    elseif arg == 'off'
      lspserver.debug = false
    elseif arg == 'messages'
      util.ServerMessagesShow(lspserver.logfile)
    else
      util.ServerMessagesShow(lspserver.errfile)
    endif
  endfor
enddef

# Show information about all the LSP servers
export def ShowAllServers()
  var lines = []
  # Add filetype to server mapping information
  lines->add('Filetype Information')
  lines->add('====================')
  for [ftype, regs] in ftypeServerMap->items()
    for reg in regs
      # A registration without instances is shown as not running
      var noInstances = reg.instances->empty() && reg.pending->empty()
      for lspserver in noInstances ? [reg.params] : reg.instances->values()
	lines->add($"Filetype: '{ftype}'")
	lines->add($"Server Name: '{lspserver.name}'")
	lines->add($"Server Path: '{lspserver.path}'")
	if lspserver->has_key('rootPath')
	  lines->add($"Server Root: '{lspserver.rootPath}'")
	endif
	lines->add($"Status: {lspserver->get('running', false) ? 'Running' : 'Not running'}")
	lines->add('')
      endfor
      for root in reg.pending->keys()
	lines->add($"Filetype: '{ftype}'")
	lines->add($"Server Name: '{reg.params.name}'")
	lines->add($"Server Root: '{root}'")
	lines->add('Status: Waiting for configForRoot')
	lines->add('')
      endfor
    endfor
  endfor

  # Add buffer to server mapping information
  lines->add('Buffer Information')
  lines->add('==================')
  for bnr in range(1, bufnr('$'))
    var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)
    if !lspservers->empty()
      lines->add($"Buffer: '{bufname(bnr)}'")
      for lspserver in lspservers
        lines->add($"Server Path: '{lspserver.path}'")
        lines->add($"Status: {lspserver.running ? 'Running' : 'Not running'}")
      endfor
      lines->add('')
    endif
  endfor

  var wid = bufwinid('Language-Servers')
  if wid != -1
    wid->win_gotoid()
    :setlocal modifiable
    :silent! :%d _
  else
    :new Language-Servers
    :setlocal buftype=nofile
    :setlocal bufhidden=wipe
    :setlocal noswapfile
    :setlocal nonumber nornu
    :setlocal fdc=0 signcolumn=no
  endif
  setline(1, lines)
  :setlocal nomodified
  :setlocal nomodifiable
enddef

# Create a new window containing the buffer "bname" or if the window is
# already present then jump to it.
def OpenScratchWindow(bname: string)
  var wid = bufwinid(bname)
  if wid != -1
    wid->win_gotoid()
    :setlocal modifiable
    :silent! :%d _
  else
    exe $':new {bname}'
    :setlocal buftype=nofile
    :setlocal bufhidden=wipe
    :setlocal noswapfile
    :setlocal nonumber nornu
    :setlocal fdc=0 signcolumn=no
  endif
enddef

# Show the status of the LSP server for the current buffer
def ShowServer(arg: string)
  if ['status', 'capabilities', 'initializeRequest', 'messages']->index(arg) == -1
    util.ErrMsg($'Unsupported argument "{arg}"')
    return
  endif

  var lspservers: list<dict<any>> = buf.CurbufGetServers()
  if lspservers->empty()
    util.WarnMsg($'No Lsp servers found for "{@%}"')
    return
  endif

  var windowName: string = ''
  var lines: list<string> = []
  if arg->empty() || arg == 'status'
    windowName = $'LangServer-Status'
    for lspserver in lspservers
      if !lines->empty()
        lines->extend(['', repeat('=', &columns), ''])
      endif
      var msg = $"LSP server '{lspserver.name}' "
      if lspserver->has_key('rootPath')
        msg ..= $"for root '{lspserver.rootPath}' "
      endif
      msg ..= 'is '
      if lspserver.running
        msg ..= 'running'
      else
        msg ..= 'not running'
      endif
      lines->add(msg)
    endfor
  elseif arg == 'capabilities'
    windowName = $'LangServer-Capabilities'
    for lspserver in lspservers
      if !lines->empty()
        lines->extend(['', repeat('=', &columns), ''])
      endif
      lines->extend(lspserver.getCapabilities())
    endfor
  elseif arg == 'initializeRequest'
    windowName = $'LangServer-InitializeRequest'
    for lspserver in lspservers
      if !lines->empty()
        lines->extend(['', repeat('=', &columns), ''])
      endif
      lines->extend(lspserver.getInitializeRequest())
    endfor
  elseif arg == 'messages'
    windowName = $'LangServer-Messages'
    for lspserver in lspservers
      if !lines->empty()
        lines->extend(['', repeat('=', &columns), ''])
      endif
      lines->extend(lspserver.getMessages())
    endfor
  else
    util.ErrMsg($'Unsupported argument "{arg}"')
    return
  endif

  # Multi-line output is shown in a scratch window; single-line status is
  # echoed directly to avoid opening a window for trivial output.
  if lines->len() > 1
    OpenScratchWindow(windowName)
    setline(1, lines)
    :setlocal nomodified
    :setlocal nomodifiable
  else
    util.InfoMsg(lines[0])
  endif
enddef

# Server start requested by the user for the file type in the current buffer.
# Starts the server instances for the roots of the current buffer.
def StartServerByUser()
  var ftype: string = &filetype

  if ftypeServerMap->get(ftype, [])->empty()
    util.WarnMsg($'No Lsp servers found for "{@%}"')
    return
  endif

  var bnr = bufnr()
  var lspservers = BufInstances(bnr, ftype)
  for lspserver in lspservers
    lspserver.stoppedByUser = false
  endfor

  ForgetRootRequests(ftype)
  # The buffers whose root is the root of these instances (e.g. the library
  # files detached by ":LspServer stop") are attached to them again, the
  # current buffer first, as it starts a server without a root per instance
  # (see InitServer()).  Their root is not resolved again: for a file whose
  # project is not known, it could be the root of another running instance.
  for reg in ftypeServerMap[ftype]
    var root = bufRoots->get(bnr, {})->get(reg.id, null_string)
    var instance = reg.instances->get(root, {})
    if lspservers->util.Indexof((_, lspserver) => lspserver is instance) == -1
      continue
    endif
    var bnrs = [bnr] + getbufinfo({bufloaded: 1})
      ->mapnew((_, binfo) => binfo.bufnr)
      ->filter((_, b) => b != bnr
	&& bufRoots->get(b, {})->get(reg.id, null_string) == root
	&& b->getbufvar('&filetype') == ftype)
    for b in bnrs
      if !bufRootRequests->has_key(b)
	bufRootRequests[b] = {}
      endif
      bufRootRequests[b][reg.id] = true
    endfor
    AttachToRoot(reg, root, bnrs->mapnew((_, b) =>
      ({bnr: b, ftype: ftype, sync: false, servers: []})))
  endfor

  # Add all the other buffers with the current file type to the servers
  AddBuffersToLsp(ftype)
enddef

# Remove the buffers attached to the server instances "lspservers".  Returns
# the numbers of the removed buffers.
def RemoveServerBuffers(lspservers: list<dict<any>>): list<number>
  var bnrs: list<number> = []
  for lspserver in lspservers
    for bnr in buf.BufGetServerBufnrs(lspserver)
      RemoveFile(bnr)
      bnrs->add(bnr)
    endfor
  endfor
  return bnrs
enddef

# Server stop requested by the user for the file type in the current buffer.
# Stops the server instances for the roots of the current buffer.
def StopServerByUser()
  var lspservers = BufInstances(bufnr(), &filetype)
    ->filter((_, lspserver) => lspserver.running)
  if lspservers->empty()
    util.WarnMsg($'No Lsp servers found for "{@%}"')
    return
  endif

  var bnrs = RemoveServerBuffers(lspservers)
  for lspserver in lspservers
    lspserver.stopServer()
    lspserver.stoppedByUser = true
  endfor

  # The removed buffers keep their other language servers.  They are not
  # attached to another instance of the stopped servers (see AddFile()).
  for bnr in bnrs
    if bnr->bufloaded()
      AddFile(bnr)
    endif
  endfor
enddef

# Get LSP server running status for filetype "ftype"
# Return true if running, or false if not found or not running
export def ServerRunning(ftype: string): bool
  return !FtypeInstances(ftype)
    ->filter((_, lspserver) => lspserver.running)->empty()
enddef

# Record that the server instance "lspserver" is used now (see useCount)
def UseServer(lspserver: dict<any>)
  useCount += 1
  lspserver.lastUsed = useCount
enddef

# Record that the server instances attached to the buffer "bnr" are used now
def UseBufServers(bnr: number)
  for lspserver in buf.BufLspServersGet(bnr)
    if !lspserver->empty()
      UseServer(lspserver)
    endif
  endfor
enddef

# Returns the workspace root directories of the running instances of the
# language server named "name", ordered by last use (see useCount): the most
# recently used last.  With a buffer number "bnr", the root of the instance
# that is the origin of the buffer (see bufOrigins) is moved last.  The root
# of an instance without a fixed root is the root it was started with.
export def ServerRoots(name: string, bnr: number = 0): list<string>
  var instances: dict<dict<any>> = {}
  for regs in ftypeServerMap->values()
    for reg in regs
      if reg.params.name == name
	for lspserver in reg.instances->values()
	  if lspserver.running
	    instances[lspserver.id] = lspserver
	  endif
	endfor
      endif
    endfor
  endfor
  var originId = bufOrigins->get(bnr, {})->get('id', -1)
  return instances->values()
    ->sort((a, b) => (a.id == originId) != (b.id == originId)
		       ? (a.id == originId ? 1 : -1)
		       : a.lastUsed != b.lastUsed
		       ? a.lastUsed - b.lastUsed : a.id - b.id)
    ->mapnew((_, lspserver) => lspserver->get('rootPath',
				   lspserver.workspaceFolders->get(0, '')))
enddef

# Returns the workspace root directory of the buffer "bnr", computed in the
# same way as for a language server without a "rootDir" function, with the
# "rootSearch" file and directory names.
export def DefaultRootDir(bnr: number, rootSearch: list<any> = []): string
  return lserver.BufRootPath(bnr, rootSearch)
enddef

# Return server for the current buffer. Returns empty dict if there is none.
export def Server(): dict<any>
  return buf.CurbufGetServer()
enddef

# Go to a definition using "textDocument/definition" LSP request
export def GotoDefinition(peek: bool, cmdmods: string, count: number)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('definition')
  if lspserver->empty()
    if &tagfunc !=# 'lsp#lsp#TagFunc' && opt.lspOptions.definitionFallback
      if cmdmods !~ 'silent'
	util.WarnMsg($'definition lookup unsupported; falling back to tags file')
      endif
      try
	# Use :tjump instead of 'CTRL-]' using :tag because
	# 'tjump' works better with multiple tags.
	# Use commands as mappings close selection dialog immediately!
	if peek
	  execute (v:count > 0 ? ':' .. v:count .. 'ptag' : 'ptjump') expand('<cword>')
	else
	  execute (v:count > 0 ? ':' .. v:count .. 'tag' : 'tjump') expand('<cword>')
	endif
      catch /^Vim\%((\a\+)\)\=:E42[36]/
      endtry
    endif
    return
  endif

  lspserver.gotoDefinition(peek, cmdmods, count)
enddef

# Go to a declaration using "textDocument/declaration" LSP request
export def GotoDeclaration(peek: bool, cmdmods: string, count: number)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('declaration')
  if lspserver->empty()
    return
  endif

  lspserver.gotoDeclaration(peek, cmdmods, count)
enddef

# Go to a type definition using "textDocument/typeDefinition" LSP request
export def GotoTypedef(peek: bool, cmdmods: string, count: number)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('typeDefinition')
  if lspserver->empty()
    return
  endif

  lspserver.gotoTypeDef(peek, cmdmods, count)
enddef

# Go to a implementation using "textDocument/implementation" LSP request
export def GotoImplementation(peek: bool, cmdmods: string, count: number)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('implementation')
  if lspserver->empty()
    return
  endif

  lspserver.gotoImplementation(peek, cmdmods, count)
enddef

# Switch source header using "textDocument/switchSourceHeader" LSP request
# (Clangd specifc extension)
export def SwitchSourceHeader()
  var lspserver: dict<any> = buf.CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.switchSourceHeader()
enddef

# A buffer is saved. Send the "textDocument/didSave" LSP notification
def LspSavedFile(bnr: number)
  var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)->copy()

  # Copy + filter keeps iteration safe and skips detached/non-running entries.
  lspservers = lspservers->filter(
    (key, lspsrv) => !lspsrv->empty() && lspsrv.running
  )

  if lspservers->empty()
    return
  endif

  for lspserver in lspservers
    lspserver.didSaveFile(bnr)
  endfor
enddef

# Called after leaving insert mode. Used to process diag messages (if any)
def LspLeftInsertMode(bnr: number)
  var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)->copy()

  lspservers = lspservers->filter(
    (key, lspsrv) => !lspsrv->empty() && lspsrv.running
      && lspsrv.ready && lspsrv.isDiagnosticsProvider
  )
  for lspserver in lspservers
    lspserver.queuePullDiagnostics(bnr)
  endfor

  var updatePending: bool = bnr->getbufvar('LspDiagsUpdatePending', false)
  if !updatePending
    return
  endif
  setbufvar(bnr, 'LspDiagsUpdatePending', false)

  diag.ProcessNewDiags(bnr)
enddef

def LspHoverAutoSchedule(bnr: number)
  hover.HoverAutoSchedule(bnr)
enddef

def LspHoverAutoStop(bnr: number)
  hover.HoverAutoStop(bnr)
enddef

# Add buffer-local autocmds when attaching a LSP server to a buffer
def AddBufLocalAutocmds(lspserver: dict<any>, bnr: number): void
  var acmds: list<dict<any>> = []

  # file saved notification handler
  acmds->add({bufnr: bnr,
	      event: 'BufWritePost',
	      group: 'LSPBufferAutocmds',
	      cmd: $'LspSavedFile({bnr})'})

  # Update the diagnostics when insert mode is stopped
  acmds->add({bufnr: bnr,
	      event: 'InsertLeave',
	      group: 'LSPBufferAutocmds',
	      cmd: $'LspLeftInsertMode({bnr})'})

  # Auto highlight all the occurrences of the current keyword
  if opt.lspOptions.autoHighlight &&
			lspserver.isDocumentHighlightProvider
    acmds->add({bufnr: bnr,
		event: 'CursorMoved',
		group: 'LSPBufferAutocmds',
		cmd: $'call LspDocHighlightClear({bnr}) | call LspDocHighlight({bnr}, "silent")'})
  endif

  if opt.lspOptions.hoverOnCursorHold && lspserver.isHoverProvider
    # Setup autocmds for auto hover display
    acmds->add({bufnr: bnr,
		event: 'CursorHold',
		group: 'LSPBufferAutocmds',
		cmd: $'LspHoverAutoSchedule({bnr})'})
    acmds->add({bufnr: bnr,
		event: ['CursorMoved', 'BufLeave'],
		group: 'LSPBufferAutocmds',
		cmd: $'LspHoverAutoStop({bnr})'})
  endif

  autocmd_add(acmds)
enddef

def RemoveBufLocalAutocmds(bnr: number): void
  try
    autocmd_delete([{bufnr: bnr, group: 'LSPBufferAutocmds'}])
  catch /E367:/
    # The tests can call RemoveFile() without creating this augroup.
  endtry
enddef

def AddBufListener(lspserver: dict<any>, bnr: number): void
  # Add a per-buffer listener so incremental text changes are pushed to the
  # server and pull diagnostics are debounced from edits.
  var listenerId = listener_add((_bnr: number, start: number, end: number, added: number, changes: list<dict<number>>) => {
    lspserver.textdocDidChange(bnr)
    if lspserver.isDiagnosticsProvider
      lspserver.queuePullDiagnostics(bnr)
    endif
  }, bnr)
  var listenerIds = bnr->getbufvar('LspListenerIds', [])
  setbufvar(bnr, 'LspListenerIds', listenerIds + [listenerId])
enddef

def RemoveBufListener(bnr: number): void
  for listenerId in bnr->getbufvar('LspListenerIds', [])
    listener_remove(listenerId)
  endfor
  setbufvar(bnr, 'LspListenerIds', [])
enddef

# LspAttached autocmd per buffer state
var bufAttachStates: dict<dict<any>>

# Returns true if the LspAttached autocmd is either pending or already fired
# for buffer 'bnr'.
def LspAttached(bnr: number): bool
  var acmd_state: dict<any> =  bufAttachStates->get(bnr, {})

  if acmd_state->empty()
    return false
  endif

  return acmd_state->get('pending', false) || acmd_state->get('fired', false)
enddef

# Invoke the LspAttached autocmd for buffer 'bnr'
export def FireLspAttachedAutocmd(bnr: number): void
  bufAttachStates[bnr] = {pending: false, fired: true}

  var attachedBufName = bnr->bufname()
  var attachedBufPath = attachedBufName->empty()
    ? ''
    : attachedBufName->fnamemodify(':p')
  var attachedServerNames = buf.BufLspServersGet(bnr)->copy()
    ->filter((_, lspsrv) => !lspsrv->empty())
    ->map((_, lspsrv) => lspsrv.name)

  g:LspAttachedContext = {
    bufnr: bnr,
    file: attachedBufPath,
    servers: attachedServerNames
  }
  doautocmd <nomodeline> User LspAttached
enddef

# The LSP server with ID "lspserverId" is ready, initialize the LSP features
# for buffer "bnr".
def BufferInit(lspserverId: number, bnr: number): void
  var lspserver = buf.BufLspServerGetById(bnr, lspserverId)
  if lspserver->empty() || !lspserver.running
    return
  endif

  var ftype: string = bnr->getbufvar('&filetype')
  lspserver.textdocDidOpen(bnr, ftype)

  AddBufListener(lspserver, bnr)

  AddBufLocalAutocmds(lspserver, bnr)

  diag.BufferInit(lspserver, bnr)

  if lspserver.isDiagnosticsProvider
    lspserver.pullDiagnostics(bnr)
  endif

  # Delay feature-specific initialization until all attached servers are ready,
  # so feature-provider selection uses finalized capabilities.
  var allServersReady = true
  var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)
  for lspsrv in lspservers
    if !lspsrv.ready
      allServersReady = false
      break
    endif
  endfor

  if allServersReady
    for lspsrv in lspservers
      # It's only possible to initialize the features when the server
      # capabilities of all the registered language servers for this file type
      # are known.
      var serverId = lspsrv.id
      var completionServer = buf.BufLspServerGet(bnr, 'completion')
      if !completionServer->empty() && serverId == completionServer.id
        completion.BufferInit(lspsrv, bnr, ftype)
      endif

      var signatureServer = buf.BufLspServerGet(bnr, 'signatureHelp')
      if !signatureServer->empty() && serverId == signatureServer.id
	signature.BufferInit(lspsrv)
      endif

      var inlayHintServer = buf.BufLspServerGet(bnr, 'inlayHint')
      if !inlayHintServer->empty() && serverId == inlayHintServer.id
	inlayhints.BufferInit(lspsrv, bnr)
      endif

      var semanticServer = buf.BufLspServerGet(bnr, 'semanticTokens')
      if !semanticServer->empty() && serverId == semanticServer.id
	semantichighlight.BufferInit(lspserver, bnr)
      endif

      var onTypeFormatServer = buf.BufLspServerGet(bnr, 'documentOnTypeFormatting')
      if !onTypeFormatServer->empty() && serverId == onTypeFormatServer.id
	ontypeformat.BufferInit(lspsrv, bnr)
      endif
    endfor

    if exists('#User#LspAttached')
      if LspAttached(bnr)
        return
      endif

      bufAttachStates[bnr] = {pending: true, fired: false}
      if bnr == bufnr()
        FireLspAttachedAutocmd(bnr)
      else
        # Delay doautocmd until entering the buffer
        execute 'autocmd LspAutoCmds BufEnter <buffer=' .. bnr .. '>'
              \ .. $' ++once FireLspAttachedAutocmd({bnr})'
      endif
    endif
  endif
enddef

# The 'filetype' option is set for the buffer "bnr"
def FileTypeSet(bnr: number)
  if bufRootRequests->has_key(bnr)
    bufRootRequests->remove(bnr)
  endif
  AddFile(bnr)
enddef

# A new buffer is opened. If LSP is supported for this buffer, then add it
export def AddFile(bnr: number): void
  # Skip remote files
  if util.LspUriRemote(bnr->bufname()->fnamemodify(':p'))
    return
  endif

  # Skip popup buffers (special UI buffers should not attach language servers).
  var buftype: string = bnr->getbufvar('&buftype')
  if buftype ==# 'popup'
    return
  endif

  var ftype: string = bnr->getbufvar('&filetype')
  if ftype->empty()
    return
  endif
  var regs: list<dict<any>> = LspGetServers(bnr, ftype)
  if regs->empty()
    return
  endif

  # The server instances found before AddFile() returns are attached together,
  # in the order of the registrations, so that the features are initialized
  # with the capabilities of all of them (see BufferInit()).
  var ctx = {bnr: bnr, ftype: ftype, sync: true, servers: []}
  var attachedRegIds: list<number> = buf.BufLspServersGet(bnr)
    ->copy()
    ->filter((_, lspsrv) => !lspsrv->empty())
    ->map((_, lspsrv) => lspsrv.registrationId)
  if !bufRootRequests->has_key(bnr)
    bufRootRequests[bnr] = {}
  endif
  var requests = bufRootRequests[bnr]
  var originFound = false
  for reg in regs
    if attachedRegIds->index(reg.id) == -1 && !requests->has_key(reg.id)
	&& !StoppedForBuffer(reg, bnr)
      if !originFound
	SetBufOrigin(bnr, origin.Find(bnr))
	originFound = true
      endif
      requests[reg.id] = true
      ResolveRoot(reg, ctx)
    endif
  endfor
  ctx.sync = false

  AttachServers(bnr, ctx.servers)
enddef

# Returns true if the server instance of the registration "reg" for the root
# last resolved for the buffer "bnr" is stopped by the user (see ":LspServer
# stop").  The buffer is then not attached to another instance of the
# registration (e.g. a library file going to the most recently used one) until
# ":LspServer start".
def StoppedForBuffer(reg: dict<any>, bnr: number): bool
  var root = bufRoots->get(bnr, {})->get(reg.id, null_string)
  return root != null_string
    && reg.instances->get(root, {})->get('stoppedByUser', false)
enddef

# Resolve the workspace root of the buffer of "ctx" for the registration
# "reg", and attach the buffer to the server instance for that root, now or
# later.  "ctx" has the buffer number ("bnr"), its file type ("ftype"), and
# the server instances to attach when called from AddFile() ("sync" and
# "servers").
def ResolveRoot(reg: dict<any>, ctx: dict<any>)
  if reg.params->has_key('rootDir')
    try
      var RootDir = reg.params.rootDir
      RootDir(ctx.bnr, function(OnRootDir, [reg, ctx]))
    catch
      util.ErrMsg($'rootDir of LSP server "{reg.params.name}" failed: {v:exception}')
    endtry
  elseif PerRoot(reg)
    var root = lserver.BufRootPath(ctx.bnr, reg.params.rootSearch)
    if root->empty()
      # An ignored root, e.g. a library file: the instance of its origin,
      # else the most recently used running instance, else an instance
      # without a root
      root = OriginRoot(reg, ctx.bnr)
    endif
    OnRoot(reg, ctx, root)
  else
    OnRoot(reg, ctx, SHARED_ROOT)
  endif
enddef

# Record "lspserver" as the origin of the buffer "bnr" (see bufOrigins), unless
# it is empty
def SetBufOrigin(bnr: number, lspserver: dict<any>)
  if !lspserver->empty()
    bufOrigins[bnr] = lspserver
  endif
enddef

# Returns the root of the running server instance of the registration "reg"
# that is the origin of the buffer "bnr" (see bufOrigins), else the root of the
# most recently used running instance (see LastUsedRoot()), else an empty
# string
def OriginRoot(reg: dict<any>, bnr: number): string
  var lspserver = bufOrigins->get(bnr, {})
  if !lspserver->empty() && lspserver.running
    for [root, instance] in reg.instances->items()
      if instance is lspserver
	return root
      endif
    endfor
  endif
  return LastUsedRoot(reg)
enddef

# Returns the root of the most recently used running server instance of the
# registration "reg" (see useCount), or an empty string if none is running
def LastUsedRoot(reg: dict<any>): string
  var lastRoot = ''
  var lastUsed = -1
  for [root, lspserver] in reg.instances->items()
    if lspserver.running && lspserver.lastUsed > lastUsed
      lastRoot = root
      lastUsed = lspserver.lastUsed
    endif
  endfor
  return lastRoot
enddef

# The callback of the "rootDir" function of the registration "reg", called
# with the workspace root "root" of the buffer of "ctx"
def OnRootDir(reg: dict<any>, ctx: dict<any>, root: any)
  if root->type() != v:t_string
    util.ErrMsg($'rootDir of LSP server "{reg.params.name}" returned a root that is not a String: {root->string()}')
    return
  endif
  OnRoot(reg, ctx, root->empty() ? '' : root->fnamemodify(':p'))
enddef

# Returns true if the buffer of "ctx" (see ResolveRoot()) can still be
# attached to a server instance when a "rootDir" or "configForRoot" function
# calls back after AddFile() returned: it is loaded and its file type is the
# same.
def BufferWantsServer(ctx: dict<any>): bool
  return ctx.sync || (lspEnabled && ctx.bnr->bufloaded()
		      && ctx.bnr->getbufvar('&filetype') == ctx.ftype)
enddef

# Called with the workspace root "root" of the buffer of "ctx" for the
# registration "reg", or with SHARED_ROOT
def OnRoot(reg: dict<any>, ctx: dict<any>, root: string)
  if !BufferWantsServer(ctx)
    return
  endif
  if ctx->has_key('rehome')
    MoveToRoot(reg, ctx, root)
    return
  endif
  if !bufRoots->has_key(ctx.bnr)
    bufRoots[ctx.bnr] = {}
  endif
  bufRoots[ctx.bnr][reg.id] = root
  AttachToRoot(reg, root, [ctx])
enddef

# Returns the server instance of the registration "reg" attached to the buffer
# "bnr", or an empty Dict if there is none
def BufRegServer(bnr: number, reg: dict<any>): dict<any>
  for lspserver in buf.BufLspServersGet(bnr)
    if !lspserver->empty() && lspserver.registrationId == reg.id
      return lspserver
    endif
  endfor
  return {}
enddef

# A location from the answer of the server instance "lspserver" is opened in
# the buffer "bnr" (see origin.Opening()).  If the buffer is attached to
# another instance of the same registration, then resolve its root again,
# with "lspserver" as its origin, and attach it to the instance for that root
# if it is another one (see MoveToRoot()).  This moves a library file to the
# instance it is opened from, unless the resolver knows its project.
def RehomeBuffer(bnr: number, lspserver: dict<any>)
  if !lspEnabled || lspserver->empty()
    return
  endif
  var ftype: string = bnr->getbufvar('&filetype')
  var regs = ftypeServerMap->get(ftype, [])->copy()
    ->filter((_, r) => r.id == lspserver.registrationId)
  if regs->empty() || !PerRoot(regs[0])
    return
  endif
  var reg = regs[0]
  var old = BufRegServer(bnr, reg)
  if old->empty() || old is lspserver
    return
  endif
  SetBufOrigin(bnr, lspserver)
  if !bnr->bufloaded()
    # A buffer that was unloaded (e.g. without 'hidden') is still attached.
    # Detach it: it is added again when it is loaded to go to the location,
    # with this origin.
    RemoveFile(bnr)
    return
  endif
  ResolveRoot(reg, {bnr: bnr, ftype: ftype, sync: false, servers: [],
		    rehome: old})
enddef

# Called by OnRoot() with the workspace root "root" resolved again for the
# buffer of "ctx" by RehomeBuffer().  If the buffer is still attached to the
# same instance ("ctx.rehome") and the root is another one, then attach the
# buffer to the instance for this root instead: its language servers are
# detached and attached again, so that it has one instance of each
# registration, and its features are initialized for all of them (see
# BufferInit()).
def MoveToRoot(reg: dict<any>, ctx: dict<any>, root: string)
  var bnr = ctx.bnr
  var old = ctx.rehome
  if BufRegServer(bnr, reg) isnot old
      || bufRoots->get(bnr, {})->get(reg.id, null_string) == root
    return
  endif

  var others = buf.BufLspServersGet(bnr)->copy()
    ->filter((_, lspserver) => !lspserver->empty() && lspserver isnot old)
  RemoveFile(bnr)
  # The buffer keeps its roots: they are not asked again
  bufRootRequests[bnr] = {[reg.id]: true}
  for lspserver in others
    bufRootRequests[bnr][lspserver.registrationId] = true
  endfor
  bufRoots[bnr][reg.id] = root

  var attach = {bnr: bnr, ftype: ctx.ftype, sync: true, servers: others}
  AttachToRoot(reg, root, [attach])
  attach.sync = false
  # In the order of the registrations, as in AddFile()
  var regIds = ftypeServerMap->get(ctx.ftype, [])->mapnew((_, r) => r.id)
  AttachServers(bnr, attach.servers->sort((a, b) =>
    regIds->index(a.registrationId) - regIds->index(b.registrationId)))
enddef

# Attach the buffers of "ctxs" (see ResolveRoot()) to the server instance of
# the registration "reg" for the root "root", now if it exists, else when it
# is created (see RequestInstance())
def AttachToRoot(reg: dict<any>, root: string, ctxs: list<dict<any>>)
  if reg.instances->has_key(root)
    for ctx in ctxs
      AttachInstance(reg.instances[root], ctx)
    endfor
  elseif reg.pending->has_key(root)
    var request = reg.pending[root]
    for ctx in ctxs
      if request.ctxs->util.Indexof((_, c) => c.bnr == ctx.bnr) == -1
	request.ctxs->add(ctx)
      endif
    endfor
  else
    RequestInstance(reg, root, ctxs)
  endif
enddef

# Create the server instance of the registration "reg" for the root "root",
# with the settings computed by its "configForRoot" function, now or later.
# Then attach the buffers of "ctxs" to it.  Until then, the root is in
# "reg.pending", and the buffers with this root are added to "ctxs".
def RequestInstance(reg: dict<any>, root: string, ctxs: list<dict<any>>)
  var request = {ctxs: ctxs}
  reg.pending[root] = request
  var Done = function(OnConfig, [reg, root, request])
  if !reg.params->has_key('configForRoot')
    Done({})
    return
  endif

  try
    var ConfigForRoot = reg.params.configForRoot
    ConfigForRoot(root, Done)
  catch
    util.ErrMsg($'configForRoot of LSP server "{reg.params.name}" failed: {v:exception}')
    if reg.pending->get(root, {}) is request
      reg.pending->remove(root)
    endif
  endtry
enddef

# The callback of the "configForRoot" function of the registration "reg" for
# the root "root" and the "request" (see RequestInstance()).  A Dict
# "config" overrides the settings of the registration.  v:null means "not
# now": nothing is started, and the next buffer with this root asks again.
def OnConfig(reg: dict<any>, root: string, request: dict<any>, config: any)
  if reg.pending->get(root, {}) isnot request
    # Called back twice, or after an error
    return
  endif
  reg.pending->remove(root)

  if config->type() == v:t_none
    return
  endif
  if config->type() != v:t_dict
    util.ErrMsg($'configForRoot of LSP server "{reg.params.name}" returned a value that is not a Dict: {config->string()}')
    return
  endif

  var ctxs = request.ctxs->filter((_, ctx) => BufferWantsServer(ctx))
  if ctxs->empty()
    return
  endif
  var instance = NewInstance(reg, root, config)
  if instance->empty()
    return
  endif
  for ctx in ctxs
    AttachInstance(instance, ctx)
  endfor
enddef

# Create the server instance of the registration "reg" for the root "root"
# (or SHARED_ROOT), with the settings of the registration overridden by
# "config".  Returns an empty dict (after showing an error message) if the
# settings are not valid.
def NewInstance(reg: dict<any>, root: string, config: dict<any>): dict<any>
  var params = reg.params
  if !config->empty()
    params = reg.params->deepcopy()
    for [key, val] in config->items()
      if REGISTRATION_KEYS->index(key) == -1
	params[key] = val
      endif
    endfor
  endif
  if params.path->empty()
    util.ErrMsg($'configForRoot of LSP server "{reg.params.name}" did not return a path for root "{root}"')
    return {}
  endif
  if !config->empty() && !NormalizeServer(params)
    return {}
  endif

  var instance = lserver.NewLspServer(params)
  instance.registrationId = reg.id
  # Whether other instances of this registration may exist, so that the
  # origin of a file matters (see origin.vim)
  instance.perRoot = PerRoot(reg)
  instance.lastUsed = 0
  if root != SHARED_ROOT
    instance.rootPath = root
  endif
  reg.instances[root] = instance
  return instance
enddef

# Attach the server instance "instance" to the buffer of "ctx" (see
# ResolveRoot())
def AttachInstance(instance: dict<any>, ctx: dict<any>)
  if !ctx.sync
    AttachServers(ctx.bnr, [instance])
  elseif ctx.servers->util.Indexof((_, srv) => srv.id == instance.id) == -1
    ctx.servers->add(instance)
  endif
enddef

# Attach the server instances "lspservers" to the buffer "bnr", and start the
# ones that are not running
def AttachServers(bnr: number, lspservers: list<dict<any>>)
  # Start the servers (if needed)
  var attachedServerIds: list<number> = buf.BufLspServersGet(bnr)
    ->copy()
    ->filter((_, lspsrv) => !lspsrv->empty())
    ->map((_, lspsrv) => lspsrv.id)
  var attachedServers: list<dict<any>> = []
  for lspserver in lspservers
    if lspserver.stoppedByUser
      continue
    endif

    if attachedServerIds->index(lspserver.id) != -1
      # This server is already attached to the buffer
      continue
    endif

    if !lspserver.running
      if !lspInitializedOnce
        LspInitOnce()
      endif
      lspserver.startServer(bnr)
    endif

    buf.BufLspServerSet(bnr, lspserver)
    attachedServers->add(lspserver)
    # Attaching a buffer that is not current (e.g. when all the buffers are
    # added again, or a "configForRoot" function calls back late) is not a
    # use.  The current buffer may have been entered before its server
    # instance was created.
    if bnr == bufnr()
      UseServer(lspserver)
    endif
  endfor

  for lspserver in attachedServers
    if lspserver.ready
      BufferInit(lspserver.id, bnr)
    else
      # Lsp server is not ready yet.  Initialize the lsp state for this buffer
      # when the server is ready.
      # The user event is server-id scoped, so each delayed init is tied to the
      # exact server instance attached to this buffer.
      var serverId = lspserver.id
      autocmd_add([{group: 'LSPBufferAutocmds',
                   event: 'User',
                   pattern: $'LspServerReady_{serverId}',
                   once: true,
                   cmd: $'BufferInit({serverId}, {bnr})'}])
    endif
  endfor
enddef

# Notify LSP server to remove a file
export def RemoveFile(bnr: number): void
  var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)
  var detachedBufName = bnr->bufname()
  var detachedBufPath = detachedBufName->empty()
    ? ''
    : detachedBufName->fnamemodify(':p')
  var detachedServerNames = lspservers->copy()
    ->filter((_, lspsrv) => !lspsrv->empty())
    ->map((_, lspsrv) => lspsrv.name)
  var hasLspDetachedAutocmd = exists('#User#LspDetached')
  var hadAttachedServers = !lspservers->empty()
  if hadAttachedServers
    RemoveBufLocalAutocmds(bnr)
    RemoveBufListener(bnr)
  endif
  # Iterate over a copy because BufLspServerRemove mutates the underlying list.
  for lspserver in lspservers->copy()
    if lspserver->empty()
      continue
    endif
    var serverId = lspserver.id
    try
      autocmd_delete([{group: 'LSPBufferAutocmds',
                     event: 'User',
                     pattern: $'LspServerReady_{serverId}',
                     cmd: $'BufferInit({serverId}, {bnr})'}])
    catch /E367:/
      # The tests can call RemoveFile() without creating this augroup.
    endtry
    if lspserver.running
      lspserver.textdocDidClose(bnr)
    endif
    diag.DiagRemoveFile(bnr)
    buf.BufLspServerRemove(bnr, lspserver)
  endfor

  if hadAttachedServers && hasLspDetachedAutocmd
    # User autocommands allow only one match pattern; provide detach details
    # through a global context dict for handlers.
    g:LspDetachedContext = {
      bufnr: bnr,
      file: detachedBufPath,
      servers: detachedServerNames
    }
    doautocmd <nomodeline> User LspDetached
  endif

  if bufAttachStates->has_key(bnr)
    bufAttachStates->remove(bnr)
  endif

  if bufRootRequests->has_key(bnr)
    bufRootRequests->remove(bnr)
  endif
enddef

# The buffer "bnr" is wiped out
def BufferWipedOut(bnr: number)
  RemoveFile(bnr)
  if bufRoots->has_key(bnr)
    bufRoots->remove(bnr)
  endif
  if bufOrigins->has_key(bnr)
    bufOrigins->remove(bnr)
  endif
enddef

# Buffer 'bnr' is loaded in a window, refresh visuals and UI state.
export def BufferLoadedInWin(bnr: number)
  var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)
  if lspservers->empty()
    # No language servers for this buffer
    return
  endif
  for lspserver in lspservers
    if !lspserver->empty() && lspserver.ready
      lspserver.textdocDidChange(bnr)
    endif
  endfor
  # Refresh the displayed diags visuals
  if opt.lspOptions.autoHighlightDiags
    diag.DiagsRefresh(bnr)
  endif

  completion.BufferLoadedInWin(bnr)

  # Refresh the semantic highlights
  if opt.lspOptions.semanticHighlight
    var semanticServer = buf.BufLspServerGet(bnr, 'semanticTokens')
    if !semanticServer->empty()
      semanticServer.semanticHighlightUpdate(bnr)
    endif
  endif
enddef

# File was modified outside of Vim and reloaded. Refresh diagnostics.
export def BufferExternallyChanged(bnr: number): void
  var lspservers: list<dict<any>> = buf.BufLspServersGet(bnr)
  if lspservers->empty()
    return
  endif

  for lspserver in lspservers
    if !lspserver->empty() && lspserver.running && lspserver.ready
      # Notify server of the change to trigger re-analysis
      lspserver.textdocDidChange(bnr)
      if lspserver.isDiagnosticsProvider
        # For pull-based diagnostics, explicitly request fresh diagnostics
        lspserver.queuePullDiagnostics(bnr)
      endif
    endif
  endfor
enddef

# Send synchronous "shutdown" request to LSP server with a tiny timeout.
# It's for vim exit. We're in a hurry and ain't waiting for slow servers.
# Time out of slow responses within a split second (125 milliseconds).
def FastShutdownServer(lspserver: dict<any>): void
  if lspserver.job->job_status() == 'run'
    lspserver.shutdownServer(125)     # 125 msec timeout
  endif
enddef

# Send shutdown/exit to all the LSP servers (fast for vim exit)
export def FastShutdownExitAllServers()
  for regs in ftypeServerMap->values()
    for lspserver in regs->mapnew((_, reg) => reg.instances->values())->flattennew()
      if lspserver.running
	FastShutdownServer(lspserver)
	lspserver.exitServer()
	lspserver.running = false
	lspserver.ready = false
      endif
    endfor
  endfor
enddef

# Forget the root requests of the buffers with 'filetype' set to "ftype" (see
# bufRootRequests), so that their roots are asked again.
def ForgetRootRequests(ftype: string)
  for bnr in bufRootRequests->keys()
    if bnr->str2nr()->getbufvar('&filetype') == ftype
      bufRootRequests->remove(bnr)
    endif
  endfor
enddef

# Add all the buffers with 'filetype' set to "ftype" to the language server.
def AddBuffersToLsp(ftype: string)
  # Add all the buffers with the same file type as the current buffer
  for binfo in getbufinfo({bufloaded: 1})
    if binfo.bufnr->getbufvar('&filetype') == ftype
      AddFile(binfo.bufnr)
    endif
  endfor
enddef

# Restart the LSP server instances for the roots of the current buffer.  Each
# instance is replaced with a new one, attached to the buffers of the old one.
def RestartServer()
  var ftype: string = &filetype
  var bnr = bufnr()

  var regs = ftypeServerMap->get(ftype, [])
  if regs->empty()
    util.WarnMsg($'No Lsp servers found for "{@%}"')
    return
  endif

  var roots = bufRoots->get(bnr, {})
  # The buffers not attached to a server are asked again
  ForgetRootRequests(ftype)
  var removedBufs: list<number> = []
  for reg in regs
    var root = roots->get(reg.id, null_string)
    if !reg.instances->has_key(root)
      continue
    endif
    # Forget the old instance before stopping it: stopping waits for the
    # server, and a buffer added meanwhile must get the new instance.
    var lspserver = reg.instances->remove(root)
    var debug = lspserver.debug
    var bnrs = RemoveServerBuffers([lspserver])
    if lspserver.running
      lspserver.stopServer()
    endif

    # The current buffer first: it starts a server without a root per
    # instance (see InitServer()).
    var ctxs = ([bnr] + bnrs->copy()->filter((_, b) => b != bnr))
      ->filter((_, b) => b->bufloaded())
      ->mapnew((_, b) => ({bnr: b, ftype: b->getbufvar('&filetype'),
			   sync: false, servers: []}))
    # These buffers keep their root: they are not asked again below, even if
    # "configForRoot" does not create the new instance
    for ctx in ctxs
      if !bufRootRequests->has_key(ctx.bnr)
	bufRootRequests[ctx.bnr] = {}
      endif
      bufRootRequests[ctx.bnr][reg.id] = true
    endfor
    AttachToRoot(reg, root, ctxs)
    # Keep the debug setting (see ":LspServer debug"), unless the new
    # instance is created later
    if reg.instances->has_key(root)
      reg.instances[root].debug = debug
    endif
    removedBufs->extend(bnrs)
  endfor

  # The other buffers, and the other language servers of the removed buffers
  AddBuffersToLsp(ftype)
  for b in removedBufs
    if b->bufloaded() && b->getbufvar('&filetype') != ftype
      AddFile(b)
    endif
  endfor
enddef

# Add the LSP server registration "reg" for files with 'filetype' as "ftype".
def AddServerForFiltype(reg: dict<any>, ftype: string, omnicompl: bool)
  LspAddServer(ftype, reg)
  completion.OmniComplSet(ftype, omnicompl)

  # If a buffer of this file type is already present, then send it to the LSP
  # server now.
  AddBuffersToLsp(ftype)
enddef

# Validate the language server information "server", and set the default
# values expected by NewLspServer(), in place.  Returns false (after showing an
# error message) if the information is not valid.
def NormalizeServer(server: dict<any>): bool
  # The "configForRoot" function can provide the path
  if !server->has_key('filetype')
      || (!server->has_key('path') && !server->has_key('configForRoot'))
    util.ErrMsg('LSP server information is missing filetype or path')
    return false
  endif
  for key in ['rootDir', 'configForRoot']
    if server->has_key(key) && server[key]->type() != v:t_func
      util.ErrMsg($'Setting of {key} {server[key]} is not a Funcref nor lambda')
      return false
    endif
  endfor
  if server->has_key('perRoot')
    if server.perRoot->type() != v:t_bool
      util.ErrMsg($'Setting of perRoot {server.perRoot} is not a Boolean')
      return false
    endif
    # The "rootDir" and "configForRoot" functions work on a root
    if !server.perRoot
	&& (server->has_key('rootDir') || server->has_key('configForRoot'))
      util.ErrMsg($'LSP server {server->get("name", server->get("path", ""))} with a rootDir or configForRoot function cannot have perRoot set to false')
      return false
    endif
  endif
  # Enable omni-completion by default when auto-complete is disabled, unless
  # the user explicitly overrides this per server.
  var omnicompl_def: bool = false
  if opt.lspOptions.omniComplete == true
	|| (opt.lspOptions.omniComplete == null
	    && !opt.lspOptions.autoComplete)
    omnicompl_def = true
  endif
  server.omnicompl = server->get('omnicompl', omnicompl_def)

  if !server->has_key('path')
    # The name of the server instances cannot default to their path
    if !server->has_key('name') || server.name->type() != v:t_string
	|| server.name->empty()
      util.ErrMsg('LSP server information is missing name or path')
      return false
    endif
    server.path = ''
  else
    server.path = expandcmd(server.path)

    # Skip missing executables unless user opted into silent ignore.
    if !server.path->executable()
      if !opt.lspOptions.ignoreMissingServer
	util.ErrMsg($'LSP server {server.path} is not found')
      endif
      return false
    endif
  endif
  if server->has_key('args')
    if server.args->type() != v:t_list
      util.ErrMsg($'Arguments for LSP server {server.args} is not a List')
      return false
    endif
  else
    server.args = []
  endif

  # Normalize optional fields to canonical types expected by NewLspServer().
  if !server->has_key('initializationOptions')
	|| server.initializationOptions->type() != v:t_dict
    server.initializationOptions = {}
  endif

  if !server->has_key('clientCapabilities')
	|| server.clientCapabilities->type() != v:t_dict
    server.clientCapabilities = {}
  endif

  if !server->has_key('forceOffsetEncoding')
	|| server.forceOffsetEncoding->type() != v:t_string
	|| (server.forceOffsetEncoding != 'utf-8'
	    && server.forceOffsetEncoding != 'utf-16'
	    && server.forceOffsetEncoding != 'utf-32')
    server.forceOffsetEncoding = ''
  endif

  if !server->has_key('customNotificationHandlers')
	|| server.customNotificationHandlers->type() != v:t_dict
    server.customNotificationHandlers = {}
  endif

  if server->has_key('processDiagHandler')
    if server.processDiagHandler->type() != v:t_func
      util.ErrMsg($'Setting of processDiagHandler {server.processDiagHandler} is not a Funcref nor lambda')
      return false
    endif
  else
    server.processDiagHandler = null_function
  endif

  if !server->has_key('customRequestHandlers')
	|| server.customRequestHandlers->type() != v:t_dict
    server.customRequestHandlers = {}
  endif

  if !server->has_key('features') || server.features->type() != v:t_dict
    server.features = {}
  endif

  if server.omnicompl->type() != v:t_bool
    util.ErrMsg($'Setting of omnicompl {server.omnicompl} is not a Boolean')
    return false
  endif

  if !server->has_key('syncInit')
    server.syncInit = false
  endif

  if !server->has_key('name') || server.name->type() != v:t_string
	|| server.name->empty()
    # Use the executable name (without the extension) as the language server
    # name.
    server.name = server.path->fnamemodify(':t:r')
  endif

  if !server->has_key('debug') || server.debug->type() != v:t_bool
    server.debug = false
  endif

  if !server->has_key('traceLevel')
	|| server.traceLevel->type() != v:t_string
	|| (server.traceLevel != 'off' && server.traceLevel != 'debug'
	    && server.traceLevel != 'verbose')
    server.traceLevel = 'off'
  endif

  if !server->has_key('workspaceConfig')
	|| server.workspaceConfig->type() != v:t_dict
    server.workspaceConfig = {}
  endif

  if !server->has_key('rootSearch') || server.rootSearch->type() != v:t_list
    server.rootSearch = []
  endif

  if !server->has_key('runIfSearch') ||
	server.runIfSearch->type() != v:t_list
    server.runIfSearch = []
  endif

  if !server->has_key('runUnlessSearch') ||
	server.runUnlessSearch->type() != v:t_list
    server.runUnlessSearch = []
  endif

  if !server->has_key('languageId') ||
	server.languageId->type() != v:t_func
    server.languageId = v:none
  endif

  return true
enddef

# Register a LSP server for one or more file types
export def AddServer(serverList: list<dict<any>>)
  for server in serverList
    if !NormalizeServer(server)
      continue
    endif

    var ftypes = server.filetype
    if ftypes->type() == v:t_string
      ftypes = [ftypes]
    elseif ftypes->type() != v:t_list
      util.ErrMsg($'Unsupported file type information "{ftypes->string()}" in LSP server registration')
      continue
    endif

    # The server instances are created when they are needed (see
    # AttachToRoot()), from a copy of the settings taken now
    registrationCount += 1
    var reg = {id: registrationCount, params: server->deepcopy(),
	       instances: {}, pending: {}}
    for ftype in ftypes
      AddServerForFiltype(reg, ftype, server.omnicompl)
    endfor
  endfor
enddef

# The LSP server is considered ready when the server capabilities are
# received ("initialize" LSP reply message)
export def ServerReady(): bool
  var fname: string = @%
  if fname->empty()
    return false
  endif

  var lspservers: list<dict<any>> = buf.CurbufGetServers()
  if lspservers->empty()
    return false
  endif

  for lspserver in lspservers
    if !lspserver.ready
      return false
    endif
  endfor

  return true
enddef

# set the LSP server trace level for the current buffer
# Params: SetTraceParams
def ServerTraceSet(traceVal: string)
  if ['off', 'messages', 'verbose']->index(traceVal) == -1
    util.ErrMsg($'Unsupported argument "{traceVal}"')
    return
  endif

  var lspservers: list<dict<any>> = buf.CurbufGetServers()
  if lspservers->empty()
    util.WarnMsg($'No Lsp servers found for "{@%}"')
    return
  endif

  for lspserver in lspservers
    lspserver.setTrace(traceVal)
  endfor
enddef

# Display the diagnostic messages from the LSP server for the current buffer
# in a quickfix list
export def ShowDiagnostics(): void
  diag.ShowAllDiags()
enddef

# Show the diagnostic message for the current line
export def LspShowCurrentDiag(atPos: bool)
  diag.ShowCurrentDiag(atPos)
enddef

# get the count of diagnostics in the current buffer
export def ErrorCount(): dict<number>
  var res = {Error: 0, Warn: 0, Info: 0, Hint: 0}
  var fname: string = @%
  if fname->empty()
    return res
  endif

  return diag.DiagsGetErrorCount(bufnr())
enddef

# jump to the next/previous/first diagnostic message in the current buffer
export def JumpToDiag(which: string, count: number = 0): void
  diag.LspDiagsJump(which, count)
enddef

# Display the hover message from the LSP server for the current cursor
# location
export def Hover(cmdmods: string)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('hover')
  if lspserver->empty()
    if &keywordprg !=# ':LspHover' && !empty(&l:keywordprg) && opt.lspOptions.hoverFallback
      if cmdmods !~ 'silent'
      	util.WarnMsg($'Hovering unsupported; falling back to built-in.')
      endif
      try
      	execute 'normal! K'
      catch /.*/
      	# Ignore any errors from built-in fallback
      endtry
    endif
    return
  endif

  lspserver.hover(cmdmods)
enddef

# Enable or disable inlay hints
export def InlayHints(ctl: string)
  if ctl == 'enable'
    inlayhints.InlayHintsEnable()
  elseif ctl == 'disable'
    inlayhints.InlayHintsDisable()
  elseif ctl == 'toggle'
    inlayhints.InlayHintsToggle()
  else
    util.ErrMsg($'LspInlayHints - Unsupported argument "{ctl}"')
  endif
enddef

# Command-line completion for the ":LspInlayHints" command
export def LspInlayHintsComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  var l = ['enable', 'disable', 'toggle']
  return filter(l, (_, val) => val =~ $'^{arglead}')
enddef

# show symbol references
export def ShowReferences(peek: bool)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('references')
  if lspserver->empty()
    return
  endif

  lspserver.showReferences(peek)
enddef

# send custom locations request
def g:LspFindLocations(server_name: string, peek: bool, method: string, args: dict<any> = {})
  var lspserver: dict<any> = buf.CurbufGetServerByName(server_name)
  if lspserver->empty()
    return
  endif
  if !lspserver.running
    util.ErrMsg($'Language server "{server_name}" is not running')
    return
  endif
  if !lspserver.ready
    util.ErrMsg($'Language server "{server_name}" is not ready')
    return
  endif

  lspserver.findLocations(peek, method, args)
enddef

# highlight all the places where a symbol is referenced
def g:LspDocHighlight(bnr: number = bufnr(), cmdmods: string = '')
  var lspserver: dict<any> = buf.CurbufGetServerChecked('documentHighlight')
  if lspserver->empty()
    return
  endif

  lspserver.docHighlight(bnr, cmdmods)
enddef

# clear the symbol reference highlight
def g:LspDocHighlightClear(bnr: number = bufnr())
  var lspserver: dict<any> = buf.CurbufGetServerChecked('documentHighlight')
  if lspserver->empty()
    return
  endif

  var propNames = ['LspTextRef', 'LspReadRef', 'LspWriteRef']
  if has('patch-9.0.0233')
    prop_remove({types: propNames, bufnr: bnr, all: true})
  else
    for propName in propNames
      prop_remove({type: propName, bufnr: bnr, all: true})
    endfor
  endif
enddef

def g:LspRequestDocSymbols()
  if outline.SkipOutlineRefresh()
    return
  endif

  var fname: string = @%
  if fname->empty()
    return
  endif

  var lspserver: dict<any> = buf.CurbufGetServer('documentSymbol')
  if lspserver->empty() || !lspserver.running || !lspserver.ready
    return
  endif

  lspserver.getDocSymbols(fname, true)
enddef

# open a window and display all the symbols in a file (outline)
export def Outline(ctl: string, cmdmods: string, winsize: number)
  var fname: string = @%
  if fname->empty()
    return
  endif

  var lspserver: dict<any> = buf.CurbufGetServerChecked('documentSymbol')
  if (lspserver->empty() || !lspserver.running || !lspserver.ready) && fname != 'LSP-Outline'
    return
  endif

  if ctl == 'open' || ctl == ''
    outline.OpenOutlineWindow(cmdmods, winsize)
    g:LspRequestDocSymbols()
  elseif ctl == 'close'
    outline.CloseOutlineWindow()
  elseif ctl == 'toggle'
    if outline.ToggleOutlineWindow(cmdmods, winsize)
      g:LspRequestDocSymbols()
    endif
  endif
enddef

# Command-line completion for the ":LspOutline" command
export def LspOutlineComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  var l = ['open', 'close', 'toggle']
  return filter(l, (_, val) => val =~ $'^{arglead}')
enddef

# show all the symbols in a file in a popup menu
export def ShowDocSymbols()
  var fname: string = @%
  if fname->empty()
    return
  endif

  var lspserver: dict<any> = buf.CurbufGetServerChecked('documentSymbol')
  if lspserver->empty() || !lspserver.running || !lspserver.ready
    return
  endif

  lspserver.getDocSymbols(fname, false)
enddef

# Format a range of lines in a file
# If a language server supporting range formatting is not found and
# 'canFallback' is true then use builtin formatting.
def DocRangeFormat(fname: string, line1: number, line2: number, canFallback: bool)
  var lspserver: dict<any> = buf.BufLspServerGet(bufnr(), 'documentRangeFormatting')
  if !lspserver->empty()
    lspserver.textDocFormat(fname, true, line1, line2)
    return
  endif

  if canFallback
    util.WarnMsg('Formatting unsupported; falling back to built-in.')
    execute $'keepjumps normal! {line1}Ggq{line2}G'
  elseif !&filetype->empty()
    util.ErrMsg($'Language server for "{&filetype}" file type supporting "documentRangeFormatting" feature is not found')
  else
    util.ErrMsg('No language server supporting "documentRangeFormatting" feature is found')
  endif
enddef

# Format the entire file.
# If a language server supporting range formatting is not found and
# 'canFallback' is true then use builtin formatting.
def DocFormat(fname: string, canFallback: bool)
  var lspserver: dict<any> = buf.BufLspServerGet(bufnr(), 'documentFormatting')
  if !lspserver->empty()
    lspserver.textDocFormat(fname, false, 0, 0)
    return
  endif

  if canFallback
    util.WarnMsg('Formatting unsupported; falling back to built-in.')
    execute 'keepjumps normal! 1GgqG'
  elseif !&filetype->empty()
    util.ErrMsg($'Language server for "{&filetype}" file type supporting "documentFormatting" feature is not found')
  # else
    # util.ErrMsg('No language server supporting "documentFormatting" feature is found')
  endif
enddef

# If 'range_args' is false, then format the entire file.  Otherwise format a
# range of lines.
export def TextDocFormat(range_args: number, line1: number, line2: number)
  if !&modifiable
    util.ErrMsg('Current file is not a modifiable file')
    return
  endif

  var fname: string = @%
  const canFallback = opt.lspOptions.formatFallback &&
					&formatexpr !=# 'lsp#lsp#FormatExpr()'
  if range_args > 0
    DocRangeFormat(fname, line1, line2, canFallback)
  else
    DocFormat(fname, canFallback)
  endif
enddef

# Support for textDocument/onTypeFormatting is implemented in
# autoload/lsp/ontypeformat.vim (opt-in via the 'onTypeFormatting' option).

# Display all the locations where the current symbol is called from.
# Uses LSP "callHierarchy/incomingCalls" request
export def IncomingCalls()
  var lspserver: dict<any> = buf.CurbufGetServerChecked('callHierarchy')
  if lspserver->empty()
    return
  endif

  lspserver.incomingCalls(@%)
enddef

# Display all the symbols used by the current symbol.
# Uses LSP "callHierarchy/outgoingCalls" request
export def OutgoingCalls()
  var lspserver: dict<any> = buf.CurbufGetServerChecked('callHierarchy')
  if lspserver->empty()
    return
  endif

  lspserver.outgoingCalls(@%)
enddef

# Display the type hierarchy for the current symbol.  Direction is 0 for
# sub types and 1 for super types.
export def TypeHierarchy(direction: number)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('typeHierarchy')
  if lspserver->empty()
    return
  endif

  lspserver.typeHierarchy(direction)
enddef

# Rename a symbol
# Uses LSP "textDocument/rename" request
export def Rename(a_newName: string)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('rename')
  if lspserver->empty()
    return
  endif

  var newName: string = a_newName
  if newName->empty()
    var sym: string = expand('<cword>')
    newName = input($"Rename symbol '{sym}' to: ", sym)
    if newName->empty()
      return
    endif

    # clear the input prompt
    :echo "\r"
  endif

  lspserver.renameSymbol(newName)
enddef

# Perform a code action
# Uses LSP "textDocument/codeAction" request
def CurbufGetCodeActionServersChecked(): list<dict<any>>
  return codeaction.CurbufGetCodeActionServersChecked()
enddef

export def CodeAction(line1: number, line2: number, query: string)
  var lspservers = CurbufGetCodeActionServersChecked()
  if lspservers->empty()
    return
  endif

  var fname: string = @%
  var bnr = bufnr()
  # Shared mutable aggregation state captured by all async callbacks.
  var state = {
    bnr: bnr,
    pending: lspservers->len(),
    selectorQuery: '',
    actions: []
  }

  for lspserver in lspservers
    # Fan out requests in parallel; callback merges replies into shared state.
    lspserver.codeActionAsync(fname, line1, line2, query,
	function(codeaction.CodeActionReply, [state]))
  endfor
enddef

export def AutoFix(line1: number = 0, line2: number = 0)
  var lspservers = CurbufGetCodeActionServersChecked()
  if lspservers->empty()
    return
  endif

  var fname: string = @%
  var bnr = bufnr()
  # Default to current line if no range is given
  var start = line1 > 0 ? line1 : line('.')
  var end_ = line2 > 0 ? line2 : line('.')

  # Collect all diagnostics strictly within the range
  var allDiags = diag.GetDiagsForBuf(bnr)
  var rangeDiags = []
  for d in allDiags
    var dline = d.range.start.line + 1
    if dline >= start && dline <= end_
      rangeDiags->add(d)
    endif
  endfor
  # Sort by line descending (bottom to top)
  rangeDiags->sort((a, b) => b.range.start.line - a.range.start.line)

  if rangeDiags->empty()
    util.WarnMsg('No diagnostics found in the selected range')
    return
  endif

  # Setup state for diagnostic processing
  var state = {
    servers: lspservers,
    fname: fname,
    bnr: bnr,
    errorOccurred: false
  }

  # Start processing diagnostics from the first one.
  # Per-diagnostic pending/action aggregation is initialized in
  # codeaction.AutoFixProcessDiag().
  codeaction.AutoFixProcessDiag(rangeDiags, 0, state)
enddef

# Perform a source code action for the whole file.
export def SourceCodeAction(kind: string, queryArg: string)
  # Reuse the generic selector syntax so this command stays aligned with
  # :LspCodeAction filtering semantics.
  var query = $'only:{kind}'
  var selector = queryArg->trim()
  if selector == ''
    # Match historical behavior: default to the first filtered action.
    selector = '1'
  endif
  query ..= $'#{selector}'

  CodeAction(1, line('$'), query)
enddef

# Code lens
# Uses LSP "textDocument/codeLens" request
export def CodeLens()
  var lspserver: dict<any> = buf.CurbufGetServerChecked('codeLens')
  if lspserver->empty()
    return
  endif

  lspserver.codeLens(@%)
enddef

# Perform a workspace wide symbol lookup
# Uses LSP "workspace/symbol" request
export def SymbolSearch(queryArg: string, cmdmods: string)
  var lspserver: dict<any> = buf.CurbufGetServerChecked('workspaceSymbol')
  if lspserver->empty()
    return
  endif

  var query: string = queryArg
  if query->empty()
    query = input('Lookup symbol: ', expand('<cword>'))
    if query->empty()
      return
    endif
  endif
  :redraw!

  lspserver.workspaceQuery(query, true, cmdmods)
enddef

# Display the list of workspace folders
export def ListWorkspaceFolders()
  var lspservers: list<dict<any>> = buf.CurbufGetServers()
  for lspserver in lspservers
    util.InfoMsg($'Workspace Folders: "{lspserver.name}" {lspserver.workspaceFolders->string()}')
  endfor
enddef

# Add a workspace folder. Default is to use the current folder.
export def AddWorkspaceFolder(dirArg: string)
  var dirName: string = dirArg
  if dirName->empty()
    dirName = input('Add Workspace Folder: ', getcwd(), 'dir')
    if dirName->empty()
      return
    endif
  endif
  :redraw!
  if !dirName->isdirectory()
    util.ErrMsg($'{dirName} is not a directory')
    return
  endif

  var lspservers: list<dict<any>> = buf.CurbufGetServers()

  for lspserver in lspservers
    lspserver.addWorkspaceFolder(dirName)
  endfor
enddef

# Remove a workspace folder. Default is to use the current folder.
export def RemoveWorkspaceFolder(dirArg: string)
  var dirName: string = dirArg
  if dirName->empty()
    dirName = input('Remove Workspace Folder: ', getcwd(), 'dir')
    if dirName->empty()
      return
    endif
  endif
  :redraw!
  if !dirName->isdirectory()
    util.ErrMsg($'{dirName} is not a directory')
    return
  endif

  var lspservers: list<dict<any>> = buf.CurbufGetServers()
  for lspserver in lspservers
    lspserver.removeWorkspaceFolder(dirName)
  endfor
enddef

# expand the previous selection or start a new selection
export def SelectionExpand()
  var lspserver: dict<any> = buf.CurbufGetServerChecked('selectionRange')
  if lspserver->empty()
    return
  endif

  lspserver.selectionExpand()
enddef

# shrink the previous selection or start a new selection
export def SelectionShrink()
  var lspserver: dict<any> = buf.CurbufGetServerChecked('selectionRange')
  if lspserver->empty()
    return
  endif

  lspserver.selectionShrink()
enddef

# fold the entire document
export def FoldDocument()
  var lspserver: dict<any> = buf.CurbufGetServerChecked('foldingRange')
  if lspserver->empty()
    return
  endif

  if &foldmethod != 'manual'
    util.ErrMsg("Only works when 'foldmethod' is 'manual'")
    return
  endif

  var fname: string = @%
  lspserver.foldRange(fname)
enddef

# Enable diagnostic highlighting for all the buffers
export def DiagHighlightEnable()
  diag.DiagsHighlightEnable()
enddef

# Disable diagnostic highlighting for all the buffers
export def DiagHighlightDisable()
  diag.DiagsHighlightDisable()
enddef

# Function to use with the 'tagfunc' option.
export def TagFunc(pat: string, flags: string, info: dict<any>): any
  var lspserver: dict<any> = buf.CurbufGetServerChecked('definition')
  if lspserver->empty()
    return v:null
  endif

  return lspserver.tagFunc(pat, flags, info)
enddef

# Function to use with the 'formatexpr' option.
export def FormatExpr(): number
  var lspserver: dict<any> = buf.CurbufGetServerChecked('documentRangeFormatting')
  if lspserver->empty()
    return 1
  endif

  if ['i', 'R', 'ic', 'ix']->index(mode()) != -1
    # When 'formatexpr' is called in insert mode to format a line exceeding
    # 'textwidth', use internal formatting.
    return 1
  endif

  lspserver.textDocFormat(@%, true, v:lnum, v:lnum + v:count - 1)
  return 0
enddef

export def RegisterCmdHandler(cmd: string, Handler: func)
  codeaction.RegisterCmdHandler(cmd, Handler)
enddef

# Command-line completion for the ":LspServer <cmd>" and ":LspDiag <cmd>" sub
# commands
def LspSubCmdComplete(cmds: list<string>, arglead: string, cmdline: string, cursorPos: number): list<string>
  var wordBegin = cmdline->match('\s\+\zs\S', cursorPos)
  if wordBegin == -1
    return cmds
  endif

  # Make sure there are no additional sub-commands. This keeps completion
  # strict for one-level command grammars such as ":LspServer show ...".
  var wordEnd = cmdline->stridx(' ', wordBegin)
  if wordEnd == -1
    return cmds->filter((_, val) => val =~ $'^{arglead}')
  endif

  return []
enddef

# Command-line completion for the ":LspDiag highlight" command
def LspDiagHighlightComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  return LspSubCmdComplete(['enable', 'disable', 'toggle'], arglead, cmdline, cursorPos)
enddef

# Command-line completion for the ":LspDiag" command
export def LspDiagComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  var wordBegin = -1
  var wordEnd = -1
  var l = ['first', 'current', 'here', 'highlight', 'last', 'next', 'nextWrap',
           'prev', 'prevWrap', 'show']

  # Skip the command name
  var i = cmdline->stridx(' ', 0)
  wordBegin = cmdline->match('\s\+\zs\S', i)
  if wordBegin == -1
    return l
  endif

  wordEnd = cmdline->stridx(' ', wordBegin)
  if wordEnd == -1
    return filter(l, (_, val) => val =~ $'^{arglead}')
  endif

  var cmd = cmdline->strpart(wordBegin, wordEnd - wordBegin)
  if cmd == 'highlight'
    return LspDiagHighlightComplete(arglead, cmdline, wordEnd)
  endif

  return []
enddef

# ":LspDiag" command handler
export def LspDiagCmd(args: string, cmdCount: number, force: bool)
  # Keep explicit string dispatch for predictable CLI behavior and messages.
  if args->stridx('highlight') == 0
    if args[9] == ' '
      var subcmd = args[10 : ]->trim()
      if subcmd == 'enable'
	diag.DiagsHighlightEnable()
      elseif subcmd == 'disable'
	diag.DiagsHighlightDisable()
      elseif subcmd == 'toggle'
	diag.DiagsHighlightToggle()
      else
	util.ErrMsg($':LspDiag highlight - Unsupported argument "{subcmd}"')
      endif
    else
      util.ErrMsg('Argument required for ":LspDiag highlight"')
    endif
  elseif args == 'first'
    diag.LspDiagsJump('first', 0)
  elseif args == 'current'
    LspShowCurrentDiag(force)
  elseif args == 'here'
    diag.LspDiagsJump('here', 0)
  elseif args == 'last'
    diag.LspDiagsJump('last', 0)
  elseif args == 'next'
    diag.LspDiagsJump('next', cmdCount)
  elseif args == 'nextWrap'
    diag.LspDiagsJump('nextWrap', cmdCount)
  elseif args == 'prev'
    diag.LspDiagsJump('prev', cmdCount)
  elseif args == 'prevWrap'
    diag.LspDiagsJump('prevWrap', cmdCount)
  elseif args == 'show'
    ShowDiagnostics()
  else
    util.ErrMsg($':LspDiag - Unsupported argument "{args}"')
  endif
enddef

# Command-line completion for the ":LspServer debug" command
def LspServerDebugComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  return LspSubCmdComplete(['errors', 'messages', 'off', 'on'], arglead,
			   cmdline, cursorPos)
enddef

# Command-line completion for the ":LspServer show" command
def LspServerShowComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  return LspSubCmdComplete(['capabilities', 'initializeRequest', 'messages',
			    'status'], arglead, cmdline, cursorPos)
enddef

# Command-line completion for the ":LspServer trace" command
def LspServerTraceComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  return LspSubCmdComplete(['messages', 'off', 'verbose'], arglead, cmdline,
			   cursorPos)
enddef

# Command-line completion for the ":LspServer" command
export def LspServerComplete(arglead: string, cmdline: string, cursorPos: number): list<string>
  var wordBegin = -1
  var wordEnd = -1
  var l = ['debug', 'restart', 'show', 'trace', 'stop', 'start']

  # Skip the command name
  var i = cmdline->stridx(' ', 0)
  wordBegin = cmdline->match('\s\+\zs\S', i)
  if wordBegin == -1
    return l
  endif

  wordEnd = cmdline->stridx(' ', wordBegin)
  if wordEnd == -1
    return filter(l, (_, val) => val =~ $'^{arglead}')
  endif

  var cmd = cmdline->strpart(wordBegin, wordEnd - wordBegin)
  if cmd == 'debug'
    return LspServerDebugComplete(arglead, cmdline, wordEnd)
  elseif cmd == 'show'
    return LspServerShowComplete(arglead, cmdline, wordEnd)
  elseif cmd == 'trace'
    return LspServerTraceComplete(arglead, cmdline, wordEnd)
  endif

  return []
enddef

# ":LspServer" command handler
export def LspServerCmd(args: string)
  if args->stridx('debug') == 0
    if args[5] == ' '
      var subcmd = args[6 : ]->trim()
      ServerDebug(subcmd)
    else
      util.ErrMsg('Argument required for ":LspServer debug"')
    endif
  elseif args == 'restart'
    RestartServer()
  elseif args->stridx('show') == 0
    if args[4] == ' '
      var subcmd = args[5 : ]->trim()
      ShowServer(subcmd)
    else
      util.ErrMsg('Argument required for ":LspServer show"')
    endif
  elseif args->stridx('start') == 0
    StartServerByUser()
  elseif args->stridx('stop') == 0
    StopServerByUser()
  elseif args->stridx('trace') == 0
    if args[5] == ' '
      var subcmd = args[6 : ]->trim()
      ServerTraceSet(subcmd)
    else
      util.ErrMsg('Argument required for ":LspServer trace"')
    endif
  else
    util.ErrMsg($'LspServer - Unsupported argument "{args}"')
  endif
enddef

# A buffer opened from the answer of a server instance is attached to it (see
# RehomeBuffer()).  Set at the end of the script: setting it compiles the
# function, and the functions it calls must be defined.
origin.SetRehome(RehomeBuffer)

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
