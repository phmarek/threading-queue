(in-package :threading-queue)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-concurrency)
  (use-package :sb-concurrency))

;;;
;;; Every queue accepts data as long there's at least one input left.
;;; As long as there's data available the second value it T.
;;; After completely reading the queue the defined stop-symbol is given as
;;; first and NIL as second value.
;;;


(defstruct (%threading-queue
             (:conc-name tq-)
             (:constructor make-threading-queue)
             (:print-function
               (lambda (tq stream depth)
                 (declare (ignore depth))
                 (with-slots (input-count mb eoq?) tq
                   (print-unreadable-object (tq stream :identity t :type nil)
                     (format stream "tq inputs ~a elements ~a eoq? ~a"
                             input-count
                             (mailbox-count mb)
                             eoq?))))))
  (stop-sym *default-stop-sym* :type symbol)
  ;; TODO: make output-count, to provide EPIPE behaviour
  (input-count 1 :type sb-ext:word)
  ;; set by tq-get if no inputs left and stop-symbol encountered;
  (eoq? nil :type (member t nil))
  (mb (make-mailbox)))



;;; --------------------------------------------------
;;; Input count handling
(defun tq-inputs-left (tq)
  (tq-input-count tq))

(defun tq-inputs-exhausted? (tq)
  (zerop (tq-inputs-left tq)))

(defun tq-inputs-left? (tq)
  (not (tq-inputs-exhausted? tq)))

(defun %tq-send-eoq (queue)
  (assert (tq-inputs-exhausted? queue))
  (send-message (tq-mb queue) *internal-stop-sym*))


(defun tq-new-input (tq)
  (sb-ext:atomic-incf (tq-input-count tq)))

(defun tq-input-vanished (tq &optional (n 1))
  (declare (type %threading-queue tq))
  (assert (plusp n))
  (let ((old-val (sb-ext:atomic-decf (tq-input-count tq) n)))
    (cond
      ((= n old-val)
       (%tq-send-eoq tq))
      ((> n old-val)
       (error "input count got negative: ~d" (tq-input-count tq)))
      (t t))))



;;; --------------------------------------------------
;;; Writing into the queue
(defun tq-end-of-queue? (tq)
  (declare (type %threading-queue tq))
  ;; we're just looking at a few pointers, so no need to lock (?)
  (with-slots (mb) tq
    (and (tq-inputs-exhausted? tq)
         (mailbox-empty-p mb))))


(defun tq-put-list (queue data)
  "Takes a single argument, which is a list, and puts
  its elements on the queue."
  (declare (type %threading-queue queue))
  (when data
    (when (tq-inputs-exhausted? queue)
      (error "queue has no inputs left"))
    ;(format t "got ~a to put on queue ~a~%" data queue)
    ;; TODO: locking if strict order needed
    (dolist (d data)
      (send-message (tq-mb queue) d)))
  data)

(defun tq-put (queue &rest data)
  "Takes &rest arguments and puts them on the queue."
  (tq-put-list queue data))


;;; --------------------------------------------------
;;; Reading from the queue
(defun tq-fix-end-of-queue (queue data)
  "In case of a race it's possible that a list of data includes the
  stop-symbol."
  (if (tq-inputs-exhausted? queue)
    (iter (for lst on data)
          (for prev-to-lst previous lst)
          (when (eq (car lst) *internal-stop-sym*)
            (%tq-send-eoq queue)
            (when prev-to-lst
              (setf (cdr prev-to-lst) nil)
              (finish))
            ;; Nothing to cut off, got only (list *internal-stop-sym*)
            (leave (values (tq-stop-sym queue) nil)))
          (finally
            ;(Format t "fix-eoq: ~a~%" data)
            (return
              (if data
                (values data t)
                (values (tq-stop-sym queue) nil)))))
    (values data t)))


(defun %tq-get-multiple (queue n)
  (with-slots (mb stop-sym) queue
    (let ((pending (receive-pending-messages mb n)))
      (if pending
        (tq-fix-end-of-queue queue pending)
        ;; Else wait for a (single!) message
        (multiple-value-bind (msg valid) (tq-get queue nil)
          (if valid
            ;; Have to return a list
            (values (list msg) t)
            (values stop-sym nil)))))))


