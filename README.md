**Experimental Maxima MCP Server**


A lightweight, dependency-free HTTP server for Maxima symbolic computation. Exposes Maxima via JSON-over-HTTP endpoints for tool-calling integration (MCP protocol). Runs on vanilla SBCL/Maxima with SB-BSD-SOCKETS only—no Quicklisp, usockets, or external libs.
​
Features

- Pure SBCL: No dependencies (Uses native sb-bsd-sockets and sb-thread).

- JSON API: Manual serialization/parsing for basic payloads.

- Threaded: One thread per client, clean shutdown via *server-running*.

- Maxima evaluation: Safe evaluation with auto-semicolon and error capture.

- DoS protection: 100KB body limit 

- Debug mode: Verbose logging with *debug* = t.

- Endpoints: /ping, /health, /tool-call, /mcp.


**Starting**

```
load("mcp_server.lisp");

:lisp (maxima-mcp:start-server 8000)

```

**Examples**
```
curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{ "expression": "erf(0.5);" }' --max-time 5
{"success":true,"result":"displayinput(false,0.5204998778130465)


curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{ "expression": "solve(x^2-2,x);" }' --max-time 5
{"success":true,"result":"displayinput(false,[x = -sqrt(2),x = sqrt(2)])
"}

curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{\"expression\":\"integrate(erf(-x^2/2),x);\"}' --max-time 5
{"success":true,"result":"displayinput(false,
             -(x*erf(x^2/2))-(sqrt(2)*gamma_incomplete(3/4,x^4/4)*x)
                             /(sqrt(%pi)*abs(x)))
"}
```

**Stopping**
```
:lisp (maxima-mcp:stop-server)
```

**Example uses**
- Local LLM tool-calling (Ollama/LM Studio → Maxima)
- Research workflows (Python → symbolic math API)
