(use-modules (gnu)
             (gnu services shepherd)
             (gnu services containers)
             (gnu system accounts)
             (nongnu packages linux)
             (gnu packages networking)
             (nongnu system linux-initrd)
             (rosenthal services networking)
             (gnu packages gnome)
             (gnu packages suckless))
(use-service-modules desktop networking xorg dbus nix)
(use-package-modules package-management security-token)

(define %my-services
  (modify-services %desktop-services
    (guix-service-type
      config => (guix-configuration
                  (inherit config)
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
                       (wayland? #t)))))

(define username "worldofgeese")

(operating-system
  (kernel linux)
  (initrd microcode-initrd)
  (kernel-arguments (cons "i915.enable_psr=0 pcie_aspm=off ath10k_core.skip_otp=y" %default-kernel-arguments))
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
                     (list "nix"
                           "emacs-exwm"
                           "emacs"
                           "xdg-dbus-proxy"
                           "emacs-desktop-environment"))
                    %base-packages))

  (services
   (cons*
    (udev-rules-service 'fido2 libfido2 #:groups '("plugdev"))
    (service screen-locker-service-type
             (screen-locker-configuration
              (name "slock")
              (program (file-append slock "/bin/slock"))))
    (service gnome-desktop-service-type)
    (service bluetooth-service-type)
    (service nix-service-type
             (nix-configuration
              (extra-config
               (list "trusted-users = root worldofgeese\n"))))
    (service tailscale-service-type)

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
                      (documentation "Symlink /run/opengl-driver for Nix GPU apps (home-manager GPU module).")
                      (one-shot? #t)
                      (start #~(make-forkexec-constructor
                                (list "/bin/sh" "-c"
                                      "target=$(grep -oP '(?<=^new=)\\S+' /home/worldofgeese/.local/state/home-manager/gcroots/current-home/activate) && [ -d \"$target\" ] && ln -sfT \"$target\" /run/opengl-driver")))
                      (stop #~(make-kill-destructor)))))
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
                         (source (uuid
                                  "c667edf6-fb07-4ce4-bd62-060d7b835cd3"))
                         (target "cryptroot")
                         (type luks-device-mapping))))

  ;; The list of file systems that get "mounted".  The unique
  ;; file system identifiers there ("UUIDs") can be obtained
  ;; by running 'blkid' in a terminal.
  (file-systems (cons* (file-system
                         (mount-point "/boot/efi")
                         (device (uuid "2C9C-4D34"
                                       'fat32))
                         (type "vfat"))
                       (file-system
                         (mount-point "/")
                         (device "/dev/mapper/cryptroot")
                         (type "ext4")
                         (dependencies mapped-devices)) %base-file-systems)))
