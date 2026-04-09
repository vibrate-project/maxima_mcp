;; maxima-mcp-server.lisp
;; 
;; Works in vanilla Maxima SBCL.

;; (C) 2026 Dimiter Prodanov, IICT
;; help from Deepseek and Calude 

(in-package :cl-user)
(require :sb-bsd-sockets)

(defpackage :maxima-mcp
  (:use :cl :sb-bsd-sockets)
  (:export :start-server :stop-server :server-running-p :server-port :*server-running* :*debug* ))

(in-package :maxima-mcp)
(defparameter *debug* t)
(format t "~&[DEBUG] === maxima-mcp-server.lisp loading ===~%")

;;; Configuration
(defparameter *port* 8000)
(defparameter *server-running* nil)
(defparameter *server-socket* nil)

;; JSON helpers (minimal escaping for quote and backslash only)
; (defun json-escape (string)
  ; (with-output-to-string (out)
    ; (loop for ch across string do
      ; (cond ((char= ch #\") (write-string "\\\"" out))
            ; ((char= ch #\\) (write-string "\\\\" out))
            ; (t (write-char ch out))))))
            
;;; JSON helpers — RFC 8259 compliant escaping
;;; Uses (char-code ch) comparisons only — avoids implementation-specific
;;; character names like #\Backspace, #\Page which may not be supported
;;; in all SBCL builds (e.g., embedded in Maxima).
(defun json-escape (string)
  (with-output-to-string (out)
    (loop for ch across string
          for code = (char-code ch)
          do (cond
               ((= code 34)  (write-string "\\\"" out))  ; U+0022 quotation mark
               ((= code 92)  (write-string "\\\\" out))  ; U+005C backslash
               ((= code  8)  (write-string "\\b"  out))  ; U+0008 backspace
               ((= code  9)  (write-string "\\t"  out))  ; U+0009 tab
               ((= code 10)  (write-string "\\n"  out))  ; U+000A newline
               ((= code 12)  (write-string "\\f"  out))  ; U+000C form feed
               ((= code 13)  (write-string "\\r"  out))  ; U+000D carriage return
               ((< code 32)  (format out "\\u~4,'0x" code)) ; other control chars
               ((= code 127) (write-string "\\u007f" out))  ; U+007F DEL
               (t            (write-char ch out))))))
               
(defun json-string (s) (format nil "\"~a\"" (json-escape s)))
(defun json-array (items) (format nil "[~{~a~^,~}]" (mapcar #'json-string items)))
(defun json-object (&rest pairs)
  (with-output-to-string (out)
    (write-char #\{ out)
    (loop for (key value) on pairs by #'cddr for first = t then nil do
      (unless first (write-char #\, out))
      (format out "~a:~a"
        (json-string (string key))
        (typecase value
          (string  (json-string value))
          (integer (format nil "~d" value))
          (float   (format nil "~f" value))
          (list    (json-array value))
          ((eql t) "true")
          (null    "null")
          (t       (json-string (princ-to-string value))))))
    (write-char #\} out)))

;;; HTTP response helper
(defun http-response (content &optional (status 200))
  (let ((body (if (stringp content) content (princ-to-string content))))
    (format nil "HTTP/1.1 ~d OK~c~cContent-Type: application/json~c~cContent-Length: ~d~c~cConnection: close~c~c~c~c~a"
      status
      #\Return #\Linefeed
      #\Return #\Linefeed
      (length body)
      #\Return #\Linefeed
      #\Return #\Linefeed #\Return #\Linefeed
      body)))

;;; Maxima evaluation
(defun last-char (string)
  (char string (1- (length string))))


; (defun clean-maxima-result (s)
  ; (let ((s (string-trim '(#\Space #\Newline #\Return #\Tab) s)))
    ; (if (and (> (length s) 13)
             ; (string= (subseq s 0 13) "displayinput("))
        ; (let* ((comma-pos (position #\, s))
               ; (inner (subseq s (1+ comma-pos) (1- (length s)))))
          ; (string-trim '(#\Space #\Newline #\Return #\Tab) inner))
        ; s)))
(defun clean-maxima-result (s)
  (let ((s (string-trim '(#\Space #\Newline #\Return #\Tab) s)))
    (let ((prefix (cond
                    ((and (> (length s) 14)
                          (string= (subseq s 0 14) "nodisplayinput")) "nodisplayinput(")
                    ((and (> (length s) 13)
                          (string= (subseq s 0 13) "displayinput(")) "displayinput(")
                    (t nil))))
      (if prefix
          (let* ((plen (length prefix))
                 ;; skip past "prefix" then find the comma separating
                 ;; the boolean arg from the actual result
                 (comma-pos (position #\, s :start plen))
                 (inner (when comma-pos
                          (subseq s (1+ comma-pos) (1- (length s))))))
            (if inner
                (string-trim '(#\Space #\Newline #\Return #\Tab) inner)
                s))
          s))))


(defun extract-tool-argument (body arg-name)
  "Extract arg-name value from nested \"arguments\":{\"arg-name\":\"value\"}"
  (let* ((args-start (search "\"arguments\":{" body))
         (arg-key    (format nil "\"~a\":\"" arg-name))  ; include opening quote
         (arg-start  (when args-start
                       (search arg-key body :start2 args-start))))
    (when arg-start
      (let* ((val-start (+ arg-start (length arg-key)))
             (val-end   (position #\" body :start val-start)))  ; closing quote
        (when (and val-end (> val-end val-start))
          (let ((value (subseq body val-start val-end)))
            (when *debug* (format t "~&[DEBUG] Tool arg ~a: ~s~%" arg-name value))
            value))))))
          
;;; Get Maxima user function source definition
(defun handle-functsource (body)
  (when *debug* (format t "~&[DEBUG] handle-functsource: ~a~%" body))
  (let* ((fname  (or (extract-tool-argument body "name")    ; MCP tools/call standard
                     (extract-json-field body "name")       ; direct HTTP fallback
                     (extract-json-field body "function")   ; legacy fallback
                     ""))
         (id     (extract-json-id body)))
    (when *debug* (format t "~&[DEBUG] functsource fname: ~a id: ~a~%" fname id))
    (if (plusp (length (string-trim " " fname)))
        (let* ((raw     (run-maxima (format nil "errcatch(fundef(~a))" fname)))
               (cleaned (clean-maxima-result raw))
               (result
                 (cond
                   ;; errcatch returned [] — not defined
                   ((or (string= cleaned "[]") (string= cleaned "") (string= cleaned "false"))
                    (format nil "Error: no such function: ~a" fname))
                   ;; errcatch returned [result] — strip []
                   ((and (> (length cleaned) 1)
                         (char= (char cleaned 0) #\[)
                         (char= (char cleaned (1- (length cleaned))) #\]))
                    (string-trim " " (subseq cleaned 1 (1- (length cleaned)))))
                   (t cleaned)))
               (escaped (json-escape result)))
          (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"~a\"}]}}"
                  (or id "null") escaped))
        (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Error: no function name specified\"}]}}"
                  (or id "null")))))

                  
; (defun run-maxima (expr)
  ; (when *debug* (format t "~&[DEBUG] Maxima expr: ~a~%" expr))
  ; (let ((fixed-expr (if (and (plusp (length expr))
                             ; (not (member (last-char expr) '(#\;))))
                        ; (concatenate 'string expr ";")
                        ; expr)))
    ; (when *debug* (format t "~&[DEBUG] Fixed expr: ~a~%" fixed-expr))
    ; (handler-case
        ; (with-input-from-string (in (format nil "~a$" fixed-expr))
          ; (let* ((maxima::$display2d nil)
                 ; (evaled (maxima::meval (maxima::mread in)))
                 ; (result (with-output-to-string (out)
                           ; (maxima::mgrind evaled out))))
            ; (string-trim '(#\Space #\Newline #\Return #\Tab) result)))
      ; (error (e)
        ; (when *debug* (format t "~&[DEBUG] Maxima error: ~a~%" e))
        ; (format nil "Maxima error: ~a" e)))))

(defun run-maxima (expr)
  (when *debug* (format t "~&[DEBUG] Maxima expr: ~a~%" expr))
  (let* ((trimmed (string-trim '(#\Space #\Newline #\Return #\Tab #\; #\$) expr))
         (input   (format nil "~a$" trimmed)))
    (when *debug* (format t "~&[DEBUG] Input to mread: ~a~%" input))
    (handler-case
      (with-input-from-string (in input)
        (let* ((maxima::$display2d nil)
               (evaled (maxima::meval (maxima::mread in)))
               (result (with-output-to-string (out)
                         (maxima::mgrind evaled out))))
          (string-trim '(#\Space #\Newline #\Return #\Tab) result)))
      (error (e)
        (when *debug* (format t "~&[DEBUG] Maxima error: ~a~%" e))
        (format nil "Maxima error: ~a" e)))))

;; Simple JSON field extraction (for demo purposes) 
; (defun extract-json-field (body field-name)
  ; (when *debug* (format t "~&[DEBUG] Extracting ~a from: ~a~%" field-name body))
  ; Quoted - CORRECT ESCAPES
  ; (let* ((qkey (format nil "\"~a\":\"" field-name))  ; Produces "expression":
         ; (qstart (search qkey body)))
    ; (when qstart
      ; (let* ((after (+ qstart (length qkey)))
             ; (qend (position #\" body :start after)))
        ; (when (and after qend (> qend after))
          ; (let ((value (subseq body after qend)))
            ; (when *debug* (format t "~&[DEBUG] Quoted RETURNING: ~s~%" value))
            ; (return-from extract-json-field value))))))
  ; Unquoted - ANY COLON
  ; (let ((colon (search ":" body)))
    ; (when colon
      ; For expression field, find the matching closing brace
      ; (let ((end (if (string= field-name "expression")
                     ; Find the last } that matches the opening {
                     ; (let ((depth 1)
                           ; (pos (1+ colon)))
                       ; (loop while (< pos (length body))
                             ; do (let ((ch (char body pos)))
                                  ; (cond ((char= ch #\{) (incf depth))
                                        ; ((char= ch #\}) 
                                         ; (decf depth)
                                         ; (when (zerop depth)
                                           ; (return pos))))
                                  ; (incf pos))
                             ; finally (return (length body))))
                     ; For other fields, stop at comma or brace
                     ; (or (position #\, body :start colon)
                         ; (position #\} body :start colon)))))
        ; (when end
          ; (let ((value (string-trim " ;" (subseq body (1+ colon) end))))
            ; (when *debug* (format t "~&[DEBUG] Unquoted RETURNING: ~s~%" value))
            ; value)))))) 

(defun extract-json-field (body field-name)
  (when *debug* (format t "~&[DEBUG] Extracting ~a from: ~a~%" field-name body))

  ;; Case 1: quoted key + quoted value  {"field":"value"}
  (let* ((qkey (format nil "\"~a\":\"" field-name))
         (qstart (search qkey body)))
    (when qstart
      (let* ((after (+ qstart (length qkey)))
             (qend (position #\" body :start after)))
        (when (and qend (> qend after))
          (let ((value (subseq body after qend)))
            (when *debug* (format t "~&[DEBUG] Quoted RETURNING: ~s~%" value))
            (return-from extract-json-field value))))))

  ;; Case 2: quoted key + unquoted value  {"field":value}
  (let* ((ukey (format nil "\"~a\":" field-name))
         (ustart (search ukey body)))
    (when ustart
      (let* ((after (+ ustart (length ukey)))
             (end (find-unquoted-end body after)))
        (when (> end after)
          (let ((value (string-trim " \"" (subseq body after end))))
            (when *debug* (format t "~&[DEBUG] Quoted-key RETURNING: ~s~%" value))
            (return-from extract-json-field value))))))

  ;; Case 3: unquoted key + unquoted value  { field:value }
  (let* ((ukey (format nil "~a:" field-name))
         (ustart (search ukey body)))
    (when ustart
      (let* ((after (+ ustart (length ukey)))
             (end (find-unquoted-end body after)))
        (when (> end after)
          (let ((value (string-trim " \"" (subseq body after end))))
            (when *debug* (format t "~&[DEBUG] Unquoted RETURNING: ~s~%" value))
            value))))))

(defun find-unquoted-end (body start)
  "Find the end of a JSON value starting at START.
   Stops at , or } only when paren/bracket depth is zero.
   Handles nested () [] {} so Maxima expressions like solve(x^2-2,x)
   are not truncated at the internal comma."
  (let ((depth 0)
        (pos start))
    (loop while (< pos (length body))
          for ch = (char body pos)
          do (cond
               ((member ch '(#\( #\[ #\{)) (incf depth))
               ((member ch '(#\) #\] #\}))
                (if (zerop depth)
                    (return pos)        ; closing brace at depth 0 = end
                    (decf depth)))
               ((and (char= ch #\,) (zerop depth))
                (return pos)))          ; comma at depth 0 = field separator
             (incf pos))
    pos))  ; end of string if nothing found


;;; HTTP handlers
(defun handle-health ()
  (when *debug* (format t "~&[DEBUG] /health~%"))
  (json-object "status" "ok"))

(defun handle-root ()
  (when *debug* (format t "~&[DEBUG] /~%"))
  (json-object "message" "Maxima MCP Server" "endpoints" (list "/health" "/tool-call" "/load" "/mcp")))




(defun handle-tool-call (body)
  (when *debug* (format t "~&[DEBUG] handle-tool-call: ~a~%" body))
  (let* ((tool-name (extract-json-field body "name"))
         (expr (extract-json-field body "expression"))
         (id (extract-json-id body)))
    (when *debug* (format t "~&[DEBUG] tool: ~a expr: ~a id: ~a~%" tool-name expr id))
    (if (and expr (plusp (length (string-trim " " expr))))
        (let* ((clean-expr (string-trim " " expr))
               (raw (run-maxima clean-expr))
               (result (clean-maxima-result raw))
               (escaped (json-escape result)))
          (when *debug* (format t "~&[DEBUG] tool result: ~a~%" result))
          (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"~a\"}]}}"
                  (or id "null") escaped))

        (progn
          (when *debug* (format t "~&[DEBUG] tool error: no expression~%"))
          (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Error: no expression\"}]}}"
                  (or id "null"))))))


;; Package loader
(defun handle-load (body &optional id)
  (when *debug* (format t "~&[DEBUG] /load body: ~a id: ~a~%" body id))
  (let ((pkg nil))
    ;; Try to extract from quoted format: {"package":"value"}
    (let ((start (search "\"package\":" body)))
      (when start
        (let* ((after-colon (position #\: body :start start))
               (quote-start (position #\" body :start (1+ after-colon)))
               (quote-end (when quote-start
                           (position #\" body :start (1+ quote-start)))))
          (when (and quote-start quote-end (> quote-end quote-start))
            (setf pkg (subseq body (1+ quote-start) quote-end))
            (when *debug* (format t "~&[DEBUG] Extracted quoted package: ~a~%" pkg))))))
    
    ;; If not found, try unquoted format: {package:value}
    (when (null pkg)
      (let ((start (search "package:" body)))
        (when start
          (let* ((after-colon (+ start (length "package:")))
                 (end (or (position #\, body :start after-colon)
                          (position #\} body :start after-colon)
                          (length body))))
            (when (> end after-colon)
              (setf pkg (string-trim " \"" (subseq body after-colon end)))
              (when *debug* (format t "~&[DEBUG] Extracted unquoted package: ~a~%" pkg)))))))
    
    (if (and pkg (plusp (length pkg)))
        (handler-case
            (progn
              (when *debug* (format t "~&[DEBUG] Loading package: ~a~%" pkg))
              (run-maxima (format nil "load(\"~a\")" pkg))
              ;; Return proper JSON-RPC format if id is provided (from tools/call)
              (if id
                  (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Package ~a loaded.\"}]}}"
                          id pkg)
                  (format nil "{\"success\":true,\"result\":\"Package ~a loaded.\"}" pkg)))
          (error (e)
            (when *debug* (format t "~&[DEBUG] Load error: ~a~%" e))
            (if id
                (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32000,\"message\":\"~a\"}}"
                        id e)
                (format nil "{\"success\":false,\"error\":\"Load error: ~a\"}" e))))
        (if id
            (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32602,\"message\":\"Missing package name\"}}"
                    id)
            (format nil "{\"success\":false,\"error\":\"No package specified\"}")))))
            
;;; Request parsing
(defun parse-request-line (line)
  (when *debug* (format t "~&[DEBUG] Parse line: ~a~%" line))
  (let* ((space1 (position #\Space line))
         (space2 (and space1 (position #\Space line :start (1+ space1)))))
    (when (and space1 space2)
      (values (subseq line 0 space1)
              (subseq line (1+ space1) space2)))))

;;; Client handling
(defun handle-client (client-socket)
  (when *debug* (format t "~&[DEBUG] New client~%"))
  (let ((stream (socket-make-stream client-socket :input t :output t :element-type 'character :external-format :latin-1
                :buffering :full)))
    (unwind-protect
      (handler-case
        (loop
          (let ((request-line (read-line stream nil nil)))
            (unless request-line (return))
            (multiple-value-bind (method path) (parse-request-line request-line)
              (when *debug* (format t "~&[DEBUG] Method: ~a Path: ~a~%" method path))
              (let ((headers '()) content-length body)
                (when *debug* (format t "~&[DEBUG] Reading headers~%"))
                (loop for line = (read-line stream nil nil)
                      do (when *debug* (format t "~&[DEBUG] Header line: ~s~%" line))
                      while (and line (plusp (length (string-trim '(#\Space #\Tab #\Return #\Newline) line))))
                      do (let* ((colon (position #\: line)))
                           (when colon
                             (let* ((header-name (string-upcase (subseq line 0 colon)))
                                    (header-value (string-trim " " (subseq line (1+ colon)))))
                               (push (cons header-name header-value) headers)
                               (when *debug* (format t "~&[DEBUG] Header: ~a = ~a~%" header-name header-value))))))
                (let ((raw-len (let ((header (assoc "CONTENT-LENGTH" headers :test #'string=)))
                                 (if header
                                     (or (parse-integer (cdr header) :junk-allowed t) 0)
                                     0))))
                  (setf content-length (min raw-len 100000))
                  (when (> raw-len 100000)
                    (when *debug* (format t "~&[DEBUG] Body too large: ~d > 100000, capping~%" raw-len))
                    (dotimes (_ (- raw-len 100000))
                      (read-char stream nil nil)))
                  (when *debug* (format t "~&[DEBUG] Effective Content-Length: ~d~%" content-length)))
                (setf body (when (plusp content-length)
                             (let ((b (make-string content-length)))
                               (let ((read-bytes (read-sequence b stream)))
                                 (when (< read-bytes content-length)
                                   (when *debug* (format t "~&[DEBUG] Partial read: ~d/~d~%" read-bytes content-length)))
                                 b))))
                (when *debug*
                  (format t "~&[DEBUG] Body: ~d bytes~%" (if body (length body) 0)))
                (let ((response
                       (cond ((and method (string= method "GET")  (string= path "/"))          (handle-root))
                             ((and method (string= method "GET")  (string= path "/health"))    (handle-health))
                             ((and method (string= method "POST") (string= path "/tool-call")) (handle-tool-call body))
                             ;;((and method (string= method "POST") (string= (string-trim " " path) "/mcp")) (handle-mcp-sse stream body))
                            ((and method (string= method "POST") (string= path "/mcp"))
                             (let ((response (handle-mcp body)))
                               (format stream "~a" (http-response response))
                               (finish-output stream)
                               (force-output stream)))
                             ((and method (string= method "POST") (string= path "/load"))      (handle-load body))
                             ((and method (string= method "POST") (string= path "/functsource")) (handle-functsource body))
                             (t (json-object "error" "Not found")))))
                  (when response
                    (when *debug* (format t "~&[DEBUG] Response: ~a~%" response))
                    (format stream "~a" (http-response response))
                    (finish-output stream)
                    (force-output stream)))
                ;; Close connection if client requested it
                (let ((conn (cdr (assoc "CONNECTION" headers :test #'string=))))
                  (when (and conn (string-equal (string-trim " " conn) "close"))
                    (return)))))))
        (error (e)
          (when *debug* (format t "~&[DEBUG] Client error: ~a~%" e))
          (format t "Client error: ~a~%" e)))
      (when stream (close stream))))
  (when *debug* (format t "~&[DEBUG] Client closed~%"))
  (socket-close client-socket))


(defun extract-json-id (body)
  (let* ((key "\"id\":"))
    (let ((kstart (search key body)))
      (when kstart
        (let* ((after (+ kstart (length key)))
               (end1 (position #\, body :start after))
               (end2 (position #\} body :start after))
               (end (cond ((and end1 end2) (min end1 end2))
                          (end1 end1)
                          (end2 end2))))
          (when end
            (string-trim " " (subseq body after end))))))))



(defun handle-mcp (body)
  (when *debug* (format t "~&[DEBUG] /mcp body: ~a~%" body))
  (let ((method (extract-json-field body "method"))
        (id (extract-json-id body)))
    (cond
      ((search "notifications/" method)
       nil)
      ((string= method "load")
       (handle-load body id))  ; Pass nil for id for direct load
      ((search "tools/call" method)
       (let ((tool-name (extract-json-field body "name")))
         (cond ((or (search "compute" tool-name) (search "maxima_compute" tool-name)) 
                (handle-tool-call body))
               ((or (search "load" tool-name) (search "maxima_load" tool-name))
                ;; Extract package from the arguments
                (let ((package-name nil))
                  ;; Find the arguments object
                  (let ((args-start (search "\"arguments\":" body)))
                    (when args-start
                      ;; Find "package": within arguments
                      (let ((pkg-start (search "\"package\":" body :start2 args-start)))
                        (when pkg-start
                          (let ((colon (position #\: body :start pkg-start)))
                            (when colon
                              (let ((quote-start (position #\" body :start (1+ colon))))
                                (when quote-start
                                  (let ((quote-end (position #\" body :start (1+ quote-start))))
                                    (when quote-end
                                      (setf package-name (subseq body (1+ quote-start) quote-end))))))))))))
                  (if package-name
                      (let ((simple-body (format nil "{\"package\":\"~a\"}" package-name)))
                        (handle-load simple-body id))  ; Pass the id!
                      (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32602,\"message\":\"Missing package name\"}}"
                              (or id "null")))))
                ((or (search "functsource" tool-name) (search "maxima_functsource" tool-name))  (handle-functsource body))       
               (t (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32601,\"message\":\"Unknown tool: ~a\"}}"
                          (or id "null") tool-name)))))
      (t
       (let ((result
              (cond
                ((search "initialize" method)
                 "{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"maxima-mcp\",\"version\":\"1.0\"},\"capabilities\":{\"tools\":{}}}")
                ((search "tools/list" method)
                 "{\"tools\":[
                     {\"name\":\"maxima_compute\",
                      \"description\":\"Evaluate a Maxima CAS expression\",
                      \"inputSchema\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}},
                     {\"name\":\"maxima_load\",
                      \"description\":\"Load a Maxima package\",
                      \"inputSchema\":{\"type\":\"object\",\"properties\":{\"package\":{\"type\":\"string\"}},\"required\":[\"package\"]}},
                     {\"name\":\"maxima_functsource\",
                      \"description\":\"Get the source definition of a Maxima user function\",
                      \"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}}
                  ]}")                 
                 
                ((search "ping" method) "{\"pong\":true}")
                (t (json-object "error" "Unknown method")))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":~a}"
                 (or id "null") result)))))) 
         
;; JSON response
(defun send-json-response (stream json)
  (format stream "HTTP/1.1 200 OK~c~cContent-Type: text/event-stream~c~cCache-Control: no-cache~c~cConnection: keep-alive~c~c~c~cdata: ~a~c~c~c~c"
          #\Return #\Linefeed
          #\Return #\Linefeed
          #\Return #\Linefeed
          #\Return #\Linefeed
          #\Return #\Linefeed
          json
          #\Return #\Linefeed
          #\Return #\Linefeed)
  (finish-output stream))



(defun handle-mcp-sse (stream body)
  (when *debug* (format t "~&[DEBUG] handle-mcp-sse called~%"))
  (when (and body (plusp (length body)))
    (when *debug* (format t "~&[DEBUG] SSE calling handle-mcp~%"))
    (let ((result (handle-mcp body)))
      (when *debug* (format t "~&[DEBUG] SSE result: ~a~%" result))
      (cond
        (result
         ;; Check if this is a load response (has "success" field)
         (if (search "\"success\"" result)
             ;; For load, use the working http-response function
             (let ((response (http-response result)))
               (format stream "~a" response)
               (finish-output stream)
               (force-output stream)
               (close stream))
             ;; For other MCP methods, use SSE with keep-alive
             (send-json-response stream result)))
        (t
         (when *debug* (format t "~&[DEBUG] Sending 204~%"))
         (format stream "HTTP/1.1 204 No Content~c~cConnection: keep-alive~c~c~c~c"
                 #\Return #\Linefeed
                 #\Return #\Linefeed
                 #\Return #\Linefeed)
         (finish-output stream))))))
         
;;; Server loop
(defun server-loop ()
  (when *debug* (format t "~&[DEBUG] Setting up listener on port ~d~%" *port*))
  (setf *server-socket* (make-instance 'inet-socket :type :stream :protocol :tcp))
  (setf (sockopt-reuse-address *server-socket*) t)
  (socket-bind *server-socket* #(127 0 0 1) *port*)
  (socket-listen *server-socket* 5)
  (format t "*** Maxima MCP on ~d ***~%" *port*)
  (when *debug* (format t "~&[DEBUG] Server loop started~%"))
  (unwind-protect
    (loop while *server-running* do
      (let ((client (ignore-errors (socket-accept *server-socket*))))
        (when (and client *server-running*)   ; <-- both guards
          (when *debug* (format t "~&[DEBUG] Accepted client~%"))
          (sb-thread:make-thread
            (lambda () (handle-client client)) :name "client"))))
    (when *debug* (format t "~&[DEBUG] Server loop ending~%"))
    (ignore-errors (socket-close *server-socket*))))


;;; Public interface
(defun start-server (&optional (port 8000))
  (when *debug* (format t "~&[DEBUG] Starting server on port ~d~%" port))
  (setf *port* port *server-running* t)
  (sb-thread:make-thread #'server-loop :name "mcp-server")
  (format t "Server started on ~d~%" port)
  t)

(defun stop-server ()
  (when *debug* (format t "~&[DEBUG] Stopping server~%"))
  (setf *server-running* nil)
  (when *server-socket* (socket-close *server-socket*))
  t)

;; Accessors 
(defun debug-enabled-p () *debug*)
(defun server-running-p () *server-running*)
(defun server-port () *port*)
