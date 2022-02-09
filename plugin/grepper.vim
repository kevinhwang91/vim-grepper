" Initialization {{{1

if exists('g:loaded_grepper')
    finish
endif
let g:loaded_grepper = 1

" Escaping test line:
" ..ad\\f40+$':-# @=,!;%^&&*()_{}/ /4304\'""?`9$343%$ ^adfadf[ad)[(

highlight default link GrepperPrompt Question
highlight default link GrepperQuery String

"
" Default values that get used for missing values in g:grepper.
"
let s:defaults = {
            \ 'quickfix':      1,
            \ 'open':          1,
            \ 'switch':        1,
            \ 'cword':         0,
            \ 'prompt':        1,
            \ 'prompt_text':   '$c> ',
            \ 'prompt_quote':  0,
            \ 'highlight':     0,
            \ 'buffer':        0,
            \ 'buffers':       0,
            \ 'append':        0,
            \ 'searchreg':     0,
            \ 'stop':          0,
            \ 'dir':           'cwd',
            \ 'prompt_mapping_dir':  '<c-d>',
            \ 'prompt_mapping_side': '<c-s>',
            \ 'repo':          ['.git', '.hg', '.svn'],
            \ 'rg':            { 'grepprg':    'rg -H --no-heading --vimgrep' . (has('win32') ? ' $* .' : ''),
            \                    'grepformat': '%f:%l:%c:%m,%f',
            \                    'escape':     '\^$.*+?()[]{}|' },
            \ 'grep':          { 'grepprg':    'grep -RIn $* .',
            \                    'grepprgbuf': 'grep -HIn -- $* $.',
            \                    'grepformat': '%f:%l:%m,%f',
            \                    'escape':     '\^$.*[]' },
            \ }

" Make it possible to configure the global and operator behaviours separately.
let s:defaults.operator = deepcopy(s:defaults)
let s:defaults.operator.prompt = 0

function! s:merge_configs(config, defaults) abort
    let new = deepcopy(a:config)

    " Add all missing default options.
    call extend(new, a:defaults, 'keep')

    " Global options.
    for k in keys(a:config)
        if k == 'operator'
            continue
        endif

        " If only part of an option dict was set, add the missing default keys.
        if type(new[k]) == type({}) && has_key(a:defaults, k) && new[k] != a:defaults[k]
            call extend(new[k], a:defaults[k], 'keep')
        endif

        " Inherit operator option from global option unless it already exists or
        " has a default value where the global option has not.
        if !has_key(new.operator, k) || (has_key(a:defaults, k)
                    \                          && new[k] != a:defaults[k]
                    \                          && new.operator[k] == s:defaults.operator[k])
            let new.operator[k] = deepcopy(new[k])
        endif
    endfor

    " Operator options.
    if has_key(a:config, 'operator')
        for opt in keys(a:config.operator)
            " If only part of an operator option dict was set, inherit the missing
            " keys from the global option.
            if type(new.operator[opt]) == type({}) && new.operator[opt] != new[opt]
                call extend(new.operator[opt], new[opt], 'keep')
            endif
        endfor
    endif

    return new
endfunction

let g:grepper = exists('g:grepper')
            \ ? s:merge_configs(g:grepper, s:defaults)
            \ : deepcopy(s:defaults)

let s:cmdline = ''
let s:slash   = exists('+shellslash') && !&shellslash ? '\' : '/'

" Job handlers {{{1
" s:on_stdout_nvim() {{{2
function! s:on_stdout_nvim(_job_id, data, _event) dict abort
    if !exists('s:id')
        return
    endif

    let orig_dir = s:chdir_push(self.work_dir)
    let lcandidates = []

    try
        if len(a:data) > 1 || empty(a:data[-1])
            " Second-last item is the last complete line in a:data.
            let acc_line = self.stdoutbuf . a:data[0]
            let lcandidates = (empty(acc_line) ? [] : [acc_line]) + a:data[1:-2]
            let self.stdoutbuf = ''
        endif
        " Last item in a:data is an incomplete line (or empty), append to buffer
        let self.stdoutbuf .= a:data[-1]

        if self.flags.stop > 0 && (self.num_matches + len(lcandidates) >= self.flags.stop)
            " Add the remaining data
            let n_rem_lines = self.flags.stop - self.num_matches
            if n_rem_lines > 0
                noautocmd execute self.addexpr 'lcandidates[:n_rem_lines-1]'
                let self.num_matches = self.flags.stop
            endif

            silent! call jobstop(s:id)
            unlet! s:id
            return
        else
            noautocmd execute self.addexpr 'lcandidates'
            let self.num_matches += len(lcandidates)
        endif
    finally
        call s:chdir_pop(orig_dir)
    endtry
