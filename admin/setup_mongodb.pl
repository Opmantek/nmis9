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

my $adminuser = $conf->{db_username};


my $adminpwd = NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password');


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
		$adminpwd = input_text("Enter your MongoDB ADMIN password [default: " . NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password') . "]:","18ba");
		$adminpwd = NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password') if ($adminpwd eq "");

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

my $mongod_conf = '/etc/mongod.conf';
if ( ($islocal) and (! -f $mongod_conf) )
{
	die("Error: could not find local mongod configuration file '$mongod_conf' for your local MongoDB server at $dbserver:$port\n");
}
my $islocal_and_mongod_3_4_or_newer = ( ($islocal) and (version->parse($mongod_version) >= version->parse("3.4.0")) );

# warn about auth being very much recommended!
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
			# backup $mongod_conf first - we use timestamp to keep multiple copies:
			print "\n" . `cp -arf "$mongod_conf" "$mongod_conf.\$(date +%s)"` ||
				die ("Error: making backup (1) of $mongod_conf failed with status code: $?\n");

			local $YAML::XS::Boolean="JSON::PP";
			my $yaml=LoadFile($mongod_conf)||die "cannot LoadFile $mongod_conf: $!\n";
			$yaml->{security}{authorization}="enabled";
			DumpFile($mongod_conf,$yaml)||die "cannot DumpFile $mongod_conf: $!\n";

			my $startup = system("service","mongod","restart") >> 8;
			print "ERROR: failed to restart MongoDB, exit code $startup\n" if ($startup);
			sleep 3;
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
		print "\nWARNING: local MongoDB server at $dbserver:$port
operates without a logrotate script!
This is MongoDB's default, but is not recommended for production use.\n\n";

		if (input_yn("Should we add a logrotate script for your local MongoDB server at $dbserver:$port?","399a"))
		{
			# we need $osflavour for logrotate file config:
			#
			# this $osaflavour code copied from installer
			my ($osflavour,$osmajor,$osminor,$ospatch,$osiscentos,$osisrocky);
			if (-f "/etc/redhat-release")
			{
				$osflavour="redhat";
				print "\nINFO: detected OS flavour RedHat/CentOS\n";

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
			print "\n" . `cp -arf "$mongod_conf" "$mongod_conf.\$(date +%s)"` ||
				die ("Error: making backup (2) of $mongod_conf failed with status code: $?\n");

			local $YAML::XS::Boolean="JSON::PP";
			my $yaml=LoadFile($mongod_conf);
			$yaml->{systemLog}{destination}="file";
			$yaml->{systemLog}{logAppend}=JSON::PP::true;
			$yaml->{systemLog}{logRotate}="reopen";
			DumpFile($mongod_conf,$yaml);

			my $mongod_systemlog_path = $yaml->{systemLog}{path}||"null";
			if ( (! defined $mongod_systemlog_path) or ($mongod_systemlog_path eq "null") )
			{
				die "Read $mongod_conf systemLog.path not found. Exiting\n";
			}

			my $mongod_logrotate_conf = "/etc/logrotate.d/mongod.conf";

			print "\nwriting logrotate configuration file $mongod_logrotate_conf'\n";
			print "\n" . `cat > "$mongod_logrotate_conf" <<EOF
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
    kill -SIGUSR1 \\\$(pidof mongod) >/dev/null 2>&1||:
  endscript
}
EOF`||die ("Error: could not writing logrotate configuration file $mongod_logrotate_conf with status code: $?\n");

			print "\nchmod 0644 $mongod_logrotate_conf\n";
			print "\n" . `chmod 0644 "$mongod_logrotate_conf" 2>&1;` ||
				die ("Error: chmod 0644 $mongod_logrotate_conf failed with status code: $?\n");

			# restart mongod to implement settings for logrotate test
			print "\nrestarting mongod to implement settings for logrotate ...\n\n";
			my $startup = system("service","mongod","restart") >> 8;
			print "ERROR: failed to restart MongoDB, exit code $startup\n" if ($startup);
			sleep 3;

			# test logrotate:
			print "\ntesting logrotate ...\n\n";
			print "\n" . `logrotate -vf "$mongod_logrotate_conf"` ||
				die ("Error: testing logrotate failed with status code: $?\n");
		}
	}
}


print "\nMongoDB server at $dbserver:$port setup completed\n\n";

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
