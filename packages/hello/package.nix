{ lib, stdenv, fetchurl }:

stdenv.mkDerivation (finalAttrs: {
  pname = "hello";
  version = "2.12.3";

  src = fetchurl {
    url = "mirror://gnu/hello/hello-${finalAttrs.version}.tar.gz";
    hash = "sha256-DV9gFUOC/uELEUocNOeF2LH0kgc64tOm97FHaHs2aqA=";
  };

  strictDeps = true;
  enableParallelBuilding = true;
  doCheck = true;

  postInstall = ''
    mkdir -p "$out/share/hello-custom"
    cat > "$out/share/hello-custom/build-info.txt" <<'BUILD_INFO'
    GNU Hello built by the custom nix-packages repository.
    BUILD_INFO
    chmod 0444 "$out/share/hello-custom/build-info.txt"
  '';

  meta = {
    description = "GNU Hello built by the custom package repository";
    homepage = "https://www.gnu.org/software/hello/";
    license = lib.licenses.gpl3Plus;
    mainProgram = "hello";
    platforms = [ "x86_64-linux" ];
  };
})
