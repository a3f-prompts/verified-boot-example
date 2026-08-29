# Minimal initramfs around Debian's static busybox: enough to prove the
# kernel came up and to poke around from a shell.
{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  cpio,
  gzip,
  busybox, # from versions.nix
}:
stdenvNoCC.mkDerivation {
  pname = "initramfs-busybox";
  version = busybox.version;

  src = fetchurl { inherit (busybox) urls hash; };

  nativeBuildInputs = [
    dpkg
    cpio
    gzip
  ];

  unpackPhase = ''
    dpkg-deb -x "$src" deb
  '';

  buildPhase = ''
    runHook preBuild
    mkdir -p root/bin root/sbin root/proc root/sys root/dev root/etc root/tmp
    cp deb/usr/bin/busybox root/bin/busybox
    cat > root/init <<'INIT'
    #!/bin/busybox sh
    /bin/busybox --install -s /bin
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    echo
    echo "barebox verified boot example: initramfs reached, dropping to shell"
    echo
    exec sh
    INIT
    chmod +x root/init
    find root -exec touch -h -d @1 {} +
    (cd root && find . | LC_ALL=C sort | cpio -o -H newc --reproducible --owner=+0:+0) \
      | gzip -n -9 > initramfs.cpio.gz
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 initramfs.cpio.gz $out/initramfs.cpio.gz
    runHook postInstall
  '';

  meta = {
    description = "busybox initramfs for the reference bootchain";
    license = lib.licenses.gpl2Only;
  };
}
