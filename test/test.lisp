(eval-when (:execute :compile-toplevel :load-toplevel)
  (asdf:oos 'asdf:load-op :threading-queue))

(defpackage #:threading-queue-test
  (:use #:asdf #:cl #:threading-queue #:alexandria #:iterate)
  (:nicknames #:tqt))

(in-package #:threading-queue-test)

(eval-when (:execute :compile-toplevel :load-toplevel)
  (defmacro X (exp &body body)
    (with-gensyms (res)
      `(let ((,res (multiple-value-list ,@ body)))
         (format t "~&~a~%" ,res)
         (assert (equal ,res ',exp)))))
    ;(setf *print-circle* t)
    )


;; test tq-input-vanished
(let* ((q (make-threading-queue))
       (thr (sb-thread:make-thread
              (lambda ()
                (sleep 0.6)
                (tq-input-vanished q)))))
  (tq-put q 1 2 3)
  (X (1 T)     (tq-get q))
  (X ((2 3) T) (tq-get q 3))
  (X (NIL NIL) (tq-get q))
  (sb-thread:join-thread thr)
  q)


;; basic tests
(let* ((q (make-threading-queue))
       (thr (sb-thread:make-thread
              (lambda ()
                (sleep 0.6)
                (tq-put q 'end)
                (tq-input-vanished q)))))
  (tq-put q 1 2 3 4 5)
  (X (1 T)                     (tq-get q))
  (tq-put q 6 7)
  (X ((2 3 4) T)               (tq-get q 3))
  (tq-put q (cons 8 9) 10 11)
  (X ((5 6) T)                 (tq-get q 2))
  (X (7 T)                     (tq-get q))
  (X ((8 . 9) T)               (tq-get q))
  (X (10 T)                    (tq-get q))
  (X (11 T)                    (tq-get q))
  (X (end T)                   (tq-get q))
  (X (NIL NIL)                 (tq-get q))
  (sb-thread:join-thread thr)
  q)


;; test for element safety (nothing lost)
(let ((q (make-threading-queue))
      (up-to 200000))
  (sb-thread:make-thread
    (lambda ()
      (sleep 0.3)
      (iter (for i from 0 below up-to)
            (tq-put q i))
      (tq-input-vanished q)))
  (iter (for expect from 0)
        (for (v valid) = (multiple-value-list (tq-get q)))
        (while valid)
        (unless (eql v expect)
          (format t "unexp ~a ~a ...  ~a~%" v valid expect)
          (leave nil)
          (finally
            (format t "expect ~a, should be ~a~%" expect up-to)))))


;; test that no elements get lost, even for multiple writer and reader threads
(let* ((q (make-threading-queue))
       (res nil)
       (soll nil)
       (max 20000)
       (max-thr 8)
       (m (sb-thread:make-mutex))
       (w-threads
         (iter (for tn from 0 below max-thr)
               (collecting
                 (let ((tn tn))
                   (sb-thread:make-thread
                     (lambda ()
                       (tq-new-input q)
                       (sleep 0.1)
                       (let ((list (iter (for i from tn below max by max-thr)
                                         (tq-put q i)
                                         (sleep 0.00001)
                                         (collecting i))))
                         (sb-thread:with-mutex (m)
                                               (setf soll
                                                     (nconc list soll))))
                       (tq-input-vanished q))))))))
  (tq-input-vanished q)
  ;(assert (every #'numberp soll))
  ;; if this join is done *after* fetching elements some of them are lost.
  ; (mapcar #'sb-thread:join-thread w-threads)
  ;;
  ;; We read the queue; each thread collects a list of values, and these
  ;; are joined as returned by join-thread.
  (setf res
        (apply #'append
               (mapcar
                 #'sb-thread:join-thread
                 (iter (repeat max-thr)
                       (collecting
                         (sb-thread:make-thread
                           (lambda ()
                             (format t "started ~a~%" sb-thread:*current-thread*)
                             (tq-iter (q v)
                                            (unless (numberp v)
                                              (print v)
                                              (assert nil))
                                            v))))))))
  (mapcar #'sb-thread:join-thread w-threads)
  ;(format t "soll: ~a~%res: ~a~%" soll res)
  (let* ((s (sort res #'>))
         (n (length (remove-duplicates s)))
         (miss (set-difference s soll)))
    (format t "~a elements; diff ~a~%" n miss)
    (X (nil) miss)))


;; test iter clause
(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X ((1 2 3))
     (iter (for a from-tq q)
           (collecting a))))

;; test tq-iter
(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X ((1 2 3))
     (tq-iter (q v)
               v)))

(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X ((2 3 4))
     (tq-iter (q v)
               (1+ v))))

(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X (())
     (tq-iter (q v :clause progn)
               v)))

(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X (((1 2) (3)))
     (tq-iter (q v :batch-size 2)
               v)))

(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X ((1 2 3))
     (tq-iter (q v :batch-size 2 :clause nconcing)
               v)))


;; test tq-items
(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X ((1 2 3))
     (tq-items q)))

(let* ((q (make-threading-queue)))
  (tq-put q 1 2 3)
  (tq-input-vanished q)
  (X ((2 3 4))
     (tq-items q #'1+)))


;; test parse-options
(X (((:B . 2) (:A . 1) (:A . A) (:B . B))
    ())
   (threading-queue::parse-options (list :a 1 :b 2 )
                                   '((:a . a) (:b . b))))

(X (((:B . 2) (:A . 1) (:A . A) (:B . B))
    (x))
   (threading-queue::parse-options (list :a 1 :b 2 'x)
                                   '((:a . a) (:b . b))))

(X (((:A . A) (:B . B))
    (y))
   (threading-queue::parse-options (list 'y)
                                   '((:a . a) (:b . b))))


(X (((:A . 1) (:A . A) (:B . B))
    nil)
   (threading-queue::parse-options (list :a 1) '((:a . a) (:b . b))
                                   :allowed-keys '(:a :b)))

(X (((:A . 1) (:d . d) (:e . e))
    nil)
   (threading-queue::parse-options (list :c 1) '((:d . d) (:e . e))
                                   :aliases '((:c . :a))
                                   :allowed-keys '(:a :b)))

;; test with-tq-pipe
(X ((2 4 6) T)
   (let ((i (make-threading-queue))
         (o (make-threading-queue)))
     (tq-put-list i '(1 -1 3 -1 5 -1))
     (tq-input-vanished i)
     (with-tq-pipe (i o :batch-size 2 :var X :put-list nil)
                    (1+ (first X)))
     (tq-get o t)))


; test iterate-into-tq
(let ((q (make-threading-queue))
      (i (list 1 2 3 4 5)))
  (iterate-into-tq (q)
                    (pop i))
  (X ((1 2 3 4 5) t)  ; the T is "data available"
       (tq-get q t)))

(let ((q (make-threading-queue))
      (i (list '(1 2) '(3) '() '(4 5 6))))
  (iterate-into-tq (q :gives-list t)
                    ; so that the NIL in the middle is not end-of-data
                    (values (pop i) i))
  (X ((1 2 3 4 5 6) t)
     (tq-get q t)))



;; test threading-feed
(X ((1 2 3 4 5 6 7 8) (T))
   (threading-feed (:initial-contents '(1 2 3 4 5 6 7 8))
                     ((identity *))))


(X ((2 3 TT 5 6 7 8) (T T))
   (threading-feed (:initial-contents '(2 3 TT 5 6 7 8))
                   (identity *)
                   (identity *)))


(X (() (T T))
   (threading-feed (:initial-contents '(1 2 3 4 5 6 7 8)
                                      :want-result nil)
                   (identity *)
                   ((identity *))))



(let* ((i 99)
       (fn (lambda (e) (list (cons e 2) (cons (decf i) e)))))
  (X ((1 2 3 4 5 6 7 8) (T T T T))
     (threading-feed (:initial-contents '(1 2 3 4 5 6 7 8))
                     (funcall fn)
                     ((format t "~&got ~a" *)
                      *)
                     (caar)
                     (print))))

;; test :max-concurrent-threads
;; the actual number of started threads may differ
(let ((tl nil))
  (X ((11100 11101 11102 11103 11104 11105 11106 11107 11108 11109))
     (values
       (threading-feed (:initial-contents '(0 1 2 3 4 5 6 7 8 9)
                                          :parallel 10
                                          :max-concurrent-threads 1)
                       ((push (list * 'A) tl) (sleep 0.1) (+ *   100))
                       ((push (list * 'B) tl) (sleep 0.1) (+ *  1000))
                       ((push (list * 'C) tl) (sleep 0.1) (+ * 10000)))))
  (let ((nums (mapcar #'first tl)))
    (assert (equal nums (sort (copy-list nums) #'>)))))


;; Test thread creation (number of threads)
(X ((1) (T T T T T T T T T T T T T T T))
   (threading-feed (:initial-contents '(1) :parallel 3)
                   ;; make sure that all threads are started
                   (:parallel 1 (sleep 1) *)
                   (identity)
                   ;(:parallel 1 (sleep 1) (terpri) (terpri) *)
                   (:parallel 5 (print *))
                   ;(:parallel 1 (sleep 1) (terpri) (terpri) *)
                   (identity)
                   ;(:parallel 1 (sleep 1) (terpri) (terpri) *)
                   (identity)
                   ;(:parallel 1 (sleep 1) (terpri) (terpri) *)
                   ))

;; test that as few threads as needed are made
(multiple-value-bind
  (res thr)
  (threading-feed (:initial-contents '(1) :parallel 3000)
                  (identity)
                  (identity))
  (let ((c (length thr)))
    (format t "got ~d threads~%" c)
    (X ((1)) res)
    (assert (< c 3000))
    (assert (> c 2))))


;; test read-* translations
(with-input-from-string (input "6 7 8 9")
  (X ((7 8 9 10) (T T))
     (threading-feed ()
                     (read input nil nil)
                     (1+))))


;; test :call-with-fns
(X ((:xa :xs :xd :xf :xg :xh :xj) (T T T T))
   (threading-feed ()
       (:call-with-fns
         (lambda (qget qput-rest qput-list)
           (declare (ignore qget qput-list))
           (with-input-from-string (input "a s d f g h j")
             (iter (for line = (read input nil nil))
                   (while line)
                   (funcall qput-rest line)))))
       (symbol-name)
       (concatenate 'string "X" *)
       (intern * 'keyword)))


;; test :want-result
(X (nil (T))
   (threading-feed (:initial-contents '(1 2 3) :want-result nil)
                   (identity)))
(X (4 (T))
   (threading-feed (:initial-contents '(1 2 3) :want-result (progn (+ 2 2)))
                   (identity)))



;; test :queue-named
(X ((g h i) (T))
   (threading-feed
     (:initial-contents '(g h i)
                        :want-result (progn
                                       (tq-input-vanished foo)
                                       (tq-items foo)))
     (:queue-named foo (identity *))))


;; test :queue-named and :want-result
(X (("G" "H" "L"))
   (let ((tq
           (threading-feed
             (:initial-contents '(g h l)
                                :want-result foo)
             (:queue-named foo
                           (symbol-name *)))))
     (tq-input-vanished tq)
     (tq-items tq)))


;; test :initial-queue
(let ((iq (make-filled-tq  '(a d g) :eoq T)))
  (X ((a d g) (T))
     (threading-feed (:initial-queue iq)
                     (identity))))
