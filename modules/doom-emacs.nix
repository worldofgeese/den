{
  den,
  gateway,
  inputs,
  ...
}: {
  den.aspects.doom-emacs = {
    homeManager = {
      pkgs,
      config,
      lib,
      ...
    }: let
      # agent-shell talks to headroom on the loopback interface, not to the
      # gateway directly, so prior turns get frozen for the prefix cache. This
      # aspect only ships to mahakala (modules/mahakala.nix:3), which is why
      # mahakala's published port is the one read here; on M-02877 the same
      # logical port is published as 18787. Both are in gateway.json.
      gatewayBaseUrl = gateway.headroom.loopbackUrl "mahakala";
      # Printed on stdout, resolved when an agent process starts -- the same
      # command pi embeds in models.json, from the same owner.
      gatewayKeyCommand = gateway.keyCommand config.home.homeDirectory;
    in {
      imports = [inputs.nix-doom-emacs-unstraightened.homeModule];

      programs.doom-emacs = {
        enable = true;
        # doom.d is not copied verbatim: the agent-shell module needs the model
        # gateway's address and a key-lookup command, and neither may be a
        # literal in tracked elisp. --replace-fail makes a renamed or dropped
        # placeholder a build error instead of a silent miss.
        doomDir = pkgs.runCommandLocal "doom-dir" {} ''
          cp -r ${./doom.d} $out
          chmod -R u+w $out
          substituteInPlace $out/modules/tools/agent-shell/config.el \
            --replace-fail '@GATEWAY_BASE_URL@' ${lib.escapeShellArg gatewayBaseUrl} \
            --replace-fail '@GATEWAY_KEY_COMMAND@' ${lib.escapeShellArg gatewayKeyCommand}
        '';
        emacs = pkgs.emacs30-pgtk;
        provideEmacs = false;
        extraBinPackages = with pkgs; [
          ripgrep
          fd
          gnupg
          pinentry-gnome3
          unzip
        ];
        emacsPackageOverrides = eself: esuper: let
          addAgentShellDep = pkg:
            pkg.overrideAttrs (old: {
              packageRequires = (old.packageRequires or []) ++ [eself.agent-shell];
            });
          tramp-rpc-server = pkgs.pkgsCross.musl64.callPackage "${inputs.emacs-tramp-rpc}/default.nix" {};
          tramp-rpc-server-aarch64 = pkgs.pkgsCross.aarch64-multiplatform-musl.callPackage "${inputs.emacs-tramp-rpc}/default.nix" {};
          emacs-reader-src = pkgs.fetchFromGitea {
            domain = "codeberg.org";
            owner = "MonadicSheep";
            repo = "emacs-reader";
            rev = "0.3.2";
            hash = "sha256-rZ+1PgRS68QN0yXdYyEJafJmbCceaKeDQhT+GfsPiFA=";
          };
        in {
          tramp-rpc = eself.melpaBuild rec {
            pname = "tramp-rpc";
            version = "0.9.0";
            src = inputs.emacs-tramp-rpc;
            files = ''("lisp/*")'';
            postInstall = ''
              install -m755 -D ${tramp-rpc-server}/bin/tramp-rpc-server $out/share/emacs/site-lisp/elpa/${pname}-${version}/binaries/x86_64-linux/tramp-rpc-server
              install -m755 -D ${tramp-rpc-server-aarch64}/bin/tramp-rpc-server $out/share/emacs/site-lisp/elpa/${pname}-${version}/binaries/aarch64-linux/tramp-rpc-server
            '';
            packageRequires = [eself.tramp eself.msgpack];
          };
          reader = eself.melpaBuild {
            pname = "emacs-reader";
            ename = "reader";
            version = "0.3.2";
            src = emacs-reader-src;
            files = ''(:defaults "render-core.so")'';
            nativeBuildInputs = [pkgs.pkg-config pkgs.gcc pkgs.gnumake];
            buildInputs = [pkgs.mupdf];
            preBuild = "make clean all";
          };
          agent-shell-manager = addAgentShellDep esuper.agent-shell-manager;
          agent-shell-sidebar = addAgentShellDep esuper.agent-shell-sidebar;
          agent-shell-bookmark = addAgentShellDep esuper.agent-shell-bookmark;
          agent-shell-notifications = (addAgentShellDep esuper.agent-shell-notifications).overrideAttrs (old: {
            postPatch =
              (old.postPatch or "")
              + ''
                rm -f agent-shell-notifications-knockknock.el
              '';
          });
          agent-shell-org-transcript = addAgentShellDep esuper.agent-shell-org-transcript;
          ob-agent-shell = addAgentShellDep esuper.ob-agent-shell;
          agent-recall = addAgentShellDep esuper.agent-recall;
          agent-review = esuper.agent-review.overrideAttrs (old: {
            packageRequires = (old.packageRequires or []) ++ [eself.agent-shell eself.acp];
          });
          meta-agent-shell = esuper.meta-agent-shell.overrideAttrs (old: {
            packageRequires = (old.packageRequires or []) ++ [eself.agent-shell eself.shell-maker];
          });
        };
      };

      # Override Guix system's emacs.desktop so GNOME launches our wrapper
      home.file.".local/share/applications/emacs.desktop".text = ''
        [Desktop Entry]
        Name=Emacs
        GenericName=Text Editor
        Comment=Edit text
        MimeType=text/english;text/plain;text/x-makefile;text/x-c++hdr;text/x-c++src;text/x-chdr;text/x-csrc;text/x-java;text/x-moc;text/x-pascal;text/x-tcl;text/x-tex;application/x-shellscript;text/x-c;text/x-c++;
        Exec=emacs %F
        Icon=emacs
        Type=Application
        Terminal=false
        Categories=Development;TextEditor;
        StartupNotify=true
        StartupWMClass=Emacs
      '';

      home.packages = let
        emacsPkg = config.programs.doom-emacs.finalEmacsPackage;
        # Nix freetype can't open Guix's bracket-named variable fonts
        # (NotoSans[wdth,wght].ttf), so list Nix font packages first.
        emacsFontconfig = pkgs.writeText "emacs-fonts.conf" ''
          <?xml version="1.0"?>
          <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
          <fontconfig>
            <dir>${pkgs.noto-fonts}/share/fonts/noto</dir>
            <dir>${pkgs.nerd-fonts.fira-code}/share/fonts</dir>
            <dir>${pkgs.nerd-fonts.symbols-only}/share/fonts</dir>
            <include ignore_missing="yes">/home/worldofgeese/.config/fontconfig/fonts.conf</include>
            <cachedir prefix="xdg">fontconfig</cachedir>
          </fontconfig>
        '';
      in [
        (pkgs.runCommand "doom-emacs-wrapped" {
            nativeBuildInputs = [pkgs.makeBinaryWrapper];
          } ''
            mkdir -p $out/bin $out/share
            makeBinaryWrapper "${emacsPkg}/bin/emacs" "$out/bin/emacs" \
              --unset EMACSLOADPATH \
              --set FONTCONFIG_FILE "${emacsFontconfig}"
            makeBinaryWrapper "${emacsPkg}/bin/emacsclient" "$out/bin/emacsclient" \
              --unset EMACSLOADPATH \
              --set FONTCONFIG_FILE "${emacsFontconfig}"
            for f in ${emacsPkg}/share/*; do
              ln -s "$f" "$out/share/$(basename "$f")"
            done
          '')
      ];
    };
  };
}
