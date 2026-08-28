#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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
# a small helper for priming a mongodb installation with suitable settings for NMIS
our $VERSION = "9.0.7a";

use strict;
use warnings;
#use diagnostics;

use FindBin;
use lib "$FindBin::Bin/../lib";

use MongoDB;
use File::Basename;
use File::Copy;
use File::Path qw(make_path);
use File::Temp ();
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use version 0.77;
use Tie::IxHash;

use NMISNG::DB;
use NMISNG::Util;
use Compat::NMIS; 								# for nmisng::util::dbg, fixme9
use Data::Dumper;

# for editing YAML config file
use YAML::XS qw(DumpFile LoadFile);
use JSON::PP;

if (@ARGV == 1 && $ARGV[0] =~ /^--?(h|help|\?)$/i)
{
	die "Usage: ".basename($0). " [auto=0/1] [preseed=/some/file] [drop=dbname1,dbname2...]
auto: non-interactive automatic mode
preseed: pre-seeded non-interactive mode, answers come from the given file
drop: drop listed databases

resetadminpw=1: reset a forgotten MongoDB admin password (local, standalone server,
  run as root). Optional adminuser=<name> (default: the recorded admin, else
  nmis9admin) and newpassword=<pw> (default: prompt; an empty answer generates one).
  Briefly restarts MongoDB with authentication disabled to change the password,
  then re-enables it.\n\n";
}

print basename($0). " version $VERSION\n\n";

# dir=configdir auto=0/1 debug=0/1
my $args = NMISNG::Util::get_args_multi(@ARGV);

# preseed mode is also noninteractive
my $noninteractive = NMISNG::Util::getbool($args->{auto})
		|| ($args->{preseed} && -f $args->{preseed});
my $debug = NMISNG::Util::getbool($args->{debug});

my $answers = load_preseed($args->{preseed}) if ($args->{preseed});
my $cfgdir = ($args->{dir} || "$FindBin::RealBin/../conf");
my $conf = NMISNG::Util::loadConfTable(dir => $cfgdir, debug => $debug);

die "cannot read config file $cfgdir/Config.nmis!\n"
		if (ref($conf) ne "HASH" or not keys %$conf);

# do you want to drop any of the databases?
my @dropthese = split(/\s*,\s*/, $args->{drop}) if ($args->{drop});
die "\nNOT dropping any databases:\nPlease rerun this command with the argument confirm='yes' in all uppercase!\n\n"
		if (@dropthese && (!$args->{confirm} or $args->{confirm} ne "YES"));

my $dbserver = $conf->{db_server};
my $port = $conf->{db_port};

# check if its a local db server or not
print "Checking authentication status for db_server $dbserver...\n";
my $islocal=1;
if ( $dbserver ne "localhost" && $dbserver ne "127.0.0.1" )
{
	print "\nINFO: it appears that your configuration uses a remote MongoDB server!

The database setup operations WILL FAIL unless your remote MongoDB
server is running without authentication (which is unlikely) or has already
been setup with a database user that has full administrative credentials.

To configure MongoDB on a remote server please see the documentation at
    https://docs.community.firstwave.com/wiki/x/d4Cmv\n\n";

	input_ok("Hit enter to continue, Ctrl-C to abort: ");
	print "\n";
	$islocal=0;
}

# if it's local and not running, offer to start it
my $isdead = system("pidof mongod >/dev/null") >> 8;
if ($islocal)
{
	if($isdead)
	{
		# only root privileges can start a service
		if ($< != 0)
		{
			die "ERROR: No daemon active but must be running with root privileges to start one!\n";
		}
		else
		{
			print "\nERROR: No MongoDB daemon active for $dbserver
This script can start a MongoDB daemon if desired.\n\n";

			if (input_yn("Should we try to start a local MongoDB daemon?","993d"))
			{
				my $startup = system("service","mongod","start") >> 8;
				print "ERROR: failed to start MongoDB, exit code $startup\n" if ($startup);
				sleep 3;
			}
			else
			{
				die "ERROR: No daemon active but not allowed to start one!\n";
			}
		}
	}
	# only root privileges can restart a service
	elsif ($< == 0)
	{
		if (input_yn("Should we restart the local MongoDB daemon to refresh settings before we continue?","575c"))
		{
			my $startup = system("service","mongod","restart") >> 8;
			print "ERROR: failed to restart MongoDB, exit code $startup\n" if ($startup);
			sleep 3;
		}
	}
	else # ($< != 0)
	{
		print "INFO: Could not offer to restart your local MongoDB daemon as this process is not running with root privileges\n";
	}
}



# now connect, check if auth is enabled; if so, ask for admin user and auth

# get_db_connection is too much hassle as it wants the data structured in a specific way,
# AND insists on authenticating to the admin db.
my $conn;
eval { $conn = MongoDB::MongoClient->new(host => $dbserver, port => $port); };
die("Error: Connection failure for $dbserver:$port: $@\n") if ($@);

# Recovery action (standalone, NOT part of normal setup): reset a forgotten admin
# password and exit, before the provisioning flow. See reset_admin_password.
if (NMISNG::Util::getbool($args->{resetadminpw}))
{
	reset_admin_password($conn, $args, $dbserver, $port, $islocal, '/etc/mongod.conf');
	exit 0;
}

# check if auth mode is off
my $result = NMISNG::DB::run_command(command => { "getCmdLineOpts" => 1 },
																		 db => $conn->get_database("admin"));
my $isnoauth;
if (ref($result) && $result->{ok})
{
	my $options  = $result->{parsed};
	if (!$options->{auth} or $options->{noauth}
			or (!exists $options->{auth} && !exists $options->{noauth})) # default is no auth
	{
		print "MongoDB on $dbserver:$port is running in non-authenticated mode.\n";
		$isnoauth=1;
	}
	else
	{
		print "MongoDB on $dbserver:$port is running in authenticated mode.\n";
	}
}
else
{
	print "INFO: failed to retrieve server status from MongoDB, assuming auth is on.\n";
}

