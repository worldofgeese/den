(define-module (linux-cachyos)
  #:use-module (gnu packages linux)
  #:use-module (nongnu packages linux)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix utils))

;; CachyOS kernel — upstream source with CachyOS patches.
;; linux-cachyos: pre-patched CachyOS/linux release tarball (POC scheduler).
;; linux-cachyos-bore: upstream Linux kernel.org tarball + BORE scheduler patch.
;;
;; Includes: BBR3, CachyOS tuning, MGLRU improvements, ACS override,
;; ADIOS I/O scheduler, v4l2loopback, NTFS, and more.
;;
;; linux-cachyos-bore: do not enable ananicy-cpp with BORE.
;;
;; To upgrade: just upgrade-kernel

(define %cachyos-upstream-version "7.1")
(define %cachyos-version "7.1.1")
(define %cachyos-revision "2")
(define %cachyos-tag
  (string-append "cachyos-" %cachyos-version "-" %cachyos-revision))

(define %cachyos-source
  (origin
    (method url-fetch)
    (uri (string-append
          "https://github.com/CachyOS/linux/releases/download/"
          %cachyos-tag "/" %cachyos-tag ".tar.gz"))
    (sha256
     (base32 "1n1zjy5qmpnxjlh7xf3i27l81z9qnhcq55hy9h3j7mcm9yy0fspl"))))

;; BORE variant uses upstream Linux + vanilla bore patch (no pre-patched CachyOS tarball)
;; The bore-cachy patch contains #ifdef CONFIG_CACHY guards that expect the CachyOS
;; kernel tree; when applied to upstream, the context doesn't match. The vanilla
;; bore patch applies cleanly.
(define %cachyos-bore-source
  (origin
    (method url-fetch)
    (uri (string-append
          "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-"
          %cachyos-version ".tar.xz"))
    (sha256
     (base32 "0z8x6wafxzc5vkim9jh8wpycdkk9y5bpxgsirmdpyznw84szl5aj"))
    (patches
     (list
      (origin
        (method url-fetch)
        (uri "https://raw.githubusercontent.com/cachyos/kernel-patches/master/7.1/sched/0001-bore.patch")
        (sha256
         (base32 "1sgzl6qhl9nlxclr8gf8ri1aaw3s4sw46bhwd8rlm50gg1d7xjg4")))))))

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

;; Upstream vanilla Linux has no CONFIG_CACHY (CachyOS tarball only).
(define %cachyos-bore-base-configs
  (filter (lambda (c) (not (string=? c "CONFIG_CACHY=y")))
          %cachyos-base-configs))

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
                       #:base-configs %cachyos-bore-base-configs
                       #:extra-configs '("CONFIG_SCHED_BORE=y")))
