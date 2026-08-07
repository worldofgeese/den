(define-module (linux-cachyos)
  #:use-module (gnu packages linux)
  #:use-module (nongnu packages linux)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix utils))

;; CachyOS kernel — upstream source with CachyOS patches.
;; linux-cachyos: pre-patched CachyOS/linux release tarball (POC scheduler).
;; linux-cachyos-bore: same CachyOS tarball + the bore-cachy scheduler patch.
;;
;; Includes: BBR3, CachyOS tuning, MGLRU improvements, ACS override,
;; ADIOS I/O scheduler, v4l2loopback, NTFS, and more.
;;
;; linux-cachyos-bore: do not enable ananicy-cpp with BORE.
;;
;; To upgrade: just upgrade-kernel

(define %cachyos-version "7.1.5")
(define %cachyos-upstream-version (version-major+minor %cachyos-version))
(define %cachyos-revision "1")
(define %cachyos-tag
  (string-append "cachyos-" %cachyos-version "-" %cachyos-revision))
(define %cachyos-source-hash "1f8khws8ss8frd51sl4l2yp8yak0rpxvkxwy4cwgw2saf9yj36lg")
(define %cachyos-bore-patch-hash "0lc62n7llaqnk8n45dc9wly2yczqqyzgacjpb71sj8qsrq0l30a4")

(define %cachyos-source
  (origin
    (method url-fetch)
    (uri (string-append
          "https://github.com/CachyOS/linux/releases/download/"
          %cachyos-tag "/" %cachyos-tag ".tar.gz"))
    (sha256
     (base32 %cachyos-source-hash))))

;; BORE variant: CachyOS tarball + bore-cachy patch. The bore-cachy patch has
;; #ifdef CONFIG_CACHY guards written against the CachyOS tree, so it must be
;; applied to the CachyOS tarball, not to upstream kernel.org sources. The
;; CachyOS tarball itself defines no CONFIG_SCHED_BORE symbol; this patch adds it.
(define %cachyos-bore-source
  (origin
    (inherit %cachyos-source)
    (patches
     (list
      (origin
        (method url-fetch)
        (uri (string-append
              "https://raw.githubusercontent.com/cachyos/kernel-patches/master/"
              %cachyos-upstream-version "/sched/0001-bore-cachy.patch"))
        (sha256
         (base32 %cachyos-bore-patch-hash)))))))

(define %cachyos-base-configs
  '("CONFIG_CACHY=y"
    "CONFIG_HZ_1000=y"
    "CONFIG_HZ=1000"
    "# CONFIG_HZ_250 is not set"
    "# CONFIG_HZ_300 is not set"
    "CONFIG_PREEMPT=y"
    "# CONFIG_PREEMPT_VOLUNTARY is not set"
    "# CONFIG_PREEMPT_NONE is not set"
    ;; Fix linker error: hid-haptic needs HID built-in
    "CONFIG_HID=y"
    ;; Guix wants these but they conflict with USB_HID=y
    ;; in CachyOS config. Explicitly unset them.
    "# CONFIG_USB_KBD is not set"
    "# CONFIG_USB_MOUSE is not set"))

(define* (make-cachyos-kernel #:key name localversion extra-configs
                              (source %cachyos-source)
                              (base-configs %cachyos-base-configs))
  (let ((base (customize-linux
               #:name name
               #:linux linux
               #:source source
               #:configs (append base-configs
                                 extra-configs
                                 (list (string-append "CONFIG_LOCALVERSION=\""
                                                      localversion
                                                      "\""))))))
    (package
      (inherit base)
      (version %cachyos-version))))

(define-public linux-cachyos
  (make-cachyos-kernel #:name "linux-cachyos"
                       #:localversion "-cachyos"
                       #:extra-configs '()))

(define-public linux-cachyos-bore
  (make-cachyos-kernel #:name "linux-cachyos-bore"
                       #:localversion "-cachyos-bore"
                       #:source %cachyos-bore-source
                       #:extra-configs '("CONFIG_SCHED_BORE=y")))
