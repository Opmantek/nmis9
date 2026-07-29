#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Unit tests for the output-escaping helpers added for the XSS hardening work
# (OMK-12702 group). Pure functions, no MongoDB required, host-runnable.

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use_ok("NMISNG::Util") or BAIL_OUT("cannot load NMISNG::Util");
can_ok("NMISNG::Util", "escape_html", "safe_url")
	or BAIL_OUT("helper subs are missing");

# ---- escape_html -------------------------------------------------------------

is(NMISNG::Util::escape_html("plain text 123"), "plain text 123",
	"escape_html leaves benign text unchanged");

is(NMISNG::Util::escape_html("<img src=x>"), "&lt;img src=x&gt;",
	"escape_html encodes angle brackets");

is(NMISNG::Util::escape_html("a & b"), "a &amp; b",
	"escape_html encodes ampersand");

is(NMISNG::Util::escape_html('say "hi"'), "say &quot;hi&quot;",
	"escape_html encodes double quotes");

is(NMISNG::Util::escape_html("it's"), "it&#39;s",
	"escape_html encodes single quotes");

is(NMISNG::Util::escape_html(undef), "",
	"escape_html returns empty string for undef");

is(NMISNG::Util::escape_html(""), "",
	"escape_html returns empty string for empty input");

# attribute-breakout payload must not survive with a raw quote or angle bracket
my $attr_payload = '" onmouseover="alert(1)" x="';
my $escaped_attr = NMISNG::Util::escape_html($attr_payload);
unlike($escaped_attr, qr/"/, "escape_html leaves no raw double quote (attribute break-out)");

# body-context payload must not survive with raw angle brackets
my $body_payload = '<script>alert(1)</script>';
my $escaped_body = NMISNG::Util::escape_html($body_payload);
unlike($escaped_body, qr/[<>]/, "escape_html leaves no raw angle bracket (body break-out)");

# ampersand must be encoded first so we cannot re-introduce an entity
is(NMISNG::Util::escape_html("&lt;"), "&amp;lt;",
	"escape_html encodes a literal entity-looking string safely");

# ---- safe_url ----------------------------------------------------------------

is(NMISNG::Util::safe_url("http://example.com/path?a=1"), "http://example.com/path?a=1",
	"safe_url passes http through");

is(NMISNG::Util::safe_url("https://example.com"), "https://example.com",
	"safe_url passes https through");

is(NMISNG::Util::safe_url("mailto:ops\@example.com"), "mailto:ops\@example.com",
	"safe_url passes mailto through");

is(NMISNG::Util::safe_url("/relative/path"), "/relative/path",
	"safe_url passes a root-relative path through");

is(NMISNG::Util::safe_url("relative/path?x=1"), "relative/path?x=1",
	"safe_url passes a relative path through");

is(NMISNG::Util::safe_url("#section"), "#section",
	"safe_url passes a fragment through");

is(NMISNG::Util::safe_url("javascript:alert(1)"), "",
	"safe_url blocks javascript scheme");

is(NMISNG::Util::safe_url("JavaScript:alert(1)"), "",
	"safe_url blocks javascript scheme case-insensitively");

is(NMISNG::Util::safe_url("  javascript:alert(1)"), "",
	"safe_url blocks javascript scheme with leading whitespace");

is(NMISNG::Util::safe_url("java\tscript:alert(1)"), "",
	"safe_url blocks javascript scheme with an embedded control character");

is(NMISNG::Util::safe_url("data:text/html,<script>alert(1)</script>"), "",
	"safe_url blocks data scheme");

is(NMISNG::Util::safe_url("vbscript:msgbox(1)"), "",
	"safe_url blocks vbscript scheme");

is(NMISNG::Util::safe_url(undef), "",
	"safe_url returns empty string for undef");

is(NMISNG::Util::safe_url(""), "",
	"safe_url returns empty string for empty input");

# composition: the intended call-site pattern is escape_html(safe_url($x))
is(NMISNG::Util::escape_html(NMISNG::Util::safe_url("javascript:alert(1)")), "",
	"composition neutralises a javascript URL");

my $urlq = NMISNG::Util::escape_html(NMISNG::Util::safe_url('http://x/?a="1"'));
unlike($urlq, qr/"/, "composition leaves a URL attribute-safe (no raw quote)");

# ---- safe_filename (Content-Disposition, OMK-12731) --------------------------

can_ok("NMISNG::Util", "safe_filename", "sanitise_log_line") or BAIL_OUT("helpers missing");

is(NMISNG::Util::safe_filename("report.csv"), "report.csv",
	"safe_filename keeps a benign filename (dots survive)");
is(NMISNG::Util::safe_filename("a/b:c d'e\"f"), "a_b_c_d_e_f",
	"safe_filename replaces path sep, colon, space and quotes");
# the important one: CR/LF must not survive to split a header
my $crlf = "node\r\nSet-Cookie: x=1.csv";
my $sf = NMISNG::Util::safe_filename($crlf);
unlike($sf, qr/[\r\n]/, "safe_filename strips CR/LF (no header injection)");
is(NMISNG::Util::safe_filename(undef), "", "safe_filename returns empty for undef");

# ---- sanitise_log_line (auth-log injection, OMK-12731) ----------------------

my $inj = "attacker\nINFO login accepted for admin";
my $clean = NMISNG::Util::sanitise_log_line($inj);
unlike($clean, qr/\n/, "sanitise_log_line removes newlines (no forged log line)");
like($clean, qr/attacker INFO login/, "sanitise_log_line flattens to one line");
unlike(NMISNG::Util::sanitise_log_line("a\rb\tc"), qr/[\r\t]/,
	"sanitise_log_line also removes CR and tab");
is(NMISNG::Util::sanitise_log_line(undef), "", "sanitise_log_line returns empty for undef");

# ---- escape_js_string (JS-string context inside <script>, OMK-12703) ---------

can_ok("NMISNG::Util", "escape_js_string") or BAIL_OUT("escape_js_string missing");

is(NMISNG::Util::escape_js_string("http://x/ok"), "http://x/ok",
	"escape_js_string leaves a benign URL unchanged");
# single-quote breakout of window.location = '...' must be neutralised
unlike(NMISNG::Util::escape_js_string("'-alert(1)-'"), qr/(?<!\\)'/,
	"escape_js_string escapes every single quote (no JS-string break-out)");
unlike(NMISNG::Util::escape_js_string('a"b'), qr/(?<!\\)"/,
	"escape_js_string escapes double quotes");
# a </script> in the value must not close the inline script block
unlike(NMISNG::Util::escape_js_string("x</script>y"), qr{</script},
	"escape_js_string neutralises </script>");
is(NMISNG::Util::escape_js_string("a\r\nb"), "ab",
	"escape_js_string strips CR/LF");
is(NMISNG::Util::escape_js_string(undef), "", "escape_js_string returns empty for undef");

done_testing();
