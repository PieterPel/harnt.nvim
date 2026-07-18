{
  perSystem = _: {
    treefmt = {
      projectRootFile = "flake.nix";
      flakeFormatter = true;
      programs = {
        # Lua formatting — StyLua auto-discovers ./.stylua.toml
        stylua.enable = true;
        # Nix
        nixfmt.enable = true;
        # TOML (.stylua.toml, selene.toml, etc.)
        taplo.enable = true;
        # justfile
        just.enable = true;
      };
    };
  };
}
