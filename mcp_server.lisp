;; maxima-mcp-server.lisp
;; 
;; Works in vanilla Maxima SBCL.

;; (C) 2026 Dimiter Prodanov, IICT
;; help from Deepseek and Calude 
;; version 1

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
      
(defun http-status-text (code)
  (case code
    (200 "OK")
    (204 "No Content")
    (400 "Bad Request")
    (404 "Not Found")
    (500 "Internal Server Error")
    (t   "Unknown")))

(defun http-response (content &optional (status 200))
  (let ((body (if (stringp content) content (princ-to-string content))))
    (format nil "HTTP/1.1 ~d ~a~c~cContent-Type: application/json~c~cContent-Length: ~d~c~cConnection: close~c~c~c~c~a"
            status
            (http-status-text status)
            #\Return #\Linefeed
            #\Return #\Linefeed
            (length body)
            #\Return #\Linefeed
            #\Return #\Linefeed #\Return #\Linefeed
            body)))
            
            
;;; Maxima evaluation
(defun last-char (string)
  (char string (1- (length string))))

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

(defun safe-expr-p (expr)
  (and (not (search ":lisp" expr :test #'char-equal))
       (not (search "quit(" expr :test #'char-equal))))                  


(defun run-maxima (expr)
  (when *debug* (format t "~&[DEBUG] Maxima expr: ~a~%" expr))
  (let* ((trimmed (string-trim '(#\Space #\Newline #\Return #\Tab #\; #\$) expr)))
    (unless (safe-expr-p trimmed)
      (when *debug* (format t "~&[DEBUG] Blocked expr: ~a~%" trimmed))
      (return-from run-maxima "Error: expression blocked by security policy"))
    (let ((input (format nil "~a$" trimmed)))
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
          (format nil "Maxima error: ~a" e))))))
          
;; Simple JSON field extraction (for demo purposes) 
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
                             ;; FIXED — consistent with all other routes
                             ((and method (string= method "POST") (string= path "/mcp"))
                             (let ((mcp-response (handle-mcp body)))
                               (if mcp-response
                                   mcp-response
                                   :accepted)))

    
                             ((and method (string= method "POST") (string= path "/load"))      (handle-load body))
                             ((and method (string= method "POST") (string= path "/functsource")) (handle-functsource body))
                             (t (json-object "error" "Not found")))))

                    (cond
                      ((eq response :accepted)
                       (when *debug* (format t "~&[DEBUG] Response: 202 Accepted~%"))
                       (format stream "HTTP/1.1 202 Accepted~c~cConnection: close~c~c~c~c"
                               #\Return #\Linefeed
                               #\Return #\Linefeed
                               #\Return #\Linefeed)
                       (finish-output stream)
                       (force-output stream))

                      (response
                       (when *debug* (format t "~&[DEBUG] Response: ~a~%" response))
                       (format stream "~a" (http-response response))
                       (finish-output stream)
                       (force-output stream))))
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
        (id     (extract-json-id body)))
    (cond
      ;; Notifications — no response needed
      ((search "notifications/" method)
       nil)

      ;; Direct load method (non-MCP path)
      ((string= method "load")
       (handle-load body id))

      ;; tools/call dispatch
      ((search "tools/call" method)
       (let ((tool-name (extract-json-field body "name")))
         (cond
           ;; maxima_compute
           ((or (search "compute" tool-name)
                (search "maxima_compute" tool-name))
            (handle-tool-call body))

           ;; maxima_load
           ((or (search "load" tool-name)
                (search "maxima_load" tool-name))
            (let ((package-name (extract-tool-argument body "package")))
              (if package-name
                  (handle-load (format nil "{\"package\":\"~a\"}" package-name) id)
                  (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32602,\"message\":\"Missing package name\"}}"
                          (or id "null")))))

           ;; maxima_functsource
           ((or (search "functsource" tool-name)
                (search "maxima_functsource" tool-name))
            (handle-functsource body))

           ;; unknown tool
           (t
            (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32601,\"message\":\"Unknown tool: ~a\"}}"
                    (or id "null") tool-name)))))

      ;; Standard MCP methods
      (t
       (let ((result
               (cond
                  ((search "initialize" method)
                   "{\"protocolVersion\":\"2025-06-18\",\
                  \"serverInfo\":{\"name\":\"maxima-mcp\",\"version\":\"1.0\"},\
                  \"capabilities\":{\"tools\":{\"listChanged\":false}}}")
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

                 ((search "ping" method)
                  "{\"pong\":true}")

                 (t (json-object "error" "Unknown method")))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":~a}"
                 (or id "null") result))))))

         
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
        (unless client (sleep 0.05))   ; <-- add this
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
