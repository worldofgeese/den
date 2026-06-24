(use-modules (gnu home)
             (gnu packages)
             (gnu packages emacs-xyz)
             (gnu packages gnupg)
             (gnu services)
             (guix gexp)
             (gnu home services)
             (gnu home services fontutils)
             (gnu home services gnupg)
             (gnu home services desktop)
             (gnu home services mpv)
             (gnu home services xdg)
             (gnu home services containers)
             (gnu home services shepherd)
             (gnu services containers)
             (rde features)
             (rde features linux)
             (gnu home services shells))

(define my-rde-services
  (home-environment-user-services
   (rde-config-home-environment
    (rde-config
     (features
      (list (feature-pipewire)))))))

(home-environment
 (packages (append
            (specifications->packages
             (list "git"
                  "fd"
                  "openssh"
                  ;; Gas City dependencies
                  "tmux"
                  "lsof"
                  ;; direnv managed by Nix Home Manager with shell integration
                  "openssl"
                  "curl"
                  "racket"
                  "flatpak"
                  "xdg-utils"
                  "ncurses"
                  "gnome-tweaks"
                  "ripgrep"
                   ;; tools for gooseandquill.blog
                   "tidy-html"
                   "make"
                   "python"
                   ;; end tools for gooseandquill.blog
                   "emacs-all-the-icons"
                   "steam"
                   "vlc"
                     "font-jetbrains-mono"
                   "font-inter"
                   "font-google-noto" ;; display symbols normally in Doom Emacs
                   "font-noto-emoji"  ;; color emoji
                   "font-nerd-symbols" ;; icon glyphs for Doom Emacs nerd-icons
                  ;; podman provided by Guix System rootless-podman-service
                  ;; kind and helm consolidated to Nix HM workstation aspect
                  "pinentry-gnome3"
                  "rsync"
                  ;; tools for EXWM
                  "gtk+:bin" ;; provides gtk-launch required for counsel-linux-app
                  "brightnessctl"
                  "scrot"
                  "pasystray"
                  "dunst"
                  "network-manager-applet"
                  "emacs-pulseaudio-control"
                  "emacs-windower"
                  "emacs-ace-window"
                  "emacs-vterm"
                  "cmake"
                  "libtool"
                  "libvterm"
                  "gcc-toolchain"
                  "pavucontrol" ;; provides pactl for pulseaudio-control
                  "playerctl"
                  "blueman"
                  "redshift"
                  "lxqt-powermanagement"
                  "emacs-pdf-tools" ;; for pdf-tools
                  "ispell"   ;; for flyspell
                  "graphviz" ;; for org-roam
                  ;; tools for Guix hacking
                  "guile-picture-language"
                  "pandoc"
                  "xeyes"
                  "glib:bin"
                  "ffmpeg"
                  "exercism"
                  ;; git-annex removed: ghc-feed (haskell dep) broken by xml-conduit update in guix
                  ;; helm-kubernetes consolidated to Nix HM workstation aspect
                  "qbittorrent"
                  "distrobox"
		  "qutebrowser"
		  "dino"
                  "mosh"
                  "poppler"
                  "imagemagick"
                  "tesseract-ocr"
                  ;; Desktop apps (substitutes available from Bordeaux)
                  "telegram-desktop"
                  ;; Provides org.kde.StatusNotifierWatcher so Qt tray apps
                  ;; (Telegram, Synology Drive) actually appear in the GNOME
                  ;; top bar. Without it Telegram launches but its window
                  ;; goes straight to a non-existent tray and is invisible.
                  ;; After install: gnome-extensions enable
                  ;;   appindicatorsupport@rgcjonas.gmail.com
                  ;; then log out / log back in.
                  "gnome-shell-extension-appindicator"
                  "yt-dlp"))
            (list emacs-guix)))


 (services
  (append
   my-rde-services
   (list
    (service home-dbus-service-type)
    (service home-bash-service-type
             (home-bash-configuration
              (bashrc
               (list (local-file "bashrc")
                     (local-file "vterm-bash.sh")))))
     (simple-service
      'ssh-permissions-service
      home-activation-service-type
      #~(begin
          (use-modules (ice-9 ftw))
          (define (chmod-regular-files directory)
            (for-each
             (lambda (entry)
               (unless (member entry '("." ".."))
                 (let ((file (string-append directory "/" entry)))
                   (cond
                    ((symbolic-link? file) #t)
                    ((file-is-directory? file) (chmod-regular-files file))
                    (else (chmod file #o600))))))
             (scandir directory)))
          (let ((ssh-dir (string-append (getenv "HOME") "/.ssh")))
            (when (not (file-exists? ssh-dir))
              (mkdir ssh-dir))
            (chmod ssh-dir #o700)
            (chmod-regular-files ssh-dir))))
     (simple-service
      'nix-github-token-service
      home-activation-service-type
      #~(system*
         "sh"
         "-c"
         "set -eu
secret=dev/github-token
target=\"$HOME/.config/nix/github-access-token.conf\"

if ! command -v gopass >/dev/null 2>&1; then
  exit 0
fi

token=\"$(gopass show -o \"$secret\" 2>/dev/null || true)\"
if [ -z \"$token\" ]; then
  exit 0
fi

install -d -m 700 \"$(dirname \"$target\")\"
tmp=\"$(mktemp \"${target}.XXXXXX\")\"
chmod 600 \"$tmp\"
printf 'access-tokens = github.com=%s\n' \"$token\" > \"$tmp\"
mv \"$tmp\" \"$target\""))
     (service home-gpg-agent-service-type
              (home-gpg-agent-configuration
              (ssh-support? #t)
              (default-cache-ttl 60480000)
              (default-cache-ttl-ssh 60480000)
              (max-cache-ttl 60480000)
              (max-cache-ttl-ssh 60480000)
              (pinentry-program
               (file-append pinentry-gnome3 "/bin/pinentry-gnome3"))))

    (simple-service 'custom-profile
                    home-shell-profile-service-type
                    (list (plain-file "profile"
                                      (string-append
                                       "[ -r ~/.nix-profile/etc/profile.d/nix.sh ] && source ~/.nix-profile/etc/profile.d/nix.sh\n"
                                       "# Distrobox: override Guix env vars that break container tooling\n"
                                       "if [ -f /run/.containerenv ]; then\n"
                                       "  export GIT_EXEC_PATH=/usr/lib/git-core\n"
                                       "  export GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt\n"
                                       "  export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt\n"
                                       "  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"\n"
                                       "fi"))))

    (simple-service 'autostart-config
                    home-xdg-configuration-files-service-type
                    (list `("autostart/gnome-keyring-ssh.desktop"
                            ,(plain-file "gnome-keyring-ssh.desktop"
                                         "[Desktop Entry]\nType=Application\nName=SSH Key Agent\nX-GNOME-Autostart-enabled=false\n"))
                          `("autostart/com.quexten.Goldwarden.desktop"
                            ,(plain-file "goldwarden-autostart.desktop"
                                         "[Desktop Entry]\nType=Application\nName=com.quexten.Goldwarden\nExec=flatpak run --command=goldwarden_ui_main.py com.quexten.Goldwarden --hidden\nX-Flatpak=com.quexten.Goldwarden\n"))))

    (simple-service 'containers-config
                    home-xdg-configuration-files-service-type
                    (list `("containers/storage.conf"
                            ,(plain-file "containers-storage.conf"
                                         "[storage]\ndriver = \"overlay\"\n"))))

    ;; Headroom token-efficiency proxy (rootless Podman via system profile)
    (service home-oci-service-type
             (for-home
              (oci-configuration
               (runtime 'podman)
               (runtime-cli "/run/current-system/profile/bin/podman"))))
    (simple-service 'headroom-proxy
                    home-oci-service-type
                    (oci-extension
                     (volumes
                      (list
                       (oci-volume-configuration (name "headroom-data"))))
                     (containers
                      (list
                       (oci-container-configuration
                        (provision "headroom")
                        (image "ghcr.io/chopratejas/headroom:latest")
                        (ports '("127.0.0.1:8787:8787"))
                        (volumes '(("headroom-data" . "/data")))
                        (environment
                         (list
                          "HEADROOM_HOST=0.0.0.0"
                          "HEADROOM_DEFAULT_MODE=optimize"
                          "HEADROOM_STORE_URL=sqlite:////data/headroom.db"
                          "HEADROOM_SAVINGS_PATH=/data/proxy_savings.json"
                          "HEADROOM_TELEMETRY=off"
                          "ANTHROPIC_TARGET_API_URL=https://models.assistant.legogroup.io/claude"))
                        (command
                         '("--host" "0.0.0.0"
                           "--port" "8787"
                           "--memory"
                           "--learn"
                           "--code-graph"))
                        (extra-arguments '("--pull" "always"))
                        (respawn? #t)
                        (auto-start? #t)
                        (log-file
                         (string-append (getenv "HOME")
                                        "/.local/state/headroom.log")))))))

    ;; Signet memory daemon (Nix bun + Nix profile libstdc++ for ONNX)
    (simple-service
     'signet-daemon
     home-shepherd-service-type
     (list
      (shepherd-service
       (provision '(signet))
       (documentation "Signet cross-session memory daemon")
       (start #~(make-forkexec-constructor
                 (list (string-append (getenv "HOME") "/.nix-profile/bin/bun")
                       (string-append (getenv "HOME")
                                      "/.local/lib/node_modules/signetai/dist/daemon.js"))
                 #:environment-variables
                 (append (default-environment-variables)
                         (list (string-append "LD_LIBRARY_PATH="
                                              (getenv "HOME") "/.nix-profile/lib")))
                 #:log-file (string-append (getenv "HOME")
                                           "/.local/state/signet.log")))
       (stop #~(make-kill-destructor))
       (respawn? #t)
       (auto-start? #t))))

    ;; Guix channels — single source of truth in this repo
    (simple-service 'guix-channels
                    home-xdg-configuration-files-service-type
                    (list `("guix/channels.scm"
                            ,(local-file "channels.scm"))))

    (service home-xdg-user-directories-service-type
             (home-xdg-user-directories-configuration
              (desktop "$HOME/Desktop")
              (download "$HOME/Downloads")
              (templates "$HOME/Templates")
              (publicshare "$HOME/Public")
              (documents "$HOME/Documents")
              (music "$HOME/Music")
              (pictures "$HOME/Pictures")
              (videos "$HOME/Videos")))

     ;; Substituters and keys are in system.scm (nix-service-type extra-config).
     ;; experimental-features must also be in user nix.conf for unprivileged nix commands.
     ;; GitHub API tokens are materialized from gopass during activation, then
     ;; included from a mode-0600 fragment so the secret never enters the store.
     (simple-service 'nix-config
                     home-xdg-configuration-files-service-type
                     (list `("nix/nix.conf"
                             ,(plain-file "nix.conf"
                                          "experimental-features = nix-command flakes
download-buffer-size = 536870912
!include /home/worldofgeese/.config/nix/github-access-token.conf
"))))

    (service home-xdg-mime-applications-service-type
             (home-xdg-mime-applications-configuration
              (default
               '((x-scheme-handler/http . app.zen_browser.zen.desktop)
                 (x-scheme-handler/https . app.zen_browser.zen.desktop)
                 (x-scheme-handler/about . app.zen_browser.zen.desktop)
                  (x-scheme-handler/unknown . app.zen_browser.zen.desktop)
                  (text/html . app.zen_browser.zen.desktop)
                  (application/xhtml+xml . app.zen_browser.zen.desktop)
                  (devpod . DevPod-handler.desktop)
                  (video/quicktime . org.videolan.VLC.desktop)
                  (image/jpeg . org.gnome.Loupe.desktop)
                  (image/png . org.gnome.Loupe.desktop)
                  (image/gif . org.gnome.Loupe.desktop)
                  (image/webp . org.gnome.Loupe.desktop)
                  (image/tiff . org.gnome.Loupe.desktop)
                  (image/x-tga . org.gnome.Loupe.desktop)
                  (image/vnd-ms.dds . org.gnome.Loupe.desktop)
                  (image/x-dds . org.gnome.Loupe.desktop)
                  (image/bmp . org.gnome.Loupe.desktop)
                  (image/vnd.microsoft.icon . org.gnome.Loupe.desktop)
                  (image/vnd.radiance . org.gnome.Loupe.desktop)
                  (image/x-exr . org.gnome.Loupe.desktop)
                  (image/x-portable-bitmap . org.gnome.Loupe.desktop)
                  (image/x-portable-graymap . org.gnome.Loupe.desktop)
                  (image/x-portable-pixmap . org.gnome.Loupe.desktop)
                  (image/x-portable-anymap . org.gnome.Loupe.desktop)
                  (image/x-qoi . org.gnome.Loupe.desktop)
                  (image/qoi . org.gnome.Loupe.desktop)
                  (image/svg+xml . org.gnome.Loupe.desktop)
                  (image/svg+xml-compressed . org.gnome.Loupe.desktop)
                  (image/avif . org.gnome.Loupe.desktop)
                  (image/heic . org.gnome.Loupe.desktop)
                  (image/jxl . org.gnome.Loupe.desktop)))
               (added
                '((text/plain . drracket.desktop)
                  (video/x-msvideo . io.github.celluloid_player.Celluloid.desktop)
                  (video/mp4 . org.videolan.VLC.desktop)
                  (text/markdown . org.gnome.TextEditor.desktop)
                  (image/png . org.gnome.Loupe.desktop)
                  (image/jpeg . org.gnome.Loupe.desktop)
                  (video/x-matroska . mpv.desktop)
                  (video/quicktime . org.videolan.VLC.desktop)))))

    (service home-mpv-service-type
             (make-home-mpv-configuration
              #:extra-config
              (string-append
               "profile=gpu-hq\n"
               "gpu-api=vulkan\n"
               "hwdec=vaapi\n"
               "force-window=yes\n"
               "ytdl-format=bestvideo+bestaudio\n")))

    (simple-service 'extended-fontconfig
                    home-fontconfig-service-type
                    (list
                     ;; Additional font directories
                     "~/.nix-profile/share/fonts"
                     "~/.local/share/fonts"

                     ;; Include system fontconfig conf.d for base rendering rules
                     '(include "/run/current-system/profile/etc/fonts/conf.d")

                     ;; Cache directories
                     '(cachedir "~/.cache/fontconfig")
                     '(cachedir "/var/cache/fontconfig")

                     ;; === Rendering settings (ArchWiki "Hinted fonts" consensus) ===
                     ;; Enable antialiasing
                     '(match (@ (target "font"))
                             (edit (@ (mode "assign") (name "antialias"))
                                   (bool "true")))
                     ;; Disable embedded bitmaps (prevents pixelated fallbacks)
                     '(match (@ (target "font"))
                             (edit (@ (mode "assign") (name "embeddedbitmap"))
                                   (bool "false")))
                     ;; Enable hinting
                     '(match (@ (target "font"))
                             (edit (@ (mode "assign") (name "hinting"))
                                   (bool "true")))
                     ;; Slight hinting (best balance of shape retention vs crispness)
                     '(match (@ (target "font"))
                             (edit (@ (mode "assign") (name "hintstyle"))
                                   (const "hintslight")))
                     ;; LCD filter for subpixel rendering
                     '(match (@ (target "font"))
                             (edit (@ (mode "assign") (name "lcdfilter"))
                                   (const "lcddefault")))
                     ;; Subpixel layout (RGB is most common)
                     '(match (@ (target "font"))
                             (edit (@ (mode "assign") (name "rgba"))
                                   (const "rgb")))

                     ;; === Re-enable embedded bitmaps for emoji ===
                     '(match (@ (target "font"))
                             (test (@ (qual "any") (name "family"))
                                   (string "Noto Emoji"))
                             (edit (@ (name "embeddedbitmap"))
                                   (bool "true")))

                     ;; === Hard-assign generic families (Omarchy style) ===
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "sans-serif"))
                             (edit (@ (name "family") (mode "assign") (binding "strong"))
                                   (string "Inter Variable")))
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "serif"))
                             (edit (@ (name "family") (mode "assign") (binding "strong"))
                                   (string "Noto Serif")))
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "monospace"))
                             (edit (@ (name "family") (mode "assign") (binding "strong"))
                                   (string "JetBrains Mono")))

                     ;; === Map web/CSS font names to local equivalents ===
                     '(alias
                       (family "system-ui")
                       (prefer (family "Inter Variable")))
                     '(alias
                       (family "ui-monospace")
                       (default (family "monospace")))
                     '(alias
                       (family "-apple-system")
                       (prefer (family "Inter Variable")))
                     '(alias
                       (family "BlinkMacSystemFont")
                       (prefer (family "Inter Variable")))

                     ;; === Emoji fallback for all generic families ===
                     '(alias
                       (family "sans-serif")
                       (accept (family "Noto Emoji")))
                     '(alias
                       (family "serif")
                       (accept (family "Noto Emoji")))
                     '(alias
                       (family "monospace")
                       (accept (family "Noto Emoji")))

                     ;; === Alias fixups (common misspellings) ===
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "mono"))
                             (edit (@ (name "family") (mode "assign") (binding "same"))
                                   (string "monospace")))
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "sans serif"))
                             (edit (@ (name "family") (mode "assign") (binding "same"))
                                   (string "sans-serif")))
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "sans"))
                             (edit (@ (name "family") (mode "assign") (binding "same"))
                                   (string "sans-serif")))
                     '(match (@ (target "pattern"))
                             (test (@ (qual "any") (name "family"))
                                   (string "system ui"))
                             (edit (@ (name "family") (mode "assign") (binding "same"))
                                   (string "system-ui")))))

    (simple-service 'additional-env-vars-service
                    home-environment-variables-service-type
                    `(                      ("PATH" . "$HOME/.nix-profile/bin:$HOME/.local/bin:$HOME/.config/emacs/bin:$HOME/.krew/bin:$PATH")
                      ("XDG_DATA_DIRS" . "$XDG_DATA_DIRS:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share:$HOME/.nix-profile/share:$HOME/.local/share/fonts")
                      ("FONTCONFIG_FILE" . "$HOME/.config/fontconfig/fonts.conf")
                      ;; Fix blurry small text in Chromium/Electron apps on dark backgrounds
                      ("FREETYPE_PROPERTIES" . "cff:no-stem-darkening=0 autofitter:no-stem-darkening=0")
                      ("VISUAL" . "emacsclient")
                      ("BROWSER" . "flatpak run app.zen_browser.zen")
                      ("_JAVA_AWT_WM_NONREPARENTING" . "1")
                      ("MOZ_USE_XINPUT2" . "1")
                      ("npm_config_prefix" . "$HOME/.local")
                      ("EDITOR" . "emacsclient")
                      ;; Force Qt apps to use native Wayland — fixes Telegram EGL mismatch
                      ("QT_QPA_PLATFORM" . "wayland")))))))
