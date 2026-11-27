vim9script

# The origin of a file: the language server instance whose answer opened it,
# e.g. by going to a definition, or from a list of references.  When the
# workspace root of the file is not known (e.g. a library file), it is
# attached to the instance of its origin (see lsp#lsp#ServerRoots()).

# The files of the answer of a language server instance that is being
# handled: "server" is the instance, and "files" has the full path of each
# file (see Begin()).
var pending: dict<any> = {server: {}, files: {}}

# The quickfix and location lists filled with the answer of a language server
# instance: maps a number stored in the "context" of a list to a Dict with the
# instance ("server") and the full path of each file in the list ("files").
# The "context" is used rather than the id of the list, because a location
# list copied to a new window (e.g. by ":split") gets a new id.
var lists: dict<dict<any>> = {}

# Number of the lists recorded in "lists"
var listCount = 0

# The function called by Opening() for a loaded buffer, set by SetRehome()
var Rehome: func(number, dict<any>) = null_function

# Returns the full path of the file "fname"
def FullPath(fname: string): string
  return fname->fnamemodify(':p')
enddef

# The answer of the language server instance "lspserver" with the files
# "fnames" is handled until End() is called: the files opened (or loaded)
# meanwhile have this origin.  Returns the answer handled before, to pass to
# End().
export def Begin(lspserver: dict<any>, fnames: list<string>): dict<any>
  var files: dict<bool> = {}
  for fname in fnames
    files[FullPath(fname)] = true
  endfor
  var saved = pending
  pending = {server: lspserver, files: files}
  return saved
enddef

# The answer passed to Begin() is handled.  "saved" is the value returned by
# Begin().
export def End(saved: dict<any>)
  pending = saved
enddef

# Set the function called with a buffer number and a language server instance
# when a file of the answer of that instance is opened in an existing buffer
# (see Opening())
export def SetRehome(F: func(number, dict<any>))
  Rehome = F
enddef

# The file "fname" is opened, e.g. to go to a location.  If it is a file of
# the answer passed to Begin(), and it has a buffer (which may be attached to
# a server instance already), then call the function set by SetRehome(), to
# attach the buffer to the instance of its origin.
export def Opening(fname: string)
  var fullName = FullPath(fname)
  if Rehome == null_function || !pending.files->has_key(fullName)
    return
  endif
  var bnr = fullName->bufnr()
  if bnr != -1
    Rehome(bnr, pending.server)
  endif
enddef

# Returns the context to set for a quickfix or location list filled with the
# files "fnames" from the answer of the language server instance "lspserver".
# The files opened from this list, while it is the current list, have this
# origin.
export def ListContext(lspserver: dict<any>, fnames: list<string>): dict<any>
  ForgetLists()
  listCount += 1
  var files: dict<bool> = {}
  for fname in fnames
    files[FullPath(fname)] = true
  endfor
  lists[listCount] = {server: lspserver, files: files}
  return {lspOrigin: listCount}
enddef

# Returns the number stored by ListContext() in the context "context" of a
# list, or 0 if there is none
def ListNr(context: any): number
  if context->type() != v:t_dict
    return 0
  endif
  var nr = context->get('lspOrigin', 0)
  return nr->type() == v:t_number ? nr : 0
enddef

# Forget the lists recorded by ListContext() that are no longer in the
# quickfix stack or in the location list stack of a window
def ForgetLists()
  if lists->empty()
    return
  endif
  var alive: dict<bool> = {}
  for n in range(1, getqflist({nr: '$'}).nr)
    alive[ListNr(getqflist({nr: n, context: 0}).context)] = true
  endfor
  for winid in getwininfo()->mapnew((_, w) => w.winid)
    for n in range(1, getloclist(winid, {nr: '$'}).nr)
      alive[ListNr(getloclist(winid, {nr: n, context: 0}).context)] = true
    endfor
  endfor
  lists->filter((nr, _) => alive->has_key(nr))
enddef

# Returns the origin of the file "fname" in the list with the context
# "context" and the id "id", as a Dict with the number of the list ("nr", see
# ListContext()), its id and the language server instance ("server"), or an
# empty Dict
def ListOrigin(context: any, id: number, fname: string): dict<any>
  var nr = ListNr(context)
  if !lists->has_key(nr) || !lists[nr].files->has_key(fname)
    return {}
  endif
  return {id: id, server: lists[nr].server}
enddef

# Returns the language server instance whose answer opened the buffer "bnr",
# or an empty Dict if not known.  This is the instance passed to Begin() if
# its answer is handled and has the file of the buffer, else the instance of
# the current quickfix list, or of the location list of the current window,
# if it has the file (the most recently created of both lists).
export def Find(bnr: number): dict<any>
  var fname = bnr->bufname()
  if fname->empty()
    return {}
  endif
  fname = FullPath(fname)
  if pending.files->has_key(fname)
    return pending.server
  endif

  if lists->empty()
    return {}
  endif
  var qf = getqflist({id: 0, context: 0})
  var loc = getloclist(0, {id: 0, context: 0})
  var qfOrigin = ListOrigin(qf.context, qf.id, fname)
  var locOrigin = ListOrigin(loc.context, loc.id, fname)
  # The ids of the quickfix and location lists increase together
  if !qfOrigin->empty()
      && (locOrigin->empty() || qfOrigin.id > locOrigin.id)
    return qfOrigin.server
  endif
  return locOrigin->get('server', {})
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
