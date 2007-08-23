" Vim completion script	- hit 80% complete tasks
" Version:	0.76.6
" Language:	Java
" Maintainer:	cheng fang <fangread@yahoo.com.cn>
" Last Change:	2007-08-23
" Copyright:	Copyright (C) 2006-2007 cheng fang. All rights reserved.
" License:	Vim License	(see vim's :help license)


" constants							{{{1
" input context type
let s:CONTEXT_AFTER_DOT		= 1
let s:CONTEXT_METHOD_PARAM	= 2
let s:CONTEXT_IMPORT		= 3
let s:CONTEXT_IMPORT_STATIC	= 4
let s:CONTEXT_INCOMPLETE_WORD	= 5
let s:CONTEXT_PACKAGE_DECL	= 6 
let s:CONTEXT_OTHER 		= 0


let s:ARRAY_TYPE_MEMBERS = [
\	{'kind': 'm',		'word': 'clone(',	'abbr': 'clone()',	'menu': 'Object clone()', },
\	{'kind': 'm',		'word': 'equals(',	'abbr': 'equals()',	'menu': 'boolean equals(Object)', },
\	{'kind': 'm',		'word': 'getClass(',	'abbr': 'getClass()',	'menu': 'Class Object.getClass()', },
\	{'kind': 'm',		'word': 'hashCode(',	'abbr': 'hashCode()',	'menu': 'int hashCode()', },
\	{'kind': 'f',		'word': 'length',				'menu': 'int'},
\	{'kind': 'm',		'word': 'notify(',	'abbr': 'notify()',	'menu': 'void Object.notify()', },
\	{'kind': 'm',		'word': 'notifyAll(',	'abbr': 'notifyAll()',	'menu': 'void Object.notifyAll()', },
\	{'kind': 'm',		'word': 'toString(',	'abbr': 'toString()',	'menu': 'String toString()', },
\	{'kind': 'm',		'word': 'wait(',	'abbr': 'wait()',	'menu': 'void Object.wait() throws InterruptedException', },
\	{'kind': 'm', 'dup': 1, 'word': 'wait(',	'abbr': 'wait()',	'menu': 'void Object.wait(long timeout) throws InterruptedException', },
\	{'kind': 'm', 'dup': 1, 'word': 'wait(',	'abbr': 'wait()',	'menu': 'void Object.wait(long timeout, int nanos) throws InterruptedException', }]

let s:JSP_BUILTIN_OBJECTS = {'session':	'javax.servlet.http.HttpSession',
\	'request':	'javax.servlet.http.HttpServletRequest',
\	'response':	'javax.servlet.http.HttpServletResponse',
\	'pageContext':	'javax.servlet.jsp.PageContext', 
\	'application':	'javax.servlet.ServletContext',
\	'config':	'javax.servlet.ServletConfig',
\	'out':		'javax.servlet.jsp.JspWriter',
\	'page':		'javax.servlet.jsp.HttpJspPage', }

let s:CLASS_ABBRS = {'Object': 'java.lang.Object',
\	'Class': 'java.lang.Class', 
\	'System': 'java.lang.System', 
\	'String': 'java.lang.String', 
\	'StringBuffer': 'java.lang.StringBuffer', 
\	}
let s:INVALID_FQNS = ['java', 'java.lang', 'com', 'org', 'javax']

" local variables						{{{1
let b:context_type = s:CONTEXT_OTHER
"let b:statement = ''			" statement before cursor
let b:dotexpr = ''			" expression before '.'
let b:incomplete = ''			" incomplete word, three types: a. dotexpr.method(|) b. new classname(|) c. dotexpr.ab|
let b:errormsg = ''
let b:packages = []			
let b:fqns = []
let b:ast = {}				" Abstract Syntax Tree of the current buf

" script variables						{{{1
let s:cache = {}	" FQN -> member list, e.g. {'java.lang.StringBuffer': classinfo, 'java.util': packageinfo, }


" This function is used for the 'omnifunc' option.		{{{1
function! javacomplete#Complete(findstart, base)
  if a:findstart
    let s:et_whole = reltime()
    let start = col('.') - 1
    let s:log = []

    " reset enviroment
    let b:dotexpr = ''
    let b:incomplete = ''
    let b:context_type = s:CONTEXT_OTHER
    if !empty(b:ast) && changenr() > 0
      let b:ast = {}
    endif

    let statement = s:GetStatement()
    call s:WatchVariant('statement: "' . statement . '"')
    let valid = statement =~ '[."(0-9A-Za-z_]\s*$'
    if statement =~ '\.\s*$'
      let valid = statement =~ '[")0-9A-Za-z_\]]\s*\.\s*$' && statement !~ '\<\H\w\+\.\s*$' && statement !~ '\<\(abstract\|assert\|break\|case\|catch\|const\|continue\|default\|do\|else\|enum\|extends\|final\|finally\|for\|goto\|if\|implements\|import\|instanceof\|interface\|native\|new\|package\|private\|protected\|public\|return\|static\|strictfp\|switch\|synchronized\|throw\|throws\|transient\|try\|volatile\|while\|true\|false\|null\)\.\s*$'
    endif
    if !valid
      return -1
    endif

    " import or package declaration
    if statement =~# '^\s*\(import\|package\)\s\+'
      let statement = substitute(statement, '\s\+\.', '.', 'g')
      let statement = substitute(statement, '\.\s\+', '.', 'g')
      if statement =~ '^\s*import\s\+'
	let b:context_type = statement =~# '\<static\s\+' ? s:CONTEXT_IMPORT_STATIC : s:CONTEXT_IMPORT
	let b:dotexpr = substitute(statement, '^\s*import\s\+\(static\s\+\)\?', '', '')
      else
	let b:context_type = s:CONTEXT_PACKAGE_DECL
	let b:dotexpr = substitute(statement, '\s*package\s\+', '', '')
      endif

      let idx_dot = strridx(b:dotexpr, '.')
      " case: " import 	java.util.|"
      if idx_dot == strlen(b:dotexpr)-1
	let b:dotexpr = strpart(b:dotexpr, 0, strlen(b:dotexpr)-1)
      " case: " import 	java.ut|"
      elseif idx_dot != -1
	let b:incomplete = strpart(b:dotexpr, idx_dot+1)
	let b:dotexpr = strpart(b:dotexpr, 0, idx_dot)
      " case: " import 	ja|"
      "else
      endif
      return start - strlen(b:incomplete)
    endif

    let b:dotexpr = statement
    call s:KeepCursor('call s:GenerateImports()')

    " method parameters, treat methodname or 'new' as an incomplete word
    let len = strlen(statement)
    if statement =~ '(\s*$'
      let b:context_type = s:CONTEXT_METHOD_PARAM
      let pos = strridx(statement, '(')
      let s:padding = strpart(statement, pos+1)
      let statement = strpart(statement, 0, pos)
      let start = start - (len - pos)

      " skip a word
      let pos = pos - 1
      while (pos != 0 && statement[pos] =~ '\w')
	let pos = pos - 1
      endwhile
      let b:incomplete = statement
      if pos > 0
	" test case: expr.method(|)
	if statement[pos] == '.'
	  let b:dotexpr = strpart(statement, 0, pos+1)
	  let b:incomplete = strpart(statement, pos+1)
	endif

	" test special case: new ClassName(|)
	if statement[pos] == ' ' && pos-3 >= 0
	  let b:incomplete = strpart(statement, pos-3, 3)
	  if b:incomplete == 'new'
	    let b:dotexpr = strpart(statement, pos+1)
	    " excluding 'new this()' or 'new super()'
	    if b:dotexpr == 'this' || b:dotexpr == 'super'
	      let b:dotexpr = ''
	      let b:incomplete = ''
	      return -1
	    endif
	    return start - strlen(b:dotexpr)
	  endif
	else
	  let idx_begin = match(statement, '\s\+new\s\+[a-zA-Z0-9_. \t\r\n]\+')
	  if idx_begin > -1
	    let idx_end = matchend(statement, '\s\+new\s\+[a-zA-Z0-9_. \t\r\n]\+')
	    if idx_end >= pos
	      let b:dotexpr = substitute(strpart(statement, idx_begin, idx_end-idx_begin), '\s\+new\s\+\([a-zA-Z0-9_. \t\r\n\n]\+\)', '\1', '')
	      let b:dotexpr = substitute(b:dotexpr, '[ \t\r\n]', '', 'g')
	      let b:incomplete = 'new'
	      " excluding 'new this()' or 'new super()'
	      if b:dotexpr == 'this' || b:dotexpr == 'super'
		let b:dotexpr = ''
		let b:incomplete = ''
		return -1
	      endif
	      return start - strlen(b:dotexpr)
	    endif
	  endif
	endif
      else
	if b:incomplete == 'this' || b:incomplete == 'super' 
	  let b:dotexpr = b:incomplete
	  let b:incomplete = 'new'
	  return start - strlen(b:dotexpr)
	else
	  let b:dotexpr = 'this.'
	  return start - strlen(b:incomplete)
	endif
      end
      let b:dotexpr = s:ExtractCleanExpr(b:dotexpr)
      return start - strlen(b:incomplete)
    endif

    " String literal
    if b:dotexpr =~  '"\s*\.\s*$'
      let b:dotexpr = substitute(b:dotexpr, '\s*\.\s*$', '\.', '')
      let b:context_type = s:CONTEXT_AFTER_DOT
      return start - strlen(b:incomplete)
    endif

    let b:dotexpr = s:ExtractCleanExpr(b:dotexpr)

    let end_char = statement[strlen(statement)-1]
    if end_char == '.'
      let b:context_type = s:CONTEXT_AFTER_DOT

    " an incomplete word, identifier, or method
    elseif end_char =~ '\w'
      let b:context_type = s:CONTEXT_INCOMPLETE_WORD
      let idx_dot = strridx(b:dotexpr, '.')
      if idx_dot != -1
	let b:incomplete = strpart(b:dotexpr, idx_dot+1)
	let b:dotexpr = strpart(b:dotexpr, 0, idx_dot+1)
      endif

    else
      let b:context_type = s:CONTEXT_OTHER
      echo 'Cannot correctly parse ' . statement . ''
    end

    return start - strlen(b:incomplete)
  endif


  " Return list of matches.

  call s:WatchVariant('b:context_type: "' . b:context_type . '"  b:incomplete: "' . b:incomplete . '"  b:dotexpr: "' . b:dotexpr . '"')
  if b:dotexpr =~ '^\s*$' && b:incomplete =~ '^\s*$'
    return []
  endif


  let result = []
  if b:dotexpr !~ '^\s*$'
    if b:context_type == s:CONTEXT_AFTER_DOT || b:context_type == s:CONTEXT_INCOMPLETE_WORD
      let result = s:CompleteAfterDot()
    elseif b:context_type == s:CONTEXT_IMPORT || b:context_type == s:CONTEXT_IMPORT_STATIC || b:context_type == s:CONTEXT_PACKAGE_DECL
      let result = s:GetMembers(b:dotexpr)
    elseif b:context_type == s:CONTEXT_METHOD_PARAM
      if b:incomplete == 'new'
	let fqn = s:GetFQN(b:dotexpr)
	if (fqn != '')
	  let result = s:GetConstructorList(fqn, b:dotexpr)
	endif
      else
	let result = s:CompleteAfterDot()
      endif
    endif
  endif


  if len(result) > 0
    " filter according to b:incomplete
    if len(b:incomplete) > 0 && b:incomplete != 'new'
      let result = filter(copy(result), "type(v:val) == type('') ? v:val =~ '^" . b:incomplete . "' : v:val['word'] =~ '^" . b:incomplete . "'")
      if exists('s:padding') && !empty(s:padding)
	for item in result
	  if type(item) == type("")
	    let item .= s:padding
	  else
	   let item.word .= s:padding
	  endif
	endfor
      endif
    endif

    call s:Debug('finish completion' . reltimestr(reltime(s:et_whole)) . 's')
    return result
  endif

  if strlen(b:errormsg) > 0
    echoerr 'omni-completion error: ' . b:errormsg
  endif
