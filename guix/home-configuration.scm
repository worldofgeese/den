(use-modules (gnu home)
             (gnu packages)
             (gnu packages gnupg)
             (gnu services)
             (guix gexp)
             (gnu home services)
             (gnu home services fontutils)
             (gnu home services gnupg)
             (gnu home services desktop)
             (gnu home services mpv)
             (gnu home services xdg)
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
 (packages (specifications->packages
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
                  "texlive-scheme-basic"
                  "make"
                  "python"
                  ;; end tools for gooseandquill.blog
                  "emacs-guix"
                  "emacs-all-the-icons"
                  "steam"
                  "neovim"
                   "font-jetbrains-mono"
                   "font-inter"
                   "font-google-noto" ;; display symbols normally in Doom Emacs
                   "font-noto-emoji"  ;; color emoji
                   "font-nerd-symbols" ;; icon glyphs for Doom Emacs nerd-icons
                  "podman"
                  "kind"
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
                  "git-annex"
                  "helm-kubernetes"
                  "qbittorrent"
                  "distrobox"
		  "qutebrowser"
		  "dino"
                  "mosh"
                  "poppler"
                  "imagemagick"
                  "tesseract-ocr"
                  "ungoogled-chromium"
                  )))


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
     (with-imported-modules '((guix build utils))
       #~(begin
           (use-modules (guix build utils))
           (let ((ssh-dir (string-append (getenv "HOME") "/.ssh")))
             (when (not (file-exists? ssh-dir))
               (mkdir-p ssh-dir))
             (chmod ssh-dir #o700)
             (for-each (lambda (file)
                         (unless (symbolic-link? file)
                           (chmod file #o600)))
                       (find-files ssh-dir #:directories? #f))))))
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
                                       "[ -f ~/.nix-profile/etc/profile.d/nix.sh ] && source ~/.nix-profile/etc/profile.d/nix.sh\n"
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

    (simple-service 'nix-config
                    home-xdg-configuration-files-service-type
                    (list `("nix/nix.conf"
                            ,(plain-file "nix.conf"
                                         (string-append
                                          "extra-trusted-substituters = https://cache.floxdev.com https://devenv.cachix.org https://nixpkgs-python.cachix.org\n"
                                          "extra-trusted-public-keys = flox-store-public-0:8c/B+kjIaQ+BloCmNkRUKwaVPFWkriSAd0JJvuDu4F0= devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= nixpkgs-python.cachix.org-1:hxjI7pFxTyuTHn2NkvWCrAUcNZLNS3ZAvfYNuYifcEU=\n"
                                          "experimental-features = nix-command flakes")))))

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
                 (video/quicktime . org.videolan.VLC.desktop)))
              (added
               '((text/plain . drracket.desktop)
                 (video/x-msvideo . io.github.celluloid_player.Celluloid.desktop)
                 (video/mp4 . org.videolan.VLC.desktop)
                 (text/markdown . org.gnome.TextEditor.desktop)
                 (image/png . org.gnome.eog.desktop)
                 (image/jpeg . org.gnome.eog.desktop)
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
                      ("XDG_DATA_DIRS" . "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share:$HOME/.nix-profile/share:$HOME/.local/share/fonts")
                      ("FONTCONFIG_FILE" . "$HOME/.config/fontconfig/fonts.conf")
                      ;; Fix blurry small text in Chromium/Electron apps on dark backgrounds
                      ("FREETYPE_PROPERTIES" . "cff:no-stem-darkening=0 autofitter:no-stem-darkening=0")
                      ("VISUAL" . "emacsclient")
                      ("BROWSER" . "flatpak run app.zen_browser.zen")
                      ("_JAVA_AWT_WM_NONREPARENTING" . "1")
                      ("MOZ_USE_XINPUT2" . "1")
                      ("npm_config_prefix" . "$HOME/.local")
                      ("EDITOR" . "emacsclient")))))))
