local cmd = vim.cmd
local api = vim.api
local fn = vim.fn
local uv = vim.loop

local M = {}

local config = {
    quickfix = true,
    open = true,
    switch = true,
    cword = false,
    prompt = true,
    prompt_text = '$c> ',
    prompt_quote = false,
    highlight = false,
    buffer = false,
    buffers = false,
    append = false,
    searchreg = false,
    stop = false,
    dir = 'cwd',
    prompt_mapping_dir = '<c-d>',
    prompt_mapping_side = '<c-s>',
    repo = {'.git', '.hg', '.svn'},
    rg = {
        grepprg = {'-H', '--json', '--smart-case'},
        grepformat = '%f:%l:%c:%m,%f',
        escape = [[\^$.*+?()[]{}|]]
    }
}

function M.cmd_complete(lead, line, _)
    if lead:match('^%-') then
        local flags = {
            '-append', '-buffer', '-buffers', '-cd', '-cword', '-dir', '-grepprg', '-highlight',
            '-open', '-prompt', '-query', '-quickfix', '-stop', '-switch', '-noappend',
            '-nohighlight', '-noopen', '-noprompt', '-noquickfix', '-noswitch'
        }
        return vim.tbl_filter(function(f)
            return lead == f:sub(1, #lead)
        end, flags)
    elseif line:match('-dir %w*$') then
        local dir = {'cwd', 'file', 'filecwd', 'repo'}
        return vim.tbl_filter(function(d)
            return #lead == 0 or lead == d:sub(1, #lead)
        end, dir)
    elseif line:match('-stop $') then
        return {'5000'}
    else
        local files = fn.getcompletion(lead, 'file')
        return vim.tbl_map(function(f)
            return fn.fnameescape(f)
        end, files)
    end
end

local prompt_op

local function repo_root(repo_type, path)
    if path then
        path = fn.fnamemodify(path, ':p')
    else
        path = api.nvim_buf_get_name(0)
    end
    local prev = ''
    local ret = ''
    while path ~= prev do
        prev = path
        path = fn.fnamemodify(path, ':h')
        local st = uv.fs_stat(path .. '/' .. repo_type)
        local stt = st and st.type
        if stt == 'directory' or stt == 'file' then
            ret = path
            break
        end
    end
    return ret
end

local function escape_cword(flags, cword)
    local tool = flags.rg
    local escaped_cword = fn.escape(cword, tool.escape)
    local wordanchors = {[[\b]], [[\b]]}
    local repl = ([[%q\1%q]]):format(wordanchors[1], wordanchors[2])
    escaped_cword = fn.substitute(escaped_cword, [[\v^(\k+)$]], repl, '')
    flags.query_orig = cword
    flags.query_escaped = true
    return fn.shellescape(escaped_cword)
end

local function compute_wd(flags)
    if flags.cd then
        return flags.cd
    end

    for _, dir in ipairs(vim.split(flags.dir, ',')) do
        if dir == 'repo' then
            for _, rtype in ipairs(config.repo) do
                local root = repo_root(rtype)
                if root ~= '' then
                    return root
                end
            end
        elseif dir == 'file' then
            local buf_dir = fn.expand('%:p:h')
            return fn.fnameescape(buf_dir)
        elseif dir == 'cwd' then
            return uv.cwd()
        end
    end
end

local tmp_wd
local p_handle
local function process_flags(flags)
    if flags.stop == -1 then
        if p_handle then
            p_handle:kill(15)
        end
    end

    tmp_wd = compute_wd(flags)

    if flags.buffer then
        flags.buflist = {api.nvim_get_current_buf()}
        if uv.fs_stat(flags.buflist) ~= 'file' then
            error('???')
            return false
        end
    end

    if flags.buffers then
        flags.buflist = {}
        for _, bufnr in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(bufnr) then
                local bufname = api.nvim_buf_get_name(bufnr)
                if uv.fs_fstat(bufname) == 'file' then
                    table.insert(flags.buflist, bufname)
                end
            end
        end
    end

    if flags.cword then
        flags.query = escape_cword(flags, fn.expand('<cword>'))
    end

    if flags.prompt then
        -- prompt()
        if prompt_op == 'cancelled' then
            return false
        end
        if flags.query:match([[^\s*$]]) then
            flags.query = escape_cword(flags, fn.expand('<cword>'))
            fn.histadd('@', flags.query)
        elseif flags.prompt_quote then
            flags.query = fn.shellescape(flags.query)
        end
    else
        fn.histadd('@', flags.query)
    end

    if flags.searchreg or flags.highlight then
        fn.setreg('/', '')
        fn.histadd('/', '')
        if flags.highlight then
            return false
        end
    end
    return true
end

local function chdir_pop(buf_dir)
    if buf_dir ~= '' then
        cmd('lcd ' .. fn.fnameescape(buf_dir))
    end
end

local function get_grepprg(flags)
    local tool = flags.rg
    local grepprgbuf = flags.grepprgbuf
    -- if flags.buffers then
    --     return grepprgbuf and grepprgbuf:gsub('%$%.', '$+') or tool.grepprg .. ' -- $* $+'
    -- elseif flags.buffer then
    --     return grepprgbuf and grepprgbuf or tool.grepprg .. ' -- $* $.'
    -- end
    return vim.deepcopy(tool.grepprg)
end

local cmdl

local function build_cmdl(flags)
    local grepprg = get_grepprg(flags)
    if flags.buflist then
        vim.tbl_map(function(buf)
            return fn.shellescape(fn.fnamemodify(buf, ':.'))
        end, flags.buflist)
    end

    table.insert(grepprg, flags.query)
    return grepprg
end

function M.new_job(args, cwd)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    local handle
    handle = uv.spawn('rg',
        {args = args, stdio = {nil, stdout, stderr}, cwd = cwd, detached = false},
        function(code, signal)
            local _ = signal
            handle:close()
        end)
    local limit = 50000
    local start_time = uv.hrtime()
    local cnt = 0
    local items = {}
    local added = false
    local stdout_buffer = ''
    local file_path = '/tmp/rg.txt'
    local read_data = ''
    local rt = ktime()
    stdout:read_start(function(err, data)
        assert(not err, err)
        if data then
            if data ~= '' then
                read_data = read_data .. data
                for line in vim.gsplit(data, '\n') do
                    stdout_buffer = stdout_buffer .. line
                    if stdout_buffer ~= '' then
                        local ok, msg = pcall(vim.json.decode, stdout_buffer)
                        if ok then
                            stdout_buffer = ''
                            if msg.type == 'match' then
                                local jdata = msg.data
                                local path = jdata.path.text
                                local lines = jdata.lines.text or ''
                                local line_nr = jdata.line_number
                                local matches = jdata.submatches

                                lines = lines and lines or ''
                                for _, m in ipairs(matches) do
                                    local item = {
                                        filename = path,
                                        lnum = line_nr,
                                        col = m.start + 1,
                                        end_lnum = line_nr,
                                        end_col = m['end'] + 1,
                                        text = lines:sub(1, #lines - 1)
                                    }
                                    table.insert(items, item)
                                    cnt = cnt + 1
                                end
                                -- info(path, line_nr, matches)
                            end

                            -- table.insert(write_data, text)
                            -- write_data = write_data .. text .. '\n'
                            -- info(msg)
                            -- else
                            -- info(stdout_buffer)
                        end
                    end
                end
                if #items > 0 and uv.hrtime() - start_time > 1000000000 then
                    if cnt <= limit then
                        local t_items = items
                        vim.schedule(function()
                            if added then
                                fn.setqflist(t_items, 'a')
                            else
                                added = true
                                fn.setqflist(t_items, ' ')
                                cmd('cw')
                            end
                        end)
                    else
                        stdout:close()
                        stderr:close()
                        handle:kill(15)
                    end
                    items = {}
                    start_time = uv.hrtime()
                end
            end
        else
            require('kutils').write_file(file_path, read_data, true)
            if #items > 0 then
                vim.schedule(function()
                    if added then
                        fn.setqflist(items, 'a')
                    else
                        fn.setqflist(items, ' ')
                        cmd('cw')
                    end
                end)
            end
            stdout:close()
            stderr:close()
            info(ktime() - rt)
        end
    end)
    return handle
end

local function run(flags)
    if not flags.append then
        if flags.quickfix then
            fn.setqflist({})
        else
            fn.setloclist(0, {})
        end
    end

    cmdl = build_cmdl(flags)
    info('cmdl:', cmdl)

    -- local options = {
    --     cmd = cmdl,
    --     work_dir = tmp_wd,
    --     flags = flags,
    -- }
    local cwd = compute_wd(flags)
    info('cwd:', cwd)
    M.new_job(cmdl, cwd)
end

function M.start(flags)
    prompt_op = ''
    -- if process_flags(flags) then
    --     return
    -- end
    run(flags)
end

function M.GrepperOperator(type)
    local reg_bak = fn.getreg('@')
    local selsave = vim.o.selection
    vim.o.selection = 'inclusive'

    if type == 'v' or type == 'V' then
        cmd([[normal! gvy"]])
    elseif type == 'line' then
        cmd([[normal! '[V']y]])
    else
        cmd([[normal! `[v`]y]])
    end

    vim.o.selection = selsave
    local flags = vim.deepcopy(config)
    info(flags)
    local query_orig = fn.getreg('@')
    -- local flags.query_escaped = 0

    flags.query = query_orig
    if not flags.buffer and not flags.buffers then
        -- table.insert(flags.query, 0, '--')
    end

    fn.setreg('@', reg_bak)
    return M.start(flags)
end

local function init()
    cmd([[highlight default link GrepperPrompt Question]])
    cmd([[highlight default link GrepperQuery String]])

    cmd([[nnoremap <silent> <plug>(GrepperOperator) :set opfunc=GrepperOperator<cr>g@]])
    cmd([[xnoremap <silent> <plug>(GrepperOperator) :<c-u>call GrepperOperator(visualmode())<cr>]])

    if fn.hasmapto('<plug>(GrepperOperator)') then
        -- silent! call repeat#set("\<plug>(GrepperOperator)", v:count)
    end

    cmd(
        [[command! -nargs=* -complete=customlist,v:lua.require'grepper'.cmd_complete Krg echom 'hello']])
end

init()
return M