endfunction

" Precondition:	b:dotexpr must end with '.'
" return empty string if no matches
function! s:CompleteAfterDot()
  " Firstly, remove the last '.' in the b:dotexpr 
  let expr = strpart(b:dotexpr, 0, strlen(b:dotexpr)-1)
  let expr = s:Trim(expr)	" trim head and tail spaces

  let typename = ''
  if expr =~ '^('
    let idx = matchend(expr, '^\s*(', 1)
    " Assume it is casting conversion
    if idx != -1
      let typename = strpart(expr, idx, s:GetMatchedIndexEx(expr, idx, '(', ')')-idx)
      let expr = strpart(expr, s:GetMatchedIndexEx(expr, 0, '(', ')')+2)
      " "((Object)o).|" or "((Object)o.getCanonicalName()).|"
      if empty(expr)
	return s:GetMemberList(typename)

      " "((Object)o).getClass().|"
      else
	let fqn = s:GetFQN(typename)
	if (fqn != '')
	  let fqn = s:GetNextSubexprType(fqn, expr)
	  if (fqn != '')
	    return s:GetMemberList(fqn)
	  endif
	endif
      endif
    else
      " "(o).getClass().|" --> "o.getClass().|"
      let idx = s:GetMatchedIndexEx(expr, 0, '(', ')')
      let expr = strpart(expr, 1, idx-1) . strpart(expr, idx+1)
    endif
  endif

  " 0. String literal
  call s:Info('P0. "str".|')
  if expr =~  '"$'
    return s:GetMemberList("java.lang.String")
  endif

  let isnew = expr =~ '^new\>'
  if isnew
    let typename = substitute(expr, '^new\s*\([a-zA-Z_$. \t\r\n]\+\)(.*$', '\1', '')
  endif

  " prepend 'this.' if it is a local method. e.g.
  " 	getFoo() --> 	this.getFoo()
  " 	getFoo().foo() --> 	this.getFoo().foo()
  if expr =~ ')\s*$' && !isnew && (stridx(expr, '.') == -1 || stridx(expr, '.') > stridx(expr, '('))
    let expr = 'this.' . expr
  endif


  let list = []
  " Simple expression without dot.
  " Assumes in the following order:
  "    -1) "new String().|"	- new instance
  "	0) "int.|"	- builtin types
  "	1) "str.|"	- Simple variable declared in the file
  "	2) "String.|" 	- Type (whose definition is imported)
  "	3) "java.|"   	- First part of the package name
  if (stridx(expr, '.') == -1)
    if isnew
      call s:Info('S. "new String().|"')
      return s:GetMemberList(typename)
    endif

    call s:Info('S0. "int.|" or "void.|"')
    if s:IsBuiltinType(expr) || expr == 'void'
      return [{'word': 'class', 'abbr': 'class', 'menu': 'Class'}]
    endif

    " 1. assume it as variable 
    let class = s:GetDeclaredClassName(expr)
    call s:Info('S1. "str.|"  classname: "' . class . '"')
    if (class != '')
      " array
      if (class[strlen(class)-1] == ']')
	return s:ARRAY_TYPE_MEMBERS
      elseif s:IsBuiltinType(class)
	return []
      else
	return s:GetMemberList(class)
      endif
    endif

    " 2. assume identifier as a TYPE name. 
    " It is right if there is a fully qualified name matched. Then return member list
    call s:Info('S2. "String.|"')
    let fqn = s:GetFQN(expr)
    if (fqn != '')
      return s:GetStaticMemberList(fqn)
    endif

    " 3. it may be the first part of a package name.
    call s:Info('S3. "java.|"')
    return s:GetMembers(expr)

  "
  " an dot separated expression 
  " Assumes in the following order:
  "	0) "boolean.class.|"	- java.lang.Class
  "	1) "java.lang.String.|"	- A fully qualified class name
  "	
  "	2) "obj.var.|"		- An object's field
  "	3) "obj.getStr().|"	- An method's result
  "	   "getFoo()"	== "this.getFoo()"
  "	   "getFoo().foo()"	== "this.getFoo().foo()"
  "	   "int.class.toString().|"
  "	   "list.toArray().|"
  "	   "new ZipFile(path).|entries().|"
  "	   "(new ZipFile(path)).|entries().|"
  "							  
  "	4) "System.in.|"	- A static field of a type (System)
  "	5) "System.getenv().|"	- Return value of static method getEnv()
  "	
  "	6) "java.lang.Sytem.in.|"	- Same as 4 and type given in FQN
  "	7) "java.lang.System.getenv().|"- Same as 5 and type given in FQN
  "	
  "	8) "java.lang.|"		- Part or Full package name
  "
  else
    if expr !~ ')\s*$'
      " 0.
      call s:Info('C0. "int.class.|" or "Integer.class.|"')
      if expr =~# '\.class$'
	return s:GetMemberList('java.lang.Class')
      endif

      call s:Info('C. check cache')
      if has_key(s:cache, expr)
	return s:GetMembers(expr)
      endif

      " 1.
      call s:Info('C1. "java.lang.String.|"')
      let fqn = s:GetFQN(expr)
      if (fqn != '')
	return s:GetMembers(fqn)
      endif
    endif

    let idx_dot = stridx(expr, '.')
    let first = strpart(expr, 0, idx_dot)
    
    if s:IsBuiltinType(first)
      let tail = strpart(expr, idx_dot+1)
      let idx = matchend(tail, '\s*class\s*\.')
      if idx == -1
	return []
      else
	let fqn = s:GetNextSubexprType('java.lang.Class', strpart(tail, idx))
	if (fqn != '')
	  return s:GetMemberList(fqn)
	endif
      endif
    endif

    " 2|3. 
    let classname = isnew ? typename : s:GetDeclaredClassName(first)
    call s:Info('C2|3. "obj.var.|", or "sb.append().|"  classname: "' . classname . '" for "' . first . '"')
    if (classname != '')
      if s:IsBuiltinType(classname)
	return []
      endif

      let fqn = s:GetFQN(classname)
      if (fqn != '')
	let fqn = s:GetNextSubexprType(fqn, strpart(expr, idx_dot+1))
	if (fqn != '')
	  return s:GetMemberList(fqn)
	endif
      endif
    endif

    " 4|5.
    call s:Info('C4|5. "System.in.|", or "System.getenv().|"')
    let fqn = s:GetFQN(first)
    if (fqn != '')
      let fqn = s:GetNextSubexprType(fqn, strpart(expr, idx_dot+1))
      if (fqn != '')
	return s:GetMemberList(fqn)
      endif
    endif

    " 6|7.
    call s:Info('C6|7. "java.lang.System.in.|", or "java.lang.System.getenv().|"')
    let idx_dot_prev = 0
    let idx_dot_next = idx_dot
    while idx_dot_next != -1 && fqn == ''
      let idx_dot_prev = idx_dot_next
      let subexpr = strpart(expr, 0, idx_dot_next)
      let subexpr = s:Trim(subexpr)
      let subexpr = substitute(subexpr, '\s*\.\s*', '.', 'g')
      let fqn = s:GetFQN(subexpr)
      let idx_dot_next = stridx(expr, '.', idx_dot_prev+1)
      call s:Trace('fqn: "' . fqn . '"' . '  idx_dot_next: ' . idx_dot_next . ' subexpr: ' . subexpr)
    endwhile
    if fqn != ''
      let fqn = s:GetNextSubexprType(fqn, strpart(expr, idx_dot_prev+1))
      if (fqn != '')
	return s:GetMemberList(fqn)
      endif
    endif

    " 8. 
    return s:GetMembers(expr)
  endif

  return []
