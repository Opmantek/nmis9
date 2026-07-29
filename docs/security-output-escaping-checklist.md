# Output-escaping / XSS checklist for NMIS9 CGI changes

A hard pre-PR gate for any change that touches how the CGI GUI or auth renders
collected, config, or request data. Two rounds of review on OMK-12702 each found
sinks the author's own tests passed, because the work was scoped to the review's
findings instead of the whole surface. Do not scope to the report.

## Escaping helpers (lib/NMISNG/Util.pm, plus CGI.pm)

Pick the encoder by the OUTPUT CONTEXT, not the data source:

| Context | Use | Notes |
|---|---|---|
| HTML element content (`td({...}, $x)`, interpolated `print`/`qq`) | `escape_html($x)` | CGI does NOT escape tag content |
| HTML attribute via CGI hashref (`a({href=>$x})`, `Link({-href=>$x})`) | CGI auto-escapes it | but NOT the `'` char, and NOT scheme; add `safe_url` for a URL |
| `start_html(-xbase => $x)` | `escape_html(safe_url($x))` | CGI does NOT auto-escape `-xbase` (it DOES escape `-title`) |
| URL in an href/src/value | `escape_html(safe_url($x))` | `safe_url` blocks `javascript:`/`data:` and control chars |
| Inside a `<script>` block / `window.location=` / `on*` handler | `escape_js_string($x)` | HTML escaping is WRONG here - the browser does not HTML-decode inside `<script>` |
| Download filename / `Content-Disposition` | `safe_filename($x)` | strips CR/LF so the header cannot be split |
| Anything logged (`logAuth`, ...) | `sanitise_log_line($x)` | flattens CR/LF/control so logs cannot be forged |

Request params from `$q->Vars` are already entity-encoded by
`NMISNG::Util::filter_params`; do not double-encode them. Collected (SNMP) and
config-file values are NOT filtered and must be escaped on output.

## Before opening the PR

1. **Exhaustive independent sink sweep** of EVERY edited file (separate from the
   fixing). Grep for every class, not just what a review named:
   - CGI content args and interpolated `print`/`qq` HTML;
   - `start_html` named params (`-xbase`, `-script`, `-style`, ...);
   - JS contexts: `<script>`, `window.location`, `onclick`/`on*`, `var x = "..."`;
   - `CGI::url(-query=>1)` reflected into output;
   - `Content-Disposition`/filenames and `logAuth` calls.
2. **Probe each distinct framework context empirically** (a 5-line script).
   Never generalise one probe to another context. `$q->Vars` is a tied hash;
   writing back through it collapses multi-value params.
3. **Drive every edited endpoint in a render test** - the real page, not just an
   extracted helper. Plant a marker in EVERY rendered field and assert no raw
   payload survives anywhere in the response.
4. **Test a changed function's full contract and all its consumers**, not just
   the reported symptom.
5. **Gate on a different-model review.** A Claude reviewer shares a Claude
   author's blind spots; "a Claude reviewer passed it" is weak evidence.

## Running the tests

Host-runnable unit tests: `prove test/t_util_escape.pl test/t_filter_params.t`.
Full CGI render suite needs the dev container (Test::Mojo driving the real cgi-bin
through NMISx) - see the test-environment notes:
- `test/t_cgi_xss_escaping.t` - stored-XSS sweep across find.pl / network.pl /
  community_rss.pl with a seeded marker node.
- `test/t_cgi_modules_xbase.t` - fail-without-fix regression for the modules.pl
  `start_html(-xbase)` sink, driven with a hostile `<url_base>` in an isolated
  (untracked conf/) config so the base URL is not corrupted for other pages.
