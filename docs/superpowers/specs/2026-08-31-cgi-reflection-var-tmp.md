# OMK-12926 + OMK-12929 — CGI password reflection fix and dev-entrypoint var/tmp (combined spec + plan)

> Tonight-mode: one implementation pass, one review, Codex `!review` as the PR merge gate.

- **Tickets:** OMK-12926 (Minor, security hygiene), OMK-12929 (Minor). Epic OMK-12644 adjacent.
- **Branch:** `sec/OMK-12926-12929-cgi-reflection-var-tmp` off `origin/nmis9_sec` (14d4aeac). One PR, one commit per ticket.
- **Worktree:** `/home/md/claude-tmp/nmis9-wt-cgi-hygiene`. Container `nmis9-hygiene-test` mounts it (mongo reachable, docker exec is root).

## OMK-12926 — stop reflecting POSTed passwords into the response HTML

**Defect:** `cgi-bin/config.pl` (`displayConfig`, `start_form` around line 171) and `cgi-bin/setup.pl` (`display_setup`, around line 151) call CGI.pm's `start_form` without `-action`. CGI.pm defaults the action to `self_url`, which reserialises every request parameter — including POSTed `value`/`confirm` passwords — into the form's action URL, so submitted secrets come back in cleartext in the page, on refusals and successes alike. Observed and documented during OMK-12827 Slice B test work (comments in `test/t_cgi_config_password_refusals.t` and the vacuous-assertion incident in `test/t_cgi_config_protected_keys.t`).

**Fix:**
- Pass an explicit `-action` carrying the script path with NO query string to those `start_form` calls. Read how each script builds self-referencing links elsewhere first (`url(-absolute => 1)` is the likely idiom; whatever is chosen must preserve the existing form behaviour — the forms POST `act=` and hidden fields, so dropping the query string from the action must not lose parameters the form does not re-submit as fields; verify by reading the form bodies and the existing hidden inputs, and adjust hidden fields if any parameter was only ever carried by the action URL).
- Audit the rest of `cgi-bin/` for `start_form` without `-action`: fix every script that renders after a POST that can carry a secret; for the remainder, list them in the PR (fixing all is fine if mechanical, but do not destabilise pages you cannot drive with a test).
- Regression: extend `test/t_cgi_config_password_refusals.t` and `test/t_cgi_config_protected_keys.t` with assertions that the submitted password value appears NOWHERE in the response body — on the refusal responses and the success response. These assertions must be RED against the current code (the reflection is live; record it) and green after. The vacuity trap from Slice B is documented in those files — anchor carefully.

## OMK-12929 — var/tmp in the dev entrypoint

`docker-dev/docker-entrypoint-dev.sh` `setup()`'s directory loop omits `var/tmp`, which runtime code expects (bit two container sessions during OMK-12827; e.g. `admin/compare_models.pl`). Add `var/tmp` to the loop's list. Verification: `bash -n`, plus in the container confirm the path the loop would create resolves (`docker exec nmis9-hygiene-test bash -c 'grep -n "var/tmp" /usr/local/nmis9/docker-dev/docker-entrypoint-dev.sh'`) — the full entrypoint run is CI's job.

## Constraints (binding)
- No behaviour change beyond the two fixes; nothing under `lib/`.
- The CGI tests must keep their isolation discipline (config backup/restore incl. mode+owner; self-seeded admin; CSRF).
- Never echo secrets; the new assertions must not print the password value on failure (use `ok(index($body, $pw) < 0, ...)` not `unlike` with the value interpolated into the test name/diagnostics).
- Commits: `sec: OMK-12926 - ...` and `fix: OMK-12929 - ...`. NEVER a Co-Authored-By trailer.
- Container tests: `docker exec nmis9-hygiene-test bash -c 'cd /usr/local/nmis9 && perl test/<file>'`.

## Plan (single pass)
1. RED: add the no-reflection assertions to both CGI tests; run in container; record the reflection failing them.
2. Fix the two `start_form` calls; audit `cgi-bin/`; re-run both CGI tests green; run `t_csrf.t` (the chain parser must not be disturbed) and `t_cgi_xss_escaping.t` (nearby rendering).
3. Commit OMK-12926.
4. Add `var/tmp`; `bash -n`; commit OMK-12929.
5. Full suite in container with `-e NMIS_DB_AUTH_SOURCE=admin`; known-environmental trio acceptable; anything else is a blocker.
6. Deliver: push, PR into `nmis9_sec` (title `sec: OMK-12926 + OMK-12929 - no password reflection in CGI responses; dev entrypoint creates var/tmp`), description with the RED evidence and the audit list, `!review`, Jira comments on both tickets.
