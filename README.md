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


**Starting w/o no wraper**
```
load("mcp_server.lisp");

:lisp (maxima-mcp:start-server 8000)

```

**Starting with wrapper**
```
load("mcp_server.lisp");
load("mcp_wrapper.lisp");
mcp_start_server (8000);
```

**Turning on/off debug output**
```
mcp_debug_on();

mcp_debug_off();
```

**Server status**
```
mcp_status();
```

**Examples**
Start a command shell. Next example is in PowerShell:
```
curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{ "expression": "erf(-0.5);" }' --max-time 5
{"jsonrpc":"2.0","id":null,"result":{"content":[{"type":"text","text":"-0.5204998778130465"}]}}


curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{ "expression": "solve(x^2-2,x);" }' --max-time 5
{"jsonrpc":"2.0","id":null,"result":{"content":[{"type":"text","text":"[x = -sqrt(2),x = sqrt(2)]"}]}}

curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{\"expression\":\"integrate(erf(-x^2/2),x);\"}' --max-time 5
{"jsonrpc":"2.0","id":null,"result":{"content":[{"type":"text","text":"-(x*erf(x^2/2))-(sqrt(2)*gamma_incomplete(3/4,x^4/4)*x)
                             /(sqrt(%pi)*abs(x))"}]}}

 curl.exe -X POST http://127.0.0.1:8000/mcp -H "Content-Type: application/json" -d '{"method":"load","package":"clifford.mac"}' --max-time 5
{"success":true,"result":"Package clifford.mac loaded."}

 curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{ "expression": "clifford(e,3);" }' --max-time 5
{"success":true,"result":"displayinput(false,[1,1,1])
"}

curl.exe -X POST http://127.0.0.1:8000/tool-call -H "Content-Type: application/json" -d '{ "expression": "e[2].e[1];" }' --max-time 5
{"success":true,"result":"displayinput(false,-(e[1] . e[2]))
"}

```

**Stopping**
```
:lisp (maxima-mcp:stop-server)
```
or
```
mcp_stop_server();
```


**Example uses**
- Local LLM tool-calling (Ollama/LM Studio → Maxima)
- Research workflows (Python → symbolic math API)
