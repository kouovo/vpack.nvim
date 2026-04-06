local M = {}

M.defaults = {
  window = {
    border = "rounded",
    width = 0.8,
    height = 0.8,
  },
  log = {
    path = vim.fs.joinpath(vim.fn.stdpath("log"), "nvim-pack.log"),
    border = "rounded",
    width = 0.8,
    height = 0.6,
  },
}

M.values = vim.deepcopy(M.defaults)

---@param opts table?
---@return table
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.values
end

return M
