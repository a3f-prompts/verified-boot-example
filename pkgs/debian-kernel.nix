# The Linux kernel that the bootchain ends in. Taken as a prebuilt, signed
# Debian package so that no kernel has to be built; only the arm64 Image and
# the imx8mm-evk device tree are extracted.
{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  debianKernel, # from versions.nix
}:
stdenvNoCC.mkDerivation {
  pname = "linux-image-debian-arm64";
  version = debianKernel.version;

  src = fetchurl { inherit (debianKernel) urls hash; };

  nativeBuildInputs = [ dpkg ];

  unpackPhase = ''
    dpkg-deb -x "$src" .
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp boot/vmlinuz-${debianKernel.kernelVersion} $out/Image
    cp usr/lib/linux-image-${debianKernel.kernelVersion}/freescale/imx8mm-evk.dtb $out/
    runHook postInstall
  '';

  passthru = { inherit (debianKernel) kernelVersion; };

  meta = {
    description = "Debian arm64 kernel Image and imx8mm-evk.dtb (binary)";
    license = lib.licenses.gpl2Only;
  };
}
