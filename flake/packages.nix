{
  perSystem =
    { system, pkgs, ... }:
    let
      helloTest = pkgs.stdenv.mkDerivation {
        pname = "hello-test";
        version = "0.0.1";

        src = pkgs.runCommand "empty-src" { } "mkdir -p $out";
        dontUnpack = true;

        installPhase = "mkdir -p $out";

        meta = with pkgs.lib; {
          description = "Example package";
          homepage = "https://github.com/RebelsAI";
          license = licenses.mit;
          maintainers = [ ];
          platforms = [
            "aarch64-linux"
            "x86_64-linux"
            "x86_64-darwin"
            "aarch64-darwin"
          ];
        };
      };
    in
    {
      packages.hello-test = helloTest;
    };
}
