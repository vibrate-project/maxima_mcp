# Maxima MCP Server — Developer Skill Reference

**File:** `mcp_server.lisp`  
**Author:** Dimiter Prodanov, IICT-BAS  
**Runtime:** Maxima (SBCL embedded)  
**Protocol:** JSON-RPC 2.0 over HTTP/1.1  
**Default port:** `8000` (localhost only when `*local* t`)  
**Version:** 1.2

---

## Overview

`mcp_server.lisp` implements a Model Context Protocol (MCP) server that exposes Maxima CAS
operations as JSON-RPC tools. It runs inside the Maxima SBCL process, using `sb-bsd-sockets`
directly — no external HTTP library is required. All tool calls arrive as HTTP POST requests
to `/mcp` and are dispatched by `handle-mcp`. LM Studio connects using the Streamable HTTP
transport (POST /mcp) with SSE fallback (GET /mcp).

---

## Starting and Stopping

Load the file inside a running Maxima session:

```lisp
:lisp (load "mcp_server.lisp")
:lisp (maxima-mcp:start-server 8000)   ; start on port 8000
:lisp (maxima-mcp:stop-server)         ; graceful shutdown
```

Exported symbols from the `maxima-mcp` package:

| Symbol | Type | Purpose |
|---|---|---|
| `start-server` | function | Start HTTP listener on given port |
| `stop-server` | function | Stop listener, close all SSE streams, close socket |
| `server-running-p` | function | Returns `*server-running*` |
| `server-port` | function | Returns `*port*` |
| `server-version` | function | Returns `*version*` |
| `*server-running*` | parameter | Boolean — server state |
| `*debug*` | parameter | Boolean — verbose logging to stdout |

---

## Configuration Parameters

| Parameter | Type | Default | Effect |
|---|---|---|---|
| `*port*` | defparameter | `8000` | TCP listen port |
| `*local*` | defparameter | `t` | `t` = bind `127.0.0.1`; `nil` = bind `0.0.0.0` |
| `*debug*` | defparameter | `t` | Print `[DEBUG]` trace lines to stdout |
| `*version*` | defparameter | `"1.2"` | Server version string |
| `*server-running*` | defparameter | `nil` | Set to `t` by `start-server` |
| `*request-id*` | defvar | `"null"` | Current JSON-RPC id — dynamic, thread-local |
| `*sse-streams*` | defvar | `'()` | List of active SSE streams — closed by `stop-server` |
| `*sse-lock*` | defvar | mutex | Protects `*sse-streams*` across threads |

`defvar` is used for `*request-id*`, `*sse-streams*`, and `*sse-lock*` so that reloading
the file during a live session does not reset runtime state or recreate the mutex.

---

## Thread Safety — `*request-id*`

`*request-id*` is a dynamic (special) variable. In `handle-client`, it is rebound with
`let` at the start of each request:

```lisp
(let ((*request-id* "null")   ; dynamic rebind — thread-local per request
      (headers '()) content-length body)
  ...)
```

`handle-mcp` sets it once after extracting the id from the envelope:

```lisp
(setf *request-id* (or id "null"))
```

All handlers read `*request-id*` directly — no re-parsing of the body. Because SBCL's
dynamic binding stack is per-thread, concurrent requests never interfere.

**Rule:** Never call `extract-json-id` inside a handler. Always read `*request-id*`.

---

## HTTP Endpoints

| Method | Path | Handler | Purpose |
|---|---|---|---|
| GET | `/` | `handle-root` | List available endpoints |
| GET | `/health` | `handle-health` | Health check — returns `{"status":"ok"}` |
| GET | `/mcp` | `handle-mcp-sse` | SSE transport — keeps connection open for LM Studio |
| POST | `/mcp` | `handle-mcp` | Main MCP JSON-RPC dispatcher |
| POST | `/tool-call` | `handle-tool-call` | Direct expression evaluation (legacy) |
| POST | `/load` | `handle-load` | Load a Maxima package (legacy) |
| POST | `/functsource` | `handle-functsource` | Get user-function source (legacy) |
| POST | `/help` | `handle-help` | Maxima `? topic` documentation lookup |
| POST | `/listfunctions` | `handle-listfunctions` | List user-defined functions |

---

## SSE Transport — `handle-mcp-sse`

LM Studio uses the MCP Streamable HTTP transport (POST `/mcp`) and opens a parallel
`GET /mcp` SSE channel for server-to-client push. `handle-mcp-sse` handles this:

