local M = {}

local conf = require('fff.conf')

-- State management
local state = {
  active_process = nil,
  pending_results = {},
  current_query = '',
  result_count = 0,
  max_results_reached = false,
  debounce_timer = nil,
  throttle_timer = nil,
  base_path = nil,
  on_results_callback = nil,
}

--- Check if ripgrep is available
--- @return boolean
local function is_ripgrep_available()
  return vim.fn.executable('rg') == 1
end

--- Parse a single vimgrep output line
--- Format: path:line:col:content
--- @param line string The vimgrep output line
--- @param base_path string Base path for relative paths
--- @return table|nil Parsed result or nil if invalid
local function parse_vimgrep_line(line, base_path)
  if not line or line == '' then return nil end

  -- vimgrep format: path:line:col:content
  -- Handle paths with colons (Windows, URLs) by finding last 3 colons
  local parts = {}
  local last_colon_pos = #line + 1

  -- Find the last 3 colons from the end
  for i = #line, 1, -1 do
    if line:sub(i, i) == ':' then
      table.insert(parts, 1, line:sub(i + 1, last_colon_pos - 1))
      last_colon_pos = i
      if #parts == 3 then
        local path = line:sub(1, i - 1)
        local line_num = tonumber(parts[1])
        local col_num = tonumber(parts[2])
        local content = parts[3]

        if not line_num then return nil end

        -- Make path absolute if needed
        local full_path = path
        if not vim.fn.isdirectory(path) == 1 and not vim.fn.filereadable(path) == 1 then
          -- Try relative to base_path
          if base_path then
            full_path = vim.fn.fnamemodify(base_path .. '/' .. path, ':p')
          end
        else
          full_path = vim.fn.fnamemodify(path, ':p')
        end

        local relative_path = vim.fn.fnamemodify(full_path, ':.')

        return {
          path = full_path,
          relative_path = relative_path,
          name = vim.fn.fnamemodify(full_path, ':t'),
          line = line_num,
          column = col_num or 0,
          content = content or '',
          display_text = string.format('%s:%d:%s', relative_path, line_num, content or ''),
        }
      end
    end
  end

  return nil
end

--- Format result for UI display
--- @param parsed table Parsed result
--- @return table Formatted result compatible with picker UI
local function format_result(parsed)
  return {
    path = parsed.path,
    relative_path = parsed.relative_path,
    name = parsed.name,
    line = parsed.line,
    column = parsed.column,
    content = parsed.content,
    display_text = parsed.display_text,
    -- Add location for jump_to_location
    location = {
      line = parsed.line,
      col = parsed.column > 0 and parsed.column or nil,
    },
  }
end

--- Cancel active search
function M.cancel_search()
  if state.debounce_timer then
    state.debounce_timer:stop()
    state.debounce_timer:close()
    state.debounce_timer = nil
  end

  if state.throttle_timer then
    state.throttle_timer:stop()
    state.throttle_timer:close()
    state.throttle_timer = nil
  end

  if state.active_process then
    -- Kill the process
    pcall(function()
      local uv = vim.uv or vim.loop
      state.active_process:kill(uv.constants.SIGTERM)
    end)
    state.active_process = nil
  end

  state.pending_results = {}
  state.current_query = ''
  state.result_count = 0
  state.max_results_reached = false
end

--- Flush pending results to callback
local function flush_results()
  if not state.on_results_callback or #state.pending_results == 0 then return end

  local results = {}
  for _, parsed in ipairs(state.pending_results) do
    table.insert(results, format_result(parsed))
  end

  state.pending_results = {}
  state.throttle_timer = nil

  if state.on_results_callback then
    state.on_results_callback(results, {
      total_matched = state.result_count,
      max_results_reached = state.max_results_reached,
    })
  end
end

