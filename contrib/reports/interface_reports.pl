#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
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

# copy me or sym link me to /usr/local/nmis9/admin before you run me.
# ln -s /usr/local/nmis9/contrib/reports/interface_reports.pl  /usr/local/nmis9/admin/interface_reports.pl 

# need to verify which Perl libraries are needed.
# you will need to install the Perl MIME tools
# sudo apt install libemail-mime-perl 
# sudo apt install libmime-tools-perl

# setup your base libraries for perl and using the NMIS Perl API
our $VERSION="1.1.0";
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Basename;
use Data::Dumper;
use MIME::Entity;
use Cwd 'abs_path';

use Compat::NMIS;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;

my $defaultConf = "$FindBin::Bin/../../conf";
$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print "Default Configuration directory is '$defaultConf'\n";

# print out a nice version response if someone asks
if ( @ARGV == 1 && $ARGV[0] eq "--version" )
{
	print "version=$NMISNG::VERSION\n";
	exit 0;
}

# setup a nice usage message and let everyone know the purpose of this code
# also inline documentation for the people looking at code, HI!
my $thisprogram = basename($0);
my $usage       = "$thisprogram generates various interface reports from NMIS data.
Initially there is a discards and errors reports, what reports will you add?

Usage: $thisprogram [option=value...] <act=command>

 * act=(report name) email=email\@domain.com quiet=true debug=false
	
   where:
	* act=(report name) 
		Current Reports:
		* discards-errors: find all interfaces with discards in the last 24 hours
    
	* email = email address for notifications
		Send an email with some content in the body and a CSV attachment.

	* output=(true|false|1|0)
		output the exceptions and CSV data to STDOUT default = false

	* subject = \"subject string to use for email\"
		A default subject is setup, override this default.

	* quiet=(true|false|1|0)
		if quiet, no print messages, otherwise let me know, default = true

	* debug=(1-9|true|false)
		Debug what is happening.
 
\n";

# if no CLI arguments die and print usage statement.
die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );

# handle the command line arguments.
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# debug me or not.
my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

# set a default value and if there is a CLI argument, then use it to set the option
my $wantquiet = 1;
$wantquiet =  NMISNG::Util::getbool( $cmdline->{quiet} ) if defined $cmdline->{quiet};

# What is my action!  Must always be set.
my $act = $cmdline->{act} if defined $cmdline->{act};

# set a default value and if there is a CLI argument, then use it to set the option
my $email = 0;
$email = $cmdline->{email} if defined $cmdline->{email};

# set a default value and if there is a CLI argument, then use it to set the option
my $customSubject = 0;
$customSubject = $cmdline->{subject} if defined $cmdline->{subject};

# set a default value and if there is a CLI argument, then use it to set the option
my $output = 0;
$output =  NMISNG::Util::getbool( $cmdline->{output} ) if defined $cmdline->{output};

# setup the NMIS logger and use debug, or info arg, or configured log_level
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => undef );

# get an NMIS config and create an NMISNG object ready for use.
if ( not defined $cmdline->{conf}) {
    $cmdline->{conf} = $defaultConf;
}
else {
    $cmdline->{conf} = abs_path($cmdline->{conf});
}

print "Configuration Directory = '$cmdline->{conf}'\n" if ($debug);
# load configuration table
our $C = NMISNG::Util::loadConfTable(dir=>$cmdline->{conf}, debug=>$debug);
my $nmisng = NMISNG->new(config => $C, log  => $logger);

# every report runs and generates a CSV and an email body
if ( $act eq "discards-errors" ) {
	# default subject or use the custom one.
	my $subject = "NMIS Interface Discards and Errors Exception Report: ". NMISNG::Util::returnDateStamp;
	$subject = $customSubject if $customSubject;

	my ($content,$csvData) = runDiscardsErrors();
	notifyByEmail(email => $email, subject => $subject, content => $content, csvName => "nmis-interface-discards-errors.csv", csvData => $csvData);
	print "$content\n\n$csvData\n" if $output;
}
else {
    die $usage;
}

exit 0;