```lisp
(defun handle-mcp-sse (stream)
  ;; Register in *sse-streams* for graceful shutdown
  (sb-thread:with-mutex (*sse-lock*)
    (push stream *sse-streams*))
  (unwind-protect
    (progn
      (ignore-errors
        ;; Send SSE headers
        (format stream "HTTP/1.1 200 OK
Content-Type: text/event-stream
...")
        (force-output stream)
        ;; Send MCP endpoint event
        (format stream "event: endpoint
data: /mcp

")
        (force-output stream))
      ;; Heartbeat loop — exits when server stops or client disconnects
      (loop while *server-running*
        do (sleep 5)
           (unless (ignore-errors (format stream ": heartbeat
") (force-output stream) t)
             (return))))
    ;; Deregister on exit
    (sb-thread:with-mutex (*sse-lock*)
      (setf *sse-streams* (remove stream *sse-streams*)))))
```

Key points:
- `force-output` (not `finish-output`) flushes to the OS immediately on Windows
- `unwind-protect` guarantees deregistration even if an error escapes
- The heartbeat interval is 5 seconds — fast enough to detect disconnection quickly
- `stop-server` closes all streams in `*sse-streams*` before closing the listener socket

**LM Studio behaviour:** LM Studio opens the SSE channel after `notifications/initialized`.
It then sends `tools/list` on POST simultaneously — this causes a `notifications/cancelled`
for `requestId:1`. This is **expected and harmless** — LM Studio cancels the SSE-paired
request when the POST response arrives first.

---

## MCP Tools

All tools are accessible via `POST /mcp` with method `tools/call`.

### `maxima_compute`
Evaluate any Maxima CAS expression. Returns the result as a string.
```json
{"name":"maxima_compute","arguments":{"expression":"integrate(sin(x),x)"}}
```

### `maxima_load`
Load a Maxima package by filename.
```json
{"name":"maxima_load","arguments":{"package":"draw"}}
```

### `maxima_functsource`
Retrieve the source definition of a user-defined Maxima function via `fundef()`.
```json
{"name":"maxima_functsource","arguments":{"name":"myfunction"}}
```

### `maxima_help`
Return built-in documentation for a Maxima function or topic (`? topic`).
```json
{"name":"maxima_help","arguments":{"topic":"integrate"}}
```

### `maxima_listfunctions`
Return the value of Maxima's `functions` variable. Takes **no arguments**.
```json
{"name":"maxima_listfunctions","arguments":{}}
```

**Note:** `handle-listfunctions` takes no parameters — call sites use `(handle-listfunctions)`
with no arguments. No `body` parameter, no `(declare (ignore body))` needed.

---

## Standard MCP Methods

| Method | Response |
|---|---|
| `initialize` | Protocol version `2025-06-18`, server info, capabilities |
| `tools/list` | Array of all five tool descriptors with `inputSchema` |
| `ping` | `{"pong":true}` |
| `notifications/*` | No response (returns `nil` → HTTP 202 Accepted) |

---

## Internal Architecture

### Request Flow

```
TCP accept → handle-client
  → let ((*request-id* "null") ...)   ; thread-local rebind
    → parse HTTP headers + body
      → route on (method, path)
        → GET  /mcp → handle-mcp-sse  (SSE keepalive, returns :sse)
        → POST /mcp → handle-mcp
                        → extract-json-id → setf *request-id*
                        → tools/call → dispatch on tool-name
                        → initialize / tools/list / ping → inline result
                        → notifications/* → nil (202)
```

### Key Internal Functions

| Function | Purpose |
|---|---|
| `run-maxima` | Evaluate a Maxima expression string; returns result or error string |
| `clean-maxima-result` | Strip `nodisplayinput(…)` / `displayinput(…)` wrappers |
| `get-maxima-error-message` | Capture Maxima's `errormsg` from `*standard-output*`; strip debug trailer |
| `normalize-maxima-error` | Translate `MACSYMA-QUIT` / `attempt to THROW` into a clean message |
| `run-maxima-describe` | Intern topic as Maxima symbol; call `$describe`; capture stdout |
| `safe-expr-p` | Block expressions containing `:lisp` or `quit(` |
| `format-id` | Emit JSON-RPC id correctly: numeric string → unquoted, other → quoted, nil → null |
| `extract-json-field` | Hand-rolled JSON field extraction — handles quoted/unquoted keys and values |
| `extract-tool-argument` | Extract from `"arguments":{"key":"value"}` (MCP tools/call path) |
| `extract-json-id` | Extract top-level `"id"` from JSON-RPC body — searches full body, no anchor |
| `find-unquoted-end` | Depth-aware JSON value terminator — handles nested `()[]{}` |
| `json-escape` | RFC 8259 compliant string escaping using `char-code` comparisons |
| `http-response` | Build HTTP/1.1 response with correct `Content-Length` |
| `handle-mcp-sse` | SSE keepalive handler — sends endpoint event, heartbeat loop |

