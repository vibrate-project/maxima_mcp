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
to `/mcp` and are dispatched by `handle-mcp`.

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
| `stop-server` | function | Stop listener, close socket |
| `server-running-p` | function | Returns `*server-running*` |
| `server-port` | function | Returns `*port*` |
| `server-version` | function | Returns `*version*` |
| `*server-running*` | parameter | Boolean — server state |
| `*debug*` | parameter | Boolean — verbose logging to stdout |

---

## Configuration Parameters

| Parameter | Default | Effect |
|---|---|---|
| `*port*` | `8000` | TCP listen port |
| `*local*` | `t` | `t` = bind `127.0.0.1` only; `nil` = bind `0.0.0.0` |
| `*debug*` | `t` | Print `[DEBUG]` trace lines to stdout |
| `*version*` | `"1.2"` | Server version string |
| `*server-running*` | `nil` | Set to `t` by `start-server` |
| `*request-id*` | `"null"` | Current JSON-RPC request id — dynamic, thread-local |

---

## Thread Safety — `*request-id*`

`*request-id*` is declared with `defvar` (dynamic/special variable). In `handle-client`,
it is rebound with `let` at the start of each request:

```lisp
(let ((*request-id* "null")   ; dynamic rebind — thread-local per request
      (headers '()) content-length body)
  ...)
```

`handle-mcp` then sets it once after extracting the id from the envelope:

```lisp
(setf *request-id* (or id "null"))
```

All handlers read `*request-id*` directly — no re-parsing of the body. Because SBCL's
dynamic binding stack is per-thread, concurrent requests never interfere.

**Rule:** Never use `extract-json-id` inside a handler. Always read `*request-id*`.

---

## HTTP Endpoints

| Method | Path | Handler | Purpose |
|---|---|---|---|
| GET | `/` | `handle-root` | List available endpoints |
| GET | `/health` | `handle-health` | Health check — returns `{"status":"ok"}` |
| POST | `/mcp` | `handle-mcp` | Main MCP JSON-RPC dispatcher |
| POST | `/tool-call` | `handle-tool-call` | Direct expression evaluation (legacy) |
| POST | `/load` | `handle-load` | Load a Maxima package (legacy) |
| POST | `/functsource` | `handle-functsource` | Get user-function source (legacy) |
| POST | `/help` | `handle-help` | Maxima `? topic` documentation lookup |
| POST | `/listfunctions` | `handle-listfunctions` | List user-defined functions |

The `/mcp` endpoint handles all standard MCP traffic. The other POST endpoints are legacy
direct-HTTP paths that bypass JSON-RPC method dispatch.

---

## MCP Tools

All tools are accessible via `POST /mcp` with method `tools/call`.

### `maxima_compute`

Evaluate any Maxima CAS expression. Returns the result as a string.

```json
{
  "jsonrpc": "2.0", "id": 1,
  "method": "tools/call",
  "params": {"name": "maxima_compute", "arguments": {"expression": "integrate(sin(x),x)"}}
}
```

**Security:** Blocked if expression contains `:lisp` or `quit(`.

### `maxima_load`

Load a Maxima package by filename.

```json
{
  "jsonrpc": "2.0", "id": 2,
  "method": "tools/call",
  "params": {"name": "maxima_load", "arguments": {"package": "draw"}}
}
```

### `maxima_functsource`

Retrieve the source definition of a user-defined Maxima function via `fundef()`.
Returns an error string if the function is not defined.

```json
{
  "jsonrpc": "2.0", "id": 3,
  "method": "tools/call",
  "params": {"name": "maxima_functsource", "arguments": {"name": "myfunction"}}
}
```

### `maxima_help`

Return the built-in documentation for a Maxima function or topic.
Equivalent to `? topic` at the Maxima prompt.

```json
{
  "jsonrpc": "2.0", "id": 4,
  "method": "tools/call",
  "params": {"name": "maxima_help", "arguments": {"topic": "erf"}}
}
```

**Implementation note:** The topic is interned as a Maxima symbol via
`(intern (string-upcase topic) :maxima)`. Do **not** use `mread` — it wraps the
symbol in `nodisplayinput(false, …)` which `$describe` cannot match.

