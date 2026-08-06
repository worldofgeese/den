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
      # agent-shell uses headroom's loopback URL so prior turns get prefix-cached.
      # Darwin uses M-02877's published loopback port; Linux uses mahakala's.
      # Both addresses come from gateway.json.
      gatewayBaseUrl = gateway.headroom.loopbackUrl (
        if pkgs.stdenv.isDarwin
        then "M-02877"
        else "mahakala"
      );
      # Printed on stdout and resolved when an agent process starts.
      gatewayKeyCommand = gateway.keyCommand config.home.homeDirectory;
      # Claude Code model ids published by LEGO AI Model Gateway.
      slots = {
        opus = "eu.anthropic.claude-opus-5";
        sonnet = "eu.anthropic.claude-sonnet-5";
        haiku = "eu.anthropic.claude-haiku-4-5-20251001-v1:0";
      };
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
            --replace-fail '@GATEWAY_KEY_COMMAND@' ${lib.escapeShellArg gatewayKeyCommand} \
            --replace-fail '@GATEWAY_OPUS_MODEL@' ${lib.escapeShellArg slots.opus} \
            --replace-fail '@GATEWAY_SONNET_MODEL@' ${lib.escapeShellArg slots.sonnet} \
            --replace-fail '@GATEWAY_HAIKU_MODEL@' ${lib.escapeShellArg slots.haiku}
        '';
        # Doom packages are built with matching Emacs 30 ABIs. On Darwin the
        # installed launcher below uses Homebrew Emacs Plus at runtime.
        emacs =
          if pkgs.stdenv.isDarwin
          then pkgs.emacs30
          else pkgs.emacs30-pgtk;
        provideEmacs = false;
        extraBinPackages =
          (with pkgs; [
            ripgrep
            fd
            gnupg
            unzip
          ])
          ++ lib.optionals pkgs.stdenv.isLinux [pkgs.pinentry-gnome3];
        emacsPackageOverrides = eself: esuper: let
          addAgentShellDep = pkg:
            pkg.overrideAttrs (old: {
              packageRequires = (old.packageRequires or []) ++ [eself.agent-shell];
            });
          mkTrampRpcServer = crossPkgs:
            (crossPkgs.callPackage "${inputs.emacs-tramp-rpc}/default.nix" {}).overrideAttrs {
              doCheck = false;
            };
          # These target binaries are cross-compiled for deployment to Linux.
          # Their tests spawn target `python3`, `/bin/sh`, and PTYs, which are
          # unavailable while cross-building (and under Darwin's sandbox).
          tramp-rpc-server = mkTrampRpcServer pkgs.pkgsCross.musl64;
          tramp-rpc-server-aarch64 = mkTrampRpcServer pkgs.pkgsCross.aarch64-multiplatform-musl;
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
            postPatch = lib.optionalString pkgs.stdenv.isDarwin ''
              substituteInPlace Makefile \
                --replace-fail 'else ifeq ($(OS_NAME),Darwin)' 'else ifeq ($(OS_NAME),DisabledDarwinBranch)'
            '';
            files = ''(:defaults "render-core.so")'';
            nativeBuildInputs = [pkgs.pkg-config pkgs.gnumake];
            buildInputs = [pkgs.mupdf];
            preBuild =
              ''
                make clean all USE_PKGCONFIG=yes CC=cc
              ''
              + lib.optionalString pkgs.stdenv.isDarwin ''
                cp render-core.dylib render-core.so
              '';
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

      home.file = lib.mkIf pkgs.stdenv.isLinux {
        # Override Guix system's emacs.desktop so GNOME launches our wrapper.
        ".local/share/applications/emacs.desktop".text = ''
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
      };

      home.packages = let
        emacsPkg = config.programs.doom-emacs.finalEmacsPackage;
        emacsFontconfig = pkgs.writeText "emacs-fonts.conf" ''
          <?xml version="1.0"?>
          <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
          <fontconfig>
            <dir>${pkgs.noto-fonts}/share/fonts/noto</dir>
            <dir>${pkgs.nerd-fonts.fira-code}/share/fonts</dir>
            <dir>${pkgs.nerd-fonts.symbols-only}/share/fonts</dir>
            <include ignore_missing="yes">${config.home.homeDirectory}/.config/fontconfig/fonts.conf</include>
            <cachedir prefix="xdg">fontconfig</cachedir>
          </fontconfig>
        '';
      in [
        (pkgs.runCommand "doom-emacs-wrapped" {
            nativeBuildInputs = lib.optionals pkgs.stdenv.isLinux [pkgs.makeBinaryWrapper];
          } ''
            mkdir -p $out/bin $out/share
            ${
              if pkgs.stdenv.isDarwin
              then ''
                cat >$out/bin/emacs <<'EOF'
                #!${pkgs.runtimeShell}
                unset EMACSLOADPATH
                export DOOMPROFILELOADFILE="${emacsPkg.doomEmacs.doomProfile}/loader/init"
                export DOOMPROFILE="nix"
                export DOOMDIR="${emacsPkg.doomEmacs.doomProfile}/doomdir"
                export DOOMLOCALDIR="${emacsPkg.doomEmacs.doomLocalDir}"
                exec ${config.home.homeDirectory}/Applications/Emacs.app/Contents/MacOS/Emacs --init-directory="${emacsPkg.doomEmacs.doomSource}" "$@"
                EOF
                cat >$out/bin/emacsclient <<'EOF'
                #!${pkgs.runtimeShell}
                unset EMACSLOADPATH
                exec ${config.home.homeDirectory}/Applications/Emacs.app/Contents/MacOS/bin/emacsclient "$@"
                EOF
                chmod +x $out/bin/emacs $out/bin/emacsclient
                mkdir -p "$out/Applications/Doom Emacs.app/Contents/MacOS"
                cat >"$out/Applications/Doom Emacs.app/Contents/Info.plist" <<'EOF'
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                  <key>CFBundleExecutable</key><string>Doom Emacs</string>
                  <key>CFBundleIdentifier</key><string>org.worldofgeese.doom-emacs</string>
                  <key>CFBundleName</key><string>Doom Emacs</string>
                  <key>CFBundlePackageType</key><string>APPL</string>
                  <key>CFBundleVersion</key><string>1</string>
                </dict>
                </plist>
                EOF
                ln -s ../../../../bin/emacs "$out/Applications/Doom Emacs.app/Contents/MacOS/Doom Emacs"
              ''
              else ''
                makeBinaryWrapper "${emacsPkg}/bin/emacs" "$out/bin/emacs" \
                  --unset EMACSLOADPATH \
                  --set FONTCONFIG_FILE "${emacsFontconfig}"
                makeBinaryWrapper "${emacsPkg}/bin/emacsclient" "$out/bin/emacsclient" \
                  --unset EMACSLOADPATH \
                  --set FONTCONFIG_FILE "${emacsFontconfig}"
              ''
            }
            for f in ${emacsPkg}/share/*; do
              ln -s "$f" "$out/share/$(basename "$f")"
            done
          '')
      ];
    };
  };
}
