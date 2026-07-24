rockspec_format = "3.0"
package = "harnt.nvim"
version = "scm-1"

source = {
  url = "git+https://github.com/PieterPel/harnt.nvim.git",
}

description = {
  summary = "Drive any native-TUI coding agent in Neovim at full fidelity via reverse-MCP.",
  detailed = [[
    One Neovim plugin that hosts the reverse-MCP / IDE-callback channel each coding
    agent (Claude Code, Codex, Gemini, ...) already speaks, behind a single shared
    editor-context / diff / approvals / keymap layer. The agent keeps its own TUI;
    harnt never renders a chat UI, so no native feature is ever lost.
  ]],
  homepage = "https://github.com/PieterPel/harnt.nvim",
  license = "MIT",
  labels = { "neovim", "ai", "agents", "mcp" },
}

dependencies = {
  "lua >= 5.1",
}

test_dependencies = {
  "busted",
  "nlua",
}

test = {
  type = "busted",
}

build = {
  type = "builtin",
}
