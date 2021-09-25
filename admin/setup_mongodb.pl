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
our $VERSION = "9.0.6a";

use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use MongoDB;
use File::Basename;
use File::Copy;
use version 0.77;
use Tie::IxHash;

use NMISNG::DB;
use NMISNG::Util;
use Compat::NMIS; 								# for nmisng::util::dbg, fixme9
use Data::Dumper;

if (@ARGV == 1 && $ARGV[0] =~ /^--?(h|help|\?)$/i)
{
	die "Usage: ".basename($0). " [auto=0/1] [preseed=/some/file] [drop=dbname1,dbname2...]
auto: non-interactive automatic mode
preseed: pre-seeded non-interactive mode, answers come from the given file
drop: drop listed databases\n\n";
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
https://community.opmantek.com/x/h4Aj\n\n";

	input_ok("Hit enter to continue, Ctrl-C to abort: ");
	print "\n";
	$islocal=0;
}

# if it's local and not running, offer to start it
my $isdead = system("pidof mongod >/dev/null") >> 8;
if ($islocal && $isdead)
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

# now connect, check if auth is enabled; if so, ask for admin user and auth

# get_db_connection is too much hassle as it wants the data structured in a specific way,
# AND insists on authenticating to the admin db.
my $conn;
eval { $conn = MongoDB::MongoClient->new(host => $dbserver, port => $port); };
die("Error: Connection failure for $dbserver:$port: $@\n") if ($@);

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
}
else
{
	print "INFO: failed to retrieve server status from MongoDB, assuming auth is on.\n";
}

my $adminuser = $conf->{db_username};
my $adminpwd = NMISNG::Util::decrypt('database', 'db_password', $conf->{db_password});

