# Maxima MCP Server v1.1 Technical Specs

**Author**: Dimiter Prodanov, IICT (2026)

## Protocol & Transport
- **Protocol Version**: `2025-06-18`
- **Transport**: Streamable HTTP JSON-RPC 2.0
- **Endpoints**: `POST /mcp` (MCP protocol), `POST /batch` (direct HTTP), `GET /mcp` → `{"error":"Not found"}` (no SSE)
- **HTTP Headers**: Supports `Content-Type: application/json`, `Content-Length`, `Connection: keep-alive`
- **Max Body Size**: 100KB (capped for safety)

## Server Info (initialize response)
```json
{
  "protocolVersion": "2025-06-18",
  "serverInfo": {"name": "maxima-mcp", "version": "1.1"},
  "capabilities": {"tools": {"listChanged": false}}
}
```

## Exposed Tools (tools/list response)
| Tool Name | Description | Input Schema |
|-----------|-------------|--------------|
| `maxima_compute` | Evaluate a single Maxima expression | `{"expression": "string"}` |
| `maxima_load` | Load a Maxima package | `{"package": "string"}` |
| `maxima_functsource` | Get source of a Maxima user function | `{"name": "string"}` |
| `maxima_help` | Describe a Maxima symbol | `{"topic": "string"}` |
| `maxima_batch` | Evaluate a semicolon-separated sequence of expressions | `{"expressions": "string"}` |

## Direct HTTP Endpoints
| Path | Body | Description |
|------|------|-------------|
| `POST /batch` | `{"expressions":"expr1; expr2;"}` | Evaluate batch without MCP wrapper |
| `POST /mcp` | JSON-RPC 2.0 `tools/call` | Standard MCP tool invocation |

## HTTP Response Patterns
- **Success**: `HTTP/1.1 200 OK`, `Content-Type: application/json`
- **Notifications**: `HTTP/1.1 202 Accepted` (`initialize`, `cancelled`)
- **Errors**: `{"error":"Not found"}` or JSON-RPC error codes (-32601, -32602)

## Implementation Details
- **Runtime**: SBCL (Common Lisp), embedded in Maxima
- **Networking**: `sb-bsd-sockets` (TCP, localhost:8000), `sb-thread` for concurrency
- **JSON**: RFC 8259 compliant; non-Latin-1 Unicode encoded as `\uXXXX` (fixes Maxima help output)
- **Argument extraction**: `extract-tool-argument` for MCP path; `extract-json-field` fallback for direct HTTP
- **Batch separator**: real newline (`~%`) between results, JSON-escaped to `\n` in response
- **Maxima Integration**: `maxima:grind` output, cleaned prefixes (`displayinput`, `nodisplayinput`)
- **Debug**: Verbose logging (`*debug* t`)

## Known Fixes (v1.0 → v1.1)
- `handle-batch`: added `extract-json-field` fallback so direct `POST /batch` works without MCP `arguments` wrapper
- `json-escape`: added `(> code 255)` branch to encode Unicode chars (e.g. smart quotes in `describe` output) as `\uXXXX`
- Batch result separator changed from literal `\\n` string to `~%` to avoid double-escaping

## Lifecycle Compatibility
✅ `initialize` → `tools/list` → `notifications/initialized` → `notifications/cancelled`
Compatible with: LM Studio, Open WebUI, ollama-mcp

## Testing (PowerShell)
```powershell
# Batch via pipe (recommended — avoids Content-Length issues)
@{expressions="f(x):=x^2; diff(f(x),x);"} | ConvertTo-Json -Compress | curl.exe -s -X POST http://localhost:8000/batch -H "Content-Type: application/json" -d '@-'

# MCP tools/call
'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"maxima_help","arguments":{"topic":"erf"}}}' | curl.exe -s -X POST http://localhost:8000/mcp -H "Content-Type: application/json" -d '@-'
```