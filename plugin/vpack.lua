if vim.g.loaded_vpack == 1 then
  return
end

vim.g.loaded_vpack = 1

require("vpack").setup_autocmds()

vim.api.nvim_create_user_command("Vpack", function()
  require("vpack").open()
end, {
  desc = "Open vpack UI",
})
