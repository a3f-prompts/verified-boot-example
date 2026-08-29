# Generic barebox builder: defconfig + Kconfig fragments + security policies +
# public keys + environment overlay. The per-policy variants of the bootchain
# are instances of this.
{
  lib,
  stdenv,
  toolchain,
  bison,
  flex,
  openssl,
  pkg-config,
  python3,
  libusb1,
  lz4,
  lzop,
  xz,
  zstd,

  src,
  version,
  pname ? "barebox",
  defconfig ? "imx_v8_defconfig",
  # Kconfig fragments merged on top of the defconfig, in order
  configFragments ? [ ],
  # Extra literal .config lines appended after the fragments
  extraConfig ? "",
  patches ? [ ],
  # .sconfig security policy files to compile in and register
  policies ? [ ],
  # Public keys for the "fit" keyring: list of { hint; crt; }
  publicKeys ? [ ],
  # Directory overlaying the default environment (CONFIG_DEFAULT_ENVIRONMENT_PATH)
  defaultEnv ? null,
  # Build artifacts to install, relative to the build tree
  artifacts ? [ "images/barebox-dt-2nd.img" ],
  # Directory with the firmware blobs barebox links into the PBL (DDR training
  # firmware, TF-A BL31, ...; see firmware/ in the barebox tree). null builds
  # with the dummy blobs barebox's own CI uses: the resulting i.MX images are
  # structurally complete but must not be flashed to hardware.
  firmware ? null,
  # barebox insists that .sconfig files are complete ("up to date"); the
  # build normalizes them with `make security_olddefconfig` and fails if that
  # changed anything, so that the checked-in policies stay canonical. Set
  # this to only run the configure step and install the normalized policies.
  normalizePoliciesOnly ? false,
}:
let
  policyPath = lib.concatMapStringsSep " " (p: "security/${baseNameOf p}") policies;
  keySpec = lib.concatMapStringsSep " " (k: "keyring=fit,fit-hint=${k.hint}:${k.crt}") publicKeys;
in
stdenv.mkDerivation {
  inherit
    pname
    version
    src
    patches
    ;

  nativeBuildInputs = [
    toolchain
    bison
    flex
    openssl
    pkg-config
    python3
    libusb1
    lz4
    lzop
    xz
    zstd
  ];

  # The host compiler wrapper's hardening flags are irrelevant for the
  # freestanding cross build and only produce noise.
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  makeFlags = [
    "ARCH=arm"
    "CROSS_COMPILE=${toolchain.crossCompile}"
    "KBUILD_BUILD_USER=nix"
    "KBUILD_BUILD_HOST=nix"
  ];

  postPatch = ''
    patchShebangs scripts
  ''
  + lib.concatMapStringsSep "\n" (p: "cp ${p} security/${baseNameOf p}\n") policies
  + lib.optionalString (defaultEnv != null) ''
    # scripts/genenv copies and later deletes the environment tree, which
    # fails on the read-only permissions of a store path
    cp -r ${defaultEnv} defaultenv-overlay
    chmod -R u+w defaultenv-overlay
  ''
  + (
    if firmware != null then
      ''
        cp -r ${firmware}/. firmware/
        chmod -R u+w firmware
      ''
    else
      ''
        ./test/generate-dummy-fw.sh
      ''
  );

  configurePhase = ''
    runHook preConfigure

    make $makeFlags ${defconfig}
    ${lib.optionalString (configFragments != [ ]) ''
      scripts/kconfig/merge_config.sh -m .config ${lib.concatStringsSep " " configFragments}
    ''}
    cat >> .config <<CONFIG
    ${lib.optionalString (publicKeys != [ ]) ''CONFIG_CRYPTO_PUBLIC_KEYS="${keySpec}"''}
    ${lib.optionalString (policies != [ ]) ''CONFIG_SECURITY_POLICY_PATH="${policyPath}"''}
    ${lib.optionalString (defaultEnv != null) ''CONFIG_DEFAULT_ENVIRONMENT_PATH="defaultenv-overlay"''}
    ${extraConfig}
    CONFIG
    make $makeFlags olddefconfig
    ${lib.optionalString (policies != [ ]) ''
      # Normalize the policies against the full SCONFIG symbol set
      make $makeFlags security_olddefconfig
      stale=0
      ${lib.concatMapStringsSep "\n" (p: ''
        diff -u ${p} security/${baseNameOf p} || stale=1
      '') policies}
      if [ "$stale" = 1 ] && [ -z "$normalizePoliciesOnly" ]; then
        echo "*** the security policies above are not up to date." >&2
        echo "*** Run 'nix build .#policies-normalized' and copy result/*.sconfig to config/policies/." >&2
        exit 1
      fi
    ''}

    runHook postConfigure
  '';

  dontBuild = normalizePoliciesOnly;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    ${lib.optionalString (!normalizePoliciesOnly) ''
      for f in ${lib.concatStringsSep " " artifacts}; do
        cp "$f" $out/
      done
      cp .config $out/config
    ''}
    ${lib.concatMapStringsSep "\n" (p: "cp security/${baseNameOf p} $out/") policies}
    runHook postInstall
  '';

  passthru = {
    inherit
      defconfig
      configFragments
      policies
      publicKeys
      ;
    dummyFirmware = firmware == null;
  };

  inherit normalizePoliciesOnly;

  meta = {
    description = "barebox bootloader (${pname})";
    homepage = "https://barebox.org";
    license = lib.licenses.gpl2Only;
  };
}
