(use-modules (guix build utils)
             (ice-9 textual-ports)
             (srfi srfi-13))

(define root
  (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                          "/touchpad-resume-test.XXXXXX")))
(define devices (string-append root "/devices"))
(define driver (string-append root "/driver"))
(define hook (string-append root "/hook.scm"))
(define error-log (string-append root "/stderr"))
(define id "0018:06CB:76AF.0007")
(define failures 0)

(define (write-file path value)
  (call-with-output-file path (lambda (port) (display value port))))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (replace-once text old new)
  (let ((index (string-contains text old)))
    (unless (and index
                 (not (string-contains text old (+ index (string-length old)))))
      (error "Expected one hook path" old))
    (string-append (substring text 0 index) new
                   (substring text (+ index (string-length old))))))

(define (write-hook device-path)
  (let* ((source (read-file "guix/touchpad-resume.scm"))
         (with-devices (replace-once source "\"/sys/bus/hid/devices\""
                                     (format #f "~s" device-path))))
    (write-file hook
                (replace-once with-devices
                              "\"/sys/bus/hid/drivers/hid-multitouch\""
                              (format #f "~s" driver)))))

(define (run-hook . args)
  (apply system* "sh" "-c" "log=$1; shift; exec \"$@\" 2>\"$log\""
         "touchpad-test" error-log "guile" "--no-auto-compile" hook args))

(define (failed-with? status text)
  (and (not (zero? status))
       (string-contains (read-file error-log) text)))

(define (check condition message)
  (if condition
      (format #t "PASS: ~a~%" message)
      (begin
        (format (current-error-port) "FAIL: ~a~%" message)
        (set! failures (+ failures 1)))))

(dynamic-wind
  (lambda ()
    (mkdir devices)
    (mkdir driver)
    (write-hook devices))
  (lambda ()
    (check (zero? (run-hook "pre" "suspend"))
           "pre-suspend is a no-op")
    (write-file (string-append devices "/" id) "")
    (write-file (string-append devices "/0018:06CB:0001.0001") "")
    (write-file (string-append driver "/" id) "")
    (write-file (string-append driver "/unbind") "untouched")
    (write-file (string-append driver "/bind") "untouched")
    (check (and (zero? (run-hook "pre" "post"))
                (string=? "untouched" (read-file (string-append driver "/unbind")))
                (string=? "untouched" (read-file (string-append driver "/bind"))))
           "only the first hook argument selects post-resume")
    (check (zero? (run-hook "post" "suspend"))
           "a successful post-resume exits successfully")
    (check (and (string=? id (read-file (string-append driver "/unbind")))
                (string=? id (read-file (string-append driver "/bind"))))
           "post-resume rebinds only the matching touchpad")
    (delete-file (string-append driver "/" id))
    (write-file (string-append driver "/unbind") "untouched")
    (write-file (string-append driver "/bind") "untouched")
    (check (failed-with? (run-hook "post" "suspend") "device not bound")
           "a touchpad on another driver is reported")
    (check (string=? "untouched" (read-file (string-append driver "/bind")))
           "a touchpad on another driver is not rebound")
    (delete-file (string-append devices "/" id))
    (check (failed-with? (run-hook "post" "suspend") "matching touchpad not found")
           "a missing touchpad is reported")
    (write-hook (string-append root "/missing"))
    (check (failed-with? (run-hook "post" "suspend") "cannot read HID device directory")
           "a missing device directory is reported")
    (write-hook devices)
    (write-file (string-append devices "/" id) "")
    (write-file (string-append driver "/" id) "")
    (delete-file (string-append driver "/bind"))
    (mkdir (string-append driver "/bind"))
    (check (failed-with? (run-hook "post" "suspend") "/bind")
           "a failed rebind is reported")
    (rmdir (string-append driver "/bind"))
    (write-file (string-append driver "/bind") "untouched")
    (delete-file (string-append driver "/unbind"))
    (mkdir (string-append driver "/unbind"))
    (check (failed-with? (run-hook "post" "suspend") "/unbind")
           "a failed unbind is reported")
    (check (string=? "untouched" (read-file (string-append driver "/bind")))
           "a failed unbind does not trigger a bind"))
  (lambda () (delete-file-recursively root)))

(exit (if (zero? failures) 0 1))
