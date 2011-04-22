#-sbcl
(error "Sorry, currently only with SBCL.")


(defpackage #:threading-queue-system
         (:use :common-lisp :asdf))

(in-package #:threading-queue-system)

(defpackage #:threading-queue
  (:use #:asdf #:cl #:iterate #:alexandria) ;#:sb-concurrency
  (:export #:make-threading-queue
           #:tq-new-input
           #:tq-input-vanished
           #:tq-inputs-exhausted?
           #:tq-inputs-left
           #:tq-get
           #:tq-put-list
           #:tq-put
           #:with-tq-pipe
           #:tq-iter
           #:tq-items
           #:iterate-into-tq
           #:threading-feed)
  (:nicknames #:tq))

(defsystem #:threading-queue
           :description "Threading-feed macro for splitting work across threads"
           ; :version "0.2"
           :author "philipp@marek.priv.at"
           :licence "LLGPL"
           :pathname "src"
           :components ((:file "prereq")
                        (:file "options")
                        (:file "threading-queue"))
           :serial T
		   :depends-on (alexandria iterate ;sb-concurrency
                                  ))