### `maxima_listfunctions`

Return the value of Maxima's `functions` variable — the list of all user-defined functions.
Takes no arguments.

```json
{
  "jsonrpc": "2.0", "id": 5,
  "method": "tools/call",
  "params": {"name": "maxima_listfunctions", "arguments": {}}
}
```

**Implementation note:** `handle-listfunctions` takes no parameters. The HTTP dispatcher
and MCP dispatcher both call `(handle-listfunctions)` with no arguments.

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
        → /mcp → handle-mcp
                   → (setf *request-id* ...)   ; set once
                   → tools/call → dispatch on tool-name
                   → initialize / tools/list / ping → inline result
                   → notifications/* → nil (202)
```

### Key Internal Functions

| Function | Purpose |
|---|---|
| `run-maxima` | Evaluate a Maxima expression string; returns result or error string |
| `clean-maxima-result` | Strip `nodisplayinput(…)` / `displayinput(…)` wrappers from result |
| `get-maxima-error-message` | Capture Maxima's `errormsg` output from `*standard-output*`; strip debug trailer |
| `normalize-maxima-error` | Translate `MACSYMA-QUIT` / `attempt to THROW` into a clean message |
| `run-maxima-describe` | Intern topic as Maxima symbol; call `$describe`; capture stdout |
| `safe-expr-p` | Block expressions containing `:lisp` or `quit(` |
| `extract-json-field` | Hand-rolled JSON field extraction — handles quoted/unquoted keys and values |
| `extract-tool-argument` | Extract from `"arguments":{"key":"value"}` (MCP tools/call path) |
| `extract-json-id` | Extract top-level `"id"` from JSON-RPC body — anchored before `params`/`method` |
| `find-unquoted-end` | Depth-aware JSON value terminator — handles nested `()[]{}` |
| `json-escape` | RFC 8259 compliant string escaping using `char-code` comparisons |

### Error Handling Pattern

`run-maxima` uses a two-layer strategy:
1. Evaluate inside `handler-case`
2. On error, call `get-maxima-error-message` to retrieve Maxima's own error text
3. Fall back to `normalize-maxima-error` on the Lisp condition if Maxima message is empty

`handle-functsource` wraps the call in `errcatch()` at the Maxima level to safely handle
undefined functions without triggering a Lisp condition.

---

## Adding a New Tool

### With arguments
1. Write `(defun handle-newtool (body) (let* ((arg (extract-tool-argument body "arg")) (id *request-id*)) ...))`
2. Add branch in `handle-mcp` tools/call dispatch
3. Add HTTP route: `((... (string= path "/newtool")) (handle-newtool body))`
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
| No SSE streaming | All responses are request/response. SSE would require `text/event-stream`, chunked transfer, and non-blocking `meval`. Not yet implemented. |
| No run-maxima timeout | Long-running `meval` calls block the handler thread indefinitely. No timeout/kill mechanism exists yet. |
| Body size cap | Request bodies capped at 100,000 bytes; excess drained. |
| Hand-rolled JSON parser | `extract-json-field` is a linear string search. Malformed or adversarial JSON may extract wrong fields. |
| Windows curl strips quotes | `curl.exe -d '{"id":1}'` on Windows CMD strips single quotes, sending `{id:1}`. Use escaped double quotes: `-d "{"id":1}"`. `extract-json-id` handles both forms. |

---

## curl Test Examples

```bash
# Health check
curl -s http://localhost:8000/health

# List tools
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":1,"method":"tools/list"}"

# Evaluate expression
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"maxima_compute","arguments":{"expression":"diff(sin(x),x)"}}}"

# Help lookup
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"maxima_help","arguments":{"topic":"integrate"}}}"

# Load a package
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"maxima_load","arguments":{"package":"draw"}}}"

# Get function source
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"maxima_functsource","arguments":{"name":"myf"}}}"

# List user-defined functions
curl -s -X POST http://localhost:8000/mcp ^
  -H "Content-Type: application/json" ^
  -d "{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"maxima_listfunctions","arguments":{}}}"
```

> **Windows note:** Use `^` for line continuation in CMD, or run as a single line.
> Always use escaped double-quotes with `curl.exe -d` — single quotes are stripped by CMD.
