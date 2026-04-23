# Maxima MCP Server — Use Skill (Small Model Edition)

You have access to a Maxima CAS (Computer Algebra System) via HTTP on `http://localhost:8000`.
Use it for ALL symbolic mathematics. Never compute math yourself — always call a tool.

---

## Tools Available

| Tool | When to use | Required argument |
|---|---|---|
| `maxima_compute` | Evaluate, simplify, solve, differentiate, integrate, ODE | `expression` (string) |
| `maxima_load` | Before using any package function | `package` (string) |
| `maxima_help` | Look up syntax before using an unfamiliar function | `topic` (string) |
| `maxima_functsource` | Inspect a user-defined function | `name` (string) |
| `maxima_listfunctions` | List all user-defined functions in session | *(none)* |

---

## Decision Rules

Follow these rules exactly:

- IF user asks to compute, simplify, solve, differentiate, integrate, or expand → `maxima_compute`
- IF you are unsure of a function's argument order → `maxima_help` FIRST, then `maxima_compute`
- IF expression uses a package function (see list below) → `maxima_load` FIRST, then `maxima_compute`
- IF user asks what a function does → `maxima_help`
- IF user references "my function" or a named function → `maxima_listfunctions` then `maxima_functsource`
- NEVER invent Maxima function names — use only names from the cheatsheet below

---

## Argument Names — Exact Spelling

Always use these exact argument keys:

```json
{"name":"maxima_compute",     "arguments":{"expression":"..."}}
{"name":"maxima_load",        "arguments":{"package":"..."}}
{"name":"maxima_help",        "arguments":{"topic":"..."}}
{"name":"maxima_functsource", "arguments":{"name":"..."}}
{"name":"maxima_listfunctions","arguments":{}}
```

---

## Maxima Function Cheatsheet — Correct Names

Small models frequently hallucinate function names. Use ONLY these:

### Calculus
| Operation | Correct call | Common wrong names |
|---|---|---|
| Differentiate | `diff(f, x)` or `diff(f, x, n)` | `derivative`, `deriv` |
| Indefinite integral | `integrate(f, x)` | `integral`, `antiderivative` |
| Definite integral | `integrate(f, x, a, b)` | `integrate(f, a, b)` |
| Limit | `limit(f, x, a)` | `lim` |
| Taylor series | `taylor(f, x, x0, n)` | `taylor_series`, `series` |

### Transforms
| Operation | Correct call | Notes |
|---|---|---|
| Laplace transform | `laplace(f, t, s)` | 3rd arg is frequency var, NOT a number |
| Inverse Laplace | `ilt(F, s, t)` | NOT `ilaplace` or `inverse_laplace` |
| Fourier (load first) | `load("fourie")` then `fourier(f, x, w)` | NOT `fourier_transform` |

### Algebra
| Operation | Correct call | Common wrong names |
|---|---|---|
| Solve equation | `solve(eq, x)` or `solve([eqs],[vars])` | `solve_for` |
| Factor | `factor(f)` | `factorize`, `factorise` |
| Expand | `expand(f)` | `expand_expr` |
| Partial fractions | `partfrac(f, x)` | `partial_fractions`, `apart` |
| Simplify (rational) | `ratsimp(f)` | `simplify`, `simplify_full` |
| Simplify (radical) | `radcan(f)` | `radsimp` |
| Numerical value | `float(f)` | `eval`, `N(f)` |

### Linear Algebra
| Operation | Correct call | Common wrong names |
|---|---|---|
| Eigenvalues | `eigenvalues(M)` | `eig`, `eigvals`, `eigs` |
| Eigenvectors | `eigenvectors(M)` | `eigvecs` |
| Matrix inverse | `invert(M)` | `inv(M)`, `M^-1` |
| Determinant | `determinant(M)` | `det` |

### ODEs
| Operation | Correct call | Common wrong names |
|---|---|---|
| First/second order ODE | `ode2(eq, y, x)` | `dsolve`, `solve_ode` |
| With initial conditions | `ic1(soln, x=x0, y=y0)` | |
| With boundary conditions | `bc2(soln, x=x0, y=y0, x=x1, y=y1)` | |

### Constants
| Symbol | Maxima | Wrong |
|---|---|---|
| π | `%pi` | `pi`, `PI` |
| e | `%e` | `e`, `E` |
| i (imaginary) | `%i` | `i`, `1i` |
| infinity | `inf` | `infinity`, `Inf` |

---

## Package Functions — Always Load First

These require `maxima_load` before `maxima_compute`:

| Function | Package |
|---|---|
| `draw2d`, `draw3d` | `draw` |
| `pdf_normal`, `mean`, `variance` | `distrib` |
| `laplace_matrix` | `linalg` |
| `fourier` | `fourie` |
| `dgeev` (numerical eigen) | `lapack` |

---

## Worked Examples

### Example 1 — Laplace transform
User: "Compute the Laplace transform of exp(-a*t)"

```json
{"name":"maxima_compute","arguments":{"expression":"laplace(exp(-a*t), t, s)"}}
```
Result: `1/(s+a)`

**NOT:** `laplace_transform(exp(-a*t), t, s)` ← does not exist

---

### Example 2 — ODE with initial condition
User: "Solve y' + 2y = 0, y(0)=3"

Step 1:
```json
{"name":"maxima_compute","arguments":{"expression":"ode2('diff(y,x)+2*y=0, y, x)"}}
```
Step 2 (apply IC):
```json
{"name":"maxima_compute","arguments":{"expression":"ic1(%, x=0, y=3)"}}
```

---

### Example 3 — Unknown function, check first
User: "Use my_kernel function"

Step 1:
```json
{"name":"maxima_listfunctions","arguments":{}}
```
Step 2:
```json
{"name":"maxima_functsource","arguments":{"name":"my_kernel"}}
```
Step 3: use it in `maxima_compute` once you know its arguments.

---

### Example 4 — Package function
User: "Plot sin(x)"

Step 1:
```json
{"name":"maxima_load","arguments":{"package":"draw"}}
```
Step 2:
```json
{"name":"maxima_compute","arguments":{"expression":"draw2d(explicit(sin(x),x,-5,5))"}}
```

---

### Example 5 — Unsure of syntax
User: "Apply Runge-Kutta to this ODE"

Step 1:
```json
{"name":"maxima_help","arguments":{"topic":"rk"}}
```
Then use the correct syntax from the documentation.

---

## Maxima Syntax Reminders

- Assignment: `a: 3` not `a = 3`
- Equation: `x^2 = 1` (used inside `solve`)
- Unevaluated derivative: `'diff(y, x)` (apostrophe suppresses evaluation)
- End of expression: server strips `;` and `$` automatically — do not include them
- Previous result: `%` refers to the last output

---

## Anti-Hallucination Checklist

Before calling `maxima_compute`, verify:
1. ☑ Function name is in the cheatsheet above
2. ☑ Argument key is exactly `expression`
3. ☑ Third argument of `laplace` is a variable name (e.g. `s`), not a number
4. ☑ Package is loaded if the function requires one
5. ☑ Constants use `%pi`, `%e`, `%i` — not `pi`, `e`, `i`