endfunction

" s:on_exit() {{{2
function! s:on_exit(...) dict abort
    execute 'tabnext' self.tabpage
    execute self.window .'wincmd w'
    unlet! s:id
    return s:finish_up(self.flags)
endfunction

" Completion {{{1
" grepper#complete() {{{2
function! grepper#complete(lead, line, _pos) abort
    if a:lead =~ '^-'
        let flags = ['-append', '-buffer', '-buffers', '-cd', '-cword', '-dir',
                    \ '-grepprg', '-highlight', '-open', '-prompt', '-query',
                    \ '-quickfix', '-stop', '-switch', '-noappend',
                    \ '-nohighlight', '-noopen', '-noprompt', '-noquickfix', '-noswitch']
        return filter(map(flags, 'v:val." "'), 'v:val[:strlen(a:lead)-1] ==# a:lead')
    elseif a:line =~# '-dir \w*$'
        return filter(map(['cwd', 'file', 'filecwd', 'repo'], 'v:val." "'),
                    \ 'empty(a:lead) || v:val[:strlen(a:lead)-1] ==# a:lead')
    elseif a:line =~# '-stop $'
        return ['5000']
    else
        return grepper#complete_files(a:lead, 0, 0)
    endif
endfunction

" grepper#complete_files() {{{2
function! grepper#complete_files(lead, _line, _pos)
    let [head, path] = s:extract_path(a:lead)
    " handle relative paths
    if empty(path) || (path =~ '\s$')
        return map(split(globpath('.'.s:slash, path.'*'), '\n'), 'head . "." . v:val[1:] . (isdirectory(v:val) ? s:slash : "")')
        " handle sub paths
    elseif path =~ '^.\/'
        return map(split(globpath('.'.s:slash, path[2:].'*'), '\n'), 'head . "." . v:val[1:] . (isdirectory(v:val) ? s:slash : "")')
        " handle absolute paths
    elseif path[0] == '/'
        return map(split(globpath(s:slash, path.'*'), '\n'), 'head . v:val[1:] . (isdirectory(v:val) ? s:slash : "")')
    endif
endfunction

" s:extract_path() {{{2
function! s:extract_path(string) abort
    let item = split(a:string, '.*\s\zs', 1)
    echom a:string
    echom item
    let len  = len(item)

    if     len == 0 | let [head, path] = ['', '']
    elseif len == 1 | let [head, path] = ['', item[0]]
    elseif len == 2 | let [head, path] = item
    else            | throw 'The unexpected happened!'
    endif

    return [head, path]
endfunction

" Helpers {{{1
" s:error() {{{2
function! s:error(msg)
    redraw
    echohl ErrorMsg
    echomsg a:msg
    echohl NONE
endfunction

" s:lstrip() {{{2
function! s:lstrip(string) abort
    return substitute(a:string, '^\s\+', '', '')
endfunction

" s:split_one() {{{2
function! s:split_one(string) abort
    let stripped = s:lstrip(a:string)
    let first_word = substitute(stripped, '\v^(\S+).*', '\1', '')
    let rest = substitute(stripped, '\v^\S+\s*(.*)', '\1', '')
    return [first_word, rest]
endfunction

function! s:get_grepprg(flags) abort
    let tool = a:flags.rg
    if a:flags.buffers
        return has_key(tool, 'grepprgbuf')
                    \ ? substitute(tool.grepprgbuf, '\V$.', '$+', '')
                    \ : tool.grepprg .' -- $* $+'
    elseif a:flags.buffer
        return has_key(tool, 'grepprgbuf')
                    \ ? tool.grepprgbuf
                    \ : tool.grepprg .' -- $* $.'
    endif
    return tool.grepprg