### `format-id` — JSON-RPC id formatting

```lisp
(defun format-id (id)
  (cond
    ((or (null id) (string= id "null")) "null")
    ((every #'digit-char-p (string-trim " " id))
     (string-trim " " id))        ; numeric → unquoted: 0, 1, 42
    (t (format nil ""~a"" (json-escape id)))))  ; string → quoted: "abc"
```

Use `(format-id *request-id*)` in all response format strings instead of
`(or id "null")`. LM Studio's Zod schema rejects `id: null` — numeric ids like `0`
must be emitted as unquoted JSON numbers.

### Error Handling Pattern

`run-maxima` uses a two-layer strategy:
1. Evaluate inside `handler-case`
2. On error, call `get-maxima-error-message` to retrieve Maxima's own error text
3. Fall back to `normalize-maxima-error` on the Lisp condition if Maxima message is empty

`handle-client` uses `(handler-case ... (serious-condition (e) ...))` as the outer guard —
this catches both `error` and `SB-INT:SIMPLE-CONTROL-ERROR` (broken-pipe on Windows),
preventing the "attempt to THROW to RETURN-FROM-DEBUGGER" secondary error in client threads.

Each response write is individually wrapped:
```lisp
(handler-case
  (progn (format stream ...) (finish-output stream) (force-output stream))
  (error (e) (when *debug* (format t "~&[DEBUG] Write error: ~a~%" e))))
```

---

## Adding a New Tool

### With arguments
1. Write `(defun handle-newtool (body) (let* ((arg (extract-tool-argument body "arg")) (id *request-id*)) ...))`
2. Add branch in `handle-mcp` tools/call dispatch
3. Add HTTP route in `handle-client`: `((... (string= path "/newtool")) (handle-newtool body))`
4. Add entry to `tools/list` JSON string
5. Add `"/newtool"` to `handle-root` endpoints list

### Without arguments (like `handle-listfunctions`)
1. Write `(defun handle-newtool () (let* ((id *request-id*)) ...))`  — no `body` parameter
2. Call sites use `(handle-newtool)` with no arguments in both dispatchers
3. No `(declare (ignore body))` needed — cleaner signature

---

## Known Issues and Pitfalls

| Issue | Detail |
|---|---|
| `mread` wraps symbols | Never pass a topic/symbol through `mread` before calling `$describe` or `fundef`. Use `intern` instead. |
| `get-maxima-error-message` defined twice | File contains two definitions — the second (with junk-stripping) overrides the first. First is dead code. |
| No `?? topic` inexact match | `$describe` with second arg `maxima::$false` does apropos search — not yet exposed as a tool. |
| No run-maxima timeout | Long-running `meval` calls block the handler thread indefinitely. No timeout/kill mechanism exists yet. |
| Body size cap | Request bodies capped at 100,000 bytes; excess drained. |
| Hand-rolled JSON parser | `extract-json-field` is a linear string search. Malformed or adversarial JSON may extract wrong fields. |
| Windows curl strips quotes | Use escaped double-quotes: `curl.exe -d "{"id":1}"`. `extract-json-id` handles both forms. |
| `notifications/cancelled` on tools/list | LM Studio sends `tools/list` on both POST and SSE paths simultaneously and cancels the loser. This is expected — handle with 202. |
| SSE closes immediately on Windows | Use `force-output` not `finish-output` for SSE writes — `finish-output` does not flush to the OS socket on Windows until the stream closes. |

---

## LM Studio Connection Sequence

A successful LM Studio connection produces this exact sequence:

```
POST /mcp  initialize              → 200  {"id":0, "result": {...}}
POST /mcp  notifications/initialized → 202 Accepted
GET  /mcp  (SSE)                   → 200  text/event-stream + endpoint event
POST /mcp  tools/list              → 200  {"id":1, "result": {"tools":[...]}}
POST /mcp  notifications/cancelled → 202 Accepted   ← expected, harmless
```

If `initialize` fails (id:null, Zod error), check `extract-json-id` — LM Studio puts
`"id"` after `"params"` in the JSON body. The extractor must search the full body.

---

## curl Test Examples (Windows)

```bat
:: Health check
curl -s http://localhost:8000/health

:: List tools
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":1,"method":"tools/list"}"

:: Evaluate expression
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"maxima_compute","arguments":{"expression":"diff(sin(x),x)"}}}"

:: Help lookup
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"maxima_help","arguments":{"topic":"integrate"}}}"

:: Get function source
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"maxima_functsource","arguments":{"name":"myf"}}}"

:: List user-defined functions
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"maxima_listfunctions","arguments":{}}}"
```

> Always use escaped double-quotes with `curl.exe -d` on Windows CMD.
> Use `^` for line continuation or run as a single line.
