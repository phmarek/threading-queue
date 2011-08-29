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


(defstruct (threading-queue
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
  "A thread-safe queue, with signalling for end-of-data.
  Relevant functions:
    TQ-GET TQ-PUT TQ-PUT-LIST TQ-ITEMS
    TQ-NEW-INPUT TQ-INPUT-VANISHED
    TQ-ITER WITH-TQ-PIPE ITERATE-INTO-TQ
  There's an ITER clause FROM-TQ, too."
  ;; TODO: make output-count, to provide EPIPE behaviour
  (input-count 1 :type sb-ext:word)
  ;; set by tq-get if no inputs left and stop-symbol encountered.
  (eoq? nil :type (member t nil))
  (mb (make-mailbox)))



;; the lists in this structure get PUSHed, so they are in reverse order.
(defstruct (tq-step)
  ;; this is the input
  definition
  ;; this is the parsed/split input
  settings
  statements
  ;; 0 based number
  index
  ;; these are build from the input above
  vars
  functions
  run-code
  ;; these two are tq-link
  input output)

(defstruct (tq-link
             ;; don't print readers and writers directly, we'd need 
             ;; *print-circle* T
             (:print-function
               (lambda (link stream depth)
                 (declare (ignore depth))
                 (print-unreadable-object (link stream :identity t :type T)
                   (with-slots (name writers readers) link
                     (format stream "name ~a" ; r ~a w ~a"
                             name ;(length readers) (length writers)
                             ))))))
  (name (gensym "Q")) 
  ;; these are tq-step
  writers readers)

#+nil
(defun make-tq-link (&key name writers readers)
  (%make-tq-link
    :name name
    :user-defined-name (not (null name))
    :writers writers
    :readers readers))



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
  (declare (type threading-queue tq))
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
  (declare (type threading-queue tq))
  ;; we're just looking at a few pointers, so no need to lock (?)
  (with-slots (mb eoq?) tq
	(or eoq?
		(and (tq-inputs-exhausted? tq)
			 (mailbox-empty-p mb)))))


(defun tq-put-list (queue data)
  "Takes a single argument, which is a list, and puts
  its elements on the queue."
  (declare (type threading-queue queue))
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
      (for counter from 1)
      (for prev-to-lst previous lst)
      (when (eq (car lst) *internal-stop-sym*)
        (setf (tq-eoq? queue) T)
        (%tq-send-eoq queue)
        (when prev-to-lst
          (setf (cdr prev-to-lst) nil)
          (finish))
        ;; Nothing to cut off, got only (list *internal-stop-sym*)
        (leave (values nil nil)))
      (finally
        ;(Format t "fix-eoq: ~a~%" data)
        (return
          (if data
            (values data counter)
            (values nil nil)))))
    (values data (length data))))


(defun %tq-get-multiple (queue n)
  (with-slots (mb) queue
    (let ((pending (receive-pending-messages mb n)))
      (if pending
        (tq-fix-end-of-queue queue pending)
        ;; Else wait for a (single!) message
        (multiple-value-bind (msg valid) (tq-get queue nil)
          (if valid
            ;; Have to return a list
            (values (list msg) valid)
            (values nil)))))))


(defun tq-get (queue &optional (n nil))
  "Fetches one or more values from the queue.
  For (eq n NIL) only an element, for positive n (even for 1!) a list is returned.
  If n is T, all (currently available!) elements are returned in a list.
  First return value is the end-of-queue symbol if nothing left;
  the second value NIL for end-of-queue, or the number of elements returned."
  ;; TODO: locking and reservation in next queue if strict order needed
  (declare (type threading-queue queue))
  (with-slots (mb eoq?) queue
    (cond
      (eoq?
        (values nil nil))
      ((null n)
       (let ((msg (receive-message mb)))
         (if (eq msg *internal-stop-sym*)
           (progn
             (setf (tq-eoq? queue) T)
             (%tq-send-eoq queue)
             (values nil nil))
           (values msg 1))))
      ((eq n t)
       (%tq-get-multiple queue nil))
      ((plusp n)
       (%tq-get-multiple queue n))
      (t
        (error "non-positive count")))))


(defun make-filled-tq (initial-contents &key (eoq nil))
  "Returns a new threading queue, with initial data."
  (let ((q (make-threading-queue)))
    (tq-put-list q initial-contents)
    (if eoq
      (tq-input-vanished q))
    q))