# OMK-12826: the admin/bootstrap credential is SEPARATE from the app credential.
# db_username/db_password now hold NMIS's own scoped app account, so setup must
# not use them to authenticate as admin. Resolve the admin credential in order:
# the NMIS_DB_ADMIN_* env vars, then the credential file NMIS wrote when it
# provisioned the admin (so a re-run - and, by the same convention, another OMK
# product's install - can pick it up without re-typing), then the interactive
# prompt below, then the legacy shared-admin default.
#
# Once the install is MIGRATED (db_auth_source is set) db_password holds the
# scoped APP secret, which is NOT the admin credential. Defaulting the admin
# password to decrypt(db_password) would make an unattended re-run authenticate
# with the app secret, fail, and later die with a misleading "could not determine
# server version". So only fall back to decrypt(db_password) on a fresh /
# first-migration install.
my $already_migrated = (defined($conf->{db_auth_source}) && $conf->{db_auth_source} ne '');

my $adminuser = $ENV{NMIS_DB_ADMIN_USERNAME};
my $adminpwd  = $ENV{NMIS_DB_ADMIN_PASSWORD};
my $admin_from_file = 0;
if (!defined($adminuser) || !defined($adminpwd))
{
	my ($fu, $fp) = read_mongo_admin_password_file();
	if (defined($fu) && defined($fp))
	{
		$adminuser //= $fu;
		$adminpwd  //= $fp;
		$admin_from_file = 1;
	}
}
$adminuser //= 'opUserRW';    # legacy default when nothing else supplied one
if (!defined($adminpwd))
{
	$adminpwd = $already_migrated
		? undef
		: NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password');
}

if (!$isnoauth)
{
	print "INFO: Your MongoDB seems to be running with authentication required.\n";

	# already-migrated + unattended + no admin creds supplied: we cannot
	# authenticate, because the app secret in db_password is NOT the admin
	# credential. No-op idempotently with an actionable message rather than
	# failing auth and dying later with a misleading "could not determine
	# server version". A preseed file (tags d92b/18ba, read further below via
	# input_text) can also legitimately supply admin creds in unattended mode,
	# so check for those too before deciding there is nothing to do.
	my $preseed_has_admin = (ref($answers) eq 'HASH'
			&& (defined($answers->{d92b}) || defined($answers->{'18ba'})));
	if ($already_migrated && $noninteractive
			&& !defined($ENV{NMIS_DB_ADMIN_USERNAME})
			&& !defined($ENV{NMIS_DB_ADMIN_PASSWORD})
			&& !$admin_from_file
			&& !$preseed_has_admin)
	{
		print "INFO: this install is already migrated (db_auth_source=\"$conf->{db_auth_source}\")\n"
			. "and MongoDB requires authentication. The value in db_password is the scoped\n"
			. "application secret, not an administrator credential, so this unattended re-run\n"
			. "cannot (and need not) re-provision. Nothing to do.\n"
			. "To force re-provisioning, re-run with NMIS_DB_ADMIN_USERNAME and\n"
			. "NMIS_DB_ADMIN_PASSWORD set to a MongoDB administrator, provide the admin\n"
			. "credential file (default /usr/local/etc/firstwave/mongodb-admin-password,\n"
			. "override with NMIS_MONGO_ADMIN_PASSWORD_FILE), supply a preseed file with\n"
			. "admin answers (tags d92b/18ba), or run interactively.\n";
		exit 0;
	}

	print "\n";
	# defaults for the prompt below: the env/legacy resolution above, captured
	# before the loop starts overwriting $adminuser/$adminpwd with entered values.
	my $default_adminuser = $adminuser;
	my $default_adminpwd  = $adminpwd // '';
	my $confirm;
	do
	{
		# let's default to our standard user for both admin and operational use...
		$adminuser = input_text("Enter your MongoDB ADMIN user for $dbserver:$port [default: $default_adminuser]:","d92b");
		$adminuser = $default_adminuser if ($adminuser eq "");

		$confirm = $noninteractive? 1 : input_yn("You entered \"$adminuser\" - is this correct?","9f20");
		print "\n";
	}
	until ($confirm);

	do
	{
		$adminpwd = input_text("Enter your MongoDB ADMIN password [default: $default_adminpwd]:","18ba");
		$adminpwd = $default_adminpwd if ($adminpwd eq "");

		$confirm = $noninteractive? 1 : input_yn("You entered \"$adminpwd\" - is this correct?","3937");
		print "\n";
	}
	until ($confirm);

	# old mongo driver: can authenticate at run time
	# new mongo driver: can ONLY authenticate at connection creation time!
	my $authfailed;
	if ($conn->can("authenticate"))
	{
		my $auth = eval { $conn->authenticate( "admin", $adminuser, $adminpwd ) };
		$authfailed = $@ || ref($auth) ne "HASH"? $auth : undef;
	}
	else
	{
		eval { $conn = MongoDB::MongoClient->new( host => $dbserver,
																							port => $port,
																							username => $adminuser,
																							password => $adminpwd ); };
		$authfailed = ($@ or !$conn)? $@ : undef;
	}
	# both new and some old drivers make connection lazily, so we're not told about failed auth!
	# new driver, however doesn't let you ping with dud auth. old driver is somewhat more stupid
	# so this is a best-effort thing...
	if ($conn && !$authfailed)
	{
		my $verify = NMISNG::DB::run_command(command => { ping => 1 },
																				 db => $conn->get_database("admin"));
		$authfailed = $verify->{err} if (!$verify->{ok});
	}

	die("ERROR: MongoDB admin authentication failed: $authfailed\n"
			. "Set NMIS_DB_ADMIN_USERNAME and NMIS_DB_ADMIN_PASSWORD to a MongoDB\n"
			. "administrator credential (or re-run interactively and supply one) and try again.\n")
		if ($authfailed);
	print "INFO: authentication succeeded.\n";
}
my $admindb = $conn->get_database("admin");

# first, check the server version
my $serverinfo = NMISNG::DB::run_command(command => { "buildInfo" => 1 },db => $admindb);

my $mongod_version = $serverinfo->{version};

if (ref($serverinfo) ne "HASH" or !$serverinfo->{ok} or !$mongod_version)
{
	die("Error: could not determine server version for $dbserver:$port\n");
}

# drop the requested dbs, which does NOT affect the users configured on them...weird.
for my $dbname (@dropthese)
{
	print "INFO: Dropping database contents for \"$dbname\" as requested.\n";
	my $res = NMISNG::DB::run_command( db => $conn->get_database($dbname),
																		 command => { 'dropDatabase' => 1 });
	print "Warning: failed to drop database: $res->{error}\n" if (!$res->{ok});
}