(defun tq-get (queue &optional (n nil))
  "Fetches one or more values from the queue.
  For (eq n NIL) only an element, for positive n (even for 1!) a list is returned.
  If n is T, all (currently available!) elements are returned in a list.
  First return value is the end-of-queue symbol if nothing left;
  the second value is T for data or NIL for end-of-queue."
  ;; TODO: locking and reservation in next queue if strict order needed
  (declare (type %threading-queue queue))
  (with-slots (mb stop-sym eoq?) queue
    (cond
      (eoq?
        (values stop-sym nil))
      ((null n)
       (let ((msg (receive-message mb)))
         (if (eq msg *internal-stop-sym*)
           (progn
             (%tq-send-eoq queue)
             (values stop-sym nil))
           (values msg t))))
      ((eq n t)
       (%tq-get-multiple queue nil))
      ((plusp n)
       (%tq-get-multiple queue n))
      (t
        (error "non-positive count")))))



;;; --------------------------------------------------
;;; Iterate clause and macros
(iterate:defmacro-driver
  (FOR var FROM-tq tq &optional batch-size batch)
  "Provides a driver for a tq:
  FOR var FROM-tq tq [BATCH (1+ (random 3))]
  The batch size should either be NIL (to get single elements) or
  a positive integer (to get a list); gets evaluated every time."
  (with-gensyms (tq-var res valid)
    `(progn
       (with ,tq-var = ,tq)
       (,(if iterate:generate 'generate 'for)
         ,var next
         (multiple-value-bind (,res ,valid) (tq-get ,tq-var ,batch)
           (while ,valid)
           ,res)))))

(defmacro tq-iter ((tq varname
                         &key batch-size
                         (clause 'collecting)) &body body)
  "Builds a loop, giving a variable 'varname' to body with elements
  from the queue.
  The results of body are collected as output.
  'batch-size' is evaluated before each call;
  'clause' can be NCONCING, COLLECTING, or PROGN."
  (assert (member clause '(collecting nconcing progn)))
  `(iter
     (for ,varname from-tq ,tq batch-size ,batch-size)
     (,clause
       (progn ,@ body))))


(defmacro tq-items (tq &optional (fn ''identity))
  (with-gensyms (q e)
    `(iter
       (with ,q = ,tq)
       (for ,e from-tq ,q)
       (collecting (funcall ,fn ,e)))))


(defmacro with-tq-pipe ((input output &key
                                (var '*)
                                (batch-size nil)
                                (put-list (not (null batch-size))))
                         &body body)
  (with-gensyms (i o v)
    `(let ((,i ,input)
           (,o ,output))
       (if ,o
         (tq-new-input ,o))
       (unwind-protect
         (tq-iter (,i ,var
                       :batch-size ,batch-size
                       :clause progn)
                   (for ,v = (progn ,@ body))
                   (if ,o
                     (,(if put-list 'tq-put-list 'tq-put)
                       ,o ,v)))
         (if ,o
           (tq-input-vanished ,o))))))


(defmacro iterate-into-tq ((destination &key gives-list) &body body)
  "Runs body while the first or second value are not NIL;
  stores the first values into the queue.
  So the second value is just used to store NILs, too (like gethash).
  :gives-list T means that every call returns a list of entries to add
  (and the flag - if needed - too)."
  (with-gensyms (valid var)
    `(progn
       (tq-new-input ,destination)
       (unwind-protect
         (iter
           (multiple-value-bind (,var ,valid) (progn ,@ body)
             (while (or ,var ,valid))
             (,(if gives-list 'tq-put-list 'tq-put)
               ,destination ,var)))
         (tq-input-vanished ,destination)))))


;;; --------------------------------------------------
;;; Option handling
(defun assoc-val (key list &optional default)
  (let ((c (assoc key list)))
    (if c
      (cdr c)
      default)))

(defun assoc-vals (keylist list)
  "keylist can have (key default) pairs"
  (iter (for %k in keylist)
        (for (key default) = (if (consp %k) %k (list %k)))
        (collecting (assoc-val key list default))))


;; TODO: make the option parsing prettier
;; We need to parse statement options, and provide the global defaults for them
;; we need to parse global options, and allow statement values
(defun parse-options (input defaults &key
                            (allowed-keys (mapcar #'car defaults))
                            aliases only-keywords)
  "Returns an ALIST and the rest of data."
  (iter (with result-alist = defaults)
        (for input-cons on input by #'cddr)
        (for input-key = (car input-cons))
        (for aliased-key = (assoc-val input-key aliases input-key))
        (if (keywordp input-key)
          (if (member aliased-key allowed-keys)
            (push (cons aliased-key (cadr input-cons)) result-alist)
            (error "~s is not allowed here. Valid are ~a."
                   aliased-key
                   (remove-duplicates
                     (append allowed-keys (mapcar #'car aliases)))))
          ;; non-keyword
          (if only-keywords
            (error "no non-keywords allowed")
            (leave
              (values result-alist input-cons))))
        (finally
          (return
            (values result-alist (cddr input-cons))))))



;;; --------------------------------------------------
;;; Helper functions
(defun %translate-known-functions (body)
  "Some well-known functions have the \"wrong\" return codes for this call.
  While GETHASH returns T as second value if valid, READ-LINE
  returns T for EOF (in some circumstances).
  Try to guess a few well-known things."
  (if (member (first body) *reverse-2nd-value*)
    (let ((res-var (gensym))
          (eof-var (gensym)))
      `(multiple-value-bind (,res-var ,eof-var) ,body
         (if ,eof-var
           (values nil nil)
           (values ,res-var ,res-var))))
    body))

