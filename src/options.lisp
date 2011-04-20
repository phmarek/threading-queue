;; Generated file, do not edit!!

(in-package :thread-safe-queue)

(defconstant +all-options+ (list
	;; global
	(cons :initial-contents NIL)
	(cons :want-result T)
	;; per-step
	(cons :parallel NIL)
	)
	"
	Global options:
	
	** :initial-contents: This expression is evaluated once, and specifies the elements that get fed into the first step.
If this is not specified, the first step will be called until it returns NIL; a verbatim NIL element can be inserted into the queue by returning a non-NIL second value.
	** :want-result: If this is T (the default), the return values of the last step are accumulated and returned.
For NIL only a single NIL is returned; this is useful if the side-effects of the process are important.
	
	Per-step options:
	
	** :parallel: How many threads should be allocated for this step?
This is an upper limit; if there's no input left, no additional threads will be started.
	")


(defconstant +per-stmt-options+ '(
	:parallel))

(defconstant +option-aliases+ '(
	(:threads . :parallel)))