;;; --------------------------------------------------
;;; Iterate clause and macros
(iterate:defmacro-driver
  (FOR var FROM-TQ tq &optional batch-size batch)
  "Provides a driver for a tq:
  FOR var FROM-TQ tq [BATCH (1+ (random 3))]
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
                               (loop-end nil)
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
                      ,o ,v))
                  ,loop-end)
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
        (error "~s is not allowed here. Valid are~& ~a."
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
    (with-gensyms (res-var eof-var)
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
         `((lambda (&optional (n 1))
             (tq-get ,load-queue-var n)))
         `(#'ignore-args))
     ,@(if store-queue-var
         `((lambda (&rest rest)
             (tq-put-list ,store-queue-var rest))
           (lambda (list)
             (tq-put-list ,store-queue-var list)))
         `(#'ignore-args
           #'ignore-args))))



(defun %make-start-fn (prev-q-n dest stmt-counter opt stmt def)
  (destructuring-bind
    (                  batch-size  call-with-fns  arg-name  at-end  uses-tq  filter)
    (assoc-vals (list :batch-size :call-with-fns :arg-name :at-end :uses-tq :filter) opt)
    (if (and call-with-fns uses-tq)
      (error "~&When using :call-with-fns referencing tqs must be done yourself, :uses-tq not possible; in~& ~s~&" def))
    (if (and call-with-fns batch-size)
      (error "~&:batch-size and :call-with-fns make no sense together, in~& ~s~&" def))
    (if (and stmt call-with-fns)
      (error "~&:call-with-fns must be something callable, and no statements are allowed, in~& ~s~&" def))
    (if (and (not prev-q-n) batch-size)
      (error "~&:batch-size invalid in generator code (first statement), in~& ~s~&" def))
    (if (and filter (or call-with-fns stmt))
      (error "~&:filter is (currently) incompatible with :call-with-fns and other statements, in~& ~a~&" def))
    (let ((fn-name (gensym (format nil "~a-~d-" 'starter stmt-counter))))
      (cond
		(filter
		  (with-gensyms (filter-fn iter-var)
			(list
			  `(,filter-fn (,(intern arg-name))
						   , filter)
			  `(,fn-name ()
						 (with-tq-pipe (,prev-q-n ,dest
												  :batch-size 1
												  :var ,iter-var)
									   (if (,filter-fn (car ,iter-var))
										 ,iter-var))
						 (progn , at-end) ))))
      (call-with-fns
        ;; User wants function called with closures
        (list
          `(,fn-name ()
                     ,(%get-call-w-fns prev-q-n call-with-fns dest)
                     (progn , at-end))))
      (t
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
                         (progn , at-end))))))))))


(defun parse-one-tq-step (defaults ostmt)
  (unless (consp ostmt)
    (error "want a list instead of ~s" ostmt))
  ;;
  ;; Read options
  (multiple-value-bind (opts stmt)
    (parse-options ostmt defaults
                   :aliases +option-aliases+
                   :allowed-keys +per-stmt-options+)
    (make-tq-step
      :definition ostmt
      :settings opts
      :statements stmt)))


(defun %make-tq (var)
  `(,var (make-threading-queue)))


(defun build-code-1-step (step) 
  ;(format t "step ~a~%" step) 
  (with-slots (settings statements index vars functions
                        run-code input output definition) step
    (let* (;; assoc-val default parameter cannot be used, as an
           ;; element with NIL would get used, too
           (user-queue-name (assoc-val :queue-named settings))
           (output-name (or user-queue-name
                            (and output
                                 (tq-link-name output))))
           (fns (%make-start-fn (if input (tq-link-name input))
                                output-name
                                index
                                settings
                                statements
                                definition)))
      (when user-queue-name
        (unless output
          (error "step ~a has no output - :queue-named invalid" step))
        (push `(tq-new-input ,user-queue-name) run-code)
        (setf (tq-link-name output) user-queue-name))
      ;;
      ;; Code block building
      (setf functions (nconc (reverse fns) functions))
      (let ((fn-name (caar (last fns))))
        (push `(new-thread #',fn-name
                           ',fn-name
                           ,(assoc-val :parallel settings)
                           ,(if input (tq-link-name input))
                           ,output-name)
              run-code)))))


(defun all-steps (fn steps)
  (apply #'append 
         (mapcar #'reverse 
                 (mapcar fn
                         (coerce steps 'list)))))


;;; --------------------------------------------------
;;; Main functions
(defun return-code (settings step-list)
  "Build the code returned by threading-feed; the step-list is in correct 
  order."
  (with-gensyms (max-cc-thr-var
                  max-thr-var
                  finished-threads-var
                  thread-count-var)
    `(block ,(assoc-val :named settings)
            (let ((,max-cc-thr-var 0)
                  (,max-thr-var ,(assoc-val :max-concurrent-threads settings))
                  ,finished-threads-var
                  (,thread-count-var (sb-thread:make-semaphore :count 0)))
              (let ,(all-steps #'tq-step-vars step-list)
                (labels
                  ,(all-steps #'tq-step-functions step-list)
                  (declare
                    (inline 
                      ,@(mapcar #'first
                                (all-steps #'tq-step-functions step-list))))
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
                     (new-thread (fn name count prev-queue next-queue)
                                 (iter (for i below (or count 1))
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
                                         nil))
                                     :name (format nil "~a#~d" name i))
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
                    ,@ (all-steps #'tq-step-run-code step-list)
                    , (ensure-list (assoc-val :before-stopping settings))
                    ;; wait for end
                    (concur-set 0)
                    ;; return final data and collect threads
                    (values
                      ,(assoc-val :want-result settings)
                      (mapcar #'sb-thread:join-thread ,finished-threads-var)))))))))


(defun fix-global-options (options) 
  (iter (for key in (list :uses-tq :filter))
    (if (assoc-val key options)
      (error "~&~s may not be used in the global options~&" key)))
  (cons
    ;; this name is only for the first queue valid;
    ;; Set option to NIL, so that statements can set other names,
    ;; but no duplicates variables are generated
    (cons :queue-named nil)
    options))


(defun fix-want-result (steps settings) 
  (let ((want-result (assoc-val :want-result settings)))
    (if (not want-result)
      `nil
      (let ((last-step (aref steps
                             (1- (fill-pointer steps))))
            (name (gensym "RESULT")))
        (setf (tq-step-output last-step)
              (make-tq-link :writers last-step
                            :name name))
        (cond
          ((eq T want-result)
           ;; make an output queue for the last step
           `(tq-get ,name t))
          (t ;; any user-code
            want-result))))))


(defun make-vars (steps)
  (iter (for s in-vector steps)
    (with-slots (input output vars) s
      (when (first-iteration-p)
        (if (and input 
                 (not (find (tq-link-name input)
                            vars
                            :key #'first)))
          (push (%make-tq (tq-link-name input)) vars)))
      (if output
        (push (%make-tq (tq-link-name output)) vars)))))


(defun build-code-blocks (steps)
  (iter (for s in-vector steps)
    (build-code-1-step s)))


(defun setup-initial (result defaults body)
  (iter 
    (for body1 in body)
    (for i from 0)
    (for new-step = (parse-one-tq-step defaults body1))
    (for prev-step previous new-step)
    (setf (tq-step-index new-step) i)
    (if prev-step
      (let ((link-to-next (make-tq-link)))
        (setf (tq-step-output prev-step) link-to-next
              (tq-step-input new-step) link-to-next)))
    (vector-push new-step result)))


(defun fix-first-step (1st-step settings)
  (let* ((initial-contents (assoc-val :initial-contents settings))
         (initial-queue (assoc-val :initial-queue settings))
         (ic-var-user (assoc-val :queue-named settings))
         (init-code (assoc-val :init-code settings))
         (ic-var
           (if (or initial-contents initial-queue)
             (or ic-var-user (gensym "INIT-CONTENTS"))))
         (link (make-tq-link :name ic-var
                             :readers (list 1st-step))))
    ;(format t "glob-def: ~a~%" settings)
    ;;
    ;; Sanity checks
    (if (and initial-contents initial-queue)
      (error "~&:initial-contents is incompatible with :initial-queue."))
    ;;
    (when init-code
      (push
        `(progn
           ;; Make the init-code work, regardless
           ;; whether its (a) or ((a) (b))
           ,@ (if (consp (first init-code))
                init-code
                (list init-code)))
        (tq-step-run-code 1st-step)))
    (when ic-var
      (setf (tq-step-input 1st-step) link)
      (cond
        (initial-queue
          (push `(,ic-var ,initial-queue)
                (tq-step-vars 1st-step))
          (push `(check-type ,ic-var threading-queue)
                (tq-step-run-code 1st-step)))
        (t
          ;; If we have initial contents, we provide an "initial queue" with the data.
          (push `(tq-put-list ,ic-var ,initial-contents) 
                (tq-step-run-code 1st-step))
          ;; TODO: done by :feedback-into ??
          (unless ic-var-user
            (push `(tq-input-vanished ,ic-var)
                  (tq-step-run-code 1st-step))))))
    1st-step))



;;; --------------------------------------------------
;;; Main macro
(defmacro threading-feed (&body body)
  #. +threading-feed-doc+
  ;; TODO: ensure order of elements across user function calls?
  (let* ((step-count (length body))
         (steps+1 (1+ step-count))
         (steps (make-array steps+1
                            :fill-pointer 0
                            :element-type 'tq-step))
         (global-settings
           (parse-options (pop body) +all-options+
                          :aliases +option-aliases+
                          :only-keywords t))
         (defaults (fix-global-options global-settings)))
    ;; make the steps
    (setup-initial steps defaults body)
    ;; fix first and last step
    (fix-first-step (aref steps 0) global-settings)
    (let ((nr (fix-want-result steps global-settings)))
      (push 
        (cons :want-result nr) global-settings))
    ;;
    (build-code-blocks steps)
    (make-vars steps)
    (return-code global-settings steps)))



(defun cpu-count ()
  ; _SC_NPROCESSORS_ONL on linux, amd64
  (osicat-posix:sysconf #x54))
