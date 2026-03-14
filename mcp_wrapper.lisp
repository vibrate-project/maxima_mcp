; (require :sb-bsd-sockets)  ; Ensure dependencies
; ;(require :maxima-mcp)      ; Load server first!

; (in-package :maxima)

; ;; Server control
; ; (defmfun $mcp-start-server (port)
  ; ; (maxima-mcp:start-server port)
   ; ; )
; ; (add2lnc '$mcp-start-server $props)

; ; (defmfun $mcp-stop-server ()
  ; ; (maxima-mcp:stop-server)
  ; ; )
; ; (add2lnc '$mcp-stop-server $props)

; ;Debug control
; ; (defmfun $mcp-debug-on ()
  ; ; (setf maxima-mcp::*debug* t)
   ; ; )
; ; (add2lnc '$mcp-debug-on $props)

; ; (defmfun $mcp-debug-off ()
  ; ; (setf maxima-mcp::*debug* nil)
   ; ; )
; ; (add2lnc '$mcp-debug-off $props)

; (in-package :maxima)

; (defmfun $start-server ($port)
  ; (maxima-mcp:start-server $port)
  ; '"Started")
; (add2lnc '$start-server $props)

; (defmfun $stop-server ()
  ; (maxima-mcp:stop-server)
  ; '"Stopped")
; (add2lnc '$stop-server $props)

; (defmfun $mcp-status ()
  ; (print (list "Debug:" (if maxima-mcp:*debug* "ON" "OFF")
               ; "Running:" (if maxima-mcp:*server-running* "YES" "NO")
               ; "Port:" maxima-mcp:*port*))
  ; '"Status printed")
; (add2lnc '$mcp-status $props)
 
;; mcp_wrapper.lisp FINAL VERSION (replace everything):


(in-package :maxima)


; (defmfun $mcp-status () 
  ; (print `(maxima-mcp::*debug* ,maxima-mcp::*server-running*,  maxima-mcp::*port*  ))
   ; )

(in-package :maxima)

(defmfun $mcp-status ()
  (princ "Debug:")
 )

(ADD2LNC '$mcp-status $PROPS)

