# Dev shell for harnt.nvim — the Lua/Neovim plugin toolchain from TOOLS.md.
# The four-command agent/CI loop (stylua / selene / emmylua_check / busted) is
# fully available here, plus the editor LSPs and a `just` task runner.
{
  perSystem =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      devShells.default = pkgs.mkShell {
        # Brings in the git-hooks (pre-commit) tooling so `pre-commit` works in-shell.
        inputsFrom = [ config.pre-commit.devShell ];

        packages = [
          # Task runner — single source of truth for the pipeline (see ./justfile).
          pkgs.just

          # Formatter + linter (TOOLS.md: StyLua, Selene)
          pkgs.stylua
          pkgs.selene

          # Type-checking + LSP — the emmylua-analyzer-rust toolchain.
          # emmylua-check is the CI type gate; emmylua-ls is the primary editor LSP.
          pkgs.emmylua-check
          pkgs.emmylua-ls
          pkgs.emmylua-doc-cli

          # Fallback editor LSP (TOOLS.md: documented escape hatch).
          pkgs.lua-language-server

          # Lua runtimes + packaging (luarocks canonical; lux optional dev ergonomics).
          pkgs.lua5_1
          pkgs.luajit
          pkgs.luarocks
          pkgs.lux-cli

          # Tests: busted with Neovim as the Lua interpreter (via nlua).
          pkgs.neovim
          pkgs.lua51Packages.busted
          pkgs.lua51Packages.nlua
        ];

        # Export VIMRUNTIME so emmylua (CLI check + LS) can resolve Neovim's Lua
        # runtime and type-check `vim.*` properly (see .luarc.json workspace.library).
        shellHook = ''
          export VIMRUNTIME="$(nvim -l <(printf 'io.write(vim.env.VIMRUNTIME)') 2>/dev/null)"
        '';

        meta.description = lib.mkDefault "harnt.nvim development shell";
      };
    };
}