if (!$isnoauth)
{
	print "INFO: Your MongoDB seems to be running with authentication required.\n";

	print "\n";
	my $confirm;
	do
	{
		# let's default to our standard user for both admin and operational use...
		$adminuser = input_text("Enter your MongoDB ADMIN user for $dbserver:$port [default: $conf->{db_username}]:","d92b");
		$adminuser = $conf->{db_username} if ($adminuser eq "");

		$confirm = $noninteractive? 1 : input_yn("You entered \"$adminuser\" - is this correct?","9f20");
		print "\n";
	}
	until ($confirm);

	do
	{
		$adminpwd = input_text("Enter your MongoDB ADMIN password [default: " . NMISNG::Util::decrypt('database', 'db_password', $conf->{db_password}) . "]:","18ba");
		$adminpwd = NMISNG::Util::decrypt('database', 'db_password', $conf->{db_password}) if ($adminpwd eq "");

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

	print $authfailed? "ERROR $authfailed\nWill attempt to continue!\n"
			: "INFO: authentication succeeded.\n";
}
my $admindb = $conn->get_database("admin");

# first, check the server version
my $serverinfo = NMISNG::DB::run_command(command => { "buildInfo" => 1 },
																				 db => $admindb);
if (ref($serverinfo) ne "HASH" or !$serverinfo->{ok} or !$serverinfo->{version})
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

print "INFO: server version is $serverinfo->{version}.\n";

# check whether the user exists already, if so grant full privileges for all dbs and ensure the password is set
my $userlist = NMISNG::DB::run_command(db => $admindb,
																			 command => {
																				 "usersInfo" => { user => $adminuser, db => "admin" }, });
# returns users->[0], roles are array of hashes in users->[0]->roles, keys db and role
if (ref($userlist) ne "HASH" or ref($userlist->{users}) ne "ARRAY" or !@{$userlist->{users}})
{
	print "INFO: adding user $adminuser to admin db\n";
	# create the user
	my $create_result =	NMISNG::DB::run_command(db => $admindb,
																					 command => Tie::IxHash->new(
																						 "createUser" => $adminuser,
																						 "pwd" => $adminpwd,
																						 "roles" => ['root'] ) );

	warn "creating $adminuser with root role failed: $create_result\n"
			if (ref($create_result) ne "HASH");
	warn "creating $adminuser with root role failed: $create_result->{errmsg}\n"
			if (!$create_result->{ok});
}
else
{
	print "INFO: user $adminuser already exists in admin db, granting root role\n";
	my $cmd = Tie::IxHash->new("grantRolesToUser" => $adminuser, "roles" => ['root'] );
	my $privl_result = NMISNG::DB::run_command(db => $admindb, command => $cmd);
	warn "upgrade to root role for $adminuser failed: $privl_result\n"
			if (ref($privl_result) ne "HASH");
	warn "upgrade to root role for $adminuser failed: $privl_result->{errmsg}\n"
			if (!$privl_result->{ok});

	print "INFO: setting password for user $adminuser\n";
	$cmd = Tie::IxHash->new("updateUser" => $adminuser, "pwd" => $adminpwd);
	my $pwd_result =  NMISNG::DB::run_command(db => $admindb, command => $cmd);
	warn "setting password for $adminuser failed: $pwd_result\n"
			if (ref($pwd_result) ne "HASH");
	warn "setting password for $adminuser failed: $pwd_result->{errmsg}\n"
			if (!$pwd_result->{ok});
}

# then add or update the correct user in the relevant database(s)
# and grant it dbOwner rights
my $dbname = $conf->{db_name};
my $dbhandle = $conn->get_database($dbname);

# nmis9: just one db, one user
my $dbuser = $adminuser;
my $password = $adminpwd;

$userlist = NMISNG::DB::run_command(db => $dbhandle,
																 command => { "usersInfo" =>
																							{ user => $dbuser, db => $dbname }, });
# returns users->[0], roles are array of hashes in users->[0]->roles, keys db and role
if (!$userlist or !$userlist->{users} or !@{$userlist->{users}})
{
	print "INFO: adding user $dbuser to database $dbname\n";
		my $create_result =	NMISNG::DB::run_command(db => $dbhandle,
																						 command => Tie::IxHash->new(
																							 "createUser" => $dbuser,
																							 "pwd" => $password,
																							 "roles" => ['dbOwner'] ) );
	warn "creating $dbuser with root dbOwner failed: $create_result\n"
			if (ref($create_result) ne "HASH");
	warn "creating $dbuser with root dbOwner failed: $create_result->{errmsg}\n"
			if (!$create_result->{ok});
}
else
{
	print "INFO: user $dbuser already exists in database $dbname, granting dbOwner role\n";
	my $cmd = Tie::IxHash->new("grantRolesToUser" => $dbuser, "roles" => ['dbOwner'] );
	my $privl_result = NMISNG::DB::run_command(db => $dbhandle, command => $cmd);
	warn "upgrade to dbOwner role for $dbuser failed: $privl_result\n"
			if (ref($privl_result) ne "HASH");
	warn "upgrade to dbOwner role for $dbuser failed: $privl_result->{errmsg}\n"
			if (!$privl_result->{ok});

	print "INFO: setting password for user $dbuser\n";
	$cmd = Tie::IxHash->new("updateUser" => $dbuser, "pwd" => $password);
	my $pwd_result =  NMISNG::DB::run_command(db => $dbhandle, command => $cmd);
	warn "setting password for $dbuser failed: $pwd_result\n"
			if (ref($pwd_result) ne "HASH");
	warn "setting password for $dbuser failed: $pwd_result->{errmsg}\n"
			if (!$pwd_result->{ok});

}

# warn about auth being very much recommended!
if ($isnoauth)
{
	print qq|\n\nWARNING: Authentication should be enabled for production use!
Currently your MongoDB server at $dbserver:$port operates without
authentication. This is MongoDB's default, but is not recommended for
production use. You should add the setting auth=true (for 2.4-style config)
or authorization: enabled (for YAML config format)
to your /etc/mongodb.conf or change your init script to include --auth.\n\n
|;
		input_ok("Hit enter to continue:");
}

exit 0;

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
				my $result = ( $answer =~ /^\s*y\s*$/i? 1:0);

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

			if ($input !~ /^\s*[yn]?\s*$/i)
			{
				print "Invalid input \"$input\"\n\n";
				next;
			}

			return ($input =~ /^\s*y?\s*$/i)? 1:0;
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
