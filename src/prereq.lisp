(in-package :threading-queue)

(defvar *internal-stop-sym* (gensym))

(defparameter *default-stop-sym* nil)

(defvar *default-arg-name* "*")


