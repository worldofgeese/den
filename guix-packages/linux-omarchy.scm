(define-module (linux-omarchy)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (nongnu packages linux)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp))

;; Omarchy kernel: the Arch PKGBUILD at
;;   https://github.com/omacom/omarchy-pkgs/tree/master/pkgbuilds/linux-omarchy
;; translated to Guix. Upstream kernel.org tarball + Omarchy's patch stack
;; (BORE, ADIOS, i915 PSR/FBC/panel fixes, mm/btrfs/fuse backports, ...) +
;; Omarchy's config.x86_64, i.e. what `makepkg` does in prepare().
;;
;; Deliberately not carried over from the PKGBUILD:
;;  - the linux-omarchy-nvidia-open subpackage (mahakala is Intel-only);
;;  - Rust: Guix's kernel build has no rustc/bindgen, so CONFIG_RUST is unset
;;    explicitly (Omarchy uses it only for drivers this laptop lacks, e.g. nova).
;;
;; To upgrade: bump %omarchy-pkgs-commit and %omarchy-version to the values in
;; that commit's PKGBUILD, then refresh both hashes (`guix hash -rx` on a
;; checkout of the commit; `guix download` for the kernel tarball).

(define %omarchy-pkgs-commit "6e9361b651309b49b5e9facad2f57dfef3e8062c")
(define %omarchy-pkgs-hash "09myndprvhvl2pn9m8yjqn0n0vjfnvhix0dwwq92gxihyz8p4ny6")
(define %omarchy-version "7.2.15")      ;pkgver in the pinned PKGBUILD
(define %kernel-hash "1aq931l3mn0a3yix7qmkxnr1vxzw9c4afk2wxg57r4sc6bbv3xnh")

(define %omarchy-pkgs
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/omacom/omarchy-pkgs")
          (commit %omarchy-pkgs-commit)))
    (file-name (git-file-name "omarchy-pkgs" (string-take %omarchy-pkgs-commit 7)))
    (sha256 (base32 %omarchy-pkgs-hash))))

(define %omarchy-dir "/pkgbuilds/linux-omarchy")

;; makepkg applies the patches in source=() order with `patch -Np1 --fuzz=0`.
;; In the pinned PKGBUILD that order is exactly the sorted *.patch file names
;; (all are NNNN-prefixed), so apply the sorted directory listing.
(define %omarchy-source
  (origin
    (method url-fetch)
    (uri (string-append "https://cdn.kernel.org/pub/linux/kernel/v"
                        (car (string-split %omarchy-version #\.))
                        ".x/linux-" %omarchy-version ".tar.xz"))
    (sha256 (base32 %kernel-hash))
    (modules '((guix build utils)))
    (snippet
     #~(for-each
        (lambda (p)
          (format #t "Applying patch ~a...~%" (basename p))
          (invoke #+(file-append patch "/bin/patch") "-Np1" "--fuzz=0" "-i" p))
        (sort (find-files #$(file-append %omarchy-pkgs %omarchy-dir)
                          "\\.patch$")
              string<?)))))

;; Omarchy's config.x86_64 is a full .config, and Guix's verify-config phase
;; requires every line of the defconfig to survive `make`. Drop the lines Kconfig
;; recomputes from the toolchain (Omarchy builds with a newer GCC, plus rustc,
;; bindgen) and the Rust-only drivers that vanish once CONFIG_RUST is unset.
(define %omarchy-defconfig
  (computed-file
   "omarchy-defconfig"
   #~(begin
       (use-modules (ice-9 rdelim) (ice-9 regex))
       (define toolchain-derived
         (make-regexp
          (string-append
           "^(# )?CONFIG_(CC_VERSION_TEXT|[A-Z]+_VERSION(_TEXT)?|CC_HAS_[A-Z0-9_]+"
           "|RUSTC?_[A-Z0-9_]+|BINDGEN_[A-Z0-9_]+|DRM_PANIC_SCREEN_QR_[A-Z_]+"
           "|ANDROID_BINDER_IPC_RUST|ANDROID_BINDER_DEVICES)[= ]")))
       (call-with-output-file #$output
         (lambda (out)
           (call-with-input-file
               #$(file-append %omarchy-pkgs %omarchy-dir "/config.x86_64")
             (lambda (in)
               (let loop ((line (read-line in)))
                 (unless (eof-object? line)
                   (unless (regexp-exec toolchain-derived line)
                     (write-line line out))
                   (loop (read-line in)))))))))))

(define-public linux-omarchy
  (let ((base (customize-linux
               #:name "linux-omarchy"
               #:linux linux
               #:source %omarchy-source
               #:defconfig %omarchy-defconfig
               #:configs '("CONFIG_LOCALVERSION=\"-omarchy\""
                           "# CONFIG_RUST is not set"))))
    (package
      (inherit base)
      (version %omarchy-version))))