--- Start a new search
--- @param query string Search query
--- @param base_path string Base path to search in
--- @param callback function Callback for results: function(results, metadata)
function M.start_search(query, base_path, callback)
  if not is_ripgrep_available() then
    vim.notify('ripgrep (rg) not found. Please install ripgrep to use live grep.', vim.log.levels.ERROR)
    if callback then callback({}, { total_matched = 0, max_results_reached = false }) end
    return
  end

  -- Cancel previous search
  M.cancel_search()

  if not query or query == '' then
    if callback then callback({}, { total_matched = 0, max_results_reached = false }) end
    return
  end

  state.current_query = query
  state.base_path = base_path or vim.fn.getcwd()
  state.on_results_callback = callback
  state.result_count = 0
  state.max_results_reached = false

  local config = conf.get()
  local debounce_ms = config.live_grep and config.live_grep.debounce_ms or 120

  -- Debounce: wait before starting search
  state.debounce_timer = vim.loop.new_timer()
  state.debounce_timer:start(
    debounce_ms,
    0,
    vim.schedule_wrap(function()
      state.debounce_timer:close()
      state.debounce_timer = nil

      -- Check if query changed during debounce
      if state.current_query ~= query then return end

      -- Build ripgrep command
      local rg_config = config.live_grep or {}
      local default_args = { '--vimgrep', '--no-heading', '--hidden' }
      local base_args = rg_config.rg_args or default_args

      -- Build full args array: base args + query + path
      local args = {}
      for _, arg in ipairs(base_args) do
        table.insert(args, arg)
      end
      table.insert(args, query)
      table.insert(args, state.base_path)

      -- Use vim.uv.spawn for streaming (fallback to vim.loop for older Neovim)
      local uv = vim.uv or vim.loop
      local stdout_buffer = ''
      
      -- Create pipes for stdout
      local stdout_pipe = uv.new_pipe(false)
      local stderr_pipe = uv.new_pipe(false)
      
      local handle, pid_or_err = uv.spawn('rg', {
        args = args,
        cwd = state.base_path,
        stdio = { nil, stdout_pipe, stderr_pipe },
      }, function(code, signal)
        vim.schedule(function()
          -- Check if this is still the current query
          if state.current_query ~= query then return end

          state.active_process = nil

          -- Process any remaining buffer
          if stdout_buffer and stdout_buffer ~= '' then
            local lines = vim.split(stdout_buffer, '\n', { plain = true })
            for _, line in ipairs(lines) do
              if line and line ~= '' then
                local parsed = parse_vimgrep_line(line, state.base_path)
                if parsed then
                  if state.result_count < (rg_config.max_results or 1000) then
                    table.insert(state.pending_results, parsed)
                    state.result_count = state.result_count + 1
                  else
                    state.max_results_reached = true
                    break
                  end
                end
              end
            end
          end

          -- Handle exit codes
          if code == 1 then
            -- Exit code 1 means no matches found (normal)
            flush_results()
            if state.on_results_callback then
              state.on_results_callback({}, { total_matched = 0, max_results_reached = false })
            end
          elseif code ~= 0 and code ~= nil then
            -- Other error (but don't error on nil, which can happen)
            flush_results()
            if state.on_results_callback then
              state.on_results_callback({}, { total_matched = state.result_count, max_results_reached = state.max_results_reached })
            end
          else
            -- Success
            flush_results()
          end
        end)
      end)

      if not handle then
        vim.notify('Failed to spawn ripgrep: ' .. tostring(pid_or_err), vim.log.levels.ERROR)
        if callback then callback({}, { total_matched = 0, max_results_reached = false }) end
        return
      end

      state.active_process = handle

      -- Read stdout incrementally
      stdout_pipe:read_start(function(err, data)
        if err then
          vim.schedule(function()
            if state.current_query ~= query then return end
            vim.notify('ripgrep read error: ' .. tostring(err), vim.log.levels.WARN)
          end)
          return
        end

        if not data then
          -- EOF - close pipe
          stdout_pipe:read_stop()
          stdout_pipe:close()
          return
        end

        vim.schedule(function()
          if state.current_query ~= query then return end

          stdout_buffer = stdout_buffer .. data
          local lines = vim.split(stdout_buffer, '\n', { plain = true })
          stdout_buffer = lines[#lines] -- Keep incomplete line in buffer

          for i = 1, #lines - 1 do
            local line = lines[i]
            if line and line ~= '' then
              local parsed = parse_vimgrep_line(line, state.base_path)
              if parsed then
                if state.result_count < (rg_config.max_results or 1000) then
                  table.insert(state.pending_results, parsed)
                  state.result_count = state.result_count + 1

                  -- Throttle UI updates
                  if not state.throttle_timer then
                    local throttle_ms = rg_config.throttle_ms or 80
                    state.throttle_timer = vim.loop.new_timer()
                    state.throttle_timer:start(
                      throttle_ms,
                      0,
                      vim.schedule_wrap(function()
                        flush_results()
                      end)
                    )
                  end
                else
                  state.max_results_reached = true
                  flush_results()
                  -- Kill process if we've reached max results
                  if state.active_process then
                    local uv = vim.uv or vim.loop
                    pcall(function()
                      state.active_process:kill(uv.constants.SIGTERM)
                    end)
                    stdout_pipe:read_stop()
                    stdout_pipe:close()
                    state.active_process = nil
                  end
                  return
                end
              end
            end
          end
        end)
      end)
    end)
  )
end

--- Cleanup on picker close
function M.cleanup()
  M.cancel_search()
  state.on_results_callback = nil
  state.base_path = nil
end

return M

