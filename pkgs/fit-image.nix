# Build (and sign) a FIT image from an .its source. @NAME@ placeholders in
# the .its are substituted with the given store paths.
{
  lib,
  stdenvNoCC,
  ubootTools,
  dtc,

  name,
  its,
  substitutions ? { },
  # directory containing <key-name-hint>.key and <key-name-hint>.crt, or null
  keys ? null,
}:
stdenvNoCC.mkDerivation {
  pname = "fit-${name}";
  version = "1";

  dontUnpack = true;

  nativeBuildInputs = [
    ubootTools
    dtc
  ];

  buildPhase = ''
    runHook preBuild
    substitute ${its} ${name}.its ${
      lib.concatStringsSep " " (
        lib.mapAttrsToList (n: v: "--replace-fail '@${n}@' '${v}'") substitutions
      )
    }
    mkimage -f ${name}.its ${lib.optionalString (keys != null) "-k ${keys}"} ${name}.fit
    mkimage -l ${name}.fit
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 ${name}.fit $out/${name}.fit
    install -Dm644 ${name}.its $out/${name}.its
    runHook postInstall
  '';

  passthru = {
    file = "${name}.fit";
    signed = keys != null;
  };
}
