_: {
  perSystem =
    { config, pkgs, ... }:
    {
      pre-commit = {
        check.enable = true; # NOTE: set to false if checks require network access
        settings = {
          hooks = {
            # Conventional commits
            convco.enable = true;

            # Nix
            flake-checker.enable = true;
            statix.enable = true;

            # Lua lint (Selene). Formatting (StyLua) is handled by treefmt below.
            selene = {
              enable = true;
              name = "selene";
              entry = "${pkgs.selene}/bin/selene";
              language = "system";
              files = "\\.lua$";
            };

            # Formatting (treefmt: stylua, nixfmt, taplo)
            treefmt = {
              enable = true;
              packageOverrides.treefmt = config.treefmt.build.wrapper;
            };

            # Misc
            trim-trailing-whitespace.enable = true;
            check-merge-conflicts.enable = true;
            check-added-large-files.enable = true;
          };
        };
      };
    };
}
