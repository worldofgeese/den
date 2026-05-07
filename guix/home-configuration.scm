(use-modules (gnu home)
             (gnu packages)
             (gnu packages gnupg)
             (gnu services)
             (guix gexp)
             (gnu home services)
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
                  "font-google-noto" ;; display symbols normally in Doom Emacs
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
                         (chmod file #o600))
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
                    (list (plain-file "profile" "[ -f ~/.nix-profile/etc/profile.d/nix.sh ] && source ~/.nix-profile/etc/profile.d/nix.sh")))

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

    (simple-service 'additional-env-vars-service
                    home-environment-variables-service-type
                    `(("PATH" . "$HOME/.local/bin:$HOME/.config/emacs/bin:$HOME/.krew/bin:$PATH")
                      ("XDG_DATA_DIRS" . "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share:$HOME/.nix-profile/share:$HOME/.local/share/fonts")
                      ("VISUAL" . "emacsclient")
                      ("BROWSER" . "flatpak run app.zen_browser.zen")
                      ("_JAVA_AWT_WM_NONREPARENTING" . "1")
                      ("MOZ_USE_XINPUT2" . "1")
                      ("npm_config_prefix" . "$HOME/.local")
                      ("EDITOR" . "emacsclient")))))))
