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
;; To upgrade: just upgrade-kernel

(define %cachyos-version "7.0.6")
(define %cachyos-revision "2")
(define %cachyos-tag
  (string-append "cachyos-" %cachyos-version "-" %cachyos-revision))

(define-public linux-cachyos
  (let ((base (customize-linux
               #:name "linux-cachyos"
               #:linux linux
               #:source
               (origin
                 (method url-fetch)
                 (uri (string-append
                       "https://github.com/CachyOS/linux/releases/download/"
                       %cachyos-tag "/" %cachyos-tag ".tar.gz"))
                 (sha256
                  (base32 "12a6l6vrmlgdqkh5gllslra607kvkzzlarjnbs2mix03rxxyf7bf")))
               #:configs '("CONFIG_CACHY=y"
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
                           "# CONFIG_USB_MOUSE is not set"
                           "CONFIG_LOCALVERSION=\"-cachyos\""))))
    (package
      (inherit base)
      (version %cachyos-version))))