endfunction
" s:store_errorformat() {{{2
function! s:store_errorformat(flags) abort
    let tool = a:flags.rg
    let s:errorformat = &errorformat
    let &errorformat = has_key(tool, 'grepformat') ? tool.grepformat : &errorformat
endfunction

" s:restore_errorformat() {{{2
function! s:restore_errorformat() abort
    let &errorformat = s:errorformat
endfunction

" s:restore_mapping() {{{2
function! s:restore_mapping(mapping)
    if !empty(a:mapping)
        execute printf('%s %s%s%s%s %s %s',
                    \ (a:mapping.noremap ? 'cnoremap' : 'cmap'),
                    \ (a:mapping.silent  ? '<silent>' : ''    ),
                    \ (a:mapping.buffer  ? '<buffer>' : ''    ),
                    \ (a:mapping.nowait  ? '<nowait>' : ''    ),
                    \ (a:mapping.expr    ? '<expr>'   : ''    ),
                    \  a:mapping.lhs,
                    \  substitute(a:mapping.rhs, '\c<sid>', '<SNR>'.a:mapping.sid.'_', 'g'))
    endif
endfunction

" s:escape_query() {{{2
function! s:escape_query(flags, query)
    let tool = a:flags.rg
    let a:flags.query_escaped = 1
    return shellescape(has_key(tool, 'escape')
                \ ? escape(a:query, tool.escape)
                \ : a:query)
endfunction

" s:unescape_query() {{{2
function! s:unescape_query(flags, query)
    let tool = a:flags.rg
    let q = a:query
    if has_key(tool, 'escape')
        for c in reverse(split(tool.escape, '\zs'))
            let q = substitute(q, '\V\\'.c, c, 'g')
        endfor
    endif
    return q
endfunction

" s:requote_query() {{{2
function! s:requote_query(flags) abort
    if a:flags.cword
        let a:flags.query = s:escape_cword(a:flags, a:flags.query_orig)
    else
        if has_key(a:flags, 'query_orig')
            let a:flags.query = '-- '. s:escape_query(a:flags, a:flags.query_orig)
        else
            if a:flags.prompt_quote >= 2
                let a:flags.query = a:flags.query[1:-2]
            else
                let a:flags.query = a:flags.query[:-1]
            endif
        endif
    endif
endfunction

" s:escape_cword() {{{2
function! s:escape_cword(flags, cword)
    let tool = a:flags.rg
    let escaped_cword = escape(a:cword, tool.escape)
    let wordanchors = ['\b', '\b']
    if a:cword =~# '^\k'
        let escaped_cword = wordanchors[0] . escaped_cword
    endif
    if a:cword =~# '\k$'
        let escaped_cword = escaped_cword . wordanchors[1]
    endif
    let a:flags.query_orig = a:cword
    let a:flags.query_escaped = 1
    return shellescape(escaped_cword)
endfunction

" s:compute_working_directory() {{{2
function! s:compute_working_directory(flags) abort
    if has_key(a:flags, 'cd')
        return a:flags.cd
    endif
    for dir in split(a:flags.dir, ',')
        if dir == 'repo'
            for repo in g:grepper.repo
                let repopath = finddir(repo, expand('%:p:h').';')
                if empty(repopath)
                    let repopath = findfile(repo, expand('%:p:h').';')
                endif
                if !empty(repopath)
                    let repopath = fnamemodify(repopath, ':h')
                    return fnameescape(repopath)
                endif
            endfor
        elseif dir == 'filecwd'
            let cwd = getcwd()
            let bufdir = expand('%:p:h')
            if stridx(bufdir, cwd) != 0
                return fnameescape(bufdir)
            endif
        elseif dir == 'file'
            let bufdir = expand('%:p:h')
            return fnameescape(bufdir)
        elseif dir == 'cwd'
            return getcwd()
        else
            call s:error("Invalid -dir flag '" . a:flags.dir . "'")
        endif
    endfor
    return ''
endfunction

" s:chdir_push() {{{2
function! s:chdir_push(work_dir)
    if !empty(a:work_dir)
        let cwd = getcwd()
        execute 'lcd' a:work_dir
        return cwd
    endif
    return ''
endfunction

" s:chdir_pop() {{{2
function! s:chdir_pop(buf_dir)
    if !empty(a:buf_dir)
        execute 'lcd' fnameescape(a:buf_dir)
    endif
