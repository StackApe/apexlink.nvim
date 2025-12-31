-- ApexLink: P2P collaboration for apex-pde
-- Communicates with apexlink-daemon via JSON-RPC over stdio

local M = {}

-- State
M.job_id = nil
M.room_code = nil
M.last_room_code = nil  -- Remember last room for rejoin
M.peers = {}
M.connected = false
M.callbacks = {}
M.sync_timer = nil  -- Timer for auto-save/reload
M.synced_buffers = {}  -- Buffers being synced {bufnr -> {path, attached}}
M.applying_remote = false  -- Flag to prevent echo when applying remote changes

-- Configuration
M.config = {
  daemon_path = nil, -- Auto-detected
  server_url = "ws://localhost:8765",
  username = nil, -- Auto-detected from $USER
  color = "#00ffff",
  auto_notify = true,
  -- Auto-sync settings (enabled when connected to a room)
  auto_save = true,      -- Auto-save buffers every sync_interval
  auto_reload = true,    -- Auto-check for external changes
  sync_interval = 2000,  -- Sync interval in ms (2 seconds like Apex)
}

-- Find the daemon binary
local function find_daemon()
  -- Check if set explicitly
  if M.config.daemon_path and vim.fn.executable(M.config.daemon_path) == 1 then
    return M.config.daemon_path
  end

  -- Check relative to this plugin (apex-pde/apexlink/daemon/target/release)
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(script_path, ":h:h:h:h")
  local release_path = plugin_dir .. "/apexlink/daemon/target/release/apexlink-daemon"
  local debug_path = plugin_dir .. "/apexlink/daemon/target/debug/apexlink-daemon"

  if vim.fn.executable(release_path) == 1 then
    return release_path
  end
  if vim.fn.executable(debug_path) == 1 then
    return debug_path
  end

  -- Hardcoded fallback for apex-pde development
  local home = os.getenv("HOME") or ""
  local apex_release = home .. "/NeovimGUI/apex-pde/apexlink/daemon/target/release/apexlink-daemon"
  local apex_debug = home .. "/NeovimGUI/apex-pde/apexlink/daemon/target/debug/apexlink-daemon"

  if vim.fn.executable(apex_release) == 1 then
    return apex_release
  end
  if vim.fn.executable(apex_debug) == 1 then
    return apex_debug
  end

  -- Check in PATH
  if vim.fn.executable("apexlink-daemon") == 1 then
    return "apexlink-daemon"
  end

  return nil
end

-- Get username
local function get_username()
  return M.config.username or os.getenv("USER") or "apex-user"
end

-- Send notification (respects auto_notify setting)
local function notify(msg, level)
  if M.config.auto_notify then
    vim.notify("ApexLink: " .. msg, level or vim.log.levels.INFO)
  end
end

-- Start the sync timer (auto-save + auto-reload)
local function start_sync_timer()
  if M.sync_timer then
    return  -- Already running
  end

  M.sync_timer = vim.uv.new_timer()
  M.sync_timer:start(M.config.sync_interval, M.config.sync_interval, vim.schedule_wrap(function()
    if not M.room_code then
      return  -- Not in a room
    end

    -- Auto-save modified buffers (silent, force write)
    if M.config.auto_save then
      pcall(function()
        -- Use noautocmd to prevent recursive triggers, force write
        vim.cmd("silent! noautocmd wall!")
      end)
    end

    -- Auto-reload: check for external file changes
    if M.config.auto_reload then
      pcall(function()
        vim.cmd("silent! checktime")
      end)
    end
  end))
end

-- Stop the sync timer
local function stop_sync_timer()
  if M.sync_timer then
    M.sync_timer:stop()
    M.sync_timer:close()
    M.sync_timer = nil
  end
end

-- Send a command to the daemon
local function send_cmd(cmd)
  if not M.job_id then
    notify("Daemon not running", vim.log.levels.ERROR)
    return false
  end

  local json = vim.fn.json_encode(cmd)
  vim.fn.chansend(M.job_id, json .. "\n")
  return true
end

