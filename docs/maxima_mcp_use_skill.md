# Maxima MCP Server — Use Skill

You have access to a running Maxima CAS (Computer Algebra System) server via HTTP on
`http://localhost:8000`. Use it to perform symbolic mathematics, retrieve documentation,
and inspect the user's Maxima session. Always prefer the MCP tools/call interface.

---

## How to Call the Server

All requests go to `POST http://localhost:8000/mcp` with `Content-Type: application/json`.

Template:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "<tool_name>",
    "arguments": { "<arg>": "<value>" }
  }
}
```

---

## Available Tools

### 1. `maxima_compute` — Evaluate a Maxima expression

Use for: symbolic computation, simplification, solving, integration, differentiation,
matrix algebra, limits, series, ODE solving, plotting commands.

| Argument | Type | Required |
|---|---|---|
| `expression` | string | yes |

**Examples:**

```json
{"name":"maxima_compute","arguments":{"expression":"diff(x^3*sin(x), x)"}}
```
→ `x^3*cos(x)+3*x^2*sin(x)`

```json
{"name":"maxima_compute","arguments":{"expression":"integrate(exp(-x^2), x, 0, inf)"}}
```
→ `sqrt(%pi)/2`

```json
{"name":"maxima_compute","arguments":{"expression":"solve([x^2+y=4, x+y=2], [x,y])"}}
```
→ `[[x=-1,y=3],[x=2,y=0]]`

```json
{"name":"maxima_compute","arguments":{"expression":"taylor(sin(x), x, 0, 7)"}}
```
→ `x-x^3/6+x^5/120-x^7/5040`

```json
{"name":"maxima_compute","arguments":{"expression":"eigenvalues(matrix([1,2],[3,4]))"}}
```
→ eigenvalues and multiplicities

```json
{"name":"maxima_compute","arguments":{"expression":"ode2('diff(y,x)+y=x, y, x)"}}
```
→ general solution of the ODE

**Security:** The server blocks expressions containing `:lisp` or `quit(`.

---

### 2. `maxima_load` — Load a Maxima package

Use for: enabling extra functionality before calling `maxima_compute` with package functions.

| Argument | Type | Required |
|---|---|---|
| `package` | string | yes |

**Examples:**

```json
{"name":"maxima_load","arguments":{"package":"draw"}}
```
→ enables `draw2d`, `draw3d`

```json
{"name":"maxima_load","arguments":{"package":"distrib"}}
```
→ enables probability distributions (`mean`, `variance`, `pdf_normal`, etc.)

```json
{"name":"maxima_load","arguments":{"package":"linalg"}}
```
→ enables advanced linear algebra functions

```json
{"name":"maxima_load","arguments":{"package":"lapack"}}
```
→ enables LAPACK numerical routines

---

### 3. `maxima_functsource` — Get source of a user-defined function

Use for: inspecting what a function does before calling it; debugging user code.

| Argument | Type | Required |
|---|---|---|
| `name` | string | yes |

**Examples:**

```json
{"name":"maxima_functsource","arguments":{"name":"testf"}}
```
→ returns `testf(x):=x^2+1` (or error if not defined)

```json
{"name":"maxima_functsource","arguments":{"name":"myintegrand"}}
```
→ returns the function body as defined by the user

---

### 4. `maxima_help` — Get documentation for a Maxima function or topic

Use for: looking up syntax, arguments, return values, and references before using a function.
Equivalent to `? topic` at the Maxima prompt.

| Argument | Type | Required |
|---|---|---|
| `topic` | string | yes |

**Examples:**

```json
{"name":"maxima_help","arguments":{"topic":"integrate"}}
```
→ full documentation for `integrate` including definite/indefinite forms

```json
{"name":"maxima_help","arguments":{"topic":"erf"}}
```
→ definition of the error function, formula, references to A&S and DLMF

```json
{"name":"maxima_help","arguments":{"topic":"solve"}}
```
→ syntax, flags like `solveradcan`, `solvefactors`, examples

```json
{"name":"maxima_help","arguments":{"topic":"matrix"}}
```
→ matrix construction syntax and related functions

```json
{"name":"maxima_help","arguments":{"topic":"taylor"}}
```
→ Taylor/Laurent series expansion documentation

---

### 5. `maxima_listfunctions` — List all user-defined functions

Use for: discovering what functions are defined in the current session before calling
`maxima_functsource` or `maxima_compute`.

No arguments required.

```json
{"name":"maxima_listfunctions","arguments":{}}
```
→ returns e.g. `[testf(x),myode(y,x),kernel(t)]`
→ returns `[]` if no user functions are defined

**Workflow:** Call `maxima_listfunctions` first, then `maxima_functsource` on each name
of interest to understand what is available in the session.

---

## Decision Guide

| User intent | Tool to use |
|---|---|
| Compute, simplify, solve, differentiate, integrate | `maxima_compute` |
| Use a package function (draw, distrib, linalg…) | `maxima_load` first, then `maxima_compute` |
| Look up how a built-in function works | `maxima_help` |
| Inspect a user-defined function | `maxima_functsource` |
| Discover what functions exist in the session | `maxima_listfunctions` |

---

## Important Conventions

- **Maxima syntax** uses `^` for exponentiation, `%pi`, `%e`, `%i` for constants,
  `'diff(y,x)` for unevaluated derivatives, and `;` or `$` as terminators
  (the server strips these automatically).
- **Always call `maxima_help`** before using an unfamiliar function to verify argument order.
- **Always call `maxima_load`** before using any package function — loading an already-loaded
  package is harmless.
- **Multi-step computations** — assign intermediate results with `:` e.g.
  `A: matrix([1,2],[3,4])` then use `A` in subsequent calls.
- **Results are strings** — parse them as Maxima output notation, not as JSON numbers or arrays.

---

## Example Multi-Step Session

```
1. maxima_listfunctions          → discover session state
2. maxima_help topic=ode2        → check syntax
3. maxima_compute "ode2('diff(y,x,2)+y=sin(x), y, x)"   → solve ODE
4. maxima_compute "ratsimp(%)"   → simplify result
```
