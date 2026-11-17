(use-modules (ice-9 ftw))

(when (and (pair? (cdr (command-line)))
           (string=? "post" (cadr (command-line))))
  (let* ((devices "/sys/bus/hid/devices")
         (driver "/sys/bus/hid/drivers/hid-multitouch")
         (ids (scandir devices
                       (lambda (name)
                         (string-prefix? "0018:06CB:76AF." name)))))
    (define (write-driver-file name id)
      (call-with-output-file (string-append driver "/" name)
        (lambda (port) (display id port))))
    (unless ids
      (error "touchpad-resume-rebind: cannot read HID device directory" devices))
    (when (null? ids)
      (error "touchpad-resume-rebind: matching touchpad not found" devices))
    (for-each
     (lambda (id)
       (unless (file-exists? (string-append driver "/" id))
         (error "touchpad-resume-rebind: device not bound to hid-multitouch" id))
       (write-driver-file "unbind" id)
       (write-driver-file "bind" id))
     ids)))
