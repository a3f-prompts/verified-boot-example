# Pinned versions of everything that is *not* pinned by flake.lock.
#
# Everything here is a prebuilt binary that is downloaded and hash-verified,
# never built from source:
#
#  * the cross toolchain (the same kernel.org crosstool tarballs that the
#    upstream barebox CI container uses),
#  * the Debian arm64 kernel that ends up in the FIT image, and
#  * the static busybox used for the demo initramfs.
#
# barebox and labgrid are git inputs of the flake (see flake.nix/flake.lock);
# QEMU, mkimage (ubootTools) and dtc come from the pinned nixpkgs revision.
#
# To update a hash: nix hash convert --hash-algo sha256 --to sri <hex sha256>
# (or nix-prefetch-url <url> and convert the printed hash).
{
  toolchain = {
    version = "15.2.0";
    x86_64-linux = {
      url = "https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/15.2.0/x86_64-gcc-15.2.0-nolibc-aarch64-linux.tar.xz";
      hash = "sha256-o7mfb5ee1CfUP7uc+r+iykDi9Ogw3/mjdSDYKOvGPk0=";
    };
    aarch64-linux = {
      url = "https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/arm64/15.2.0/arm64-gcc-15.2.0-nolibc-aarch64-linux.tar.xz";
      hash = "sha256-PQMMQXQ+rDC+mliPecEMPKUHv8R3lg4SuyaGWegRmGc=";
    };
  };

  # Debian trixie signed arm64 kernel. The deb.debian.org URL disappears once
  # the package is superseded; the snapshot.debian.org URL is permanent.
  debianKernel = {
    version = "6.12.94-1";
    kernelVersion = "6.12.94+deb13-arm64";
    urls = [
      "https://deb.debian.org/debian/pool/main/l/linux-signed-arm64/linux-image-6.12.94+deb13-arm64_6.12.94-1_arm64.deb"
      "https://snapshot.debian.org/archive/debian/20260829T000000Z/pool/main/l/linux-signed-arm64/linux-image-6.12.94%2Bdeb13-arm64_6.12.94-1_arm64.deb"
    ];
    hash = "sha256-ctt/z7RDpLA0SL2pj058Gh+g1sIfxX8LEZ1wREL4rUk=";
  };

  busybox = {
    version = "1.37.0-6+b8";
    urls = [
      "https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-6+b8_arm64.deb"
      "https://snapshot.debian.org/archive/debian/20260829T000000Z/pool/main/b/busybox/busybox-static_1.37.0-6%2Bb8_arm64.deb"
    ];
    hash = "sha256-bRROUBLUfsOm8hArpvrGRK00yYk3P+0wwbtyZPXNNhY=";
  };

  # The imx8mm-evk machine type first appeared in QEMU 11.1.0.
  qemuMinimum = "11.1.0";
}