endfunction


" Quick information						{{{1
function! MyBalloonExpr()
  if (searchdecl(v:beval_text, 1, 0) == 0)
    return s:GetVariableDeclaration()
  endif
  return ''
"  return 'Cursor is at line ' . v:beval_lnum .
"	\', column ' . v:beval_col .
"	\ ' of file ' .  bufname(v:beval_bufnr) .
"	\ ' on word "' . v:beval_text . '"'
endfunction
"set bexpr=MyBalloonExpr()
"set ballooneval

" scanning and parsing							{{{1

" Search back from the cursor position till meeting '{' or ';'.
" '{' means statement start, ';' means end of a previous statement.
" Return: statement before cursor
" Note: It's the base for parsing. And It's OK for most cases.
function! s:GetStatement()
  if getline('.') =~ '^\s*\(import\|package\)\s\+'
    return strpart(getline('.'), match(getline('.'), '\(import\|package\)'), col('.')-1)
  endif

  let lnum_old = line('.')
  let col_old = col('.')

  while 1
    if search('[{;]', 'bW') == 0
      let lnum = 1
      let col  = 1
    else
      if s:InCommentOrLiteral(line('.'), col('.'))
	continue
      endif

      normal w
      let lnum = line('.')
      let col = col('.')
    endif
    break
  endwhile

  silent call cursor(lnum_old, col_old)
  return s:MergeLines(lnum, col, lnum_old, col_old)
endfunction

fu! s:MergeLines(lnum, col, lnum_old, col_old)
  let lnum = a:lnum
  let col = a:col

  let str = ''
  if lnum < a:lnum_old
    let str = s:Prune(strpart(getline(lnum), a:col-1))
    let lnum += 1
    while lnum < a:lnum_old
      let str  .= s:Prune(getline(lnum))
      let lnum += 1
    endwhile
    let col = 1
  endif
  let str .= s:Prune(strpart(getline(a:lnum_old), col-1, a:col_old-col), col)
  let str = substitute(str, '\s\+', ' ', '')
  let str = substitute(str, '\.[ \t]\+', '.', 'g')
  return str
endfu

" Extract a clean expr, removing some non-necessary characters. 
fu! s:ExtractCleanExpr(expr)
  let cmd = substitute(a:expr, '[ \t\r\n]*\.', '.', 'g')
  let cmd = substitute(cmd, '\.[ \t\r\n]*', '.', 'g')
  let pos = strlen(cmd)-1 
  let char = cmd[pos]
  while pos != 0 && cmd[pos] =~ '[a-zA-Z0-9_.)\]]'
    if char == ')'
      let pos = s:GetMatchedIndex(cmd, pos)
    elseif char == ']'
      while char != '['
	let pos = pos - 1
	let char = cmd[pos]
      endwhile
    endif
    let pos = pos - 1
    let char = cmd[pos]
  endwhile
  if (char !~ '[a-zA-Z0-9_]')
    " look back for "new"
    let idx = match(strpart(cmd, 0, pos), '\<new[ \t\r\n]*$')
    let cmd = strpart(cmd, idx != -1 ? idx : pos+1)
  endif
  return cmd
endfu

" Generate the list of imported packages and classes.
" Scan file head to generate package list and fqn list.
" Scan the current line back to file head, ignore comments.
function! s:GenerateImports()
  let b:packages = ['java.lang.']
  let b:fqns = []

  if &ft == 'jsp'
    return s:GenerateImportsInJSP()
  endif

  while 1
    let lnum = search('\<import\>', 'Wb')
    if (lnum == 0)
      break
    endif

    if s:InComment(line("."), col(".")-1)
      continue
    end

    let stat = strpart(getline(lnum), col('.')-1)	" TODO: search semicolon or import keyword, excluding comment
    let RE_IMPORT_DECL = '\<import\>\(\s\+static\>\)\?\s\+\(\(\([a-zA-Z_$][a-zA-Z0-9_$]*\)\(\s*\.\s*[a-zA-Z_$][a-zA-Z0-9_$]*\)*\)\(\s*\.\s*\*\)\?\);'
    if stat =~ RE_IMPORT_DECL
      let item = substitute(stat, RE_IMPORT_DECL . '.*$', '\2', '')
      let item = substitute(item , '\s*\.\s*', '.', 'g')
      if item =~ '\*$'
	call add(b:packages, strpart(item, 0, strlen(item)-1))
      elseif item =~ '[A-Za-z0-9_]$'
	call add(b:fqns, item)
      endif
    endif
  endwhile
endfunction

fu! s:GenerateImportsInJSP()
  let b:packages += ['javax.servlet.', 'javax.servlet.http.', 'javax.servlet.jsp.']

  while 1
    let lnum = search('\<import\s*=[''"]', 'Wb')
    if (lnum == 0)
      break
    endif

    let str = getline(lnum)
    if str =~ '<%\s*@\s*page\>' || str =~ '<jsp:\s*directive.page\>'
      let str = substitute(str, '.*import=[''"]\([a-zA-Z0-9_$.*, \t]\+\)[''"].*', '\1', '')
      for item in split(str, ',')
	let item = substitute(item, '\s', '', 'g')
	if item =~ '\*$'
	  call add(b:packages, strpart(item, 0, strlen(item)-1))
	elseif item =~ '[A-Za-z0-9_]$'
	  call add(b:fqns, item)
	endif
      endfor
    endif
  endwhile
endfu

" Return: The declaration of identifier under the cursor
" Note: The type of a variable must be imported or a fqn.
function! s:GetVariableDeclaration()
  let lnum_old = line('.')
  let col_old = col('.')

  silent call search('[^a-zA-Z0-9$_.,?<>[\] \t\r\n]', 'bW')	" call search('[{};(,]', 'b')
  normal w
  let lnum = line('.')
  let col = col('.')
  if (lnum == lnum_old && col == col_old)
    return ''
  endif

"  silent call search('[;){]')
"  let lnum_end = line('.')
"  let col_end  = col('.')
"  let declaration = ''
"  while (lnum <= lnum_end)
"    let declaration = declaration . getline(lnum)
"    let lnum = lnum + 1
"  endwhile
"  let declaration = strpart(declaration, col-1)
"  let declaration = substitute(declaration, '\.[ \t]\+', '.', 'g')

  silent call cursor(lnum_old, col_old)
  return s:MergeLines(lnum, col, lnum_old, col_old)
endfunction

function! s:FoundClassDeclaration(type)
  let lnum_old = line('.')
  let col_old = col('.')
  call cursor(0, 0)
  let lnum = search('\<\(class\|interface\)\>[ \t\n\r]\+' . a:type . '[ \t\r\n]', '')
  silent call cursor(lnum_old, col_old)
  return lnum
endfu

fu! s:FoundClassLocally(type)
  " current path
  if globpath(expand('%:p:h'), a:type . '.java') != ''
    return 1
  endif

  " 
  let srcpath = javacomplete#GetSourcePath(1)
  let file = globpath(srcpath, substitute(fqn, '\.', '/', 'g') . '.java')
  if file != ''
    return 1
  endif

  return 0
endfu

" regexp samples:
" echo search('\(\(public\|protected|private\)[ \t\n\r]\+\)\?\(\(static\)[ \t\n\r]\+\)\?\(\<class\>\|\<interface\>\)[ \t\n\r]\+HelloWorld[^a-zA-Z0-9_$]', 'W')
" echo substitute(getline('.'), '.*\(\(public\|protected\|private\)[ \t\n\r]\+\)\?\(\(static\)[ \t\n\r]\+\)\?\(\<class\>\|\<interface\>\)\s\+\([a-zA-Z0-9_]\+\)\s\+\(\(implements\|extends\)\s\+\([^{]\+\)\)\?\s*{.*', '["\1", "\2", "\3", "\4", "\5", "\6", "\8", "\9"]', '')
" code sample: 
function! s:GetClassDeclarationOf(type)
  call cursor(0, 0)
  let decl = []

  let lnum = search('\(\<class\>\|\<interface\>\)[ \t\n\r]\+' . a:type . '[^a-zA-Z0-9_$]', 'W')
  if (lnum != 0)
    " TODO: search back for optional 'public | private' and 'static'
    " join lines till to '{'
    let lnum_end = search('{')
    if (lnum_end != 0)
      let str = ''
      while (lnum <= lnum_end)
	let str = str . getline(lnum)
	let lnum = lnum + 1
      endwhile

      exe "let decl = " . substitute(str, '.*\(\<class\>\|\<interface\>\)\s\+\([a-zA-Z0-9_]\+\)\s\+\(\(implements\|extends\)\s\+\([^{]\+\)\)\?\s*{.*', '["\1", "\2", "\4", "\5"]', '')
    endif
  endif

  return decl
