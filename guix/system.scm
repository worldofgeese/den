(use-modules (gnu)
             (gnu services shepherd)
             (gnu services containers)
             (gnu services linux)
             (gnu services sysctl)
             (gnu services firmware)
             (gnu system accounts)
             (nongnu packages linux)
             (nongnu packages firmware)
             (gnu packages networking)
             (nongnu system linux-initrd)
             (rosenthal services networking)
             (gnu packages gnome)
             (gnu packages suckless)
             (guix packages)
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
                (append (list "https://nonguix-proxy.ditigal.xyz")
                  %default-substitute-urls))
                  (authorized-keys
                   (append (list (plain-file "non-guix.pub" "
    (public-key
     (ecc
      (curve Ed25519)
      (q #C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98#)
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
))

(operating-system
  (kernel linux-cachyos)
  (initrd microcode-initrd)
  ;; PSR disabled — causes GNOME Shell compositor to spin at 15% CPU on this panel.
  ;; ASPM left enabled (managed by TLP, no observed WiFi issues).
  (kernel-arguments (cons "i915.enable_psr=0 ath10k_core.skip_otp=y snd_hda_intel.power_save=1" %default-kernel-arguments))
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
                     (list "nix" "emacs-exwm" "emacs" "xdg-dbus-proxy" "emacs-desktop-environment"))
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
    (service screen-locker-service-type
             (screen-locker-configuration
              (name "slock")
              (program (file-append slock "/bin/slock"))))
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
    (service nix-service-type
             (nix-configuration
              (extra-config
               (list "trusted-users = root worldofgeese\n"
                     "extra-trusted-substituters = https://cache.floxdev.com https://devenv.cachix.org https://nixpkgs-python.cachix.org\n"
                     "extra-trusted-public-keys = flox-store-public-0:8c/B+kjIaQ+BloCmNkRUKwaVPFWkriSAd0JJvuDu4F0= devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= nixpkgs-python.cachix.org-1:hxjI7pFxTyuTHn2NkvWCrAUcNZLNS3ZAvfYNuYifcEU=\n"
                     "experimental-features = nix-command flakes\n"))))
    (service tailscale-service-type)
    (simple-service 'msr-module kernel-module-loader-service-type '("msr"))

    ;; Power & thermal management (Dell XPS 13 9380)
    ;; See .rpi/designs/2026-05-14-power-thermal-optimization.md for revert instructions
    ;; thermald removed: redundant with platform_profile + undervolt, and --adaptive
    ;; conflicts with Dell EC thermal management (double-throttling via RAPL)
    (service tlp-service-type
             (tlp-configuration
              (cpu-boost-on-ac? #t)
              (cpu-boost-on-bat? #f)
              (energy-perf-policy-on-ac "balance_performance")
              (energy-perf-policy-on-bat "power")
              (pcie-aspm-on-ac "powersave")
              (pcie-aspm-on-bat "powersave")
              (wifi-pwr-on-ac? #f)
              (wifi-pwr-on-bat? #t)
              (sound-power-save-on-ac 0)
              (sound-power-save-on-bat 1)
              (nmi-watchdog? #f)
              (runtime-pm-on-ac "auto")
              (runtime-pm-on-bat "auto")
              (sata-linkpwr-on-ac "med_power_with_dipm")
              (sata-linkpwr-on-bat "med_power_with_dipm")))
    (simple-service 'tlp-platform-profile etc-service-type
      (list `("tlp.d/01-platform-profile.conf"
              ,(plain-file "01-platform-profile.conf"
                "PLATFORM_PROFILE_ON_AC=quiet\nPLATFORM_PROFILE_ON_BAT=low-power\n"))))

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
            "[registries.search]\nregistries = ['quay.io', 'docker.io']"))))

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
                                "/bin/sh -c 'target=$(grep -oP \"(?<=^new=)\\\\S+\" /home/worldofgeese/.local/state/home-manager/gcroots/current-home/activate) && [ -d \"$target\" ] && ln -sfT \"$target\" /run/opengl-driver'")))))
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
