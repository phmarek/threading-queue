(in-package :threading-queue)

(defvar *internal-stop-sym* (gensym))

(defparameter *default-stop-sym* nil)

(defvar *default-arg-name* "*")


(defparameter *reverse-2nd-value*
  (list
    'cl:read-line
    'cl:read
    'cl:read-char
    'cl:read-delimited-list
    'cl:read-preserving-whitespace)
  "List of symbols for which the second value is reversed, if they are the only 
expression in a step.")