endfunction

" return list
"    0	class | interface
"    1	name
"   [2	implements | extends ]
"   [3	parent list ]
function! s:GetThisClassDeclaration()
  let lnum_old = line('.')
  let col_old = col('.')

  while (1)
    call search('\(\<class\C\>\|\<interface\C\>\|\<enum\C\>\)[ \t\r\n]\+', 'bW')
    if !s:InComment(line("."), col(".")-1)
      if getline('.')[col('.')-2] !~ '\S'
	break
      endif
    end
  endwhile

  " join lines till to '{'
  let str = ''
  let lnum = line('.')
  call search('{')
  let lnum_end = line('.')
  while (lnum <= lnum_end)
    let str = str . getline(lnum)
    let lnum = lnum + 1
  endwhile

  
  let declaration = substitute(str, '.*\(\<class\>\|\<interface\>\)\s\+\([a-zA-Z0-9_]\+\)\(\s\+\(implements\|extends\)\s\+\([^{]\+\)\)\?\s*{.*', '["\1", "\2", "\4", "\5"]', '')
  call cursor(lnum_old, col_old)
  if declaration !~ '^['
    echoerr 'Some error occurs when recognizing this class:' . declaration
    return ['', '']
  endif
  exe "let list = " . declaration
  return list
endfunction