-- Handle events from daemon
local function on_event(event)
  if event.event == "ready" then
    notify("Daemon ready")
  elseif event.event == "connected" then
    M.connected = true
    notify("Connected as " .. event.peer_id)
  elseif event.event == "room_created" then
    M.room_code = event.code
    M.last_room_code = event.code  -- Remember for rejoin
    -- Copy to clipboard
    vim.fn.setreg("+", event.code)
    vim.fn.setreg("*", event.code)
    notify("Room created: " .. event.code .. " (copied to clipboard)")
    -- Start auto-sync timer
    start_sync_timer()
    -- Notify PDE GUI if available
    if vim.g.apex_gui then
      vim.rpcnotify(0, "apexlink:room_created", { code = event.code })
    end
  elseif event.event == "room_joined" then
    M.room_code = event.code
    M.last_room_code = event.code  -- Remember for rejoin
    M.peers = event.peers or {}
    local peer_names = {}
    for _, p in ipairs(M.peers) do
      table.insert(peer_names, p.name)
    end
    notify("Joined room: " .. event.code .. " (" .. #M.peers .. " peers)")
    -- Start auto-sync timer
    start_sync_timer()
    if vim.g.apex_gui then
      vim.rpcnotify(0, "apexlink:room_joined", { code = event.code, peers = M.peers })
    end
  elseif event.event == "peer_joined" then
    table.insert(M.peers, {
      id = event.peer_id,
      name = event.name,
      color = event.color,
    })
    notify(event.name .. " joined", vim.log.levels.INFO)
    if vim.g.apex_gui then
      vim.rpcnotify(0, "apexlink:peer_joined", { peer_id = event.peer_id, name = event.name })
    end
  elseif event.event == "peer_left" then
    for i, p in ipairs(M.peers) do
      if p.id == event.peer_id then
        notify(p.name .. " left", vim.log.levels.INFO)
        table.remove(M.peers, i)
        break
      end
    end
    if vim.g.apex_gui then
      vim.rpcnotify(0, "apexlink:peer_left", { peer_id = event.peer_id })
    end
  elseif event.event == "p2p_connected" then
    notify("P2P connected with " .. event.peer_id)
  elseif event.event == "data" then
    -- Handle incoming data (will be used for CRDT sync later)
    for _, cb in ipairs(M.callbacks.data or {}) do
      cb(event.peer_id, event.data)
    end
  elseif event.event == "status" then
    local status_msg = M.connected and "Connected" or "Disconnected"
    if M.room_code then
      status_msg = status_msg .. " | Room: " .. M.room_code
    end
    status_msg = status_msg .. " | Peers: " .. #M.peers
    notify(status_msg)
  elseif event.event == "buf_changed" then
    -- Remote buffer change - apply to local buffer
    local path = event.path
    local content = event.content

    -- Find buffer by path
    for bufnr, info in pairs(M.synced_buffers) do
      if info.path == path and vim.api.nvim_buf_is_valid(bufnr) then
        M.applying_remote = true
        local lines = vim.split(content, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        M.applying_remote = false
        break
      end
    end
  elseif event.event == "error" then
    notify(event.message, vim.log.levels.ERROR)
  end
end

-- Handle stdout from daemon
local function on_stdout(_, data, _)
  for _, line in ipairs(data) do
    if line and line ~= "" then
      local ok, event = pcall(vim.fn.json_decode, line)
      if ok and event then
        vim.schedule(function()
          on_event(event)
        end)
      end
    end
  end
end

-- Handle stderr from daemon
local function on_stderr(_, data, _)
  for _, line in ipairs(data) do
    if line and line ~= "" then
      vim.schedule(function()
        vim.notify("ApexLink [stderr]: " .. line, vim.log.levels.WARN)
      end)
    end
  end
end

-- Handle daemon exit
local function on_exit(_, code, _)
  M.job_id = nil
  M.connected = false
  M.room_code = nil
  M.peers = {}
  stop_sync_timer()  -- Stop auto-sync on exit
  if code ~= 0 then
    notify("Daemon exited with code " .. code, vim.log.levels.WARN)
  end
end

-- Start the daemon
function M.start()
  if M.job_id then
    notify("Daemon already running")
    return true
  end

  local daemon = find_daemon()
  if not daemon then
    notify("Cannot find apexlink-daemon binary. Build with: cd apexlink/daemon && cargo build --release", vim.log.levels.ERROR)
    return false
  end

  local cmd = { daemon, "nvim", "--server", M.config.server_url }

  M.job_id = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if M.job_id <= 0 then
    notify("Failed to start daemon", vim.log.levels.ERROR)
    M.job_id = nil
    return false
  end

  return true
end

-- Stop the daemon
function M.stop()
  stop_sync_timer()  -- Stop auto-sync
  if M.job_id then
    vim.fn.jobstop(M.job_id)
    M.job_id = nil
    M.connected = false
    M.room_code = nil
    M.peers = {}
    notify("Daemon stopped")
  end
end

-- Create a new room
function M.create()
  if not M.job_id and not M.start() then
    return
  end

  send_cmd({
    cmd = "create",
    name = get_username(),
    color = M.config.color,
  })
end

-- Join an existing room
function M.join(code)
  if not code or code == "" then
    vim.ui.input({ prompt = "Room code: " }, function(input)
      if input and input ~= "" then
        M.join(input:upper())
      end
    end)
    return
  end

  if not M.job_id and not M.start() then
    return
  end

  send_cmd({
    cmd = "join",
    code = code:upper(),
    name = get_username(),
    color = M.config.color,
  })
end

-- Leave the current room
function M.leave()
  send_cmd({ cmd = "leave" })
  stop_sync_timer()  -- Stop auto-sync
  M.room_code = nil
  M.peers = {}
  notify("Left room")
end

-- Rejoin the last room
function M.rejoin()
  if not M.last_room_code then
    notify("No previous room to rejoin", vim.log.levels.WARN)
    return
  end

  if M.room_code then
    notify("Already in a room. Leave first with :ApexLink leave", vim.log.levels.WARN)
    return
  end

  notify("Rejoining room: " .. M.last_room_code)
  M.join(M.last_room_code)
end

-- Get current status
function M.status()
  if M.job_id then
    send_cmd({ cmd = "status" })
  else
    notify("Daemon not running")
  end
end

-- Send data to peers
function M.send(data)
  send_cmd({ cmd = "send", data = data })
end

-- Register a callback for data events
function M.on_data(callback)
  M.callbacks.data = M.callbacks.data or {}
  table.insert(M.callbacks.data, callback)
end

-- === Buffer Sync Functions ===

-- Sync the current buffer with peers
function M.sync_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M.room_code then
    notify("Not in a room. Create or join one first.", vim.log.levels.WARN)
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    notify("Buffer has no file path", vim.log.levels.WARN)
    return
  end

  -- Check if already syncing
  if M.synced_buffers[bufnr] then
    notify("Buffer already syncing: " .. vim.fn.fnamemodify(path, ":t"))
    return
  end

  -- Get current content and send to daemon
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Open buffer in daemon
  send_cmd({ cmd = "buf_open", path = path })

  -- Set initial content
  send_cmd({ cmd = "buf_set", path = path, content = content })

  -- Attach to buffer changes
  local attached = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, first_line, last_line, new_last_line, _)
      -- Skip if applying remote changes or not in room
      if M.applying_remote or not M.room_code then
        return
      end

      -- For simplicity, send full content on each change
      -- (CRDT will handle merging on the daemon side)
      local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local new_content = table.concat(new_lines, "\n")
      send_cmd({ cmd = "buf_set", path = path, content = new_content })
    end,
    on_detach = function(_, buf)
      M.synced_buffers[buf] = nil
      send_cmd({ cmd = "buf_close", path = path })
    end,
  })

  if attached then
    M.synced_buffers[bufnr] = { path = path, attached = true }
    notify("Syncing: " .. vim.fn.fnamemodify(path, ":t"))

    -- Request sync from peers (in case they have newer content)
    send_cmd({ cmd = "buf_sync", path = path })
  else
    notify("Failed to attach to buffer", vim.log.levels.ERROR)
  end
