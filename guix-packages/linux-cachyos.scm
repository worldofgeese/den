(define-module (linux-cachyos)
  #:use-module (gnu packages linux)
  #:use-module (nongnu packages linux)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix utils))

;; CachyOS kernel — pre-patched source from CachyOS/linux repo.
;; Includes: POC scheduler, BBR3, CachyOS tuning, MGLRU improvements,
;; ACS override, ADIOS I/O scheduler, v4l2loopback, NTFS, and more.
;;
;; linux-cachyos: default EEVDF/POC scheduler (CONFIG_SCHED_POC_SELECTOR).
;; linux-cachyos-bore: BORE scheduler variant; do not enable ananicy-cpp with BORE.
;;
;; To upgrade: just upgrade-kernel

(define %cachyos-version "7.0.11")
(define %cachyos-revision "1")
(define %cachyos-tag
  (string-append "cachyos-" %cachyos-version "-" %cachyos-revision))

(define %cachyos-source
  (origin
    (method url-fetch)
    (uri (string-append
          "https://github.com/CachyOS/linux/releases/download/"
          %cachyos-tag "/" %cachyos-tag ".tar.gz"))
    (sha256
     (base32 "0h5a85bjm1aknv32xl4860z6lrwgdby45wlzjgv71449hj82yl32"))))

;; CachyOS PKGBUILD applies this when _cpusched=bore:
;;   ${_patchsource}/sched/0001-bore-cachy.patch
;; where _patchsource=https://raw.githubusercontent.com/cachyos/kernel-patches/master/7.0
(define %cachyos-bore-patch-uri
  "https://raw.githubusercontent.com/cachyos/kernel-patches/master/7.0/sched/0001-bore-cachy.patch")

(define %cachyos-bore-source
  (origin
    (inherit %cachyos-source)
    (patches
     (list
      (origin
        (method url-fetch)
        (uri %cachyos-bore-patch-uri)
        (sha256
         (base32 "0blkpajvndba0dl0lilndbzclbhmsmnjxhlvw1vr6r2mryhf757m")))))))

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
                              (source %cachyos-source))
  (let ((base (customize-linux
               #:name name
               #:linux linux
               #:source source
               #:configs (append %cachyos-base-configs
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
