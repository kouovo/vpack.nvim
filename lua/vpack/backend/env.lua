local M = {}

local function is_windows()
  local uname = (vim.uv or vim.loop).os_uname()
  return uname and uname.sysname == "Windows_NT"
end

local function build_non_interactive()
  local env = {
    GIT_TERMINAL_PROMPT = "0",
    GCM_INTERACTIVE = "never",
  }

  local ssh_command = vim.env.GIT_SSH_COMMAND
  if ssh_command and ssh_command ~= "" then
    if not ssh_command:lower():find("batchmode=yes", 1, true) then
      env.GIT_SSH_COMMAND = ssh_command .. " -oBatchMode=yes"
    end
  elseif vim.fn.executable("ssh") == 1 then
    env.GIT_SSH_COMMAND = "ssh -oBatchMode=yes"
  end

  if not is_windows() then
    env.GIT_ASKPASS = "/bin/false"
    env.SSH_ASKPASS = "/bin/false"
  end

  return env
end

local cached_env = build_non_interactive()

function M.non_interactive()
  return vim.deepcopy(cached_env)
end

return M
