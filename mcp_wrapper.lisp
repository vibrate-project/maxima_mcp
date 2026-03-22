(in-package :maxima)

;; Server control
(defmfun $mcp_start_server (port)
  (maxima-mcp:start-server port)
   )
(add2lnc '$mcp_start_server $props)

(defmfun $mcp_stop_server ()
  (maxima-mcp:stop-server)
  $true
  )
  
(add2lnc '$mcp-stop-server $props)

; ;Debug control
(defmfun $mcp_debug_on ()
  (setf maxima-mcp::*debug* t)
  $true
   )
(add2lnc '$mcp-debug-on $props)

(defmfun $mcp_debug_off ()
  (setf maxima-mcp::*debug* nil)
  $false
   )
(add2lnc '$mcp-debug-off $props)


(defmfun $mcp_status ()
  (print (list "Debug:" (if maxima-mcp:*debug* "ON" "OFF")
               "Running:" (if (maxima-mcp:server-running-p) "YES" "NO")
               "Port:" (maxima-mcp:server-port )))
  $true)
  
(add2lnc '$mcp_status $props)
 
