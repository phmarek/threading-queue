;; Generated file, do not edit!!

(in-package :threading-queue)

(define-constant +all-options+ (list
	;; global
	(cons :initial-contents NIL)
	(cons :max-concurrent-threads 512)
	(cons :want-result T)
	;; per-step
	(cons :parallel NIL)
	(cons :arg-name *DEFAULT-ARG-NAME*)
	(cons :batch-size NIL)
	(cons :at-end T)
	(cons :queue-named NIL)
	(cons :call-with-fns NIL)
	)
	:test #'equal :documentation "
	Global options:
	
	** :initial-contents: This expression is evaluated once, and specifies the elements that get fed into the first step.
If this is not specified, the first step will be called until it returns NIL; a verbatim NIL element can be inserted into the queue by returning a non-NIL second value.
	** :max-concurrent-threads: =for comment (floor MOST-POSITIVE-FIXNUM 3)
The maximum number of simultaneously running threads.
	** :want-result: If this is T (the default), the return values of the last step are accumulated and returned.
For NIL only a single NIL is returned; this is useful if the side-effects of the process are important.
Any expression can be used here; eg. C<(progn (+ 2 2))> is valid, and makes the first value returned from C<threading-queue> be 4.
	
	Per-step options:
	
	** :parallel: How many threads should be allocated for this step?
This is an upper limit; if there's no input left, no additional threads will be started.
	** :arg-name: This symbol gets used as argument for the generated functions; the default is C<*>, see the example above.
	** :batch-size: If you want to handle multiple elements at once, you can give this option a positive fixnum.
Ie. if C<:batch-size 3> the step will get a list with up to 3 elements each time it is called; and the return value B<must> be a list, although it can consist of more or fewer elements.
Using C<:batch-size 1> will give you (and expect) lists, too!
Only with NIL you get and return singular elements.
	** :at-end: This specifies the code that gets run at the end of each thread; the returned values are accumulated into the second value of C<THREADING-FEED>.
	** :queue-named: Normally the queue variable names are generated via GENSYM; with this option the queue that passed data further down can be given a name.
This is useful if you want to back-inject values (to get a kind of loop), or to return a queue, to pass it to other functions.
If this is used in the global options, the C<:initial-contents>-queue gets a name.
Please note that you need to care about the input-reference-counting yourself; one input reference is kept for named queues, and you must clean that up via C<tq-input-vanished>.
	** :call-with-fns: This option takes a lambda that gets called with three parameters: a closure to read from the input queue (with an optional count parameter, see :batch-size above), a closure that puts all its parameters onto the output queue, and a closure that puts the list it gets as first parameter onto the output queue.
If this is used, no other statements might be given.
  (threading-feed ()
    ...
    (:call-with-fns
      (lambda (qget qput-rest qput-list)
        (declare (ignore qput-list))
        (iter (for (values items valid) = (funcall qget 3))
              (while valid)
              (funcall qput-rest (apply #'+ items)))))))
The example takes up to 3 numbers from the input queue, and passes their sum to the output queue.
Please note the check for end-of-queue (via the valid variable).
The C<:parallel> option is still available, and the end-on-output-queue signalling is automatically done.
	")


(define-constant +per-stmt-options+ '(
	:parallel :arg-name :batch-size :at-end :queue-named :call-with-fns)
	:test #'equal)

(define-constant +option-aliases+ '(
	(:threads . :parallel))
	:test #'equal)

(define-constant +threading-feed-doc+
"# vim: et sw=2 ts=2 lisp autoindent nowrap fo= :
Threading Queue - splitting work across several threads
  (threading-feed
    (:initial-contents '(1 2 3 4 5))
      (:parallel 3
         (sleep 1)
         *)
      (format t \"output single-threaded: ~a~%\" *)
      (:parallel 2
         (format t \"output multi-threaded: ~a~%\" *)))
This Common Lisp library provides an easy way to split work over several workers.
Elements are returned with a second value of C<T>, so a C<NIL> will come out as C<(values NIL T)>.
As soon as a queue is empty it returns C<(values NIL NIL)>, and won't call your code anymore.
This is similar to the C<gethash> function.
There are several options that can be set globally and per-step.
Using per-step options in the global sections makes them defaults for the individual steps.
Please see +all-options+ for more information about the options; the small reminder list is
	:initial-contents :initial-queue :max-concurrent-threads :want-result :parallel :arg-name :batch-size :at-end :queue-named :call-with-fns"
	:test #'equal)

