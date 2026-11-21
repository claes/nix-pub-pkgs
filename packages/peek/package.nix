{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  nasm,
  pdfium,
  zstd,
  oniguruma,
  sqlite,
}:

rustPlatform.buildRustPackage {
  pname = "peek";
  version = "1.0.4";

  src = fetchFromGitHub {
    owner = "thaapasa";
    repo = "peek";
    rev = "a405279c29e5c1b4d4914f87f86760cda72d1e30"; # v1.0.4
    hash = "sha256-Y4qaktUiXIzcOrnTs8lXqV/vBTJVpMyezCM3cMmzrxk=";
  };

  cargoHash = "sha256-Qfhktm7vds48+EnJxxbAMgQRnv2VJ4oc64kK0owK13A=";

  nativeBuildInputs = [ pkg-config ]
    ++ lib.optionals stdenv.hostPlatform.isx86_64 [ nasm ];
  buildInputs = [ pdfium zstd oniguruma sqlite ];

  doCheck = false;
  cargoBuildFlags = [ "--bin" "peek" ];

  postInstall = ''
    ln -s ${pdfium}/lib/libpdfium.so "$out/bin/libpdfium.so"
  '';

  meta = {
    description = "Modern terminal file viewer";
    homepage = "https://github.com/thaapasa/peek";
    license = lib.licenses.mit;
    mainProgram = "peek";
    platforms = [ "x86_64-linux" ];
  };
}