sub runDiscardsErrors {
	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $C->{cluster_id} });
	my %seen;
	my $totalNodes;

	my @exceptions;
	my $csvData;
    
    # define the output heading and the print format
	my @heading = ("node", "ifIndex", "ifDescr", "Description", "ifInDiscards", "ifInErrors", "ifOutDiscards", "ifOutErrors", "ifInDiscardsPer", "ifInErrorsPer", "ifOutDiscardsPer", "ifOutErrorsPer");
	$csvData .= makeLineFromRow(\@heading);

	foreach my $node (sort @$nodes) {
		next if ($seen{$node});
		$seen{$node} = 1;
			
		my $nodeobj = $nmisng->node(name => $node);
		if ($nodeobj) {
            
			my ($configuration,$error) = $nodeobj->configuration();
			my $active = $configuration->{active};
			
			# Only locals and active nodes
			if ($active and $nodeobj->cluster_id eq $C->{cluster_id} ) {

				++$totalNodes;

				my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
				eval {
					$S->init(name=>$node);
				}; if ($@) # load node info and Model if name exists
				{
					print "Error init for $node" if (!$wantquiet);
					next;
				}

				my ($inventory,$error) = $S->inventory(concept => 'catchall');
				if ($error) {
					print STDERR "failed to instantiate catchall inventory: $error\n" if (!$wantquiet);
					next;
				}

				my $catchall_data = $inventory->data();

				if ( NMISNG::Util::getbool( $catchall_data->{nodedown} ) ) {
					print "node $node is down\n" if $debug;
					next;
				}

				my $result = $S->nmisng_node->get_inventory_model(concept => "interface", filter => { historic => 0 });
				if (my $error = $result->error)
				{
					$nmisng->log->error("Failed to get inventory: $error");
					return(0,undef);
				}
				my %interfaces = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});

				foreach my $ifIndex (keys %interfaces) {
					my $type = "pkts_hc";
					if (-f (my $rrdfilename = $S->makeRRDname(type => $type, index => $ifIndex))) {
						print "Processing Node: '$node' Index: '$ifIndex' ifDesc: '$interfaces{$ifIndex}->{ifDescr}' Description: '$interfaces{$ifIndex}->{Description}' File: '$rrdfilename'\n" if $debug;
						# do I need $item?
						#my $rrd = $S->getDBName(graphtype => "pkts_hc", index => $ifIndex);
						#my $use_threshold_period = $C->{"threshold_period-default"} || "-15 minutes";
						# last 24 hours!
						my $use_threshold_period = "-24 hours";
						my $now = time();
						my $endHuman = NMISNG::Util::returnDateStamp($now);
						my $currentStats = Compat::NMIS::getSummaryStats(sys=>$S,type=>$type,start=>$use_threshold_period,end=>$now,index=>$ifIndex);

						if ( ref($currentStats) eq "HASH" ) {
							print Dumper $currentStats if $debug > 2;

							my $ifOutDiscardsProc = $currentStats->{$ifIndex}{ifOutDiscardsProc};
							my $ifOutErrorsProc = $currentStats->{$ifIndex}{ifOutErrorsProc};
							my $ifInDiscardsProc = $currentStats->{$ifIndex}{ifInDiscardsProc};
							my $ifInErrorsProc = $currentStats->{$ifIndex}{ifInErrorsProc};

							my $ifOutDiscards = $currentStats->{$ifIndex}{ifOutDiscards};
							my $ifOutErrors = $currentStats->{$ifIndex}{ifOutErrors};
							my $ifInDiscards = $currentStats->{$ifIndex}{ifInDiscards};
							my $ifInErrors = $currentStats->{$ifIndex}{ifInErrors};

							# we are interested if there are any errors or discards.
							if ( $ifInDiscards > 0 or $ifInErrors > 0 or $ifOutDiscards > 0 or $ifOutErrors > 0 ) {
								print "    Exception: $ifIndex $interfaces{$ifIndex}->{ifDescr} $interfaces{$ifIndex}->{Description}\n" if $debug;
								my @row = ($node,$ifIndex,$interfaces{$ifIndex}->{ifDescr},$interfaces{$ifIndex}->{Description},$ifInDiscards,$ifInErrors,$ifOutDiscards,$ifOutErrors,$ifInDiscardsProc,$ifInErrorsProc,$ifOutDiscardsProc,$ifOutErrorsProc);
								push(@exceptions,"$node interface $interfaces{$ifIndex}->{ifDescr} with description \"$interfaces{$ifIndex}->{Description}\" has exceptions with interface discards and errors");
								$csvData .= makeLineFromRow(\@row);
							}
						}
						else {
							print "ERROR: problem with interface on $node ifIndex=$ifIndex\n";
						}
					}
				}
            }
        }
	}

	# get all the exceptions into a giant string.
	my $content = "No exceptions with discards and errors found at this time\n";
	if (@exceptions) {
		$content = "The following interfaces have exceptions with discards and errors on the interface\n\n";
		$content .= join("\n",@exceptions);
	}

	return($content,$csvData);
}

sub notifyByEmail {
	my %args = @_;

	my $email = $args{email};
	my $subject = $args{subject};
	my $content = $args{content};
	my $csvName = $args{csvName};
	my $csvData = $args{csvData};

	if ($content && $email) {

		print "Sending email with $csvName to $email\n" if $debug;

		my $entity = MIME::Entity->build(
			From=>$C->{mail_from}, 
			To=>$email,
			Subject=> $subject,
			Type=>"multipart/mixed"
		);

		# pad with a couple of blank lines
		$content .= "\n\n";

		$entity->attach(
			Data => $content,
			Disposition => "inline",
			Type  => "text/plain"
		);
										
		if ( $csvData ) {
			$entity->attach(
				Data => $csvData,
				Disposition => "attachment",
				Filename => $csvName,
				Type => "text/csv"
			);
		}

		my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
			# params for connection and sending 
			sender => $C->{mail_from},
			recipients => [$email],
		
			mailserver => $C->{mail_server},
			serverport => $C->{mail_server_port},
			hello => $C->{mail_domain},
			usetls => $C->{mail_use_tls},
			ipproto =>  $C->{mail_server_ipproto},
								
			username => $C->{mail_user},
			password => $C->{mail_password},
		
			# and params for making the message on the go
			to => $email,
			from => $C->{mail_from},
		
			subject => $subject,
			mime => $entity,
			priority => "Normal",
		
			debug => $C->{debug}
		);
		
		if (!$status)
		{
			print "Error: Sending email to $email failed: $code $errmsg\n" if (!$wantquiet);
		}
		else
		{
			print "Test Email to $email sent successfully\n" if (!$wantquiet);
		}
	}
} 

sub makeLineFromRow {
	my $data = shift;
	# join with CSV delimiters
	my $output = join("\",\"",@$data);
	# pad text with " and a new line
	return "\"$output\"\n";
}
