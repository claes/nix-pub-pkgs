{
  lib,
  fetchFromGitHub,
  python3,
  iproute2,
  wireguard-tools,
}:
python3.pkgs.buildPythonApplication rec {
  pname = "wg-netns";
  version = "";
  format = "pyproject";

  src = fetchFromGitHub {
    owner = "dadevel";
    repo = "wg-netns";
    rev = "41665ca136007de5c378703f978085eecde56db0";
    hash = "sha256-SOTOHAz94sOHw7yKuqAYqwp0GfYW11Vk6ndQn9C+CvA=";
  };

  nativeBuildInputs = with python3.pkgs; [
    poetry-core
  ];

  propagatedBuildInputs = with python3.pkgs; [
    pyyaml
  ];

  postInstall = ''
    install -m 600 -D extras/wg-netns@.service $out/lib/systemd/system/wg-netns@.service
    substituteInPlace $out/lib/systemd/system/wg-netns@.service \
      --replace "ExecStart=wg-netns" "ExecStart=$out/bin/wg-netns"
    substituteInPlace $out/lib/systemd/system/wg-netns@.service \
      --replace "ExecStop=wg-netns" "ExecStop=$out/bin/wg-netns"

    # TODO wg-resolve
  '';

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      iproute2
      wireguard-tools
    ])
  ];

  meta = with lib; {
    description = "WireGuard with Linux Network Namespaces";
    homepage = "https://github.com/dadevel/wg-netns";
    license = with licenses; [ mit ];
    maintainers = with maintainers; [ claes ];
  };
}