print "INFO: server version is $mongod_version.\n";

# OMK-12826: NMIS no longer creates, rotates, or grants root to the shared
# admin account (opUserRW). $adminuser/$adminpwd above are used only to
# authenticate this bootstrap connection when auth is required; management of
# that account is out of scope and belongs to whatever provisioned it.

# OMK-12826/OMK-12709: NMIS's own scoped app user in the nmisng database.
my $dbname   = $conf->{db_name} // 'nmisng';
my $dbhandle = $conn->get_database($dbname);

# Target app username: migrate the shared opUserRW to nmis9RW; keep any other
# existing choice (a site may already have a custom scoped user).
my $target_user = ($conf->{db_username} // 'opUserRW');
$target_user = 'nmis9RW' if ($target_user eq 'opUserRW' || $target_user eq '');

# App password. Honour an operator- or env-supplied value; generate one only
# when the effective value is a shipped default or the ship placeholder. This
# keeps the docker/env path (which supplies NMIS_DB_PASSWORD) and a real install
# (which ships a placeholder) both correct, and never overwrites a deliberate
# password. The default set mirrors installer_hooks/common_dbpassword.sh.
my $curpw = NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password') // '';
my $is_default = ($curpw eq '' || $curpw eq 'op42flow42' || $curpw eq 'example'
	|| $curpw eq 'password' || $curpw =~ /^CHANGE_ME/);
my $genpw = $curpw;
my $generated = 0;
if ($is_default)
{
	$genpw = generate_password()
		or die "ERROR: could not generate a database password (need /dev/urandom or Math::Random::Secure)\n";
	$generated = 1;
}

my $userlist = NMISNG::DB::run_command(db => $dbhandle,
	command => { "usersInfo" => { user => $target_user, db => $dbname } });
if (!$userlist or !$userlist->{users} or !@{$userlist->{users}})
{
	print "INFO: creating scoped user $target_user in $dbname (dbOwner)\n";
	my $r = NMISNG::DB::run_command(db => $dbhandle,
		command => Tie::IxHash->new("createUser" => $target_user, "pwd" => $genpw,
			"roles" => [ { role => 'dbOwner', db => $dbname } ]));
	die "creating $target_user failed: " . (ref($r) eq 'HASH' ? $r->{errmsg} : $r) . "\n"
		if (ref($r) ne 'HASH' || !$r->{ok});
}
else
{
	print "INFO: updating scoped user $target_user in $dbname (dbOwner, new password)\n";
	my $r1 = NMISNG::DB::run_command(db => $dbhandle,
		command => Tie::IxHash->new("updateUser" => $target_user, "pwd" => $genpw,
			"roles" => [ { role => 'dbOwner', db => $dbname } ]));
	die "updating $target_user failed: " . (ref($r1) eq 'HASH' ? $r1->{errmsg} : $r1) . "\n"
		if (ref($r1) ne 'HASH' || !$r1->{ok});
}

# Only now that the user exists, switch the live config over. patch_config.pl
# writes conf/Config.nmis. A failed provisioning above dies before this point,
# so a broken run never leaves the config pointing at a user that was not made.
my $cfgfile   = $conf->{configfile};
my $patchtool = $conf->{'<nmis_base>'} . "/admin/patch_config.pl";

# Order matters (OMK-12826). Persist db_password FIRST (when we generated it),
# then the db_username/db_auth_source pointers. --value-file takes only one key,
# so the secret write is necessarily a separate patch_config.pl call from the
# pointers, and the two cannot be one atomic write. Writing the credential before
# the pointers means a failure between them leaves db_auth_source still unset, so
# the config still names the pre-migration user; a re-run detects that (it is not
# yet migrated), reads the already-stored generated password, and completes
# idempotently. The reverse order would point the app at nmis9RW with a stale
# password and report the install as migrated.
#
# Feed the secret via a 0600 temp file so it never lands in the process command
# line (/proc/<pid>/cmdline) or a shell pipe. An operator/env-supplied value is
# honoured for the user above but not written to disk, so an env-only secret is
# not persisted here.
if ($generated)
{
	my $pwtmp = File::Temp->new(UNLINK => 1);
	chmod 0600, $pwtmp->filename;
	print $pwtmp $genpw;
	$pwtmp->flush;
	my $rc = system($patchtool, $cfgfile, "--value-file", $pwtmp->filename, "/database/db_password");
	$rc == 0 or die "ERROR: failed to write db_password to $cfgfile\n";	# name only the key, never the value
}
$genpw = "x" x 64; undef $genpw;

# Then switch the pointer keys over in a SINGLE patch_config.pl call: it reads,
# edits both in memory, and writes once, so db_username and db_auth_source land
# all-or-nothing with no half state. Non-secret, so they go via argv; on failure
# name only the KEYS, never any value.
system($patchtool, $cfgfile,
	"/database/db_username=$target_user",
	"/database/db_auth_source=$dbname") == 0
	or die "ERROR: failed to write db_username/db_auth_source to $cfgfile\n";
print "INFO: NMIS is now configured to use scoped user $target_user in $dbname.\n";

my $mongod_conf = '/etc/mongod.conf';
if ( ($islocal) and (! -f $mongod_conf) )
{
	die("Error: could not find local mongod configuration file '$mongod_conf' for your local MongoDB server at $dbserver:$port\n");
}
my $islocal_and_mongod_3_4_or_newer = ( ($islocal) and (version->parse($mongod_version) >= version->parse("3.4.0")) );

# warn about auth being very much recommended!
# OMK-12826: track whether an auth-enable that the operator ASKED for actually
# succeeded. A failure on this mandatory-hardening path must exit non-zero (so
# installer hook 24 aborts) instead of reporting success with Mongo left
# unauthenticated. Declining the offer (116b "no") is a deliberate no-auth choice
# and stays a success.
my $auth_enable_failed = 0;
if ($isnoauth)
{
	# only root privileges can edit $mongod_conf
	if ( ($islocal_and_mongod_3_4_or_newer) and ($< != 0) )
	{
		print "INFO: Could not offer to set authentication for your local MongoDB daemon as this process is not running with root privileges\n";
	}

	# offer to set authentication enabled for mongod version 3.4 or newer, but only root privileges can edit $mongod_conf
	if ( ($islocal_and_mongod_3_4_or_newer) and ($< == 0) )
	{
		print "\nWARNING: Authentication should be enabled for production use!
Currently your local MongoDB server at $dbserver:$port operates without
authentication. This is MongoDB's default, but is not recommended for
production use.\n\n";

		if (input_yn("Should we add the setting 'authorization: enabled' to your ${mongod_conf}?","116b"))
		{
			# OMK-12826: enabling auth closes MongoDB's localhost exception, so an
			# administrative user must already exist or nobody can manage the server
			# afterwards. NMIS provisions only the scoped nmis9RW (no admin role), so
			# create a separate admin with a generated password when none exists.
			# ensure_admin_user refuses (returns 'error') rather than leave an admin
			# whose password could not be recorded, and we then do NOT enable auth.
			my ($astatus, $amsg) = ensure_admin_user($conn, $dbserver, $port);
			print "INFO: $amsg\n" if ($astatus eq 'created');
			if ($astatus eq 'error')
			{
				print "\nERROR: $amsg\n"
					. "NOT enabling authentication: doing so without a usable administrative\n"
					. "credential would lock MongoDB administration out via the closed\n"
					. "localhost exception. Resolve the above and re-run.\n\n";
				input_ok("Hit enter to continue:");
				$auth_enable_failed = 1;
			}
			# a non-zero restart means mongod.conf says authorization:enabled but the
			# running daemon has not picked it up, so the server is still unauthenticated
			elsif (enable_mongo_auth($mongod_conf) != 0)
			{
				$auth_enable_failed = 1;
			}
		}
		else
		{
			print qq|\n\nWARNING: You should add the setting authorization: enabled
to your $mongod_conf or change your init script to include --auth.\n\n
|;
			input_ok("Hit enter to continue:");
		}
	}
	else
	{
		print qq|\n\nWARNING: Authentication should be enabled for production use!
Currently your MongoDB server at $dbserver:$port operates without
authentication. This is MongoDB's default, but is not recommended for
production use. You should add the setting auth=true (for 2.4-style config)
or authorization: enabled (for YAML config format)
to your $mongod_conf or change your init script to include --auth.\n\n
|;
		input_ok("Hit enter to continue:");
	}
}


# set up mongod logrotate if definitely not set:
# https://www.percona.com/blog/2018/09/27/automating-mongodb-log-rotation/
my $mongod_logrotate_conf_not_found = ((! -e "/etc/logrotate.d/mongod.conf") and
									   (! -e "/etc/logrotate.d/mongo.conf") and
									   (! -e "/etc/logrotate.d/mongodb.conf")
									  );
if ($mongod_logrotate_conf_not_found)
{
	# only root privileges can edit $mongod_conf
	if ( ($islocal_and_mongod_3_4_or_newer) and ($< != 0) )
	{
		print "INFO: Could not offer to add a logrotate script for your local MongoDB daemon as this process is not running with root privileges\n";
	}

	# offer to set logrotate for mongod version 3.4 or newer
	if ( ($islocal_and_mongod_3_4_or_newer) and ($< == 0) )
	{
		print "\nWARNING: local MongoDB server at $dbserver:$port operates without a logrotate script!
This is MongoDB's default, but is not recommended for production use.\n\n";

		if (input_yn("Should we add a logrotate script for your local MongoDB server at $dbserver:$port?","399a"))
		{
			# we need $osflavour for logrotate file config:
			#
			# this $osflavour code copied from installer
			my ($osflavour,$osmajor,$osminor,$ospatch,$osiscentos,$osisrocky);
			if (-f "/etc/redhat-release")
			{
				$osflavour="redhat";
				print "INFO: detected OS flavour RedHat/CentOS\n";

				open(F, "/etc/redhat-release") or die "cannot read redhat-release: $!\n";
				my $reldata = join('',<F>);
				close(F);

				($osmajor,$osminor,$ospatch) = ($1,$2,$4)
						if ($reldata =~ /(\d+)\.(\d+)(\.(\d+))?/);
				if ($reldata =~ /CentOS/)
				{
					$osiscentos = 1;
				}
				if ($reldata =~ /Rocky/)
				{
					$osisrocky = 1;
				}
			}
			elsif (-f "/etc/os-release")
			{
				# First try to find the exact ID like debian, or ubuntu.
				# If unsuccessful, then look at the ID_LIKE field.
				# We search for Debian last as even Ubuntu is 'ID_LIKE=debian'.
				# This should catch Mint ans similar Ubuntu derivatives.
				open(F,"/etc/os-release") or die "cannot read os-release: $!\n";
				my $osinfo = join("",<F>);
				close(F);
				if ($osinfo =~ /ID=[\"\']?debian/)
				{
					$osflavour="debian";
					print "\nINFO: detected OS flavour Debian\n";
				}
				elsif ($osinfo =~ /ID=[\"\']?ubuntu/)
				{
					$osflavour="ubuntu";
					print "\nINFO: detected OS flavour Ubuntu\n";
				}
				($osmajor,$osminor,$ospatch) = ($1,$3,$5)
						if ($osinfo =~ /VERSION_ID=\"(\d+)(\.(\d+))?(\.(\d+))?\"/);

				# This code should mimic that in ./installer_hooks/common_functions.sh flavour () function
				# grep 'ID_LIKE' as a catch-all for debian and ubuntu repectively - done last to not affect existing tried and tested code:
				if ( ! defined($osflavour) )
				{
					if ($osinfo =~ /ID_LIKE=[\"\']?debian/)
					{
						$osflavour="debian";
						my $debian_codename=$1 if ($osinfo =~ /DEBIAN_CODENAME=\s*[\"\']?(.+)[\"\']?\s*/);
						# we dont need 'else' catch-all blocks here as we fall back to the debian version
						# populated in the generic block above:
						if ( defined($debian_codename) )
						{
							if ($debian_codename =~ /bookworm/i)
							{
								$osmajor=12;
								$osminor=0;
								$ospatch=0;
							}
							elsif ($debian_codename =~ /bullseye/i)
							{
								$osmajor=11;
								$osminor=0;
								$ospatch=0;
							}
							elsif ($debian_codename =~ /buster/i)
							{
								$osmajor=10;
								$osminor=0;
								$ospatch=0;
							}
							elsif ($debian_codename =~ /stretch/i)
							{
								$osmajor=9;
								$osminor=0;
								$ospatch=0;
							}
							elsif ($debian_codename =~ /jessie/i)
							{
								$osmajor=8;
								$osminor=0;
								$ospatch=0;
							}
						}
						print "\nINFO: detected OS derivative of Debian: \$osmajor='$osmajor'; \$osminor='$osminor'; \$ospatch='$ospatch'\n";
					}
					elsif ($osinfo =~ /ID_LIKE=[\"\']?ubuntu/)
					{
						$osflavour="ubuntu";
						print "\nINFO: detected OS derivative Ubuntu\n";
						my $ubuntu_codename=$1 if ($osinfo =~ /UBUNTU_CODENAME=\s*[\"\']?(.+)[\"\']?\s*/);
						# we dont need 'else' catch-all blocks here as we fall back to the ubuntu version
						# populated in the generic block above:
						if ( defined($ubuntu_codename) )
						{
							if ($ubuntu_codename =~ /lunar/i)
							{
								$osmajor=23;
								$osminor=04;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /kinetic/i)
							{
								$osmajor=22;
								$osminor=10;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /jammy/i)
							{
								$osmajor=22;
								$osminor=04;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /impish/i)
							{
								$osmajor=21;
								$osminor=10;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /hirsute/i)
							{
								$osmajor=21;
								$osminor=04;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /groovy/i)
							{
								$osmajor=20;
								$osminor=10;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /focal/i)
							{
								$osmajor=20;
								$osminor=04;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /eoan/i)
							{
								$osmajor=19;
								$osminor=10;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /disco/i)
							{
								$osmajor=19;
								$osminor=04;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /cosmic/i)
							{
								$osmajor=18;
								$osminor=10;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /bionic/i)
							{
								$osmajor=18;
								$osminor=04;
								$ospatch=0;
							}
							elsif ($ubuntu_codename =~ /xenial/i)
							{
								$osmajor=16;
								$osminor=04;
								$ospatch=0;
							}
						}
						print "\nINFO: detected OS derivative of Ubuntu: \$osmajor='$osmajor'; \$osminor='$osminor'; \$ospatch='$ospatch'\n"
					}
				}
			    if ( ! defined($osflavour) )
				{
					logdie("Unsupported or unknown distribution!\n");
				}

			}
			# rhel|centos have user 'mongod' while debian|ubuntu have users 'mongodb'
			my $mongod_user;
			if ( ($osflavour eq "debian") or ($osflavour eq "ubuntu") )
			{
				$mongod_user = "mongodb";
			}
			else # ("$osflavour" == "rhel") # which includes "centos"
			{
				$mongod_user = "mongod";
			}

			# backup $mongod_conf first - we use timestamp to keep multiple copies:
			my $mongod_conf_backup = "$mongod_conf." . time;
			# stat before the copy, which would otherwise bump the source access time.
			# error handling as for backup (1) above:
			my @mongod_conf_stat = stat($mongod_conf);
			@mongod_conf_stat
				or die ("Error: cannot stat $mongod_conf for backup (2): $!\n");
			copy($mongod_conf, $mongod_conf_backup)
				or die ("Error: making backup (2) of $mongod_conf failed: $!\n");
			# preserve mode and timestamps, as 'cp -a' did:
			chmod(($mongod_conf_stat[2] & 07777), $mongod_conf_backup)
				or warn ("WARNING: could not preserve mode on $mongod_conf_backup: $!\n");
			utime($mongod_conf_stat[8], $mongod_conf_stat[9], $mongod_conf_backup)
				or warn ("WARNING: could not preserve timestamps on $mongod_conf_backup: $!\n");
			print "\nbacked up $mongod_conf to $mongod_conf_backup\n";

			local $YAML::XS::Boolean="JSON::PP";
			my $yaml=LoadFile($mongod_conf)||die "cannot LoadFile $mongod_conf: $!\n";
			$yaml->{systemLog}{destination}="file";
			$yaml->{systemLog}{logAppend}=JSON::PP::true;
			$yaml->{systemLog}{logRotate}="reopen";
			DumpFile($mongod_conf,$yaml)||die "cannot DumpFile $mongod_conf: $!\n";

			# no '|| "null"' default here: it hid undef from the '! defined' test and
			# made it dead code. the guard below rejects anything else that is not a path:
			my $mongod_systemlog_path = $yaml->{systemLog}{path};
			if ( (! defined $mongod_systemlog_path) or ($mongod_systemlog_path eq "") )
			{
				die "Read $mongod_conf systemLog.path not found. Exiting\n";
			}

			# this becomes the stanza header of the logrotate config written below, which
			# we then run with -vf, and logrotate runs postrotate as root. a value with
			# a newline plus '}' would close our stanza and open its own, so allow only
			# a plain path. \z not $, as $ would let a trailing newline through:
			if ($mongod_systemlog_path !~ m{\A/[A-Za-z0-9._/-]+\z})
			{
				die "Error: $mongod_conf systemLog.path must be a plain absolute path "
					. "(letters, digits and '/', '.', '_', '-' only). Refusing to write "
					. "a logrotate configuration for it. Exiting\n";
			}

			my $mongod_logrotate_conf = "/etc/logrotate.d/mongod.conf";

			print "\nwriting logrotate configuration file $mongod_logrotate_conf\n";
			open(my $logrotate_fh, '>', $mongod_logrotate_conf)
				or die ("Error: could not open logrotate configuration file $mongod_logrotate_conf: $!\n");
			print $logrotate_fh <<"EOF";
$mongod_systemlog_path {
  weekly
  maxsize 500M
  rotate 50
  missingok
  compress
  delaycompress
  notifempty
  create 640 $mongod_user $mongod_user
  sharedscripts
  postrotate
    /bin/kill -SIGUSR1 \$(pidof mongod) >/dev/null 2>&1||:
  endscript
}
EOF
			close($logrotate_fh)
				or die ("Error: could not write logrotate configuration file $mongod_logrotate_conf: $!\n");

			print "\nchmod 0644 $mongod_logrotate_conf\n";
			chmod(0644, $mongod_logrotate_conf)
				or die ("Error: chmod 0644 $mongod_logrotate_conf failed: $!\n");

			# restart mongod to implement settings for logrotate test
			print "restarting mongod to implement settings for logrotate ...\n";
			my $startup = system("service","mongod","restart") >> 8;
			print "ERROR: failed to restart MongoDB, exit code $startup\n" if ($startup);
			sleep 3;

			# test logrotate. a warning and not fatal, matching the mongod restart above
			# and what the backticks here effectively did:
			print "\ntesting logrotate ...\n\n";
			print "\n";
			my $logrotate_status = system("logrotate", "-vf", $mongod_logrotate_conf) >> 8;
			print "ERROR: testing logrotate failed, exit code $logrotate_status\n"
				if ($logrotate_status);
		}
	}
}


# OMK-12826: an auth-enable the operator asked for but that failed (admin could
# not be provisioned/recorded, or mongod did not restart) must not report success:
# exit non-zero so installer hook 24 aborts rather than leaving a fresh install
# unauthenticated while claiming it is done.
if ($auth_enable_failed)
{
	print "\nERROR: MongoDB authentication could not be enabled, so the server is left\n"
		. "unauthenticated. Fix the cause reported above and re-run this helper as root.\n\n";
	exit 1;
}

print "\nMongoDB server at $dbserver:$port setup completed\n\n";

exit 0;

# OMK-12826: true if MongoDB already has a user that can administer auth after it
# is enabled (root, userAdminAnyDatabase, or userAdmin on admin). Queried on the
# admin db, where those users live. On any failure it returns false, so setup
# fails safe and declines to enable auth rather than risk locking administration
# out. The role decision itself lives in NMISNG::DB::has_admin_capable_user.
sub admin_user_present
{
	my ($conn) = @_;
	my $r = NMISNG::DB::run_command(
		db      => $conn->get_database("admin"),
		command => { "usersInfo" => 1 });
	my $users = (ref($r) eq 'HASH' && ref($r->{users}) eq 'ARRAY') ? $r->{users} : [];
	return NMISNG::DB::has_admin_capable_user($users);
}

# OMK-12826: generate a 64-hex-char (32-byte) password from the kernel CSPRNG,
# falling back to Math::Random::Secure, as nmis_authkey_generate does. Returns
# the hex string, or undef if neither source is available.
sub generate_password
{
	my $pw = '';
	if (open(my $ur, '<:raw', '/dev/urandom'))
	{
		my $b; $pw = unpack('H*', $b) if (read($ur, $b, 32) == 32);
		close($ur);
	}
	if (length($pw) != 64)
	{
		eval { require Math::Random::Secure;
		       $pw = join('', map { sprintf('%08x', Math::Random::Secure::irand()) } 1..8); 1 }
			or $pw = '';
	}
	return (length($pw) == 64) ? $pw : undef;
}

# OMK-12826: record a generated MongoDB admin password in a root-only file, the
# same convention as the nmis GUI initial password (dir 0700, file 0600,
# root-owned, O_EXCL|O_NOFOLLOW). Returns undef on success or an error string.
sub write_mongo_admin_password_file
{
	my ($pwfile, $server, $port, $user, $pw) = @_;
	my $err;
	eval {
		my $pwdir = dirname($pwfile);
		make_path($pwdir, { mode => 0700 }) if (!-d $pwdir);
		# re-tighten even if the dir pre-existed with looser perms, so a
		# world-readable parent cannot expose the filename
		chmod(0700, $pwdir) or warn "WARNING: could not chmod $pwdir to 0700: $!\n";
		unlink($pwfile);
		sysopen(my $pfh, $pwfile, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
			or die "open $pwfile: $!\n";
		print $pfh <<"FILE" or die "write $pwfile: $!\n";
NMIS-provisioned MongoDB administrator
server:   $server:$port
username: $user
password: $pw

This is the administrative credential for your MongoDB. NMIS itself runs as a
separate, scoped user (see db_username in conf/Config.nmis) and does not use this
account. Record this password somewhere safe, then secure or delete this file.
FILE
		close($pfh) or die "close $pwfile: $!\n";
		chown(0, -1, $pwfile)    # best effort, needs root
			or warn "WARNING: could not chown $pwfile to root: $!\n";
		1;
	} or do { $err = $@ || "unknown error"; };
	return $err;
}

# OMK-12826: read the admin credential NMIS recorded in write_mongo_admin_password_file,
# so a re-run (or, by the same convention, another OMK product's install) can
# authenticate without re-typing. Returns (username, password), or () when the file
# is absent, unreadable (e.g. not root), or does not contain both fields. The file
# is 0600 root-only, so a non-root caller simply gets () and falls back to the prompt.
sub read_mongo_admin_password_file
{
	my $pwfile = $ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE}
		|| '/usr/local/etc/firstwave/mongodb-admin-password';
	open(my $fh, '<', $pwfile) or return ();
	my ($user, $pw);
	while (my $line = <$fh>)
	{
		$user = $1 if ($line =~ /^username:\s*(\S+)/);
		$pw   = $1 if ($line =~ /^password:\s*(\S+)/);
	}
	close($fh);
	return (defined($user) && defined($pw)) ? ($user, $pw) : ();
}

# OMK-12826: ensure MongoDB has an administrative user before auth is enabled, so
# turning auth on does not close the localhost exception with nobody able to
# manage users. Called only on a fresh no-auth local server. NMIS provisions only
# the scoped nmis9RW (no admin role), so this creates a separate admin with a
# generated password when none exists. Returns ($status, $message):
#   'exists'  an admin-capable user already exists, nothing done
#   'created' a scoped admin was created and its password recorded
#   'error'   could not provision/record one; the caller must NOT enable auth
# If the generated password cannot be recorded the just-created user is dropped,
# so a half-provisioned admin with an unknown password is never left behind.
sub ensure_admin_user
{
	my ($conn, $server, $port) = @_;

	return ('exists', undef) if (admin_user_present($conn));

	my $adminuser = 'nmis9admin';
	my $adminpw   = generate_password()
		or return ('error', "could not generate an administrator password "
			. "(need /dev/urandom or Math::Random::Secure)");

	my $cr = NMISNG::DB::run_command(
		db      => $conn->get_database("admin"),
		command => Tie::IxHash->new("createUser" => $adminuser, "pwd" => $adminpw,
			"roles" => [ { role => 'root', db => 'admin' } ]));
	if (ref($cr) ne 'HASH' || !$cr->{ok})
	{
		$adminpw = 'x' x 64; undef $adminpw;
		return ('error', "creating administrator '$adminuser' failed: "
			. (ref($cr) eq 'HASH' ? ($cr->{errmsg} // '') : $cr));
	}

	my $pwfile = $ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE}
		|| '/usr/local/etc/firstwave/mongodb-admin-password';
	my $ferr = write_mongo_admin_password_file($pwfile, $server, $port, $adminuser, $adminpw);
	$adminpw = 'x' x 64; undef $adminpw;

	if ($ferr)
	{
		# roll back: never leave an admin whose generated password nobody recorded
		my $dr = NMISNG::DB::run_command(db => $conn->get_database("admin"),
			command => { "dropUser" => $adminuser });
		my $dropped = (ref($dr) eq 'HASH' && $dr->{ok})
			? "dropped it again"
			: "and FAILED to drop it - remove '$adminuser' from the admin db by hand";
		return ('error', "created administrator '$adminuser' but could not record its "
			. "password ($ferr); $dropped");
	}
	return ('created', "created MongoDB administrator '$adminuser'; its generated "
		. "password is recorded in $pwfile");
}

# OMK-12826: set 'security.authorization' in mongod.conf to $mode ('enabled' or
# 'disabled') and restart mongod. Backs the file up first (fatal on backup
# failure), preserving its mode and timestamps. Returns the restart exit code
# (0 = ok) so callers can propagate a failed restart. `service` wraps systemd and
# SysV; NMIS installs the mongodb-org packages, whose service is `mongod` and
# config is /etc/mongod.conf.
sub set_mongo_authorization
{
	my ($mongod_conf, $mode) = @_;

	# backup $mongod_conf first - we use timestamp to keep multiple copies.
	# fatal on failure, unlike the backticks this replaced: their '|| die' was
	# unreachable, so a failed backup used to be ignored
	my $mongod_conf_backup = "$mongod_conf." . time;
	# stat before the copy, which would otherwise bump the source access time.
	# fatal if it fails, or the mode arithmetic below chmods the backup to 0000:
	my @mongod_conf_stat = stat($mongod_conf);
	@mongod_conf_stat
		or die ("Error: cannot stat $mongod_conf for backup (1): $!\n");
	copy($mongod_conf, $mongod_conf_backup)
		or die ("Error: making backup (1) of $mongod_conf failed: $!\n");
	# preserve mode and timestamps, as 'cp -a' did. the backup is already on
	# disk, so lost metadata only warrants a warning:
	chmod(($mongod_conf_stat[2] & 07777), $mongod_conf_backup)
		or warn ("WARNING: could not preserve mode on $mongod_conf_backup: $!\n");
	utime($mongod_conf_stat[8], $mongod_conf_stat[9], $mongod_conf_backup)
		or warn ("WARNING: could not preserve timestamps on $mongod_conf_backup: $!\n");
	print "\nbacked up $mongod_conf to $mongod_conf_backup\n";

	local $YAML::XS::Boolean="JSON::PP";
	my $yaml=LoadFile($mongod_conf)||die "cannot LoadFile $mongod_conf: $!\n";
	$yaml->{security}{authorization}=$mode;
	DumpFile($mongod_conf,$yaml)||die "cannot DumpFile $mongod_conf: $!\n";

	my $startup = system("service","mongod","restart") >> 8;
	print "ERROR: failed to restart MongoDB, exit code $startup\n" if ($startup);
	sleep 3;
	return $startup;
}

# OMK-12826: enable auth. Thin wrapper over set_mongo_authorization, kept so the
# enable-auth caller reads clearly. Returns the restart exit code (0 = ok), so a
# non-zero restart can be propagated to a still-unauthenticated exit.
sub enable_mongo_auth
{
	my ($mongod_conf) = @_;
	return set_mongo_authorization($mongod_conf, 'enabled');
}

# Poll until mongod at $dbserver:$port accepts connections again after a restart.
# Uses `hello`, which is allowed before authentication, so this detects readiness
# whether or not auth is on. Returns 1 when up, 0 on timeout.
sub wait_for_mongod
{
	my ($dbserver, $port, $tries) = @_;
	$tries //= 30;
	for my $i (1 .. $tries)
	{
		my $c = eval { MongoDB::MongoClient->new(host => $dbserver, port => $port,
			connect_timeout_ms => 2000, server_selection_timeout_ms => 2000) };
		if ($c)
		{
			my $h = eval { NMISNG::DB::run_command(db => $c->get_database("admin"),
				command => { hello => 1 }) };
			return 1 if (ref($h) eq 'HASH' && $h->{ok});
		}
		sleep 1;
	}
	return 0;
}

# Recovery helper (NOT part of OMK-12826): reset a forgotten MongoDB admin
# password. MongoDB has no in-place reset for a forgotten credential - the
# localhost exception only applies when no users exist - so the only supported
# path is to restart mongod without access control, change the password, then
# re-enable auth. Standalone local server only; a replica set uses keyfile
# internal auth that this does not disable, so it is refused. Runs as root.
# The no-auth window trusts the configured bindIp (a host mongod is loopback).
sub reset_admin_password
{
	my ($conn, $args, $dbserver, $port, $islocal, $mongod_conf) = @_;

	die "ERROR: admin password reset is only supported for a LOCAL MongoDB (db_server is \"$dbserver\").\n"
		. "Reset a remote server on its own host.\n" if (!$islocal);
	die "ERROR: admin password reset must run as the root user (to edit $mongod_conf and restart mongod).\n"
		if ($< != 0);
	die "ERROR: could not find $mongod_conf; cannot manage authentication to reset the password.\n"
		if (!-f $mongod_conf);

	# refuse on a replica set: the keyfile still enforces internal auth, so
	# disabling authorization would not open the server for the reset.
	my $hello = NMISNG::DB::run_command(command => { hello => 1 },
		db => $conn->get_database("admin"));
	die "ERROR: this MongoDB is a replica set (setName=\"$hello->{setName}\"). The disable-auth\n"
		. "reset does not apply to replica sets (keyfile internal auth); use a replica-set\n"
		. "member recovery procedure instead.\n"
		if (ref($hello) eq 'HASH' && $hello->{setName});

	# which admin: explicit arg, else the recorded credential file's username, else
	# NMIS's own admin.
	my $adminuser = $args->{adminuser};
	if (!defined($adminuser) || $adminuser eq '')
	{
		my ($fu) = read_mongo_admin_password_file();
		$adminuser = (defined($fu) && $fu ne '') ? $fu : 'nmis9admin';
	}

	# new password: explicit arg, else prompt (empty answer = generate). Always
	# recorded in the credential file afterwards.
	my $newpw = $args->{newpassword};
	if (!defined($newpw))
	{
		$newpw = input_text("Enter a new password for MongoDB admin \"$adminuser\", "
			. "or hit Enter to generate one:", "7a1c");
	}
	my $generated = 0;
	if (!defined($newpw) || $newpw eq '')
	{
		$newpw = generate_password()
			or die "ERROR: could not generate a password (need /dev/urandom or Math::Random::Secure).\n";
		$generated = 1;
	}

	print "\nWARNING: resetting the admin password restarts MongoDB with authentication\n"
		. "DISABLED, changes the password, then re-enables authentication and restarts\n"
		. "again. There is a brief window where MongoDB runs without access control.\n\n";
	if (!$noninteractive && !input_yn("Proceed with resetting admin \"$adminuser\"?", "3e9d"))
	{
		print "Admin password reset aborted; nothing changed.\n";
		$newpw = "x" x length($newpw); undef $newpw;
		return;
	}

	# do the reset, but ALWAYS re-enable auth afterwards, even on failure, so a
	# failure never leaves the server with authentication disabled.
	my $ok = eval {
		set_mongo_authorization($mongod_conf, 'disabled') == 0
			or die "could not restart mongod with authentication disabled\n";
		wait_for_mongod($dbserver, $port)
			or die "mongod did not accept connections after the no-auth restart\n";

		my $c2 = MongoDB::MongoClient->new(host => $dbserver, port => $port);
		my $r = NMISNG::DB::run_command(db => $c2->get_database("admin"),
			command => Tie::IxHash->new("updateUser" => $adminuser, "pwd" => $newpw));
		die "updateUser \"$adminuser\" failed: "
			. (ref($r) eq 'HASH' ? ($r->{errmsg} // '') : $r) . "\n"
			if (ref($r) ne 'HASH' || !$r->{ok});
		1;
	};
	my $err = $@;

	# restore auth no matter what
	my $restart = set_mongo_authorization($mongod_conf, 'enabled');
	wait_for_mongod($dbserver, $port);

	if (!$ok)
	{
		$newpw = "x" x length($newpw); undef $newpw;
		die "ERROR: admin password reset failed ($err)"
			. "Authentication has been re-enabled; the password was NOT changed.\n";
	}
	die "ERROR: reset applied but re-enabling authentication did not restart mongod cleanly "
		. "(exit $restart); verify the server state.\n" if ($restart != 0);

	# verify the new credential actually authenticates
	my $c3 = eval { MongoDB::MongoClient->new(host => $dbserver, port => $port,
		username => $adminuser, password => $newpw, db_name => 'admin') };
	my $v = $c3 && eval { NMISNG::DB::run_command(db => $c3->get_database("admin"),
		command => { ping => 1 }) };
	die "ERROR: reset ran but could not authenticate as \"$adminuser\" with the new password.\n"
		if (ref($v) ne 'HASH' || !$v->{ok});
	print "INFO: admin \"$adminuser\" password reset and verified.\n";

	# record the new password so it is not lost again
	my $pwfile = $ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE}
		|| '/usr/local/etc/firstwave/mongodb-admin-password';
	my $ferr = write_mongo_admin_password_file($pwfile, $dbserver, $port, $adminuser, $newpw);
	$newpw = "x" x length($newpw); undef $newpw;
	if ($ferr) { print "WARNING: reset succeeded but could not record the new password in $pwfile ($ferr).\n"; }
	else       { print "INFO: recorded the new password in $pwfile.\n"; }
}

# print question, return true if y (or in unattended mode).
# default is yes, except in preseed mode where the default
# is looked up from the preseed data tagged by the seedling argument
sub input_yn
{
	my ($query, $seedling) = @_;

	while (1)
	{
		print $query;
		if ($noninteractive)
		{
			if ($seedling && ref($answers) && defined($answers->{$seedling}))
			{
				my $answer = $answers->{$seedling};
				my $result = ( $answer =~ /^\s*y(?:es)?\s*$/i? 1:0);

				print " (preseeded answer \"$answer\" interpreted as \""
						.($result? "YES":"NO")."\")\n\n";
				return $result;
			}
			else
			{
				print " (auto-default YES)\n\n";
				return 1;
			}
		}
		else
		{
			print "\nType 'y' or <Enter> to accept, or 'n' to decline: ";
			my $input = <STDIN>;
			chomp $input;

			if ($input !~ /^\s*(y(?:es)?|n(?:o)?)?\s*$/i)
			{
				print "Invalid input \"$input\"\n\n";
				next;
			}

			return ($input =~ /^\s*(y(?:es)?)?\s*$/i)? 1:0;
		}
	}
}

# print prompt, read and return response string if interactive;
# or return default response in noninteractive mode.
#
# default  is "", except in preseed mode where the default
# is looked up from the preseed data tagged by the seedling argument
sub input_text
{
	my ($query,$seedling) = @_;

	print $query;

	if ($noninteractive)
	{
		if ($seedling && ref($answers) && defined($answers->{$seedling}))
		{
			my $answer = $answers->{$seedling};

			print " (preseeded answer \"$answer\")\n";
			return $answer;
		}
		else
		{
			print " (auto-default \"\")\n\n";
			return "";
		}
	}
	else
	{
		print "\nEnter new value or hit <Enter> to accept default: ";
		my $input = <STDIN>;
		chomp $input;
		return $input;
	}
}

sub input_ok
{
	my ($msg) = @_;
	print "$msg\n";

	my $x = <STDIN> if (!$noninteractive);
}

# returns hash (ref) of seedling tag -> answer
sub load_preseed
{
	my ($fn) = @_;
	open(F, $fn) or die "cannot read $fn: $!\n";

	my %answers;

	for my $line (<F>)
	{
		if ($line =~ /^([a-f0-9]{4})\s+"([^"]*)"/)
		{
			$answers{$1} = $2;
		}
	}
	close(F);
	return \%answers;
}
