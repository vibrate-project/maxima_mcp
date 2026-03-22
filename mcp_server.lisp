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

;;; JSON helpers (minimal escaping for quote and backslash only)
(defun json-escape (string)
  (with-output-to-string (out)
    (loop for ch across string do
      (cond ((char= ch #\") (write-string "\\\"" out))
            ((char= ch #\\) (write-string "\\\\" out))
            (t (write-char ch out))))))

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


(defun clean-maxima-result (s)
  (let ((s (string-trim '(#\Space #\Newline #\Return #\Tab) s)))
    (if (and (> (length s) 13)
             (string= (subseq s 0 13) "displayinput("))
        (let* ((comma-pos (position #\, s))
               (inner (subseq s (1+ comma-pos) (1- (length s)))))
          (string-trim '(#\Space #\Newline #\Return #\Tab) inner))
        s)))

(defun run-maxima (expr)
  (when *debug* (format t "~&[DEBUG] Maxima expr: ~a~%" expr))
  (let ((fixed-expr (if (and (plusp (length expr))
                             (not (member (last-char expr) '(#\;))))
                        (concatenate 'string expr ";")
                        expr)))
    (when *debug* (format t "~&[DEBUG] Fixed expr: ~a~%" fixed-expr))
    (handler-case
        (with-input-from-string (in (format nil "~a$" fixed-expr))
          (let* ((maxima::$display2d nil)
                 (evaled (maxima::meval (maxima::mread in)))
                 (result (with-output-to-string (out)
                           (maxima::mgrind evaled out))))
            (string-trim '(#\Space #\Newline #\Return #\Tab) result)))
      (error (e)
        (when *debug* (format t "~&[DEBUG] Maxima error: ~a~%" e))
        (format nil "Maxima error: ~a" e)))))





;;; Simple JSON field extraction (for demo purposes)
 
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
  ; (let ((colon (search ":" body)))  ; FIXED: no space!
    ; (when colon
      ; (let ((end (position #\} body :start colon)))
        ; (when end
          ; (let ((value (string-trim " ;" (subseq body (1+ colon) end))))
            ; (when *debug* (format t "~&[DEBUG] Unquoted RETURNING: ~s~%" value))
            ; value))))))

(defun extract-json-field (body field-name)
  (when *debug* (format t "~&[DEBUG] Extracting ~a from: ~a~%" field-name body))
  ;; Quoted - CORRECT ESCAPES
  (let* ((qkey (format nil "\"~a\":\"" field-name))  ; Produces "expression":
         (qstart (search qkey body)))
    (when qstart
      (let* ((after (+ qstart (length qkey)))
             (qend (position #\" body :start after)))
        (when (and after qend (> qend after))
          (let ((value (subseq body after qend)))
            (when *debug* (format t "~&[DEBUG] Quoted RETURNING: ~s~%" value))
            (return-from extract-json-field value))))))
  ;; Unquoted - ANY COLON
  (let ((colon (search ":" body)))
    (when colon
      ;; For expression field, find the matching closing brace
      (let ((end (if (string= field-name "expression")
                     ;; Find the last } that matches the opening {
                     (let ((depth 1)
                           (pos (1+ colon)))
                       (loop while (< pos (length body))
                             do (let ((ch (char body pos)))
                                  (cond ((char= ch #\{) (incf depth))
                                        ((char= ch #\}) 
                                         (decf depth)
                                         (when (zerop depth)
                                           (return pos))))
                                  (incf pos))
                             finally (return (length body))))
                     ;; For other fields, stop at comma or brace
                     (or (position #\, body :start colon)
                         (position #\} body :start colon)))))
        (when end
          (let ((value (string-trim " ;" (subseq body (1+ colon) end))))
            (when *debug* (format t "~&[DEBUG] Unquoted RETURNING: ~s~%" value))
            value)))))) 

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
; (defun handle-load (body)
  ; (when *debug* (format t "~&[DEBUG] /load body: ~a~%" body))
  ; (let* ((key "package:")
         ; (kstart (search key body))
         ; (after (when kstart (+ kstart (length key))))
         ; (end (when after (position #\} body :start after)))
         ; (pkg (when end (string-trim " \"" (subseq body after end)))))
    ; (if (and pkg (plusp (length pkg)))
        ; (handler-case
            ; (progn
              ; (when *debug* (format t "~&[DEBUG] Loading package: ~a~%" pkg))
              ; (run-maxima (format nil "load(\"~a\")" pkg))
              ; (json-object "success" t "result"
                           ; (format nil "Package ~a loaded." pkg)))
          ; (error (e)
            ; (when *debug* (format t "~&[DEBUG] Load error: ~a~%" e))
            ; (json-object "success" nil "error"
                         ; (format nil "Load error: ~a" e))))
        ; (json-object "success" nil "error" "No package specified"))))

(defun handle-load (body)
  (when *debug* (format t "~&[DEBUG] /load body: ~a~%" body))
  (let* ((key "package:")
         (kstart (search key body))
         (after (when kstart (+ kstart (length key))))
         (end (when after (position #\} body :start after)))
         (pkg (when end (string-trim " \"" (subseq body after end)))))
    (if (and pkg (plusp (length pkg)))
        (handler-case
            (progn
              (when *debug* (format t "~&[DEBUG] Loading package: ~a~%" pkg))
              (run-maxima (format nil "load(\"~a\")" pkg))
              ;; Return simple JSON string instead of json-object
              (format nil "{\"success\":true,\"result\":\"Package ~a loaded.\"}" pkg))
          (error (e)
            (when *debug* (format t "~&[DEBUG] Load error: ~a~%" e))
            (format nil "{\"success\":false,\"error\":\"Load error: ~a\"}" e)))
        (format nil "{\"success\":false,\"error\":\"No package specified\"}"))))
 


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
                             ((and method (string= method "POST") (string= (string-trim " " path) "/mcp")) (handle-mcp-sse stream body))

                             ((and method (string= method "POST") (string= path "/load"))      (handle-load body))
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


; (defun handle-mcp (body)
  ; (when *debug* (format t "~&[DEBUG] /mcp body: ~a~%" body))
  ; (let ((method (extract-json-field body "method"))
        ; (id (extract-json-id body)))
    ; (cond
      ; ((search "notifications/" method)
       ; nil)
      ; ((search "tools/call" method)
       ; (let ((tool-name (extract-json-field body "name")))
         ; (cond ((search "compute" tool-name) (handle-tool-call body))
               ; ((search "load" tool-name) (handle-load body))
               ; (t (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32601,\"message\":\"Unknown tool\"}}"
                          ; (or id "null"))))))
      ; (t
       ; (let ((result
              ; (cond
                ; ((search "initialize" method)
                 ; "{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"maxima-mcp\",\"version\":\"1.0\"},\"capabilities\":{\"tools\":{}}}")
                ; ((search "tools/list" method)
                 ; "{\"tools\":[{\"name\":\"maxima_compute\",\"description\":\"Evaluate a Maxima CAS expression\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}},{\"name\":\"maxima_load\",\"description\":\"Load a Maxima package\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"package\":{\"type\":\"string\"}},\"required\":[\"package\"]}}]}")
                ; ((search "ping" method) "{\"pong\":true}")
                ; (t (json-object "error" "Unknown method")))))
         ; (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"result\":~a}"
                 ; (or id "null") result))))))

(defun handle-mcp (body)
  (when *debug* (format t "~&[DEBUG] /mcp body: ~a~%" body))
  (let ((method (extract-json-field body "method"))
        (id (extract-json-id body)))
    (cond
      ((search "notifications/" method)
       nil)
      ;; Add this new clause for direct "load" method
      ((string= method "load")
       (handle-load body))
      ((search "tools/call" method)
       (let ((tool-name (extract-json-field body "name")))
         (cond ((search "compute" tool-name) (handle-tool-call body))
               ((search "load" tool-name) (handle-load body))
               (t (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"error\":{\"code\":-32601,\"message\":\"Unknown tool\"}}"
                          (or id "null"))))))
      (t
       (let ((result
              (cond
                ((search "initialize" method)
                 "{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"maxima-mcp\",\"version\":\"1.0\"},\"capabilities\":{\"tools\":{}}}")
                ((search "tools/list" method)
                 "{\"tools\":[{\"name\":\"maxima_compute\",\"description\":\"Evaluate a Maxima CAS expression\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}},{\"name\":\"maxima_load\",\"description\":\"Load a Maxima package\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"package\":{\"type\":\"string\"}},\"required\":[\"package\"]}}]}")
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
         (send-json-response stream result)
         (when *debug* (format t "~&[DEBUG] JSON response sent~%")))
        (t
         (when *debug* (format t "~&[DEBUG] Sending 204~%"))
         (format stream "HTTP/1.1 200 OK~c~cContent-Type: text/event-stream~c~cCache-Control: no-cache~c~cConnection: keep-alive~c~c~c~c"
                 #\Return #\Linefeed
                 #\Return #\Linefeed
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
