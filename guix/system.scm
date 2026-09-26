(use-modules (gnu)
             (gnu services shepherd)
             (gnu services containers)
             (gnu services linux)
             (gnu services sysctl)
             (gnu services firmware)
             (gnu system accounts)
             (nongnu packages linux)
             (nongnu packages firmware)
             ;; #:select avoids the ambiguity warning emitted on every reconfigure:
             ;;   WARNING: (gnu packages linux): `libcamera-minimal' imported from
             ;;   both (gnu packages networking) and (gnu packages photo)
             ;; Both modules export libcamera-minimal, so an unqualified import
             ;; leaves Guile to pick one arbitrarily. Only these two bindings are
             ;; actually referenced from this module, so selecting them keeps the
             ;; namespace unambiguous and makes the dependency explicit.
             ;; blueman is the ONLY binding this module needs from here. `tailscale`
             ;; looks like it belongs in this list but does NOT: that package comes
             ;; from the rosenthal channel (rosenthal/packages/networking.scm), while
             ;; (rosenthal services networking) below provides the service. Selecting
             ;; it here fails at load time with
             ;;   unbound-variable: no binding `tailscale' in module
             ;;   (gnu packages networking)
             ((gnu packages networking) #:select (blueman))
             (nongnu system linux-initrd)
             (rosenthal services networking)
             (gnu packages gnome)
             (guix packages)
             (guix build-system trivial)
             ((guix licenses) #:prefix license:)
             (srfi srfi-1)
             (linux-cachyos))
(use-service-modules desktop networking xorg dbus nix pm)
(use-package-modules package-management security-token)

(define username "worldofgeese")


(define %my-services
  (modify-services %desktop-services
    (guix-service-type
     config => (guix-configuration
                 (inherit config)
                 (extra-options '("--max-jobs=1" "--cores=4"))
                 (substitute-urls
                  (append (list "https://substitutes.nonguix.org"
                                "https://cache-cdn.guix.moe"
                                "https://guix.tobias.gr/substitutes/"
                                "https://guix.bordeaux.inria.fr")
                          %default-substitute-urls))
                 (authorized-keys
                  (append (list (plain-file "nonguix.pub" "
    (public-key
     (ecc
      (curve Ed25519)
      (q #C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98#)
      )
     )
    ")
                                (plain-file "guix-moe.pub" "
    (public-key
     (ecc
      (curve Ed25519)
      (q #552F670D5005D7EB6ACF05284A1066E52156B51D75DE3EBD3030CD046675D543#)
      )
     )
    ")
                                (plain-file "guix-tobias.pub" "
    (public-key
     (ecc
      (curve Ed25519)
      (q #628CD75C05C78223317092AFDCBE7130D363ACA938114A067F4F9DCF346B59DB#)
      )
     )
    ")
                                (plain-file "guix-science.pub" "
    (public-key
     (ecc
      (curve Ed25519)
      (q #89FBA276A976A8DE2A69774771A92C8C879E0F24614AAAAE23119608707B3F06#)
      )
     )
    "))
                          %default-authorized-guix-keys))))
    (sysctl-service-type
      config => (sysctl-configuration
                  (inherit config)
                  (settings (append (sysctl-configuration-settings config)
                    '(("vm.swappiness" . "150")
                      ("vm.dirty_background_ratio" . "5")
                      ("vm.dirty_ratio" . "10")
                      ("vm.vfs_cache_pressure" . "200")
                      ("vm.min_free_kbytes" . "65536")
                      ("vm.watermark_scale_factor" . "200"))))))
    (elogind-service-type config =>
                          (elogind-configuration (inherit config)
                                                 (handle-power-key 'suspend)
                                                 (handle-lid-switch-docked 'suspend)
                                                 (handle-lid-switch-external-power 'suspend)
                                                 (handle-lid-switch 'suspend)))
    (dbus-root-service-type config =>
                            (dbus-configuration
                             (inherit config)
                             (verbose? #f)
                             (services (list gdm))))
    (gdm-service-type config =>
                      (gdm-configuration
                       (inherit config)
                       (wayland? #t)))
    ;; Tailscale owns /etc/resolv.conf on this host (nameserver 100.100.100.100,
    ;; MagicDNS verified resolving), and `resolvconf` is not installed. Without
    ;; dns="none" NetworkManager retries the commit forever and logs
    ;;   dns-mgr: resolvconf failed with status 256
    ;;   dns-mgr: could not commit DNS changes
    ;; ~172 times per 500 lines of /var/log/messages, which buries real warnings.
    ;; DNS itself is healthy -- this only stops NM fighting over a file another
    ;; service legitimately manages.
    (network-manager-service-type
     config => (network-manager-configuration
                 (inherit config)
                 (dns "none")))
))

(define ewm-desktop-session
  (package
    (name "ewm-desktop-session")
    (version "0.1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:modules '((guix build utils))
           #:builder
           #~(begin
               (use-modules (guix build utils))
               ;; Install launcher script (accessible by GDM since it lives in /gnu/store)
               (let ((bin (string-append #$output "/bin")))
                 (mkdir-p bin)
                 (call-with-output-file (string-append bin "/ewm-session")
                   (lambda (port)
                     (display "#!/bin/sh
# EWM session launcher — uses Guix emacs-pgtk + Nix-built EWM module
HM_SITE_LISP=\"$HOME/.local/state/nix/profiles/home-manager/home-path/share/emacs/site-lisp\"
exec /run/current-system/profile/bin/emacs \\\n  --fg-daemon=ewm \\\n  -L \"$HM_SITE_LISP\" \\\n  -l ewm \\\n  -f ewm-start-module \\\n  \"$@\"\n" port)))
                 (chmod (string-append bin "/ewm-session") #o755))
               ;; Install .desktop file for GDM wayland session picker
               (let ((sessions (string-append #$output "/share/wayland-sessions")))
                 (mkdir-p sessions)
                 (call-with-output-file (string-append sessions "/ewm.desktop")
                   (lambda (port)
                     (display "[Desktop Entry]
Type=Application
Name=EWM
Comment=Emacs Wayland Manager
Exec=ewm-session
DesktopNames=EWM
" port)))))))
    (home-page "https://codeberg.org/ezemtsov/ewm")
    (synopsis "EWM Wayland session desktop entry")
    (description "Desktop entry file for launching EWM from GDM.")
    (license license:gpl3+)))

;; Omarchy (via nixarchy) Wayland session entry.
;;
;; Nixarchy's own session entry cannot be reused: it is delivered through
;; services.displayManager.sessionPackages, and its launcher wraps the
;; compositor in `uwsm start -N Omarchy -D Hyprland`, which requires a systemd
;; user manager. pid1 here is shepherd. So the entry is ported the same way
;; ewm-desktop-session above is, and omarchy-session.sh execs Hyprland
;; directly.
;;
;; Losing uwsm costs the per-app app.slice isolation that `uwsm-app --` gives
;; each launched program; every one of Omarchy's ~30 launch sites funnels
;; through default/hypr/helpers.lua, so apps still start, they just share one
;; cgroup. app.slice is a systemd concept with no shepherd equivalent.
;;
;; The launcher resolves the Omarchy tree and the compositor out of the Home
;; Manager profile at RUN time rather than naming them here. Two reasons: the
;; Omarchy tree is a /nix/store path Guix cannot reference, and pinning a
;; compositor at build time would make every `guix system reconfigure` build
;; Hyprland just to emit a 200-byte desktop file.
(define omarchy-desktop-session
  (package
    (name "omarchy-desktop-session")
    (version "0.1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:modules '((guix build utils))
           #:builder
           (with-imported-modules '((guix build utils))
             #~(begin
                 (use-modules (guix build utils))
                 (let ((bin (string-append #$output "/bin"))
                       (sessions (string-append #$output "/share/wayland-sessions")))
                   (mkdir-p bin)
                   (copy-file #$(local-file "omarchy-session.sh")
                              (string-append bin "/omarchy-session"))
                   (chmod (string-append bin "/omarchy-session") #o555)
                   (mkdir-p sessions)
                   ;; The basename is the session id GDM persists as "the
                   ;; session this user last picked", so it matches nixarchy's
                   ;; `omarchy` rather than being renamed to match the label.
                   (call-with-output-file
                       (string-append sessions "/omarchy.desktop")
                     (lambda (port)
                       (display "[Desktop Entry]
Type=Application
Name=Omarchy
Comment=Omarchy on Guix System, through Hyprland
Exec=omarchy-session
DesktopNames=Hyprland
" port))))))))
    (home-page "https://github.com/olafkfreund/nixarchy")
    (synopsis "Omarchy Wayland session desktop entry")
    (description
     "Desktop entry and launcher that start Omarchy's Hyprland session from GDM
on Guix System, resolving the Omarchy tree and the compositor out of the Home
Manager profile at run time.")
    (license license:expat)))

(operating-system
  ;; BORE scheduler active; keep ananicy-cpp disabled (conflicts with BORE).
  (kernel linux-cachyos-bore)
  (initrd microcode-initrd)
  ;; PSR disabled -- causes GNOME Shell compositor to spin at 15% CPU on this panel.
  ;; ASPM stays enabled because it did not cause the QCA6174 failures. The card
  ;; failed during PCI probe after a warm reboot from D3cold. Runtime-PM rules
  ;; prevent a running system from putting the card back into D3cold. This
  ;; kernel parameter also requests the ath10k warm-only reset mode. Test it on
  ;; the next planned boot; it is not a proven fix.
  (kernel-arguments (cons "i915.enable_psr=0 ath10k_core.skip_otp=y ath10k_pci.reset_mode=1 snd_hda_intel.power_save=1 mce=dont_log_ce" %default-kernel-arguments))
  (firmware (list linux-firmware))
  (locale "en_US.utf8")
  (timezone "Europe/Copenhagen")
  (keyboard-layout (keyboard-layout "us" "altgr-intl"))
  (host-name "mahakala")
  (users (cons* (user-account
                 (name username)
                 (group "users")
                 (home-directory (string-append "/home/" username))
                 (supplementary-groups '("wheel" "netdev" "audio" "video" "plugdev")))
                %base-user-accounts))
  (sudoers-file (plain-file "sudoers" "\
root ALL=(ALL) ALL
%wheel ALL=NOPASSWD: ALL\n"))
  (packages (append (specifications->packages
                     (list "emacs-pgtk" "xdg-dbus-proxy"
                           ;; Portal backends for the Omarchy session.
                           ;;
                           ;; Guix side, not home.packages, and that is not a
                           ;; preference: a portal is ACTIVATED by D-Bus, which
                           ;; scans the share/dbus-1/services of the
                           ;; XDG_DATA_DIRS the bus itself was started with.
                           ;; Measured on the running bus (pid 2011): it sees
                           ;; ~/.guix-home/profile/share, ~/.guix-profile/share,
                           ;; /run/current-system/profile/share and
                           ;; ~/.nix-profile/share -- but NOT
                           ;; ~/.local/state/nix/profiles/home-manager/home-path/share,
                           ;; which is a different profile from ~/.nix-profile
                           ;; (verified: km6z5c7b... vs j2ba8rr2...). A portal
                           ;; installed by Home Manager would therefore sit in a
                           ;; directory D-Bus never reads, and every screenshare
                           ;; would fail with no error pointing at the cause.
                           ;;
                           ;; Both backends are needed and they are not
                           ;; alternatives: -hyprland answers Screenshot,
                           ;; ScreenCast and GlobalShortcuts (its .portal
                           ;; declares UseIn=...Hyprland, matching the
                           ;; XDG_CURRENT_DESKTOP the session launcher exports),
                           ;; while -gtk answers FileChooser, which is what
                           ;; omarchy-file-select and every GTK open/save dialog
                           ;; uses. nixarchy installs exactly this pair via
                           ;; xdg.portal.extraPortals plus programs.hyprland's
                           ;; portalPackage.
                           ;;
                           ;; The frontend itself is already here and already
                           ;; running: xdg-desktop-portal 1.22.1, plus the
                           ;; permission and document portals, came in with
                           ;; gnome-desktop-service-type.
                           ;;
                           ;; Guix's -hyprland is 1.3.12 against the session's
                           ;; Hyprland 0.56. The portal talks to the compositor
                           ;; over hyprland-global-shortcuts-v1 and
                           ;; wlr-screencopy, both long stable, so the version
                           ;; gap is a real but small risk -- and the failure is
                           ;; a screenshare that does not start, not a session
                           ;; that does not boot.
                           "xdg-desktop-portal-hyprland"
                           "xdg-desktop-portal-gtk"))
                    (list ewm-desktop-session omarchy-desktop-session)
                    %base-packages))
  (services
   (cons*
    (service zram-device-service-type
             (zram-device-configuration
              (size "8G")
              (compression-algorithm 'zstd)
              (memory-limit 0)
              (priority 100)))
    (service earlyoom-service-type
             (earlyoom-configuration
              (minimum-available-memory 5)
              (minimum-free-swap 5)
              (prefer-regexp "guix-daemon|guile")
              (avoid-regexp "sshd|shepherd|earlyoom")
              (run-with-higher-priority? #t)))
    (udev-rules-service 'fido2 libfido2 #:groups '("plugdev"))
    ;; Keep the QCA6174 WiFi card out of PCI runtime power management.
    ;;
    ;; The card is intermittently missing at boot. Diagnosed over the 9 boots
    ;; retained in /var/log/messages, with total separation between the two
    ;; groups: all 4 failing boots open with
    ;;   ath10k_pci 0000:02:00.0: Unable to change power state from D3cold to
    ;;   D0, device inaccessible
    ;; then ~20 "failed to wake target ... -110", a fallback from MSI to legacy
    ;; IRQ, "failed to reset chip: -5", and "probe with driver ath10k_pci failed
    ;; with error -5". All 5 working boots open with "enabling device
    ;; (0000 -> 0002)" and never mention D3cold. lspci reports the card
    ;; PME(D3cold+) NoSoftRst-: it accepts D3cold and needs a full re-init to
    ;; come back, and that re-init is what fails.
    ;;
    ;; A udev rule and not only TLP's RUNTIME_PM_DRIVER_DENYLIST, because the
    ;; denylist was tried first and is not sufficient: with ath10k_pci denied,
    ;; tlp-stat confirms "Driver denylist = radeon nouveau ath10k_pci" and yet
    ;; power/control stays "auto", since the denylist only stops TLP from
    ;; touching the setting and "auto" -- which still permits D3cold -- is the
    ;; kernel's own default. Forcing "on" is what actually keeps the card out of
    ;; D3. Verified live before being written here: echoing "on" left the
    ;; interface up and the network reachable.
    ;;
    ;; Matched on driver rather than PCI address so it survives re-enumeration,
    ;; and ACTION=="add" so it applies at probe, which is when the state matters.
    (simple-service 'ath10k-no-runtime-pm udev-service-type
                    (list (udev-rule
                           "80-ath10k-no-runtime-pm.rules"
                           (string-append
                            "ACTION==\"add\", SUBSYSTEM==\"pci\", "
                            "DRIVERS==\"ath10k_pci\", "
                            "ATTR{power/control}=\"on\"\n"))))
    (service gnome-desktop-service-type
              (gnome-desktop-configuration
               (utilities
                (remove (lambda (pkg)
                          (member (package-name pkg)
                                  '("gnome-console"
                                    "gnome-calendar"
                                    "gnome-characters"
                                    "decibels"
                                    "gnome-maps"
                                    "gnome-music"
                                    "gnome-connections"
                                    "simple-scan"
                                    "epiphany"
                                    "showtime"
                                    "gnome-text-editor")))
                        (gnome-desktop-configuration-utilities
                         (gnome-desktop-configuration))))))
    (service bluetooth-service-type)
    (service fwupd-service-type
             (fwupd-configuration
              (fwupd fwupd-nonfree)))
    ;; Suppress fwupdmgr report-upload prompt (blanking ReportURI removes the prompt entirely)
    (simple-service 'fwupd-no-reports etc-service-type
      (list `("fwupd/remotes.d/lvfs.conf"
              ,(plain-file "lvfs.conf"
                "[fwupd Remote]\nEnabled=true\nTitle=Linux Vendor Firmware Service\nMetadataURI=https://cdn.fwupd.org/downloads/firmware.xml.xz\nReportURI=\nAutomaticReports=false\nAutomaticSecurityReports=false\nApprovalRequired=false\n"))))
    (service nix-service-type
             (nix-configuration
              (extra-config
               (list "trusted-users = root worldofgeese\n"
                     ;; Must match the user-level nix.conf in home-configuration.scm.
                     ;; The daemon fetches substitutes and reads only /etc/nix/nix.conf,
                     ;; so setting this solely on the user side left the daemon on the
                     ;; 64MB default -- the source of "download buffer is full".
                     "download-buffer-size = 536870912\n"
                     "extra-trusted-substituters = https://cache.floxdev.com https://devenv.cachix.org https://nixpkgs-python.cachix.org https://cache.numtide.com\n"
                     ;; The entries above are only *permitted*, not enabled: a
                     ;; trusted substituter still has to be requested per build.
                     ;; This one is enabled outright so decapod and anything else
                     ;; pushed by `just cachix-push` is fetched instead of rebuilt.
                     "extra-substituters = https://worldofgeese.cachix.org\n"
                     "extra-trusted-public-keys = flox-store-public-0:8c/B+kjIaQ+BloCmNkRUKwaVPFWkriSAd0JJvuDu4F0= devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= nixpkgs-python.cachix.org-1:hxjI7pFxTyuTHn2NkvWCrAUcNZLNS3ZAvfYNuYifcEU= niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g= worldofgeese.cachix.org-1:Xs/BcZWj1l+kWJlD1PwsnYR+fTZC49uey77NABJZmEs=\n"
                     "experimental-features = nix-command flakes\n"))))
    (service tailscale-service-type)
    (simple-service 'msr-module kernel-module-loader-service-type '("msr"))

    ;; Power & thermal management (Dell XPS 13 9380)
    ;; See .rpi/designs/2026-05-14-power-thermal-optimization.md for revert instructions
    ;; thermald removed: redundant with platform_profile + undervolt, and --adaptive
    ;; conflicts with Dell EC thermal management (double-throttling via RAPL)
    (service tlp-service-type
             (tlp-configuration
              ;; AC/charging: balanced performance (see .rpi/specs/power-thermal.md)
              (cpu-boost-on-ac? #t)
              (cpu-boost-on-bat? #f)
              (cpu-scaling-governor-on-ac '("powersave"))
              (cpu-max-perf-on-ac 100)
              (sched-powersave-on-ac? #f)
              (energy-perf-policy-on-ac "balance_performance")
              (cpu-energy-perf-policy-on-ac "balance_performance")
              ;; Reduce charging heat and battery wear; resume charging below 75%, stop at 85%.
              (start-charge-thresh-bat0 75)
              (stop-charge-thresh-bat0 85)
              (energy-perf-policy-on-bat "power")
              (pcie-aspm-on-ac "powersave")
              (pcie-aspm-on-bat "powersave")
              (wifi-pwr-on-ac? #f)
              (wifi-pwr-on-bat? #t)
              (sound-power-save-on-ac 1)
              (sound-power-save-on-bat 1)
              (nmi-watchdog? #f)
              (runtime-pm-on-ac "auto")
              (runtime-pm-on-bat "auto")
              ;; Keep the WiFi card out of runtime PM.
              ;;
              ;; The QCA6174 is intermittently not detected at boot. Diagnosed
              ;; across the 9 boots retained in /var/log/messages, and the
              ;; separation is total: the 4 failing boots all open with
              ;;   ath10k_pci: Unable to change power state from D3cold to D0,
              ;;   device inaccessible
              ;; followed by ~20 "failed to wake target ... -110", a fallback
              ;; from MSI to legacy IRQ, "failed to reset chip: -5" and finally
              ;; "probe with driver ath10k_pci failed with error -5". The 5
              ;; working boots all open with "enabling device (0000 -> 0002)"
              ;; and never mention D3cold. lspci reports the card as
              ;; PME(D3cold+) NoSoftRst-, i.e. it both accepts D3cold and needs
              ;; a full re-init to leave it, which is the path that fails.
              ;;
              ;; This is the driver blacklist rather than the address blacklist
              ;; so it keeps working if the card ever enumerates elsewhere.
              ;;
              ;; Note what this does NOT claim to fix: TLP starts well after
              ;; the PCI probe -- measured on the 2026-09-03 failure, the probe
              ;; failed at 23:16:54 and TLP applied its settings at 23:16:56 --
              ;; so TLP cannot have caused the boot-time D3cold state, and an
              ;; earlier theory of mine that blamed pcie-aspm was wrong for
              ;; exactly that reason. What this prevents is the card being put
              ;; into D3cold while the system is RUNNING, which is the state a
              ;; subsequent warm reboot then inherits. If failures continue
              ;; after a cold power-off, the remaining suspect is firmware
              ;; leaving it powered down. The kernel argument now requests the
              ;; driver's warm-only reset mode. Verify it on the next planned
              ;; boot; do not treat the parameter as a confirmed fix.
              (runtime-pm-driver-blacklist '("radeon" "nouveau" "ath10k_pci"))
              (sata-linkpwr-on-ac "med_power_with_dipm")
              (sata-linkpwr-on-bat "med_power_with_dipm")))
    (simple-service 'tlp-platform-profile etc-service-type
      (list `("tlp.d/01-platform-profile.conf"
              ,(plain-file "01-platform-profile.conf"
                "PLATFORM_PROFILE_ON_AC=balanced\nPLATFORM_PROFILE_ON_BAT=low-power\n"))))

    (simple-service 'flatpak-hicolor-icon-index activation-service-type
                    #~(begin
                        (for-each
                         (lambda (directory)
                           (unless (file-exists? directory)
                             (mkdir directory)))
                         '("/usr" "/usr/share" "/usr/share/icons" "/usr/share/icons/hicolor"))
                        (let ((target "/usr/share/icons/hicolor/index.theme"))
                          (when (file-exists? target)
                            (delete-file target))
                          (symlink "/run/current-system/profile/share/icons/hicolor/index.theme"
                                   target))))

    (service rootless-podman-service-type
      (rootless-podman-configuration
        (subgids (list (subid-range (name "worldofgeese"))))
        (subuids (list (subid-range (name "worldofgeese"))))
        (containers-policy
          (plain-file "policy.json"
            "{\"default\": [{\"type\": \"insecureAcceptAnything\"}]}"))
        (containers-storage
          (plain-file "storage.conf"
            "[storage]\ndriver = \"overlay\""))
        (containers-registries
          (plain-file "registries.conf"
            "unqualified-search-registries = [\"quay.io\", \"docker.io\"]"))))

    (set-xorg-configuration
     (xorg-configuration
      (keyboard-layout keyboard-layout)
      (extra-config (list
                     "Section \"InputClass\"
                                      Identifier \"TouchPad\"
                                      MatchIsTouchpad \"on\"
                                      Driver \"libinput\"
                                      Option \"Tapping\" \"on\"
                                      Option \"NaturalScrolling\" \"true\"
                                      Option \"DisableWhileTyping\" \"on\"
                              EndSection"))))

    (simple-service 'blueman dbus-root-service-type (list blueman))
    (service iptables-service-type
             (iptables-configuration
              (ipv4-rules (plain-file "iptables.rules" "*filter
:INPUT ACCEPT
:FORWARD ACCEPT
:OUTPUT ACCEPT
COMMIT
"))
              (ipv6-rules (plain-file "ip6tables.rules" "*filter
:INPUT ACCEPT
:FORWARD ACCEPT
:OUTPUT ACCEPT
COMMIT
"))))
    (simple-service 'nix-opengl-driver shepherd-root-service-type
                    (list
                     (shepherd-service
                      (provision '(nix-opengl-driver))
                       (requirement '(file-systems user-homes))
                       (documentation "Symlink /run/opengl-driver for Nix GPU apps (home-manager GPU module).")
                       (one-shot? #t)
                       (start #~(make-system-constructor
                                 (string-append
                                  "target=$("
                                  #$(file-append (specification->package "grep") "/bin/grep")
                                  " -m1 -oP \"(?<=^new=)\\\\S+\" /home/worldofgeese/.local/state/home-manager/gcroots/current-home/activate) && "
                                  "[ -d \"$target\" ] && "
                                  #$(file-append (specification->package "coreutils") "/bin/ln")
                                  " -sfT \"$target\" /run/opengl-driver"))))))
    ;; /run/wrappers/bin, for Nix programs that authenticate through polkit.
    ;;
    ;; Quickshell -- the Omarchy bar, and so the polkit agent for the whole
    ;; session -- links Nix's libpolkit-agent-1, and that library hardcodes the
    ;; NIXOS setuid-wrapper path /run/wrappers/bin/polkit-agent-helper-1. Guix
    ;; puts its setuid helper in /run/privileged/bin instead, so the exec failed
    ;; and the agent could show a password dialog, take a correct password, and
    ;; reject it with nothing logged -- an authentication prompt that could not
    ;; be satisfied and had to be escaped with a power cycle.
    ;;
    ;; The symlink points at GUIX's helper, not the Nix polkit-127 one that
    ;; library was built against. The helper authenticates the user and reports
    ;; to polkitd over a private protocol, and the polkitd running here is
    ;; Guix's polkit-121, so the helper has to be its counterpart. It is also
    ;; the only one of the two that is setuid root, which is the entire reason a
    ;; helper exists: /run/privileged/bin/polkit-agent-helper-1 is -r-sr-xr-x,
    ;; while the Nix copy in the store is -r-xr-xr-x and could not check a
    ;; password even if it were found.
    ;;
    ;; A directory holding one symlink, rather than making /run/wrappers/bin a
    ;; link to /run/privileged/bin: that directory holds every setuid program on
    ;; the system (sudo, su, passwd, fusermount), and republishing all of them
    ;; under the path NixOS binaries probe invites a Nix program to pick up a
    ;; Guix setuid binary by accident. Only the helper is exposed.
    (simple-service 'nix-polkit-wrapper shepherd-root-service-type
                    (list
                     (shepherd-service
                      (provision '(nix-polkit-wrapper))
                      (requirement '(file-systems))
                      (documentation "Expose polkit-agent-helper-1 and unix_chkpwd at the NixOS wrapper path for Nix PAM/polkit clients (Quickshell).")
                      (one-shot? #t)
                      (start #~(make-system-constructor
                                (string-append
                                 #$(file-append (specification->package "coreutils") "/bin/mkdir")
                                 " -p /run/wrappers/bin && "
                                 #$(file-append (specification->package "coreutils") "/bin/ln")
                                 " -sfT /run/privileged/bin/polkit-agent-helper-1"
                                 " /run/wrappers/bin/polkit-agent-helper-1 && "
                                 ;; unix_chkpwd, for the LOCK SCREEN.
                                 ;;
                                 ;; Same class of bug as the polkit helper and
                                 ;; found because publishing only that one was
                                 ;; not enough: the lock screen still rejected a
                                 ;; correct password. Quickshell links Nix's
                                 ;; libpam, /etc/pam.d/omarchy-lock-password
                                 ;; names pam_unix.so, and Nix's pam_unix.so
                                 ;; hardcodes /run/wrappers/bin/unix_chkpwd --
                                 ;; the setuid helper it must exec to read
                                 ;; /etc/shadow as a non-root user. That path
                                 ;; did not exist, so authentication failed
                                 ;; before ever reaching the shadow file, which
                                 ;; PAM reports as PAM_AUTHINFO_UNAVAIL. The
                                 ;; shell log showed exactly that: "Error while
                                 ;; authenticating: Authentication service
                                 ;; cannot retrieve authentication info".
                                 ;;
                                 ;; Guix's linux-pam is 1.7.2 and Nix's is
                                 ;; 1.7.1/1.7.2, and unix_chkpwd's contract --
                                 ;; user on argv, password on stdin, verdict in
                                 ;; the exit status -- has been stable across
                                 ;; those releases, so the Guix helper satisfies
                                 ;; the Nix module. Guix's is also the only one
                                 ;; that is setuid root; the Nix copy in the
                                 ;; store is not, and could not read shadow.
                                 ;;
                                 ;; Verified by building a probe against NIX's
                                 ;; libpam and Nix's glibc: before the symlink it
                                 ;; returned PAM_AUTHINFO_UNAVAIL, after it
                                 ;; returns Authentication failure (7) for a
                                 ;; wrong password -- i.e. pam_unix is now
                                 ;; actually consulting the shadow file. An
                                 ;; earlier probe built against GUIX's libpam
                                 ;; passed all along, which is why this was
                                 ;; missed: it never used the module quickshell
                                 ;; uses.
                                 #$(file-append (specification->package "coreutils") "/bin/ln")
                                 " -sfT /run/privileged/bin/unix_chkpwd"
                                 " /run/wrappers/bin/unix_chkpwd")))
                      (stop #~(const #f)))))
    (simple-service 'cpu-undervolt shepherd-root-service-type
                    (list
                     (shepherd-service
                      (provision '(cpu-undervolt))
                      (requirement '(file-systems udev user-processes kernel-module-loader))
                      (documentation "Apply CPU/GPU undervolt via MSR 0x150.")
                      (one-shot? #t)
                      (start #~(make-system-constructor
                                (string-append
                                 "for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/cpu/0/msr ] && break; sleep 1; done && "
                                 #$(file-append (specification->package "undervolt") "/bin/undervolt")
                                 " --core -80 --cache -80 --gpu -50 --analogio 0 --uncore 0")))
                      (stop #~(const #f)))))
    (simple-service 'cgroup-setup shepherd-root-service-type
                    (list
                     (shepherd-service
                      (provision '(cgroup-setup))
                      (documentation "Configure cgroup on login.")
                      (one-shot? #t)
                      (start #~(make-forkexec-constructor
                                (list "/bin/sh" "-c"
                                      (string-append
                                       "echo '+cpu +cpuset +memory +pids' > /sys/fs/cgroup/cgroup.subtree_control && "
                                       "g=users && chgrp -R $g /sys/fs/cgroup/ && "
                                       "u=" '#$username " && chown -R $u: /sys/fs/cgroup"))))
                      (stop #~(make-kill-destructor)))))
    (simple-service 'etc-subuid etc-service-type
                    (list `("subuid" ,(plain-file "subuid" (string-append "root:0:65536\n" username ":100000:65536\n")))))
    (simple-service 'etc-subgid etc-service-type
                    (list `("subgid" ,(plain-file "subgid" (string-append "root:0:65536\n" username ":100000:65536\n")))))
    (service pam-limits-service-type
             (list
              (pam-limits-entry "*" 'both 'nofile 100000)))
    ;; Omarchy's lock screen authenticates through PAM by stack NAME: the
    ;; Quickshell plugin opens PamContext { config: "omarchy-lock-password" }
    ;; (shell/plugins/lock/Service.qml:321) and live-watches
    ;; /etc/pam.d/omarchy-lock-password to decide whether to offer password
    ;; auth at all (:485). With the file absent the lock screen has no way to
    ;; unlock, which is why this is not optional the way the theming shims are.
    ;;
    ;; unix-pam-service produces the same pam_unix stack that NixOS's empty
    ;; `security.pam.services.omarchy-lock-password = { }` does. pam_unix
    ;; checking a non-root password needs the setuid unix_chkpwd helper, and
    ;; pam-root-service-type already installs it.
    ;;
    ;; No omarchy-lock-fingerprint counterpart on purpose: the shell gates the
    ;; fingerprint method on that file AND on fprintd-list reporting enrolled
    ;; fingers, so a pam_unix stack under that name would advertise a
    ;; "fingerprint" prompt that silently waits for a typed password.
    (simple-service 'omarchy-lock-pam pam-root-service-type
                    (list (unix-pam-service "omarchy-lock-password")))
    ;; The file ~/.XCompose includes. Omarchy's first run writes that anchor
    ;; once and never rewrites it (so it cannot name a store path), and line 4
    ;; of it is an unconditional `include "/etc/omarchy/xcompose"`. nixarchy
    ;; supplies the target through environment.etc, which does not exist here.
    ;;
    ;; Without it the whole anchor fails to PARSE, not just the emoji half:
    ;; libxkbcommon reports `failed to open included Compose file` and then
    ;; `failed to parse file`, and returns no table at all, so every dead key
    ;; and compose sequence in the session stops working. Measured directly
    ;; against libxkbcommon 2026-09-20: the shipped ~/.XCompose FAILs and the
    ;; same file with a resolvable include is OK, and foot in a real session
    ;; printed "failed to instantiate compose table; dead keys (compose) will
    ;; not work".
    ;;
    ;; plain-file with the content inline rather than a reference to the
    ;; package's own default/xcompose: that tree lives in the Home Manager
    ;; profile under /nix/store, which Guix cannot reference -- the same
    ;; constraint that makes omarchy-desktop-session resolve its paths at run
    ;; time. The content is a static table upstream changes rarely; it is
    ;; reproduced verbatim from share/omarchy/default/xcompose (4.0.4),
    ;; including the leading `include "%L"` that pulls in the locale's own
    ;; sequences -- dropping that line would trade the missing-file failure for
    ;; a silently smaller keymap.
    (simple-service
     'omarchy-xcompose etc-service-type
     (list `("omarchy/xcompose"
             ,(plain-file "omarchy-xcompose"
                          "include \"%L\"

# Emoji
<Multi_key> <m> <s> : \"😄\" # smile
<Multi_key> <m> <c> : \"😂\" # cry
<Multi_key> <m> <l> : \"😍\" # love
<Multi_key> <m> <v> : \"✌️\"  # victory
<Multi_key> <m> <h> : \"❤️\"  # heart
<Multi_key> <m> <y> : \"👍\" # yes
<Multi_key> <m> <n> : \"👎\" # no
<Multi_key> <m> <f> : \"🖕\" # fuck
<Multi_key> <m> <w> : \"🤞\" # wish
<Multi_key> <m> <r> : \"🤘\" # rock
<Multi_key> <m> <k> : \"😘\" # kiss
<Multi_key> <m> <e> : \"🙄\" # eyeroll
<Multi_key> <m> <d> : \"🤤\" # droll
<Multi_key> <m> <m> : \"💰\" # money
<Multi_key> <m> <x> : \"🎉\" # xellebrate
<Multi_key> <m> <1> : \"💯\" # 100%
<Multi_key> <m> <t> : \"🥂\" # toast
<Multi_key> <m> <p> : \"🙏\" # pray
<Multi_key> <m> <i> : \"😉\" # wink
<Multi_key> <m> <o> : \"👌\" # OK
<Multi_key> <m> <g> : \"👋\" # greeting
<Multi_key> <m> <a> : \"💪\" # arm
<Multi_key> <m> <b> : \"🤯\" # blowing

# Typography
<Multi_key> <space> <space> : \"—\"
"))))
    %my-services))
  (bootloader (bootloader-configuration
               (bootloader grub-efi-bootloader)
               (targets (list "/boot/efi"))
               (keyboard-layout keyboard-layout)))
  (mapped-devices (list (mapped-device
                         (source (uuid "c667edf6-fb07-4ce4-bd62-060d7b835cd3"))
                         (target "cryptroot")
                         (type luks-device-mapping))))
  (file-systems (cons* (file-system
                         (mount-point "/boot/efi")
                         (device (uuid "2C9C-4D34" 'fat32))
                         (type "vfat"))
                       (file-system
                         (mount-point "/")
                         (device "/dev/mapper/cryptroot")
                         (type "ext4")
                         (dependencies mapped-devices)) %base-file-systems)))
