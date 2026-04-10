# Maxima MCP Server v1.0 Technical Specs

**Author**: Dimiter Prodanov, IICT (2026)  

## Protocol & Transport
- **Protocol Version**: `2025-06-18`  
- **Transport**: Streamable HTTP JSON-RPC 2.0  
- **Endpoint**: `POST /mcp` (primary)  
- **SSE Probe Handling**: `GET /mcp` → `{"error":"Not found"}` (no SSE support) 
- **HTTP Headers**: Supports `Content-Type: application/json`, `Content-Length`, `Connection: keep-alive`  
- **Max Body Size**: 100KB (capped for safety)  

## Server Info (initialize response)
```md
{
"protocolVersion": "2025-06-18",
"serverInfo": {
"name": "maxima-mcp",
"version": "1.0"
},
"capabilities": {
"tools": {
"listChanged": false
}
} }
```

## Exposed Tools (tools/list response)
| Tool Name | Description | Input Schema |
|-----------|-------------|--------------|
| `maxima_compute` | Evaluate a Maxima CAS expression | `{"expression": "string"}` |
| `maxima_load` | Load a Maxima package | `{"package": "string"}` |
| `maxima_functsource` | Get source of Maxima user function | `{"name": "string"}`  

## HTTP Response Patterns
- **Success**: `HTTP/1.1 200 OK`, `Content-Type: application/json`  
- **Notifications**: `HTTP/1.1 202 Accepted` (initialize, cancelled)  
- **Errors**: `{"error": "Not found"}` or JSON-RPC error codes (-32601, -32602)  

## Implementation Details
- **Runtime**: SBCL (Common Lisp), embedded in Maxima  
- **Networking**: `sb-bsd-sockets` (TCP, localhost:8000)  
- **JSON**: RFC 8259 compliant escaping (quotes, backslash, control chars)  
- **Maxima Integration**: `maxima:grind` output, cleaned prefixes (`displayinput`, `nodisplayinput`) [file:148]
- **Threading**: `sb-thread` for concurrent client handling  
- **Debug**: Verbose logging (`debug: t`)  

## Lifecycle Compatibility
✅ `initialize` → `tools/list` → `notifications/initialized` → `notifications/cancelled`  
The server fully implements Streamable HTTP MCP and is compatible with LM Studio, recent Open WebUI, and ollama-mcp

