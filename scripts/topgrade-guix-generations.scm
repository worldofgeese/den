(use-modules (guix config)
             (guix profiles)
             (guix ui)
             (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-13))

(define profile
  (match (command-line)
    ((_ "package") %current-profile)
    ((_ "home") (string-append %profile-directory "/guix-home"))
    ((_ "system") (string-append %state-directory "/profiles/system"))
    (_ (error "expected a package, home, or system profile"))))

(unless (file-exists? profile)
  (error "Guix profile does not exist" profile))

(let* ((current (generation-number profile))
       (old (matching-generations "2w" profile #:duration-relation >))
       (removable (delv current old)))
  (display (string-join (map number->string removable) ",")))
