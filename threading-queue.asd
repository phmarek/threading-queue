#-sbcl
(error "Sorry, currently only with SBCL.")


(defpackage #:threading-queue-system
         (:use :common-lisp :asdf))

(in-package #:threading-queue-system)

(defsystem #:threading-queue
           :description "Threading-feed macro for splitting work across threads"
           ; :version "0.2"
           :author "philipp@marek.priv.at"
           :licence "LLGPL"
           :pathname "src"
           :components ((:file "package")
                        (:file "prereq")
                        (:file "options")
                        (:file "threading-queue"))
           :serial T
		   :depends-on (alexandria iterate sb-concurrency))


