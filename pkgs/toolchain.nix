# Prebuilt aarch64 cross toolchain from kernel.org (crosstool), the same
# toolchain the upstream barebox CI container uses. Nothing is compiled here:
# the tarball is downloaded, hash-checked and patchelf'ed against the nixpkgs
# glibc so the binaries run inside the Nix sandbox.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
  toolchain, # from versions.nix
}:
let
  host =
    toolchain.${stdenv.hostPlatform.system}
      or (throw "no prebuilt aarch64 crosstool for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "crosstool-aarch64-linux";
  version = toolchain.version;

  src = fetchurl { inherit (host) url hash; };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  # gprofng helper libraries reference symbols we don't care about
  autoPatchelfIgnoreMissingDeps = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a aarch64-linux/. $out/
    rm -rf $out/lib/gprofng $out/bin/gprofng* $out/bin/gp-*
    runHook postInstall
  '';

  passthru = {
    crossCompile = "aarch64-linux-";
    target = "aarch64-linux";
  };

  meta = {
    description = "kernel.org crosstool GCC ${toolchain.version} for aarch64-linux (binary)";
    homepage = "https://mirrors.edge.kernel.org/pub/tools/crosstool/";
    license = lib.licenses.gpl3Plus;
    platforms = builtins.filter (s: toolchain ? ${s}) lib.platforms.linux;
  };
}
