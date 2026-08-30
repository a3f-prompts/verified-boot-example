# Raw GPT disk image with one partition per payload. barebox exposes GPT
# partition labels as /dev/<disk>.<label>, which is what the boot scripts
# use to find the images. All GUIDs are fixed so the image is reproducible.
{
  lib,
  stdenvNoCC,
  util-linux,

  name ? "disk",
  sizeMiB ? 64, # QEMU wants SD card images to be a power of two in size
  diskUuid,
  # list of { name; sizeMiB; uuid; image ? null; type ? "linux"; }
  # A partition without an "image" is left zeroed (barebox state, for
  # example, initializes its backend on first write).
  # "type" is an sfdisk partition type: a GPT type GUID or one of sfdisk's
  # aliases for one ("linux" is 0fc63daf-8483-4772-8e79-3d69d8477de4).
  partitions,
}:
let
  # Lay partitions out back to back starting at 1 MiB
  layout =
    (lib.foldl
      (
        acc: p:
        {
          next = acc.next + p.sizeMiB;
          parts = acc.parts ++ [ (p // { startMiB = acc.next; }) ];
        }
      )
      {
        next = 1;
        parts = [ ];
      }
      partitions
    ).parts;
  sectorsPerMiB = 2048;
in
assert lib.assertMsg (
  (lib.last layout).startMiB + (lib.last layout).sizeMiB <= sizeMiB - 1
) "partitions do not fit into the ${toString sizeMiB} MiB disk image";
stdenvNoCC.mkDerivation {
  pname = "${name}-image";
  version = "1";

  dontUnpack = true;
  nativeBuildInputs = [ util-linux ];

  buildPhase = ''
    runHook preBuild
    truncate -s ${toString sizeMiB}M ${name}.img
    sfdisk --no-tell-kernel ${name}.img <<SFDISK
    label: gpt
    label-id: ${diskUuid}
    unit: sectors
    first-lba: 2048
    ${lib.concatMapStringsSep "\n" (
      p:
      "start=${toString (p.startMiB * sectorsPerMiB)}, size=${toString (p.sizeMiB * sectorsPerMiB)}, "
      + "type=${p.type or "linux"}, name=${p.name}, uuid=${p.uuid}"
    ) layout}
    SFDISK
    ${lib.concatMapStringsSep "\n" (p: lib.optionalString (p.image or null != null) ''
      size=$(stat -c %s ${p.image})
      if [ "$size" -gt $((${toString p.sizeMiB} * 1024 * 1024)) ]; then
        echo "${p.image} ($size bytes) does not fit into partition ${p.name}" >&2
        exit 1
      fi
      dd if=${p.image} of=${name}.img bs=1M seek=${toString p.startMiB} conv=notrunc status=none
    '') layout}
    sfdisk --dump ${name}.img
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 ${name}.img $out/${name}.img
    runHook postInstall
  '';

  passthru = { inherit layout; };
}
