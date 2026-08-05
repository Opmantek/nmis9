# Reviewing tests that touch `cgi-bin/` scripts

## The anti-pattern to flag

A test that opens a `cgi-bin/*.pl` file as text and inspects its source. Signs of it:

- `open`/slurp of a script under `cgi-bin/`, then a brace-counter or regex that pulls a named `sub` out of the text.
- `grep` over those lines for call names (`graph_refusal`, `rrdfunc::draw`), with `ok(... =~ /.../)`.
- Ordering asserted by comparing line offsets (`$gate_ln < $draw_ln`).

Why it is weak:

- It tests the shape of the text, not the behaviour. It passes when the right strings appear in the right order and fails on a rename, a reformat, or a helper extraction, even when behaviour is unchanged.
- It gives false confidence. A gate wired to the wrong table, or one whose verdict is discarded, can still contain the expected tokens in the expected order and pass.
- It is a proxy for a property that is directly testable. "The gate runs before the draw and its refusal is acted on" is a runtime behaviour, so test it at runtime.

Live example of the anti-pattern in the tree: `test/t_graph_authz.t` (subtests 1 to 5).
That file arrives with the OMK-12706 branch, so it is not present on every branch yet.

## The pattern to require instead

Drive the real CGI in-process through the `NMISx` Mojolicious app with `Test::Mojo`, against a real authenticated session. This is already the house pattern. Exemplars: `test/t_cgi_xss_escaping.t` and `test/t_cgi_modules_xbase.t`.

Mechanics:

- `lib/NMISx.pm` mounts every `cgi-bin` script via `Mojolicious::Plugin::CGI` under `/cgi-nmis9/<script>.pl` (for example `node.pl` and `rrddraw.pl`). No shim is needed to reach a script.
- `Test::Mojo->new('NMISx')` boots the app in-process.
- Authenticate by POSTing to `/cgi-nmis9/nmiscgi.pl` with `conf`, `auth_username`, `auth_password`. The cookie jar then carries the session for later requests.
- GET the target endpoint and assert on the response with `get_ok`/`status_is`/`content_like`, or read `$t->tx->res->{code,body}` directly.

## Fixtures and isolation the test must follow

- Seed hostile or config values into the untracked `conf/Config.nmis` override, never tracked `conf-default/`. Back up first and restore in an `END` block, so a hard kill can only leave an untracked file behind.
- Seed nodes and inventory through `NMISNG::Node` against the configured database, and delete them in `END`.
- For authorisation tests, a group-restricted user comes from two places. Group membership is set in `conf/Users.nmis` through the user's `groups` field (parsed by `Auth::_GetPrivs`, which calls `SetGroups`). The password is in `conf/users.dat`. The shipped admin `nmis` user sees all groups, so it cannot exercise a group boundary on its own.
- Skip cleanly off the dev container. `plan skip_all` unless MongoDB is configured (`$C->{db_name}`) and unless `Test::Mojo->new('NMISx')` loads. The app and `Plugin::CGI` are only present in the dev container. A bare host must skip, never fail.

## Assertion rules for security and authorisation endpoints

This is the part the structural tests were dodging, and where a shallow behavioural test still fails to prove anything.

- Endpoints refuse in different ways, and the test must match the endpoint. Some emit a visible marker. `node.pl` renders `"Not Authorized"`, so assert on it. Others make refusal deliberately identical to a benign failure. `rrddraw.pl` routes a refusal through the same generic `error()` as a draw failure, so a client cannot tell them apart. That is intended, and it means an HTTP-response assertion alone cannot tell "refused at the gate" from "draw failed for a benign reason".
- For an endpoint whose refusal mimics failure, the test needs a disambiguator. Either a positive control, an authorised identical request that visibly succeeds (for `rrddraw.pl`, a real `image/*` 200), or an in-band side channel, the distinct log line the refusal emits (`not authorised, refused on ...` versus `rrddraw failed: ...`). A test that only asserts "an error came back" for the unauthorised case is not proving the gate. Flag it.
- Always pair a negative case with a positive control, so the test shows the difference is authorisation and not a broken fixture. Without the positive control, a refusal that is really a setup failure passes as green.
- Assert the fail-closed cases as behaviour through the endpoint: unknown node, node carrying no group, blank or missing group, and any pseudo-group promotion (for example an empty group promoted to `network` for metrics graphs). These are the paths a proxy test cannot see leaking.

## When a source-level check is still legitimate

Do not over-correct into banning all structural assertions. A genuine source property that no runtime test can observe is fair game, kept narrow and commented:

- Anti-drift after centralisation. Once an authorisation decision is centralised, a check that the call site has not re-inlined or duplicated it (for example "no second inline group-table test crept back in") guards against the exact regression the centralisation was meant to prevent. That is a property of the source, not of one request.
- The dividing line. If the assertion is about what the code does at runtime (gate refuses, no data leaks, gate runs before the effect), it belongs in a `Test::Mojo` behavioural test. If it is about what the source must not contain (no duplicated decision, no direct table access bypassing the shared helper), a structural check is fine. Scope it to that and state why.

## Reviewer checklist

1. Does the test read a `cgi-bin` script as text and grep its source for sub or call names. If yes, flag and point to the `Test::Mojo` via `NMISx` pattern.
2. Does an authorisation or security test drive the endpoint through a real authenticated session rather than the module in isolation.
3. Does it use a correctly scoped user for the boundary under test (a group-restricted user for a group check, not the all-groups admin).
4. Is there a positive control next to every negative case.
5. For an endpoint whose refusal is indistinguishable from a failure, is there a disambiguator (positive control or log line).
6. Are fixtures isolated in untracked `conf/` and torn down in `END`.
7. Does it `skip_all` cleanly when MongoDB or the `NMISx` app is absent.