end

-- Stop syncing a buffer
function M.unsync_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local info = M.synced_buffers[bufnr]
  if not info then
    notify("Buffer not being synced")
    return
  end

  -- Detach will trigger on_detach callback
  vim.api.nvim_buf_detach(bufnr)
  M.synced_buffers[bufnr] = nil

  send_cmd({ cmd = "buf_close", path = info.path })
  notify("Stopped syncing: " .. vim.fn.fnamemodify(info.path, ":t"))
end

-- List synced buffers
function M.list_synced()
  if vim.tbl_isempty(M.synced_buffers) then
    notify("No buffers being synced")
    return
  end

  local names = {}
  for bufnr, info in pairs(M.synced_buffers) do
    table.insert(names, vim.fn.fnamemodify(info.path, ":t"))
  end
  notify("Syncing: " .. table.concat(names, ", "))
end

-- Setup function (called from plugin config)
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Enable autoread for better file sync
  vim.opt.autoread = true

  -- Auto-reload files when focus returns or buffer entered
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    pattern = "*",
    callback = function()
      if vim.fn.getcmdwintype() == "" then
        pcall(function() vim.cmd("checktime") end)
      end
    end,
    desc = "ApexLink: Check for file changes",
  })

  -- Auto-load changed files without prompting (for ApexLink sync)
  vim.api.nvim_create_autocmd("FileChangedShell", {
    pattern = "*",
    callback = function()
      -- If in an ApexLink room, auto-reload without prompt
      if M.room_code then
        vim.cmd("edit!")
        return true  -- Suppress the default prompt
      end
      return false  -- Show normal prompt when not in a room
    end,
    desc = "ApexLink: Auto-reload changed files",
  })

  -- Register user commands
  vim.api.nvim_create_user_command("ApexLink", function(args)
    local subcmd = args.fargs[1]
    if subcmd == "create" then
      M.create()
    elseif subcmd == "join" then
      M.join(args.fargs[2])
    elseif subcmd == "rejoin" then
      M.rejoin()
    elseif subcmd == "leave" then
      M.leave()
    elseif subcmd == "status" then
      M.status()
    elseif subcmd == "stop" then
      M.stop()
    -- Buffer sync commands
    elseif subcmd == "sync" then
      M.sync_buffer()
    elseif subcmd == "unsync" then
      M.unsync_buffer()
    elseif subcmd == "buffers" then
      M.list_synced()
    else
      notify("Usage: :ApexLink <create|join|rejoin|leave|status|stop|sync|unsync|buffers>", vim.log.levels.INFO)
    end
  end, {
    nargs = "*",
    complete = function(_, cmdline, _)
      local args = vim.split(cmdline, "%s+")
      if #args == 2 then
        return { "create", "join", "rejoin", "leave", "status", "stop", "sync", "unsync", "buffers" }
      end
      return {}
    end,
    desc = "ApexLink P2P collaboration",
  })

  -- Keymaps under <leader>a for "apexlink"
  local map = vim.keymap.set
  map("n", "<leader>ac", M.create, { desc = "ApexLink: Create room" })
  map("n", "<leader>aj", M.join, { desc = "ApexLink: Join room" })
  map("n", "<leader>ar", M.rejoin, { desc = "ApexLink: Rejoin last room" })
  map("n", "<leader>al", M.leave, { desc = "ApexLink: Leave room" })
  map("n", "<leader>as", M.status, { desc = "ApexLink: Show status" })
  map("n", "<leader>ax", M.stop, { desc = "ApexLink: Stop daemon" })
  -- Buffer sync keymaps
  map("n", "<leader>ab", M.sync_buffer, { desc = "ApexLink: Sync current buffer" })
  map("n", "<leader>au", M.unsync_buffer, { desc = "ApexLink: Unsync current buffer" })
  map("n", "<leader>aB", M.list_synced, { desc = "ApexLink: List synced buffers" })

  -- Register with which-key if available
  pcall(function()
    require("which-key").add({
      { "<leader>a", group = "ApexLink" },
    })
  end)

  -- Cleanup on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if M.job_id then
        vim.fn.jobstop(M.job_id)
      end
    end,
  })
end

return M
