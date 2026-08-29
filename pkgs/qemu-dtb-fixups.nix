# Apply to a device tree blob the same fixups QEMU's imx8mm-evk board code
# applies to the DTB it loads itself (hw/arm/imx8mm-evk.c,
# imx8mm_evk_modify_dtb): remove the nodes of peripherals QEMU does not model
# and drop the PSCI CPU idle states. Linux gets its device tree from the
# signed FIT image, not from QEMU, so the fixups have to happen here.
{
  lib,
  stdenvNoCC,
  python3,
  dtb,
  name ? baseNameOf dtb,
}:
let
  python = python3.withPackages (ps: [ ps.libfdt ]);
in
stdenvNoCC.mkDerivation {
  pname = "qemu-fixups-${name}";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ python ];

  buildPhase = ''
    runHook preBuild
    python3 - ${dtb} ${name} <<'PY'
    import sys
    import libfdt

    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        fdt = libfdt.Fdt(bytearray(f.read()))

    def by_compatible(start, compat):
        # not wrapped by the Fdt class, use the low-level binding
        return libfdt.fdt_node_offset_by_compatible(fdt._fdt, start, compat)

    # Temporarily disable following nodes until they are implemented
    for compat in ("nxp,imx8mm-fspi", "fsl,imx8mm-mipi-csi", "fsl,imx8mm-mipi-dsim"):
        off = by_compatible(-1, compat)
        while off >= 0:
            fdt.del_node(off)
            off = by_compatible(-1, compat)

    # Remove cpu-idle-states property from CPU nodes
    off = by_compatible(-1, "arm,cortex-a53")
    while off >= 0:
        fdt.delprop(off, "cpu-idle-states", quiet=(libfdt.NOTFOUND,))
        off = by_compatible(off, "arm,cortex-a53")

    fdt.pack()
    with open(dst, "wb") as f:
        f.write(fdt.as_bytearray())
    PY
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 ${name} $out/${name}
    runHook postInstall
  '';
}