" Parser.GetType() in insenvim
function! s:GetDeclaredClassName(var)
  let var = s:Trim(a:var)
  call s:Trace('GetDeclaredClassName for "' . var . '"')
  if var =~# '^\(this\|super\)$'
    return var
  endif


  " Special handling for builtin objects in JSP
  if &ft == 'jsp'
    if get(s:JSP_BUILTIN_OBJECTS, a:var, '') != ''
      return s:JSP_BUILTIN_OBJECTS[a:var]
    endif
  endif


  " If the variable ends with ']', 
  let isArrayElement = 0
  if var[strlen(var)-1] == ']'
    let var = strpart(var, 0, stridx(var, '['))
    let isArrayElement = 1
  endif


  " TODO:
  " use java_parser.vim
  if javacomplete#GetSearchdeclMethod() == 4
  call javacomplete#parse()
  let matchs = []
  for type in b:ast.types
    let matchs += s:SearchNameInAST(type, var, java_parser#MakePos(line('.')-1, col('.')-1))
  endfor
  "call s:Info(var . ' ' . string(matchs) . ' line: ' . line('.') . ' col: ' . col('.'))
  if empty(matchs)
    return ''
  else
    let tree = matchs[len(matchs)-1]
    if isArrayElement
      return tree.tag == 'VARDEF' ? java_parser#type2Str(tree.vartype.elementtype) : ''
    else
      return tree.tag == 'VARDEF' ? java_parser#type2Str(tree.vartype) : ''
    endif
  endif
  endif


  let ic = &ignorecase
  setlocal noignorecase

  let searched = javacomplete#GetSearchdeclMethod() == 2 ? s:Searchdecl(var, 1, 0) : searchdecl(var, 1, 0)
  if (searched == 0)
    " code sample:
    " String tmp; java.
    " 	lang.  String str, value;
    " for (int i = 0, j = 0; i < 10; i++) {
    "   j = 0;
    " }
    let declaration = s:GetVariableDeclaration()
    " Assume it a class member, and remove modifiers
    let class = substitute(declaration, '^\(public\s\+\|protected\s\+\|private\s\+\|abstract\s\+\|static\s\+\|final\s\+\|native\s\+\)*', '', '')
    let class = substitute(class, '\s*\([a-zA-Z0-9_.]\+\)\(\[\]\)\?\s\+.*', '\1\2', '')
    let class = substitute(class, '\([a-zA-Z0-9_.]\)<.*', '\1', '')
    if isArrayElement
      let class = strpart(class, 0, stridx(class, '['))
    endif
    call s:Info('class: "' . class . '" declaration: "' . declaration . '" for ' . a:var)
    let &ignorecase = ic
    if class != '' && class !=# a:var && class !=# 'import' && class !=# 'class'
      return class
    endif
  endif

  let &ignorecase = ic
  call s:Trace('GetDeclaredClassName: cannot find')
  return ''
endfunction

" Precondition:	fqn must be valid
" Return:	type of next subexpr
" NOTE:	ListerFactory.getTypeNameInMultiDotted() in insenvim
function! s:GetNextSubexprType(fqn, expr)
  let expr = substitute(a:expr, '^\s*\.', '', '')
  let expr = substitute(expr, '\s*$', '', '')

  " try to split expr into two parts, if '(' or '.' exists
  " e.g.  expr			   next_subexpr  tail_expr	
  " 	sb.append()		-> sb		+ append()
  " 	append("str").appned()	-> append	+ append()
  let idx = match(expr, '[()\.]')
  let next_subexpr = expr
  let tail_expr = ''
  let isMethod = 0
  if idx > -1
    let next_subexpr = strpart(expr, 0, idx)
    if expr[idx] == '('
      let isMethod = 1
      call s:WatchVariant('expr "' . expr . ' idx ' .idx)
      let tail_expr = strpart(expr, s:GetMatchedIndexEx(expr, idx, '(', ')')+2)
    else
      let tail_expr = strpart(expr, idx)
    endif
  endif
  call s:WatchVariant('fqn ' . a:fqn . ' expr "' . expr . '" next_subexpr: "' . next_subexpr . '" isMethod: "' . isMethod . '" tail_expr: "' . tail_expr . '"')


  " search in the classinfo
  let classinfo = s:DoGetClassInfo(a:fqn)
  if len(classinfo) == 0
    return ''
  endif

  let resulttype = ''
  if next_subexpr == 'this'
    let resulttype = a:fqn
  elseif next_subexpr == 'super'
    let resulttype = a:fqn	" FIXME
  elseif isMethod
      for method in get(classinfo, 'methods', [])
	if method['n'] == next_subexpr
	  " get the class name of return type 
	  let resulttype = method['r']
	endif
      endfor
  elseif type(classinfo) == type({})
      for field in get(classinfo, 'fields', [])
	if field['n'] == next_subexpr
	  " get the class name of field 
	  let resulttype = field['t']
	endif
      endfor
  endif
  call s:WatchVariant('resulttype: ' . resulttype)


  if empty(tail_expr) || resulttype == '' || s:IsBuiltinType(resulttype) || resulttype == 'void'
    return resulttype
  else
    return s:GetNextSubexprType(resulttype, tail_expr)
  endif
endfunction

" using java_parser.vim					{{{1
fu! javacomplete#parse()
  if empty(b:ast)	" changenr() == 0 && 
    call java_parser#InitParser(getline('^', '$'))
    call java_parser#SetLogLevel(5)
    let b:ast = java_parser#compilationUnit()
  endif
endfu

" TODO:
fu! javacomplete#Searchdecl()
  let var  = expand('<cword>')

  let line = line('.')-1
  let col  = col('.')-1


  if var =~# '^\(this\|super\)$'
    if &ft == 'jsp'
      return ''
    endif

    call javacomplete#parse()
    let matchs = s:SearchTypeAt(b:ast, java_parser#MakePos(line, col))

    let stat = s:GetStatement()
    for t in matchs
      if stat =~ t.name
	let coor = java_parser#DecodePos(t.pos)
	return var . '(' . (coor.line+1) . ',' . (coor.col) . ') ' . getline(coor.line+1)
      endif
    endfor
    if len(matchs) > 0
      let coor = java_parser#DecodePos(matchs[len(matchs)-1].pos)
      return var . '(' . (coor.line+1) . ',' . (coor.col) . ') ' . getline(coor.line+1)
    endif
    return ''
  endif

  " Type.this.
  " new Type()
  " new Type(param1, param2)
  " this.field
  " super.field

  let s:log = []

  call s:KeepCursor('call s:GenerateImports()')

  " It may be an imported class.
  let imports = []
  for fqn in b:fqns
    if fqn =~# '\<' . var . '\>$'
      call add(imports, fqn)
    endif
  endfor
  if len(imports) > 1
    echoerr 'Imports conflicts between ' . join(imports, ' and ')
  endif


  " Search in this buffer
  if changenr() == 0
    call javacomplete#parse()
  endif
  let matchs = []
  let targetPos = java_parser#MakePos(line, col)
  for type in b:ast.types
    let matchs += s:SearchNameInAST(type, var, targetPos)
  endfor


  let hint = var . ' '
  if !empty(matchs)
    let tree = matchs[len(matchs)-1]
    let coor = java_parser#DecodePos(tree.pos)
    let hint .=  '(' . (coor.line+1) . ',' . (coor.col) . ') '
    let hint .= getline(coor.line+1)		"string(tree)
  else
    for fqn in imports
      let ci = s:DoGetClassInfo(fqn)
      if !empty(ci)
	let hint .= ' ' . fqn
      endif
      " TODO: get javadoc
    endfor

  endif
  return hint
endfu

fu! s:SearchTypeAt(tree, targetPos)
  let matches = []
  if a:tree.tag == 'TOPLEVEL'
    for type in a:tree.types
      let matches += s:SearchTypeAt(type, a:targetPos)
    endfor
  elseif a:tree.tag == 'CLASSDEF' && (a:targetPos == -1 || a:tree.pos <= a:targetPos && a:targetPos <= get(a:tree, 'endpos', -1))
    call add(matches, a:tree)
    for def in a:tree.defs
      if def.tag == 'CLASSDEF'
	let matches += s:SearchTypeAt(def, a:targetPos)
      endif
    endfor
  endif
  return matches
endfu

" precondition: name must exists in unit.
" return	a stack of matched
" ��������statement����
fu! s:SearchNameInAST(tree, name, targetPos)
  if type(a:tree) == type([])
    return []
  endif
  if !java_parser#IsStatement(a:tree) "&& !(a:tree.pos <= a:targetPos && a:targetPos <= a:tree.endpos)
    return []
  endif

  let matchs = []
  if type(a:tree) == type([])
    for i in a:tree
      let matchs += s:SearchNameInAST(i, a:name, a:targetPos)
    endfor
    return matchs
  endif


  if a:tree.tag == 'CLASSDEF'
    let type = a:tree
    " first, a class?
    if type.name == a:name
      call add(matchs, type)
    endif

    for def in type.defs
      " a field?
      if def.tag == 'VARDEF' && def.name == a:name
	call add(matchs, def)

      " a method?
      elseif def.tag == 'METHODDEF'
	if def.name == a:name
	  call add(matchs, def)
	endif

	" then, a local variable or a parameter in the body ?
	" cursor must be in this block
	if has_key(def, 'body') && def.body.pos <= a:targetPos && a:targetPos <= def.body.endpos
	  " a method parameter?
	  for param in def.params
	    if param.name == a:name
	      call add(matchs, param)
	    endif
	  endfor

	  " It is importan that just move the scanning position, avoid changing the buf!!!
	  call java_parser#GotoPosition(def.body.pos)
	  let block = java_parser#block()
	  let matchs += s:SearchNameInAST(block, a:name, a:targetPos)
	endif

      " in a static block or a nested class?
      else
	let matchs += s:SearchNameInAST(def, a:name, a:targetPos)
      endif
    endfor
    return matchs

  elseif a:tree.tag == 'VARDEF'
    if a:tree.name == a:name
      return [a:tree]
    endif

  elseif a:tree.tag == 'BLOCK'
    let stats = a:tree.stats
    if stats == []
      call java_parser#GotoPosition(a:tree.pos)
      let stats = java_parser#block().stats
    endif
    for stat in stats
      if stat.tag == 'VARDEF'
	let matchs += s:SearchNameInAST(stat, a:name, a:targetPos)

      elseif stat.tag == 'BLOCK'
	let matchs += s:SearchNameInAST(stat, a:name, a:targetPos)

      elseif stat.tag == 'IF'
	let matchs += s:SearchNameInAST(stat.cond, a:name, a:targetPos)
	let matchs += s:SearchNameInAST(stat.thenpart, a:name, a:targetPos)
	if has_key(stat, 'elsepart')
	  let matchs += s:SearchNameInAST(stat.elsepart, a:name, a:targetPos)
	endif
	
      elseif stat.tag == 'FORLOOP'
	for item in stat.init
	  let matchs += s:SearchNameInAST(item, a:name, a:targetPos)
	endfor
	let matchs += s:SearchNameInAST(stat.body, a:name, a:targetPos)

      elseif stat.tag == 'WHILELOOP'
	let matchs += s:SearchNameInAST(stat.cond, a:name, a:targetPos)
	let matchs += s:SearchNameInAST(stat.body, a:name, a:targetPos)

      elseif stat.tag == 'DOLOOP'
	let matchs += s:SearchNameInAST(stat.body, a:name, a:targetPos)

      elseif stat.tag == 'TRY'
	let matchs += s:SearchNameInAST(stat.body, a:name, a:targetPos)
	if has_key(stat, 'catchers')
	  for catch in stat.catchers
	    let matchs += s:SearchNameInAST(catch.param, a:name, a:targetPos)
	    let matchs += s:SearchNameInAST(catch.body, a:name, a:targetPos)
	  endfor
	endif
	if has_key(stat, 'finalizer')
	  let matchs += s:SearchNameInAST(stat.finalizer, a:name, a:targetPos)
	endif

      elseif stat.tag == 'SWITCH'
	for case in stat.cases
	  let matchs += s:SearchNameInAST(case, a:name, a:targetPos)
	endfor

      elseif stat.tag == 'SYNCHRONIZED'
	let matchs += s:SearchNameInAST(stat.body, a:name, a:targetPos)

      endif
    endfor
  endif

  return matchs
endfu


" java							{{{1
" NOTE: See CheckFQN, GetFQN in insenvim
function! s:GetFQN(name)
  " Consider 'this' or 'super' as class name. It will be handled DoGetClassInfo().
  if a:name =~# '^\(this\|super\)$'
    return a:name
  endif

  if a:name =~# '\[\]$'
    return '[Ljava.lang.Object;'
  endif

  " Has user-defined abbreviations?
  if has_key(s:CLASS_ABBRS, a:name)
    return s:CLASS_ABBRS[a:name]
  endif

  call s:Debug('GetFQN: to check case 1: is there ''.'' in "' . a:name . '"?')
  " Assume a:name as FQN if there is a '.' in it
  if (stridx(a:name, '.') != -1)
    if (s:IsFQN(a:name))
      return a:name
    else
      return ''
    endif
  endif

  " quick check
  if index(s:INVALID_FQNS, a:name) != -1
    return ''
  endif

  call s:Debug('GetFQN: to check case 2: is one of b:fqns?')
  let matches = []
  for fqn in b:fqns
    if fqn =~ '\<' . a:name . '$'
      call add(matches, fqn)
    endif
  endfor
  if !empty(matches)
    if len(matches) > 1
      echoerr 'Name "' . a:name . '" conflicts between ' . join(matches, ' and ')
      return ''
    else
      return matches[0]
    endif
  endif

  call s:Debug('GetFQN: to check case 3: a class in this buffer, or same package, or sourcepath?')
  if &ft != 'jsp'
    call javacomplete#parse()
    for t in s:SearchTypeAt(b:ast, -1)
      if t.name == a:name
	return a:name
      endif
    endfor
  endif

  " TODO: solve name conflict
  let srcpath = javacomplete#GetSourcePath(1)
  let file = globpath(substitute(srcpath, javacomplete#GetClassPathSep(), ',', 'g'), substitute(a:name, '\.', '/', 'g') . '.java')
  if file != ''
    return a:name
  endif
  for p in b:packages
    let fqn = p . a:name
    let file = globpath(substitute(srcpath, javacomplete#GetClassPathSep(), ',', 'g'), substitute(fqn, '\.', '/', 'g') . '.java')
    if file != ''
      return fqn
    endif
  endfor

  call s:Debug('GetFQN: to check case 4: a nonlocal class in one of b:packages?')
  " Send a batch of candidates to Reflection for checking and reading class information.
  if !empty(b:packages) && a:name =~ '^\h\(\w*\)$'
    " NOTE: search in cache if b:packages not changed	TODO: compared b:packages with the previous 
    let seplist = ''
    for p in b:packages
      let fqn = p . a:name
      if has_key(s:cache, fqn)
	return fqn
      endif
      let seplist .= fqn . ','
    endfor

    let res = s:RunReflection('-E', seplist, 's:GetFQN in Batch')
    if res =~ "^{'"
      let dict = eval(res)
      let matches = []
      for key in keys(dict)
	if type(dict[key]) == type({})
	  let s:cache[key] = s:Sort(dict[key])
	  if key =~# '\.' . a:name . '$'
	    call add(matches, key)
	  endif
	endif
      endfor
      if len(matches) > 1
	echoerr 'Name conflicts between ' . join(matches, ' and ')
      else
	return matches[0]
      endif
    endif
  endif

  call s:Debug('GetFQN: is not a fqn')
  return ''
endfunction

" Is name a full qualified class name?
" see Parser.IsFQN() in insenvim
function! s:IsFQN(name)
  " An expr cannot be fqn if it contains non-word or non-space char
  if match(a:name, '[^a-zA-Z0-9_. \t\r\n]') > -1
    return 0
  endif

  " quick check
  if index(s:INVALID_FQNS, a:name) != -1
    return 0
  endif

  " already stored in cache
  if has_key(s:cache, a:name)
    return 1
  endif

  if index(values(s:CLASS_ABBRS), a:name) != -1
    return 1
  endif

  " class defined in current source path
  " TODO:

  let res = s:RunReflection('-E', a:name, 's:IsFQN')
  if res =~ "^{'"
    exe 'let dict = ' . res
    for key in keys(dict)
      if type(dict[key]) == type({})
	let s:cache[key] = s:Sort(dict[key])
      elseif type(dict[key]) == type([])
	let s:cache[key] = sort(dict[key])
      endif
    endfor
    return 1
  else
    return 0
  endif

  "let res = s:RunReflection('-e', a:name, 's:IsFQN')
  "return res =~ '^true'
endfunction

fu! s:IsBuiltinType(name)
  return a:name =~# '^\(boolean\|byte\|char\|int\|short\|long\|float\|double\)$'
endfu

" options								{{{1
" Methods to search declaration						{{{2
"	1 - by builtin searchdecl()
"	2 - by special Searchdecl()
"	4 - by java_parser
fu! javacomplete#GetSearchdeclMethod()
  if &ft == 'jsp'
    return 1
  endif
  return exists('s:searchdecl') ? s:searchdecl : 4
endfu

fu! javacomplete#SetSearchdeclMethod(method)
  let s:searchdecl = a:method
endfu

" JDK1.1								{{{2
fu! javacomplete#UseJDK11()
  let s:isjdk11 = 1
endfu

" java compiler								{{{2
fu! javacomplete#GetCompiler()
  return exists('s:compiler') && s:compiler !~  '^\s*$' ? s:compiler : 'javac'
endfu

fu! javacomplete#SetCompiler(compiler)
  let s:compiler = a:compiler
endfu

" jvm launcher								{{{2
fu! javacomplete#GetJVMLauncher()
  return exists('s:interpreter') && s:interpreter !~  '^\s*$' ? s:interpreter : 'java'
endfu

fu! javacomplete#SetJVMLauncher(interpreter)
  if javacomplete#GetJVMLauncher() != a:interpreter
    let s:cache = {}
  endif
  let s:interpreter = a:interpreter
endfu

" sourcepath								{{{2
fu! javacomplete#AddSourcePath(s)
  if !exists('s:sourcepath')
    let s:sourcepath = [a:s]
  elseif index(s:sourcepath, a:s) == -1
    call add(s:sourcepath, a:s)
  endif
endfu

fu! javacomplete#DelSourcePath(s)
  if !exists('s:sourcepath') | return   | endif
  let idx = index(s:sourcepath, a:s)
  if idx != -1
    call remove(s:sourcepath, idx)
  endif
endfu

fu! javacomplete#SetSourcePath(s)
  if type(a:s) == type("")
    let s:sourcepath = split(a:s, javacomplete#GetClassPathSep())
  elseif type(a:s) == type([])
    let s:sourcepath = a:s
  endif
endfu

" return the sourcepath. Given argument, add current path or default package root path
" NOTE: Avoid sourcepath item repeated, otherwise globpath() will return more than
" result.
fu! javacomplete#GetSourcePath(...)
  let sourcepath = ''
  if exists('s:sourcepath')
    let sourcepath = join(s:sourcepath, javacomplete#GetClassPathSep())
  endif

  if a:0 == 0
    return sourcepath
  endif


  let filepath = expand('%:p:h')

  " get source path according to file path and package name
  let packageName = s:GetPackageName()
  if packageName != ''
    let path = substitute(filepath, packageName, '', 'g')
    if sourcepath == ''
      let sourcepath .= path
    elseif sourcepath !~ path
      let sourcepath .= path . javacomplete#GetClassPathSep() . sourcepath
    endif
  endif

  " Consider current path as a sourcepath
  if sourcepath == ''
    return filepath
  elseif sourcepath !~ path
    return filepath . javacomplete#GetClassPathSep() . sourcepath
  endif
endfu

" classpath								{{{2
fu! javacomplete#AddClassPath(s)
  if !exists('s:classpath')
    let s:classpath = [a:s]
  elseif index(s:classpath, a:s) == -1
    call add(s:classpath, a:s)
  endif
  let s:cache = {}
endfu

fu! javacomplete#DelClassPath(s)
  if !exists('s:classpath') | return   | endif
  let idx = index(s:classpath, a:s)
  if idx != -1
    call remove(s:classpath, idx)
  endif
endfu

fu! javacomplete#SetClassPath(s)
  if type(a:s) == type("")
    let s:classpath = split(a:s, javacomplete#GetClassPathSep())
  elseif type(a:s) == type([])
    let s:classpath = a:s
  endif
  let s:cache = {}
endfu

fu! javacomplete#GetClassPathSep()
  return !has("win32") ? ":" : ";"
endfu

fu! javacomplete#GetClassPath()
  return exists('s:classpath') ? join(s:classpath, javacomplete#GetClassPathSep()) : ''
endfu

" s:GetClassPath()							{{{2
fu! s:GetClassPath()
  let path = s:GetJavaCompleteClassPath() . javacomplete#GetClassPathSep()

  if exists('b:classpath') && b:classpath !~ '^\s*$'
    return path . b:classpath
  endif

  if exists('s:classpath')
    return path . javacomplete#GetClassPath()
  endif

  if exists('g:java_classpath') && g:java_classpath !~ '^\s*$'
    return path . g:java_classpath
  endif

  return path . $CLASSPATH
endfu

fu! s:GetJavaCompleteClassPath()
  let classfile = globpath(&rtp, 'autoload/Reflection.class')
  if classfile == ''
    let classfile = globpath($HOME, 'Reflection.class')
  endif
  if classfile == ''
    " try to find source file and compile to $HOME
    let srcfile = globpath(&rtp, 'autoload/Reflection.java')
    if srcfile != ''
      exe '!' . javacomplete#GetCompiler() . ' -d "' . $HOME . '" "' . srcfile . '"'
      let classfile = globpath($HOME, 'Reflection.class')
      if classfile == ''
	echo srcfile . ' can not be compiled. Please check it'
      endif
    else
      echo 'No Reflection.class found in $HOME or any autoload directory of the &rtp. And no Reflection.java found in any autoload directory of the &rtp to compile.'
    endif
  endif
  return fnamemodify(classfile, ':p:h')
endfu

" s:GetPackageName()							{{{2
fu! s:GetPackageName()
  let lnum_old = line('.')
  let col_old = col('.')

  call cursor(0, 0)
  let lnum = search('^\s*package[ \t\r\n]\+\([a-zA-Z][a-zA-Z0-9.]*\);', 'w')
  let packageName = substitute(getline(lnum), '^\s*package\s\+\([a-zA-Z][a-zA-Z0-9.]*\);', '\1', '')

  call cursor(lnum_old, col_old)
  return packageName
endfu

fu! s:IsStatic(modifier)
  return a:modifier[strlen(a:modifier)-4]
endfu

" utilities							{{{1
fu! s:Index(list, expr, key)
  let i = 0
  while i < len(a:list)
    if get(a:list[i], key, '') == expr
      return i
    endif
    let i += 1
  endwhile
  return -1
endfu

fu! s:Match(list, expr, key)
  let i = 0
  while i < len(a:list)
    if get(a:list[i], key, '') =~ expr
      return i
    endif
    let i += 1
  endwhile
  return -1
endfu

fu! s:KeepCursor(cmd)
  let lnum_old = line('.')
  let col_old = col('.')
  exe a:cmd
  call cursor(lnum_old, col_old)
endfu

fu! s:InCommentOrLiteral(line, col)
  if has("syntax")
    return synIDattr(synID(a:line, a:col, 1), "name") =~? '\(Comment\|String\|Character\)'
  endif
endfu

function! s:InComment(line, col)
  if has("syntax")
    return synIDattr(synID(a:line, a:col, 1), "name") =~? 'comment'
  endif
"  if getline(a:line) =~ '\s*\*'
"    return 1
"  endif
"  let idx = strridx(getline(a:line), '//')
"  if idx >= 0 && idx < a:col
"    return 1
"  endif
"  return 0
endfunction

" set string literal empty, remove comments, trim begining or ending spaces
" test case: ' 	sb. /* block comment*/ append( "stringliteral" ) // comment '
function! s:Prune(str, ...)
  let str = substitute(a:str, '"\(\\\(["\\''ntbrf]\)\|[^"]\)*"', '""', 'g')
  let str = substitute(str, '\/\/.*', '', 'g')
  let str = s:RemoveBlockComments(str)
  let str = substitute(str, '^\s*', '', '')
  if a:0 == 0
    let str = substitute(str, '\s*$', '', '')
  endif
  return str
endfunction

" Given argument, replace block comments with spaces of same number
fu! s:RemoveBlockComments(str, ...)
  let result = a:str
  let ib = match(result, '\/\*')
  let ie = match(result, '\*\/')
  while ib != -1 && ie != -1 && ib < ie
    let result = strpart(result, 0, ib) . (a:0 == 0 ? ' ' : repeat(' ', ie-ib+2)) . result[ie+2: ]
    let ib = match(result, '\/\*')
    let ie = match(result, '\*\/')
  endwhile
  return result
endfu

fu! s:Trim(str)
  let str = substitute(a:str, '^\s*', '', '')
  return substitute(str, '\s*$', '', '')
endfu

" TODO: search pair used in string, like 
" 	'create(ao.fox("("), new String).foo().'
function! s:GetMatchedIndexEx(str, idx, one, another)
  let pos = a:idx
  while 0 <= pos && pos < len(a:str)
    let pos = match(a:str, '['. a:one . a:another .']', pos+1)
    if pos != -1
      if a:str[pos] == a:one
	let pos = s:GetMatchedIndexEx(a:str, pos, a:one, a:another)
      elseif a:str[pos] == a:another
	break
      endif
    endif
  endwhile
  return 0 <= pos && pos < len(a:str) ? pos : -3
endfunction

function! s:GetMatchedIndex(str, idx)
  let pos = a:idx
  while pos >= 0 && a:str[pos] != '('
    let pos -= 1
    if (a:str[pos] == ')')
      let pos = s:GetMatchedIndex(a:str, pos-1)-1
    endif
  endwhile
  return pos
endfunction

fu! s:GotoUpperBracket()
  let searched = 0
  while (!searched)
    call search('[{}]', 'bW')
    if getline('.')[col('.')-1] == '}'
      normal %
    else
      let searched = 1
    endif
  endwhile
endfu

" Improve recognition of variable declaration using my version of searchdecl() for accuracy reason.
" TODO:
fu! s:Searchdecl(name, ...)
  let global = a:0 > 0 ? a:1 : 0
  let thisblock = a:0 > 1 ? a:2 : 1

  call search('\<' . a:name . '\>', 'bW')
  let lnum_old = line('.')
  let col_old = col('.')

  call s:GotoUpperBracket()
  let lnum_bracket = line('.')
  let col_bracket = col('.')
  call search('\<' . a:name . '\>', 'W', lnum_old)
  if line('.') != lnum_old || col('.') != col_old
    return 0
  endif

  " search globally
  if global
    call cursor(lnum_bracket, col_bracket)
    " search backward
    while (1)
      if search('\([{}]\|\<' . a:name . '\>\)', 'bW') == 0
	break
      endif
      if s:InComment(line('.'), col('.')) "|| s:InStringLiteral()
        continue
      endif
      let cword = expand('<cword>')
      if cword == a:name
	return 0
      endif
      if getline('.')[col('.')-1] == '}'
	normal %
      endif
    endwhile

    call cursor(lnum_old, col_old)
    " search forward
    call search('[{};]', 'W')
    while (1)
      if search('\([{}]\|\<' . a:name . '\>\)', 'W') == 0
	break
      endif
      if s:InComment(line('.'), col('.')) "|| s:InStringLiteral()
        continue
      endif
      let cword = expand('<cword>')
      if cword == a:name
	return 0
      endif
      if getline('.')[col('.')-1] == '{'
	normal %
      endif
    endwhile
  endif
  return 1
endfu
"nmap <F8> :call <SID>Searchdecl(expand('<cword>'))<CR>

fu! javacomplete#Exe(cmd)
  exe a:cmd
endfu

" Log utilities								{{{1
fu! s:WatchVariant(variant)
  "echoerr a:variant
endfu

" level
" 	5	off/fatal 
" 	4	error 
" 	3	warn
" 	2	info
" 	1	debug
" 	0	trace
fu! javacomplete#SetLogLevel(level)
  let s:loglevel = a:level
endfu

fu! javacomplete#GetLogLevel()
  return exists('s:loglevel') ? s:loglevel : 3
endfu

fu! javacomplete#GetLogContent()
  return s:log
endfu

fu! s:Trace(msg)
  call s:Log(0, a:msg)
endfu

fu! s:Debug(msg)
  call s:Log(1, a:msg)
endfu

fu! s:Info(msg)
  call s:Log(2, a:msg)
endfu

fu! s:Log(level, key, ...)
  if a:level >= javacomplete#GetLogLevel()
    echo a:key
    call add(s:log, a:key)
  endif
endfu

fu! s:System(cmd, caller)
  call s:WatchVariant(a:cmd)
  let t = reltime()
  let res = system(a:cmd)
  call s:Debug(reltimestr(reltime(t)) . 's to exec "' . a:cmd . '" by ' . a:caller)
  return res
endfu

" functions to get information						{{{1
" utilities								{{{2
fu! s:MemberCompare(m1, m2)
  return a:m1['n'] == a:m2['n'] ? 0 : a:m1['n'] > a:m2['n'] ? 1 : -1
endfu

fu! s:Sort(ci)
  let ci = a:ci
  if has_key(ci, 'fields')
    call sort(ci['fields'], 's:MemberCompare')
  endif
  if has_key(ci, 'methods')
    call sort(ci['methods'], 's:MemberCompare')
  endif
  return ci
endfu

" Function to run Reflection						{{{2
fu! s:RunReflection(option, args, log)
  let classpath = ''
  if !exists('s:isjdk11')
    let classpath = ' -classpath "' . s:GetClassPath() . '" '
  endif

  let cmd = javacomplete#GetJVMLauncher() . classpath . ' Reflection ' . a:option . ' "' . a:args . '"'
  return s:System(cmd, a:log)
endfu
" class information							{{{2


fu! s:DoGetClassInfo(class, ...)
  if has_key(s:cache, a:class)
    return s:cache[a:class]
  endif

  let ci = {}

  if a:class =~ ']$'
    return s:DoGetClassInfo('[Ljava.lang.Object;')
  endif

  if a:class =~# '^\(this\|super\)$'
    if &ft == 'jsp'
      let ci = s:DoGetReflectionClassInfo('javax.servlet.jsp.HttpJspPage')
      if a:class == 'this'
	" search methods defined in <%! [declarations] %>
      endif
      return ci
    endif

    call s:Info('A0. ' . a:class)
    call javacomplete#parse()
    let matchs = s:SearchTypeAt(b:ast, java_parser#MakePos(line('.')-1, col('.')-1))
    let t = {}
    let stat = s:GetStatement()
    for m in matchs
      if stat =~ m.name
	let t = m
	break
      endif
    endfor
    if empty(t) && len(matchs) > 0
      let t = matchs[len(matchs)-1]
    endif
    if !empty(t)
      " What will be returned for super?
      " - the protected or public inherited fields and methods. No ctors.
      " - the (public static) fields of interfaces.
      " - the methods of the Object class.
      " What will be returned for this?
      " - besides the above, all fields and methods of current class. No ctors.
      if a:class == 'this'
	let ci = s:AddInheritedClassInfo(s:Tree2ClassInfo(t), t)
      else
	let ci = s:AddInheritedClassInfo({}, t)
      endif
      call s:Sort(ci)
    endif
    return ci
  endif

  " Assumption 1: a class defined in current buffer(maybe an editing file)
  " Search class declaration in current buffer
  if s:FoundClassDeclaration(a:class) != 0
    call s:Info('A1. class in this buffer')
    let ci = s:GetLocalClassInfo(a:class, '%')
    " do not cache it
    if !empty(ci)
      return ci
    endif
  endif

  " Assumption 2: a class defined in current folder (or subfolder)
  let file = globpath(expand('%:p:h'), a:class . '.java')
  let fqn = ''
  if file == ''
    let srcpath = javacomplete#GetSourcePath(1)
    let fqn = stridx(a:class, '.') == -1 ? s:GetFQN(a:class) : a:class
    let file = globpath(substitute(srcpath, javacomplete#GetClassPathSep(), ',', 'g'), substitute(fqn, '\.', '/', 'g') . '.java')
  endif
  if file != ''
    call s:Info('A2. toplevel class in current folder, same package or sourcepath')
    if has_key(s:cache, fqn) "TODO: && NotModified
      return s:cache[fqn]
    endif

    let ci = s:GetLocalClassInfo(strpart(a:class, strridx(a:class, '.')+1, strlen(a:class)), file)
    if !empty(ci)
      let s:cache[fqn == '' ? a:class : fqn] = s:Sort(ci)
      return ci
    endif
  endif

  " Assumption 3: a runtime loadable class avaible in classpath
  call s:Info('A3. runtime loadable class')
  if fqn != ''
    let ci = s:DoGetReflectionClassInfo(fqn)
  endif

  " Assumption 4: a non-public class defined in current folder (or subfolder)
  if empty(ci)
    " grep /'\<\(class\|interface\)\>[ \t\n\r]\+' . a:type . '[ \t\r\n]'/ in
    " all path
  endif

  return ci
endfu

fu! s:MergeClassInfo(ci, another)
  if empty(a:ci)	| return a:another	| endif
  if empty(a:another)	| return a:ci		| endif

  for f in a:another.fields
    let found = 0
    for i in a:ci.fields
      if f.n == i.n
	let found = 1
	break
      endif
    endfor
    if !found
      call add(a:ci.fields, f)
    endif
  endfor

  for m in a:another.methods
    let found = 0
    for i in a:ci.methods
      if m.n == i.n
	let found = 1
	break
      endif
    endfor
    if !found
      call add(a:ci.methods, m)
    endif
  endfor
  return a:ci
endfu


" Parameters:
"   class	the qualified class name
" Return:	TClassInfo or {} when not found
" See ClassInfoFactory.getClassInfo() in insenvim.
function! s:DoGetReflectionClassInfo(fqn)
  if !has_key(s:cache, a:fqn)
    let res = s:RunReflection('-C', a:fqn, 's:DoGetReflectionClassInfo')
    if res =~ '^{'
      let s:cache[a:fqn] = s:Sort(eval(res))
    else
      let b:errormsg = res
    endif
  endif
  return get(s:cache, a:fqn, {})
endfunction

fu! s:GetLocalClassInfo(class, filename)
  let ci = {}
  if len(tagfiles()) > 0
    let ci = s:DoGetClassInfoFromTags(a:class)
  endif

  if empty(ci)
    call s:Info('Use java_parser.vim to generate class information')
    if a:filename == '%'
      call javacomplete#parse()
      let ci = s:DoGetLocalClassInfo(a:class, b:ast)
    else
      call java_parser#InitParser(readfile(a:filename))
      let unit = java_parser#compilationUnit()
      let ci = s:DoGetLocalClassInfo(a:class, unit)
    endif
  endif
  return ci
endfu

fu! s:DoGetLocalClassInfo(class, unit)
  for t in s:SearchTypeAt(a:unit, -1)
    if t.name == a:class
      return s:AddInheritedClassInfo(s:Tree2ClassInfo(t), t)
    endif
  endfor
  return {}
endfu

fu! s:Tree2ClassInfo(t)
  let t = a:t
  " fill fields and methods
  let t.fields = []
  let t.methods = []
  let t.ctors = []
  for def in t.defs
    if def.tag == 'METHODDEF'
      call add(def.n == t.name ? t.ctors : t.methods, def)
    elseif def.tag == 'VARDEF'
      call add(t.fields, def)
    endif
  endfor
  return t
endfu

fu! s:AddInheritedClassInfo(ci, t)
  let t = a:t
  let ci = a:ci
  " add inherited fields and methods
  let list = []
  if has_key(t, 'extends')
    call add(list, java_parser#type2Str(t.extends[0]))
  endif
  if has_key(t, 'implements')
    for i in t.implements
      call add(list, java_parser#type2Str(i))
    endfor
  endif
  for id in list
    let fqn = s:GetFQN(id)
    if fqn != ''
      let ci = s:MergeClassInfo(ci, s:DoGetClassInfo(fqn))
    endif
  endfor
  return ci
endfu

" To obtain information of the class in current file or current folder, or
" even in current project.
function! s:DoGetClassInfoFromTags(class)
  " find tag of a:class declaration
  let tags = taglist('^' . a:class)
  let filename = ''
  let cmd = ''
  for tag in tags
    if has_key(tag, 'kind')
      if tag['kind'] == 'c'
	let filename = tag['filename']
	let cmd = tag['cmd']
	break
      endif
    endif
  endfor

  let tags = taglist('^' . (empty(b:incomplete) ? '.*' : b:incomplete) )
  if filename != ''
    call filter(tags, "v:val['filename'] == '" . filename . "' && has_key(v:val, 'class') ? v:val['class'] == '" . a:class . "' : 1")
  endif

  let ci = {'name': a:class}
  " extends and implements
  let ci['ctors'] = []
  let ci['fields'] = []
  let ci['methods'] = []

  " members
  for tag in tags
    let member = {'n': tag['name']}

    " determine kind
    let kind = 'm'
    if has_key(tag, 'kind')
      let kind = tag['kind']
    endif

    let cmd = tag['cmd']
    if cmd =~ '\<static\>'
      let member['m'] = '1000'
    else
      let member['m'] = ''
    endif

    let desc = substitute(cmd, '/^\s*', '', '')
    let desc = substitute(desc, '\s*{\?\s*$/$', '', '')

    if kind == 'm'
      " description
      if cmd =~ '\<static\>'
	let desc = substitute(desc, '\s\+static\s\+', ' ', '')
      endif
      let member['d'] = desc

      let member['p'] = ''
      let member['r'] = ''
      if tag['name'] == a:class
	call add(ci['ctors'], member)
      else
	call add(ci['methods'], member)
      endif
    elseif kind == 'f'
      let member['t'] = substitute(desc, '\([a-zA-Z0-9_[\]]\)\s\+\<' . tag['name'] . '\>.*$', '\1', '')
      call add(ci['fields'], member)
    endif
  endfor
  return ci
endfu

" package information							{{{2

fu! s:DoGetInfoByReflection(class, option)
  if has_key(s:cache, a:class)
    return s:cache[a:class]
  endif

  let res = s:RunReflection(a:option, a:class, 's:DoGetInfoByReflection')
  if res =~ '^[{\[]'
    let v = eval(res)
    if type(v) == type([])
      let s:cache[a:class] = sort(v)
    elseif type(v) == type({})
      if get(v, 'tag', '') =~# '^\(PACKAGE\|CLASSDEF\)$'
	let s:cache[a:class] = v
      else
	for key in keys(v)
	  " option -E
	  if get(v[key], 'tag', '') =~# '^\(PACKAGE\|CLASSDEF\)$'
	    let s:cache[key] = v[key]
	  " option -P
	  else
	    let s:cache[key] = sort(get(s:cache, key, []) + split(v[key], ','))
	  endif
	endfor
      endif
    endif
    unlet v
  else
    let b:errormsg = res
  endif

  return get(s:cache, a:class, {})
endfu

" generate member list							{{{2

fu! s:DoGetFieldList(fields)
  let s = ''
  for field in a:fields
    let s .= "{'kind':'" . (s:IsStatic(field.m) ? "F" : "f") . "','word':'" . field.n . "','menu':'" . field.t . "'},"
  endfor
  return s
endfu

fu! s:DoGetMethodList(methods, ...)
  let paren = a:0 == 0 || !a:1 ? '(' : ''
  let s = ''
  for method in a:methods
    let s .= "{'kind':'" . (s:IsStatic(method.m) ? "M" : "m") . "','word':'" . method.n . paren . "','abbr':'" . method.n . "()','menu':'" . method.d . "','dup':'1'},"
  endfor
  return s
endfu

" kind:
"	0 - for instance, 
"	1 - for Class,
"	2 - for import static, no lparen
"	3 - for import or extends or implements,
fu! s:DoGetMemberList(ci, kind)
  if type(a:ci) != type({}) || a:ci == {}
    return []
  endif

  let s = ''

  if a:kind != 0
    for class in get(a:ci, 'classes', [])
      let v = {}
      if type(class) == type("") && has_key(s:cache, class)
	let v = s:cache[class]
      elseif type(class) == type({})
	let v = class
      endif
      if v != {} && v.flags[len(v.flags)-1]
	let s .= "{'kind': 'C', 'word': '" . substitute(v.name, a:ci.name . '\.', '\1', '') . "'},"
      endif
    endfor
  endif

  if a:kind != 3
    let fieldlist = []
    let sfieldlist = []
    for field in get(a:ci, 'fields', [])
      if s:IsStatic(field['m'])
	call add(sfieldlist, field)
      elseif a:kind == 0
	call add(fieldlist, field)
      endif
    endfor

    let methodlist = []
    let smethodlist = []
    for method in get(a:ci, 'methods', [])
      if s:IsStatic(method['m'])
	call add(smethodlist, method)
      elseif a:kind == 0
	call add(methodlist, method)
      endif
    endfor

    if a:kind == 0
      let s .= s:DoGetFieldList(fieldlist)
      let s .= s:DoGetMethodList(methodlist)
    endif
    let s .= s:DoGetFieldList(sfieldlist)
    let s .= s:DoGetMethodList(smethodlist, a:kind == 2)

    let s = substitute(s, '\<' . a:ci.name . '\.', '', 'g')
    let s = substitute(s, '\<java\.lang\.', '', 'g')
    let s = substitute(s, '\<\(public\|static\|synchronized\|transient\|volatile\|final\|strictfp\|serializable\|native\)\s\+', '', 'g')
  endif
  return eval('[' . s . ']')
endfu

" interface							{{{2

function! s:GetMemberList(class)
  if s:IsBuiltinType(a:class)
    return []
  endif

  return s:DoGetMemberList(s:DoGetClassInfo(a:class), 0)
endfunction

fu! s:GetStaticMemberList(class)
  return s:DoGetMemberList(s:DoGetClassInfo(a:class), 1)
endfu

function! s:GetConstructorList(fqn, class)
  let ci = s:DoGetClassInfo(a:fqn)
  if empty(ci)
    return []
  endif

  let s = ''
  for ctor in get(ci, 'ctors', [])
    let s .= "{'kind': '+', 'word':'". a:class . "(','abbr':'" . ctor.d . "','dup':1},"
  endfor

  let s = substitute(s, '\<java\.lang\.', '', 'g')
  let s = substitute(s, '\<public\s\+', '', 'g')
  return eval('[' . s . ']')
endfunction

" Name can be a (simple or qualified) package name, or a (simple or qualified)
" type name.
fu! s:GetMembers(fqn, ...)
  let list = []
  let isClass = 0

  let v = s:DoGetInfoByReflection(a:fqn, '-E')
  if type(v) == type([])
    let list = v
  elseif type(v) == type({}) && v != {}
    if get(v, 'tag', '') == 'PACKAGE'
      if b:context_type == s:CONTEXT_IMPORT_STATIC || b:context_type == s:CONTEXT_IMPORT
	call add(list, {'kind': 'P', 'word': '*;'})
      endif
      if b:context_type != s:CONTEXT_PACKAGE_DECL
	for c in sort(v.classes)
	  call add(list, {'kind': 'C', 'word': c})
	endfor
      endif
      for p in sort(v.subpackages)
	call add(list, {'kind': 'P', 'word': p})
      endfor
    else	" elseif get(v, 'tag', '') == 'CLASSDEF'
      let isClass = 1
      let list += s:DoGetMemberList(v, b:context_type == s:CONTEXT_IMPORT ? 3 : b:context_type == s:CONTEXT_IMPORT_STATIC ? 2 : 1)
    endif
  endif

  if !isClass
    let list += s:DoGetPackageInfoInSources(a:fqn, 0)
  endif

  return list
endfu

fu! s:DoGetPackageInfoInSources(package, onlySubpackages)
  let list = []

  " local package
  let srcpath = javacomplete#GetSourcePath(1)
  let srcpath = substitute(srcpath, '[\\/]\?' . javacomplete#GetClassPathSep(), ',', 'g')
  let srcpath = substitute(srcpath, '[\\/]\?$', '', 'g')
  let s = globpath(srcpath, substitute(a:package, '\.', '/', 'g') . '/*')
  if !empty(s)
    let pathes = split(srcpath, ',')
    for f in split(s, "\n")
      for path in pathes
	let idx = matchend(f, escape(path, '\') . '[\\/]\?' . a:package . '[\\/]')
	if idx != -1
	  if isdirectory(f) && f !~ 'CVS$'
	    call add(list, {'kind': 'P', 'word': strpart(f, idx)})
	  elseif !a:onlySubpackages && f =~ '\.java$'
	    call add(list, {'kind': 'C', 'word': substitute(strpart(f, idx), '\.java$', '', '')})
	  endif
	endif
      endfor
    endfor
  endif
  return list
endfu
" }}}
"}}}
" vim:set fdm=marker sw=2 nowrap:
