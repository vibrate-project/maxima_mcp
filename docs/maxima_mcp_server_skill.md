# Maxima MCP Server — Developer Skill Reference

**File:** `mcp_server.lisp`  
**Author:** Dimiter Prodanov, IICT-BAS  
**Runtime:** Maxima (SBCL embedded)  
**Protocol:** JSON-RPC 2.0 over HTTP/1.1  
**Default port:** `8000` (localhost only when `*local* t`)

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
| `*server-running*` | parameter | Boolean — server state |
| `*debug*` | parameter | Boolean — verbose logging to stdout |

---

## Configuration Parameters

| Parameter | Default | Effect |
|---|---|---|
| `*port*` | `8000` | TCP listen port |
| `*local*` | `t` | `t` = bind `127.0.0.1` only; `nil` = bind `0.0.0.0` |
| `*debug*` | `t` | Print `[DEBUG]` trace lines to stdout |
| `*server-running*` | `nil` | Set to `t` by `start-server` |

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
  "params": {
    "name": "maxima_compute",
    "arguments": {"expression": "integrate(sin(x),x)"}
  }
}
```

**Security:** Blocked if expression contains `:lisp` or `quit(`.

### `maxima_load`

Load a Maxima package by filename.

```json
{
  "jsonrpc": "2.0", "id": 2,
  "method": "tools/call",
  "params": {
    "name": "maxima_load",
    "arguments": {"package": "draw"}
  }
}
```

### `maxima_functsource`

Retrieve the source definition of a user-defined Maxima function via `fundef()`.
Returns an error string if the function is not defined.

```json
{
  "jsonrpc": "2.0", "id": 3,
  "method": "tools/call",
  "params": {
    "name": "maxima_functsource",
    "arguments": {"name": "myfunction"}
  }
}
```

### `maxima_help`

Return the built-in documentation for a Maxima function or topic.
Equivalent to `? topic` at the Maxima prompt.

```json
{
  "jsonrpc": "2.0", "id": 4,
  "method": "tools/call",
  "params": {
    "name": "maxima_help",
    "arguments": {"topic": "erf"}
  }
}
```

**Implementation note:** The topic is passed to `$describe` as a plain interned Maxima symbol
via `(intern (string-upcase topic) :maxima)`. Do **not** use `mread` here — it wraps the symbol
in a `nodisplayinput(false, …)` display form that `$describe` cannot match.
The `$describe` output is captured by redirecting `*standard-output*` inside
`with-output-to-string`, identical to the pattern used in `get-maxima-error-message`.

---

## Standard MCP Methods

These are handled by `handle-mcp` under the `(t ...)` branch:

| Method | Response |
|---|---|
| `initialize` | Protocol version `2025-06-18`, server info, capabilities |
| `tools/list` | Array of all four tool descriptors with `inputSchema` |
| `ping` | `{"pong":true}` |
| `notifications/*` | No response (returns `nil` → HTTP 202 Accepted) |

---

## Internal Architecture

### Request Flow

```
TCP accept → handle-client
  → parse HTTP headers + body
    → route on (method, path)
      → /mcp → handle-mcp
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
| `extract-json-id` | Extract top-level `"id"` value from JSON-RPC body |
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

1. **Write the handler:** `(defun handle-newtool (body) …)`  
   — Extract arguments with `extract-tool-argument` (MCP path) or `extract-json-field` (HTTP path)  
   — Extract id with `extract-json-id`  
   — Return a JSON-RPC result string

2. **Register in `tools/call` dispatch** (inside `handle-mcp`, `(search "tools/call" method)` branch):
   ```lisp
   ((or (search "newtool" tool-name)
        (search "maxima_newtool" tool-name))
    (handle-newtool body))
   ```

3. **Add HTTP route** (inside `handle-client`, the `response` cond):
   ```lisp
   ((and method (string= method "POST") (string= path "/newtool")) (handle-newtool body))
   ```

4. **Add to `tools/list`** — append a new entry to the JSON string in the `(search "tools/list" method)` branch.

5. **Expose in `handle-root`** — add `"/newtool"` to the endpoints list.

---

## Known Issues and Pitfalls

| Issue | Detail |
|---|---|
| `"id": null` in responses | `extract-json-id` searches the raw body string; if `"id"` appears in a nested field before the top-level one, it may be missed. Always place `"id"` before `"params"` in requests. |
| `mread` wraps symbols | Never pass a topic or symbol name through `mread` before calling Maxima introspection functions (`$describe`, `$fundef`). Use `intern` instead. |
| `get-maxima-error-message` defined twice | The file contains two definitions of `get-maxima-error-message` — the second (with `errormsg` junk-stripping) overrides the first. The first definition is dead code. |
| No `?? topic` (inexact match) | `$describe` called with a second argument `maxima::$false` performs inexact/apropos search — not yet exposed as a tool. |
| Body size cap | Request bodies are capped at 100,000 bytes; excess bytes are drained. |
| Single-threaded JSON parsing | `extract-json-field` is a hand-rolled linear search, not a proper parser. Malformed or adversarial JSON may cause incorrect field extraction. |

---

## curl Test Examples

```bash
# Health check
curl -s http://localhost:8000/health

# List tools
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# Evaluate expression
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"maxima_compute","arguments":{"expression":"diff(sin(x),x)"}}}'

# Help lookup
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"maxima_help","arguments":{"topic":"integrate"}}}'

# Load a package
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"maxima_load","arguments":{"package":"draw"}}}'

# Get function source
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"maxima_functsource","arguments":{"name":"myf"}}}'
```