endfunction

" s:get_config() {{{2
function! s:get_config() abort
    let g:grepper = exists('g:grepper')
                \ ? s:merge_configs(g:grepper, s:defaults)
                \ : deepcopy(s:defaults)
    let flags = deepcopy(g:grepper)
    if exists('b:grepper')
        let flags = s:merge_configs(b:grepper, g:grepper)
    endif
    return flags
endfunction

" s:set_prompt_text() {{{2
function! s:set_prompt_text(flags) abort
    let text = get(a:flags, 'simple_prompt') ? 'rg> ' : a:flags.prompt_text
    let text = substitute(text, '\V$c', s:get_grepprg(a:flags), '')
    return text
endfunction

" s:set_prompt_op() {{{2
function! s:set_prompt_op(op) abort
    let s:prompt_op = a:op
    return getcmdline()
endfunction

" s:query2vimregexp() {{{2
function! s:query2vimregexp(flags) abort
    if has_key(a:flags, 'query_orig')
        let query = a:flags.query_orig
    else
        " Remove any flags at the beginning, e.g. when using '-uu' with rg, but
        " keep plain '-'.
        let query = substitute(a:flags.query, '\v^\s+', '', '')
        let query = substitute(query, '\v\s+$', '', '')
        let pos = 0
        while 1
            let [mtext, mstart, mend] = matchstrpos(query, '\v^-\S+\s*', pos)
            if mstart < 0
                break
            endif
            let pos = mend
            if mtext =~ '\v^--\s*$'
                break
            endif
        endwhile
        let query = strpart(query, pos)
    endif

    " Change Vim's '\'' to ' so it can be understood by /.
    let vim_query = substitute(query, "'\\\\''", "'", 'g')

    " Remove surrounding quotes that denote a string.
    let start = vim_query[0]
    let end = vim_query[-1:-1]
    if start == end && start =~ "\['\"]"
        let vim_query = vim_query[1:-2]
    endif

    if a:flags.query_escaped
        let vim_query = s:unescape_query(a:flags, vim_query)
        let vim_query = escape(vim_query, '\')
        if a:flags.cword
            if a:flags.query_orig =~# '^\k'
                let vim_query = '\<' . vim_query
            endif
            if a:flags.query_orig =~# '\k$'
                let vim_query = vim_query . '\>'
            endif
        endif
        let vim_query = '\V'. vim_query
    else
        " \bfoo\b -> \<foo\> Assume only one pair.
        let vim_query = substitute(vim_query, '\v\\b(.{-})\\b', '\\<\1\\>', '')
        " *? -> \{-}
        let vim_query = substitute(vim_query, '*\\\=?', '\\{-}', 'g')
        " +? -> \{-1,}
        let vim_query = substitute(vim_query, '\\\=+\\\=?', '\\{-1,}', 'g')
        let vim_query = escape(vim_query, '+')
    endif

    return vim_query
endfunction
" }}}1

" s:parse_flags() {{{1
function! s:parse_flags(args) abort
    let flags = s:get_config()
    let flags.query = ''
    let flags.query_escaped = 0
    let [flag, args] = s:split_one(a:args)

    while !empty(flag)
        if     flag =~? '\v^-%(no)?(quickfix|qf)$' | let flags.quickfix  = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?open$'          | let flags.open      = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?switch$'        | let flags.switch    = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?prompt$'        | let flags.prompt    = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?highlight$'     | let flags.highlight = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?buffer$'        | let flags.buffer    = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?buffers$'       | let flags.buffers   = flag !~? '^-no'
        elseif flag =~? '\v^-%(no)?append$'        | let flags.append    = flag !~? '^-no'
        elseif flag =~? '^-cword$'                 | let flags.cword     = 1
        elseif flag =~? '^-stop$'
            if empty(args) || args[0] =~ '^-'
                let flags.stop = -1
            else
                let [numstring, args] = s:split_one(args)
                let flags.stop = str2nr(numstring)
            endif
        elseif flag =~? '^-dir$'
            let [dir, args] = s:split_one(args)
            if empty(dir)
                call s:error('Missing argument for: -dir')
            else
                let flags.dir = dir
            endif
        elseif flag =~? '^-grepprg$'
            if empty(args)
                call s:error('Missing argument for: -grepprg')
            else
                let flags.rg = copy(g:grepper.rg)
                let flags.rg.grepprg = args
            endif
            break
        elseif flag =~? '^-query$'
            if empty(args)
                " No warning message here. This allows for..
                " nnoremap ... :Grepper! -tool ag -query<space>
                " ..thus you get nicer file completion.
            else
                let flags.query = args
            endif
            break
        elseif flag ==# '-cd'
            if empty(args)
                call s:error('Missing argument for: -cd')
                break
            endif
            let dir = fnamemodify(args, ':p')
            if !isdirectory(dir)
                call s:error('Invalid directory: '. dir)
                break
            endif
            let flags.cd = dir
            break
        else
            call s:error('Ignore unknown flag: '. flag)
        endif

        let [flag, args] = s:split_one(args)
    endwhile

    return s:start(flags)
endfunction

" s:process_flags() {{{1
function! s:process_flags(flags)
    if a:flags.stop == -1
        if exists('s:id')
            silent! call jobstop(s:id)
            unlet! s:id
        endif
        return 1
    endif

    let s:tmp_work_dir = s:compute_working_directory(a:flags)

    if a:flags.buffer
        let a:flags.buflist = [fnamemodify(bufname(''), ':p')]
        if !filereadable(a:flags.buflist[0])
            call s:error('This buffer is not backed by a file!')
            return 1
        endif
    endif

    if a:flags.buffers
        let a:flags.buflist = filter(map(filter(range(1, bufnr('$')),
                    \ 'bufloaded(v:val)'), 'fnamemodify(bufname(v:val), ":p")'), 'filereadable(v:val)')
        if empty(a:flags.buflist)
            call s:error('No buffer is backed by a file!')
            return 1
        endif
    endif

    if a:flags.cword
        let a:flags.query = s:escape_cword(a:flags, expand('<cword>'))
    endif

    if a:flags.prompt
        call s:prompt(a:flags)
        if s:prompt_op == 'cancelled'
            return 1
        endif

        if a:flags.query =~ '^\s*$'
            let a:flags.query = s:escape_cword(a:flags, expand('<cword>'))
            " input() got empty input, so no query was added to the history.
            call histadd('input', a:flags.query)
        elseif a:flags.prompt_quote == 1
            let a:flags.query = shellescape(a:flags.query)
        endif
    else
        " input() was skipped, so add query to the history manually.
        call histadd('input', a:flags.query)
    endif

    if a:flags.searchreg || a:flags.highlight
        let @/ = s:query2vimregexp(a:flags)
        call histadd('search', @/)
        if a:flags.highlight
            call feedkeys(":set hls\<bar>echo\<cr>", 'n')
        endif
    endif

    return 0
endfunction

" s:start() {{{1
function! s:start(flags) abort
    let s:prompt_op = ''

    if s:process_flags(a:flags)
        return
    endif

    return s:run(a:flags)
endfunction

" s:prompt() {{{1
function! s:prompt(flags)
    let prompt_text = s:set_prompt_text(a:flags)

    if s:prompt_op == 'flag_dir'
        let changed_mode = '[-dir '. a:flags.dir .'] '
        let prompt_text = changed_mode . prompt_text
    endif

    " Store original mappings
    let mapping_cr   = maparg('<cr>', 'c', '', 1)
    let mapping_dir  = maparg(g:grepper.prompt_mapping_dir,  'c', '', 1)
    let mapping_side = maparg(g:grepper.prompt_mapping_side, 'c', '', 1)

    " Set plugin-specific mappings
    cnoremap <silent> <cr> <c-\>e<sid>set_prompt_op('cr')<cr><cr>
    execute 'cnoremap <silent>' g:grepper.prompt_mapping_dir  "\<c-\>e\<sid>set_prompt_op('flag_dir')<cr><cr>"
    execute 'cnoremap <silent>' g:grepper.prompt_mapping_side "\<c-\>e\<sid>set_prompt_op('flag_side')<cr><cr>"

    " Set low timeout for key codes, so <esc> would cancel prompt faster
    let ttimeoutsave = &ttimeout
    let ttimeoutlensave = &ttimeoutlen
    let &ttimeout = 1
    let &ttimeoutlen = 100

    if a:flags.prompt_quote == 2 && !has_key(a:flags, 'query_orig')
        let a:flags.query = "'". a:flags.query ."'\<left>"
    elseif a:flags.prompt_quote == 3 && !has_key(a:flags, 'query_orig')
        let a:flags.query = '"'. a:flags.query ."\"\<left>"
    else
        let a:flags.query = a:flags.query
    endif

    " s:prompt_op indicates which key ended the prompt's input() and is needed to
    " distinguish different actions.
    "   'cancelled':  don't start searching
    "   'flag_dir':   don't start searching; toggle -dir flag
    "   'cr':         start searching
    let s:prompt_op = 'cancelled'

    echohl GrepperPrompt
    call inputsave()

    try
        let a:flags.query = input({
                    \ 'prompt':     prompt_text,
                    \ 'default':    a:flags.query,
                    \ 'completion': 'customlist,grepper#complete_files',
                    \ 'highlight':  { cmdline -> [[0, len(cmdline), 'GrepperQuery']] },
                    \ })
    catch /^Vim:Interrupt$/  " Ctrl-c was pressed
        let s:prompt_op = 'cancelled'
    finally
        redraw!

        " Restore mappings
        cunmap <cr>
        execute 'cunmap' g:grepper.prompt_mapping_dir
        execute 'cunmap' g:grepper.prompt_mapping_side
        call s:restore_mapping(mapping_cr)
        call s:restore_mapping(mapping_dir)
        call s:restore_mapping(mapping_side)

        " Restore original timeout settings for key codes
        let &ttimeout = ttimeoutsave
        let &ttimeoutlen = ttimeoutlensave

        echohl NONE
        call inputrestore()
    endtry

    if s:prompt_op != 'cr' && s:prompt_op != 'cancelled'
        if s:prompt_op == 'flag_dir'
            let states = ['cwd', 'file', 'filecwd', 'repo']
            let pattern = printf('v:val =~# "^%s.*"', a:flags.dir)
            let current_index = index(map(copy(states), pattern), 1)
            let a:flags.dir = states[(current_index + 1) % len(states)]
            let s:tmp_work_dir = s:compute_working_directory(a:flags)
        endif

        call s:requote_query(a:flags)
        return s:prompt(a:flags)
    endif
endfunction

" s:build_cmdline() {{{1
function! s:build_cmdline(flags) abort
    let grepprg = s:get_grepprg(a:flags)

    if has_key(a:flags, 'buflist')
        if has('win32')
            " cmd.exe does not use single quotes for quoting. Using 'noshellslash'
            " forces path separators to be backslashes and makes shellescape() using
            " double quotes. Beforehand escape all backslashes, otherwise \t in
            " 'dir\test' would be considered a tab etc.
            let [shellslash, &shellslash] = [&shellslash, 0]
            call map(a:flags.buflist, 'shellescape(escape(fnamemodify(v:val, ":."), "\\"))')
            let &shellslash = shellslash
        else
            call map(a:flags.buflist, 'shellescape(fnamemodify(v:val, ":."))')
        endif
    endif

    if stridx(grepprg, '$.') >= 0
        let grepprg = substitute(grepprg, '\V$.', a:flags.buflist[0], '')
    endif
    if stridx(grepprg, '$+') >= 0
        let grepprg = substitute(grepprg, '\V$+', join(a:flags.buflist), '')
    endif
    if stridx(grepprg, '$*') >= 0
        let grepprg = substitute(grepprg, '\V$*', escape(a:flags.query, '\&'), 'g')
    else
        let grepprg .= ' ' . a:flags.query
    endif

    return grepprg
endfunction

" s:run() {{{1
function! s:run(flags)
    if !a:flags.append
        if a:flags.quickfix
            call setqflist([])
        else
            call setloclist(0, [])
        endif
    endif

    let orig_dir  = s:chdir_push(s:tmp_work_dir)
    let s:cmdline = s:build_cmdline(a:flags)

    " 'cmd' and 'options' are only used for async execution.
    if has('win32')
        let cmd = 'cmd.exe /c '. s:cmdline
    else
        let cmd = ['sh', '-c', s:cmdline]
    endif

    let options = {
                \ 'cmd':       s:cmdline,
                \ 'work_dir':  s:tmp_work_dir,
                \ 'flags':     a:flags,
                \ 'addexpr':   a:flags.quickfix ? 'caddexpr' : 'laddexpr',
                \ 'window':    winnr(),
                \ 'tabpage':   tabpagenr(),
                \ 'stdoutbuf': '',
                \ 'num_matches': 0,
                \ }

    call s:store_errorformat(a:flags)

    let msg = printf('Running: %s', s:cmdline)
    if strwidth(msg) > v:echospace
        let msg = printf('%.*S...', v:echospace - 3, msg)
    endif
    echo msg

    if exists('s:id')
        silent! call jobstop(s:id)
    endif
    let opts = {
                \ 'on_stdout': function('s:on_stdout_nvim'),
                \ 'on_stderr': function('s:on_stdout_nvim'),
                \ 'on_exit':   function('s:on_exit'),
                \ }
    if has('nvim-0.5.1')
        " Starting with version 13, ripgrep always stats stdin and if it's not a
        " TTY it uses it to read data. Unfortunately, Neovim always attaches a
        " pipe to stdin by default and that leads to ripgrep reading nothing...
        " (see https://github.com/mhinz/vim-grepper/issues/244 for more info)
        " This was fixed in nvim by adding an option to jobstart to not pipe stdin
        " (see https://github.com/neovim/neovim/pull/14812).
        let opts.stdin = 'null'
    endif
    try
        let s:id = jobstart(cmd, extend(options, opts))
    finally
        call s:chdir_pop(orig_dir)
    endtry
endfunction

" s:finish_up() {{{1
function! s:finish_up(flags)
    let qf = a:flags.quickfix
    let list = qf ? getqflist() : getloclist(0)
    let size = len(list)

    let cmdline = s:cmdline
    let s:cmdline = ''

    call s:restore_errorformat()

    try
        let attrs = {'title': cmdline, 'context': {'query': @/}}
        if qf
            call setqflist([], a:flags.append ? 'a' : 'r', attrs)
        else
            call setloclist(0, [], a:flags.append ? 'a' : 'r', attrs)
        endif
    catch /E118/
    endtry

    if size == 0
        execute (qf ? 'cclose' : 'lclose')
        redraw
        echo 'No matches found.'
        return
    endif

    let has_errors = !empty(filter(list, 'v:val.valid == 0'))

    " Also open if the list contains any invalid entry.
    if a:flags.open || has_errors
        execute (qf ? 'botright copen' : 'lopen') (size > 10 ? 10 : size)
        let w:quickfix_title = cmdline
        setlocal nowrap

        if !a:flags.switch
            call feedkeys("\<c-w>p", 'n')
        endif
    endif

    redraw
    echo printf('Found %d matches.', size)

    if exists('#User#Grepper')
        execute 'doautocmd <nomodeline> User Grepper'
    endif
endfunction

" }}}1

" Operator {{{1
function! GrepperOperator(type) abort
    if $GDEBUG
        lua require('grepper').GrepperOperator('n')
        return
    endif
    let regsave = @@
    let selsave = &selection
    let &selection = 'inclusive'

    if a:type =~? 'v'
        silent execute "normal! gvy"
    elseif a:type == 'line'
        silent execute "normal! '[V']y"
    else
        silent execute "normal! `[v`]y"
    endif

    let &selection = selsave
    let flags = s:get_config().operator
    let flags.query_orig = @@
    let flags.query_escaped = 0

    let flags.query = s:escape_query(flags, @@)
    if !flags.buffer && !flags.buffers
        let flags.query = '-- '. flags.query
    endif
    let @@ = regsave

    return s:start(flags)
endfunction

" Mappings {{{1
nnoremap <silent> <plug>(GrepperOperator) :set opfunc=GrepperOperator<cr>g@
xnoremap <silent> <plug>(GrepperOperator) :<c-u>call GrepperOperator(visualmode())<cr>

if hasmapto('<plug>(GrepperOperator)')
    silent! call repeat#set("\<plug>(GrepperOperator)", v:count)
endif

command! -nargs=* -complete=customlist,grepper#complete Grepper call <sid>parse_flags(<q-args>)