(defun %make-stmt-fn (statement name make-* id)
  (let* ((fn-name (gensym (format nil "~a-~d-" 'func id)))
         (caller-* (find (string name)
                         (alexandria:flatten statement)
                         :test #'equal
                         :key (lambda (x) (if (symbolp x) (symbol-name x)))))
         (surely-* (or caller-* (intern *default-arg-name*)))
         (body-with-* (if (or caller-*
                              (not make-*)
                              ;; don't put the argname there if there are
                              ;; multiple statements.
                              (consp (first statement)))
                        statement
                        (append statement (list surely-*))))
         (return-value-fixed (if make-*
                               body-with-*
                               (%translate-known-functions body-with-*))))
    `(,fn-name ,(if make-* `(,surely-*) ())
               ,@(if (consp (first return-value-fixed))
                   return-value-fixed
                   (list return-value-fixed)))))


(defun ignore-args (&rest rest)
  (declare (ignore rest))
  (values nil nil))

(defun %get-call-w-fns (load-queue-var fn store-queue-var)
  `(,fn
     ,@(if load-queue-var
         `(lambda (&optional (n 1))
            (tq-get ,load-queue-var n))
         `(#'ignore-args))
     ,@(if store-queue-var
         `((lambda (&rest rest)
             (tq-put-list ,store-queue-var rest))
           (lambda (list)
             (tq-put-list ,store-queue-var list)))
         `(#'ignore-args
           #'ignore-args))))



(defun %make-start-fn (prev-q-n dest stmt-counter opt stmt)
  (destructuring-bind
    (                  batch-size  call-with-fns  arg-name  at-end  uses-tq)
    (assoc-vals (list :batch-size :call-with-fns :arg-name :at-end :uses-tq) opt)
    (if (and call-with-fns uses-tq)
      (error "~&When using :call-with-fns referencing tqs must be done yourself, :uses-tq not possible; in~& ~a~&" stmt))
    (if (and call-with-fns batch-size)
      (error "~&:batch-size and :call-with-fns make no sense together, in~& ~a~&" stmt))
    (if (and (not prev-q-n) batch-size)
      (error "~&:batch-size invalid in generator code (first statement), in~& ~a~&" stmt))
    (let ((fn-name (gensym (format nil "~a-~d-" 'starter stmt-counter))))
      (if call-with-fns
        ;; User wants function called with closures
        (list
          `(,fn-name ()
                     ,(%get-call-w-fns prev-q-n call-with-fns dest)
                     (progn , at-end)))
        ;; User wants to process items like via mapcon
        (let ((iter-var (gensym "ITER"))
              (user-code (%make-stmt-fn stmt arg-name prev-q-n stmt-counter)))
          (list
            ;; Function wrapping user code
            user-code
            ;; Function calling it
            (let* ((tq-use-list (if (listp uses-tq) uses-tq (list uses-tq)))
                   (tq-vars (mapcar #'gensym (mapcar #'symbol-name tq-use-list))))
              `(,fn-name ()
                       (let ,(if tq-use-list
                               (mapcar #'list tq-vars tq-use-list))
                         ;; |3b| had the great idea of using curry
                         ,@ (mapcar (curry 'list 'tq-new-input) tq-vars)
                         ,(if prev-q-n
                            ;; queue to queue
                            `(with-tq-pipe (,prev-q-n
                                              ,dest
                                              :batch-size ,batch-size
                                              :var ,iter-var)
                                            (,(first user-code) ,iter-var))
                            ;; function into queue (first input step)
                            `(iterate-into-tq (,dest)
                                               (,(first user-code))))
                         ,@ (mapcar (curry 'list 'tq-input-vanished) tq-vars))
                       (progn , at-end)))))))))



;;; --------------------------------------------------
;;; Main macro
(defmacro threading-feed (&body steps)
  ;; TODO: ensure order of elements across user function calls?
  ;; :name 'A, :wait-for 'A
  ;; :use-stop-symbol (gensym)
  (let* ((global-defaults
           (parse-options (pop steps) +all-options+
                          :aliases +option-aliases+
                          :only-keywords t))
         (max-cc-thr-var (gensym "MAX-CONCUR-THR"))
         (thread-count-var (gensym "THR-COUNT"))
         (finished-threads-var (gensym "FINI"))
         (stop-marker-var (gensym "STOP-MARKER"))
         (max-thr-var (gensym "MAX-THREADS"))
         (m-tq-expr `(make-threading-queue :stop-sym ,stop-marker-var))
         (initial-contents (assoc-val :initial-contents global-defaults))
         (ic-var-user (assoc-val :queue-named global-defaults nil))
         (ic-var
           (if initial-contents
             (or ic-var-user (gensym "INIT-CONTENTS")))))
    ;(format t "glob-def: ~a~%" global-defaults)
    ;; this name is only for the first queue valid;
    ;; set to NIL, so that other statements can set values,
    ;; but no duplicates variables are generated
    (if (assoc-val :uses-tq global-defaults)
      (error "~&:uses-tq may not be used in the global options~&"))
    (push (cons :queue-named nil) global-defaults)
    ;;
    ;; For each step, parse options and build the code.
    (iter
      (when (first-iteration-p)
        (when ic-var
          ;; If we have initial contents, we provide an "initial queue" with the data.
          ;; Sadly (collecting) doesn't work in (initially).
          (collecting `(,ic-var ,m-tq-expr)
                      into vars)
          (collecting `(tq-put-list ,ic-var ,initial-contents)
                      into code)
          (unless ic-var-user
            (collecting `(tq-input-vanished ,ic-var)
                        into code)))
        (let ((init-code (assoc-val :init global-defaults)))
          (when init-code
            (collecting
              `(progn
                 ;; Make the init-code work, regardless
                 ;; whether its (a) or ((a) (b))
                 ,@ (if (consp (first init-code))
                      init-code
                      (list init-code)))
              into code))))
      ;;
      ;; Get statements
      (for %stmt = (pop steps))
      (unless (consp %stmt)
        (error "want a list instead of ~a" %stmt))
      (for stmt-counter from 1)
      ;;
      ;; Read options
      (for (values stmt-options stmt) =
           (parse-options %stmt global-defaults
                          :aliases +option-aliases+
                          :allowed-keys +per-stmt-options+))
      ;(format t "def at ~d: ~a~%    ~a~%" stmt-counter stmt-options stmt)
      (for want-result =
           (or steps ; steps is here already changed (POP above), so no CDR
               (assoc-val :want-result global-defaults)))
      ;;
      ;; Other, per-statement, values
      (for user-queue-name = (assoc-val :queue-named stmt-options))
      (if (and user-queue-name
               ;; on the first iteration the initial-queue
               (not (first-iteration-p)))
        (collecting `(tq-new-input ,user-queue-name)
                    into code))
      (for queue-name =
           ;; assoc-val default parameter cannot be used, as an
           ;; element with NIL would get used, too
           (or user-queue-name
               (gensym "QUEUE")))
      (for prev-queue-name previous queue-name
           initially ic-var)
      ;;
      ;; Code block building
      (for destination = (if want-result queue-name))
      (for fns = (%make-start-fn prev-queue-name destination stmt-counter stmt-options stmt))
      (appending fns into functions)
      (if destination
        (collecting `(,destination ,m-tq-expr) into vars))
      ;; we use a semaphore because we don't need to handle a lock ourselfes
      (collecting
        `(new-thread #',(caar (last fns))
                     ,(assoc-val :parallel stmt-options)
                     ,prev-queue-name
                     ,destination)
        into code)
      ;;
      ;;
      (while steps)
      ;;
      ;; Result generation
      (finally
        (return
          `(let ((,max-cc-thr-var 0)
                 (,stop-marker-var ,(assoc-val :stop-marker global-defaults))
                 (,max-thr-var ,(assoc-val :max-concurrent-threads global-defaults))
                 ,finished-threads-var
                 (,thread-count-var (sb-thread:make-semaphore :count 0)))
             ;; the tqs depend on stop-marker-var
             (let , vars
               (labels
                 , functions
                 (declare (inline ,@(mapcar #'first functions)))
                 ;; TODO: lower functions, upper functions & flet?
                 ;; the statements given by the user shouldn't see those labels -
                 ;; but our lambdas want to reference other lambdas, so we cannot use flet.
                 ;; TODO: make normal functions? We'd have to pass a lot
                 ;; of data, or use special variables ...
                 (labels
                   ((chg-thr-count (delta)
                                   (declare (type fixnum delta))
                                   ;; negative means more threads allowed (less active)
                                   (cond
                                     ((minusp delta)
                                      (sb-thread:signal-semaphore ,thread-count-var (- delta)))
                                     ((plusp delta)
                                      (iter (repeat delta)
                                            (sb-thread:wait-on-semaphore ,thread-count-var)))))
                    (concur-set (to)
                                (chg-thr-count (- ,max-cc-thr-var to))
                                (setf ,max-cc-thr-var to))
                    (new-thread (fn count prev-queue next-queue)
                                (iter (repeat (or count 1))
                                      ;; todo: first thread doesn't increment
                                      ;; input+output count, so that the main
                                      ;; thread doesn't need to decrement again
                                      (chg-thr-count 1)
                                      (if next-queue
                                        (tq-new-input next-queue))
                                      (sb-thread:make-thread
                                        (lambda ()
                                          (unwind-protect (funcall fn)
                                            (push sb-thread:*current-thread* ,finished-threads-var)
                                            (chg-thr-count -1)
                                            (if next-queue
                                              (tq-input-vanished next-queue))
                                            nil)))
                                      ;; stop creating threads if there's
                                      ;; nothing more to do
                                      ;; TODO: in case of "upwards" injection
                                      ;; we have to create all threads
                                      (until (and prev-queue
                                                  (tq-end-of-queue? prev-queue))))
                                ;; Now remove the initial 1 from the semaphore
                                (if next-queue
                                  (tq-input-vanished next-queue))))
                   (assert (plusp ,max-thr-var))
                   (concur-set ,max-thr-var)
                   ,@ code
                   ;; wait for end
                   (concur-set 0)
                   ;; return final data and collect threads
                   (values
                     ,(if destination
                        `(tq-get ,destination t)
                        `nil)
                     (mapcar #'sb-thread:join-thread ,finished-threads-var)))))))))))


