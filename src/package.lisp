(in-package #:cl)
(defpackage #:threading-queue
  (:use #:asdf #:cl #:iterate #:alexandria) ;#:sb-concurrency
  (:export #:make-threading-queue #:make-filled-tq

           #:tq-new-input #:tq-input-vanished
           #:tq-inputs-exhausted?  #:tq-inputs-left

           #:tq-get #:tq-put-list #:tq-put
           #:tq-items

           #:with-tq-pipe #:tq-iter #:iterate-into-tq

           #:threading-feed))
