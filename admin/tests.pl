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
use strict;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use File::Spec;
use Data::Dumper;
use Time::Local;								# report stuff - fixme needs rework!
use Time::HiRes;
use Notify::connectwiseconnector;
use Data::Dumper;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

use NMISNG;
use NMISNG::Log;
use NMISNG::Outage;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use NMISNG::Notify;

use Compat::NMIS;

if ( @ARGV == 1 && $ARGV[0] eq "--version" )
{
	print "version=$NMISNG::VERSION\n";
	exit 0;
}

my $thisprogram = basename($0);
my $usage       = "Usage: $thisprogram [option=value...] <act=command>

 * act=connectwise - Will use the connectwise settings on the config
 * act=email - Will send an email using Contact table
 * act=rrdname [datatype= index= node=] - Will return an rrd based on the parameters
 * act=snmp node=nodename - Will test snmp connection for a node
 * act=syslog - Will send a syslog message based on the configuration
 
\n";

die $usage if ( !@ARGV || $ARGV[0] =~ /^-(h|\?|-help)$/ );
my $Q = NMISNG::Util::get_args_multi(@ARGV);

my $wantverbose = (NMISNG::Util::getbool($Q->{verbose}));
my $wantquiet  = NMISNG::Util::getbool($Q->{quiet});

my $customconfdir = $Q->{dir}? $Q->{dir}."/conf" : undef;
my $C      = NMISNG::Util::loadConfTable(dir => $customconfdir,
																				 debug => $Q->{debug});
die "no config available!\n" if (ref($C) ne "HASH" or !keys %$C);

# log to stderr if debug is given
my $logfile = $C->{'<nmis_logs>'} . "/cli.log";
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
																 debug => $Q->{debug} ) // $C->{log_level},
															 path  => (defined $Q->{debug})? undef : $logfile);

# this opens a database connection
my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
		);

# for audit logging
my ($thislogin) = getpwuid($<); # only first field is of interest

# show the daemon status
if ($Q->{act} =~ /^connectwise/)
{
	my $result = testconnectwise($Q);
	exit 0;
}
elsif ($Q->{act} =~ /^email/)
{
	my $result = testemail($Q);
	exit 0;
}
elsif ($Q->{act} =~ /^rrdname/)
{
    my $datatype = $Q->{datatype};
    my $index = $Q->{index};
    my $node = $Q->{node};
	my $result = testrrdname(datatype => $datatype, index => $index, node => $node);
	exit 0;
}
elsif ($Q->{act} =~ /^snmp/)
{
    my $node = $Q->{node};
    die "Need a node to run " if (!$node);
	my $result = testsnmp(node => $node);
	exit 0;
}
elsif ($Q->{act} =~ /^syslog/)
{
	my $result = testsyslog(args => $Q);
	exit 0;
}

# Test connectwise
sub testconnectwise
{
    my %args = @_;
    my $debug = $args{debug};
    # load configuration table
    my $C = NMISNG::Util::loadConfTable(conf=>$args{conf}, debug=>$args{debug});
    my $CT = NMISNG::Util::loadTable(dir=> "conf", name=>"Contacts", debug=>$args{debug});
    
    my $contactKey = "contact1";
    
    my $target = $CT->{$contactKey}{Email};
    
    print "==============================================\n";
    print "==============Test Connectwise      ==========\n";
    print "==============================================\n";
    
    print "This script will send a connectwise $contactKey $target\n";
    print "Using the configured server $C->{auth_cw_server}\n";
    
    my $event = {
        event => "Test Event " . time,
        node_name => "asgard-local",
        context => {name => "Test ConnectWise Connector"},
        stateless => 0,
        };
    my $message = "Connectwise test";
    my $priority = 1;
    
    # now get us an nmisng object, which has a database handle and all the goods
    my $logfile = $C->{'<nmis_logs>'} . "/connectwiseConnector.log"; 
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
                                                                debug => $debug),
                                                                path  => $logfile);
    my $nmisng = NMISNG->new(config => $C, log  => $logger);
    
    my $result = Notify::connectwiseconnector::sendNotification(C => $C, nmisng => $nmisng, contact => $CT->{$contactKey}, event => $event, message => $message, priority => $priority);
    
    if (!$result)
    {
        print "Error: Connectwise test to $contactKey failed. Check $logfile for details\n";
        return 0;
    }
    else
    {
        print "Connectwise test to $contactKey done $result\n";
        return 1;
    }
}

# Test email 
sub testemail
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============      Test email      ==========\n";
    print "==============================================\n";
    
    # load configuration table
    my $C = NMISNG::Util::loadConfTable(conf=>$args{conf}, debug=>$args{debug});
    my $CT = NMISNG::Util::loadTable(dir=> "conf", name=>"Contacts", debug=>$args{debug});
    
    my $contactKey = "contact1";
    
    my $target = $CT->{$contactKey}{Email};
    
    print "This script will send a test email to the contact $contactKey $target\n";
    print "Using the configured email server $C->{mail_server}\n";
    
    my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
        # params for connection and sending 
        sender => $C->{mail_from},
        recipients => [$target],
    
        mailserver => $C->{mail_server},
        serverport => $C->{mail_server_port},
        hello => $C->{mail_domain},
        usetls => $C->{mail_use_tls},
        ipproto =>  $C->{mail_server_ipproto},
                            
        username => $C->{mail_user},
        password => NMISNG::Util::decrypt('email', 'mail_password', $C->{mail_password}),
    
        # and params for making the message on the go
        to => $target,
        from => $C->{mail_from},
    
        subject => "Normal Priority Test Email from NMIS9\@$C->{server_name}",
        body => "This is a Normal Priority Test Email from NMIS9\@$C->{server_name}",
        priority => "Normal",
    
        debug => $C->{debug}
    
            );
    
    if (!$status)
    {
        print "Error: Sending email to $target failed: $code $errmsg\n";
    }
    else
    {
        print "Test Email to $target sent successfully\n";
    }
    
    ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
        # params for connection and sending 
        sender => $C->{mail_from},
        recipients => [$target],
    
        mailserver => $C->{mail_server},
        serverport => $C->{mail_server_port},
        hello => $C->{mail_domain},
        usetls => $C->{mail_use_tls},
        ipproto =>  $C->{mail_server_ipproto},
                            
        username => $C->{mail_user},
        password => NMISNG::Util::decrypt('email', 'mail_password', $C->{mail_password}),
    
        # and params for making the message on the go
        to => $target,
        from => $C->{mail_from},
    
        subject => "High Priority Test Email from NMIS9\@$C->{server_name}",
        body => "This is a High Priority Test Email from NMIS9\@$C->{server_name}",
        priority => "High",
    
        debug => $C->{debug}
            );
    
    if (!$status)
    {
        print "Error: Sending high priority email to $target failed: $code $errmsg\n";
        return 0;
    }
    else
    {
        print "Test Email to $target high priority sent successfully\n";
        return 1;
    }
}

# Test rrdname
sub testrrdname
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============    Test rrdname      ==========\n";
    print "==============================================\n";
    
    my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);

    my $datatype = $args{datatype} // "ConnectedSubsTable";
    my $index = $args{index} // 5;
    my $node = $args{node} // "AP-CNEP3K-5-CN90-000-1.EASTGRANBURY";

    print "Using datatype $datatype, index $index and node $node \n";
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef );

    my $nmisng = NMISNG->new(config => $config, log  => $logger);

    my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
    
    eval {
        $S->init(name=>$node);
    }; if ($@) # load node info and Model if name exists
    {
         print " Error init for $node\n";
         return 0;
    }
            
    my $inventory = $S->inventory(concept => $datatype, index => $index);
    my $rrdname = $S->makeRRDname(graphtype => $datatype,
							index => $index,
							inventory => $inventory);
    print "RRD name is $rrdname \n";
    return 1;
}

# Test snmp
sub testsnmp
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============      Test snmp       ==========\n";
    print "==============================================\n";
 
    my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
    
    # use debug, or info arg, or configured log_level
    my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $debug, info => $args{info}), path  => undef ); 
    my $nmisng = NMISNG->new(config => $config, log  => $logger);
    
    if ( defined $args{node} ) {
        my $node = $args{node};
        my $nodeobj = $nmisng->node(name => $node);
            if ($nodeobj) {
                my $nodeconfig = $nodeobj->configuration;
                my $exe;
                my $testoid = "1.3.6.1.2.1.1.1.0"; # This is the sysDescr
                # SNMP v3
                if ($nodeconfig->{version} eq "snmpv3") {
                    print "*** Testing snmp with snmpget ". $nodeconfig->{version} . "\n";
                    $exe = "    snmpget -v 3 -u ".$nodeconfig->{username}." -l authNoPriv -a ".$nodeconfig->{authprotocol}." -A ".$nodeconfig->{authpassword}." ".$nodeconfig->{host}." ". $testoid;
                    my $exeoutput = $exe;
                    my $pass = $nodeconfig->{authpassword};
                    $exeoutput =~ s/$pass/\*\*\*\*/;
                    print " Running... $exeoutput \n";
                    my $output = `$exe`;
                    print " Result: ". $output . "\n";
                    
                }
                # SNMP v2c
                elsif ($nodeconfig->{version} eq "snmpv2c") {
                    print "*** Testing snmp with snmpget ". $nodeconfig->{version} . "\n";
                    $exe = "    snmpget -v 2c -c ".$nodeconfig->{community}." ".$nodeconfig->{host}." ". $testoid;
                    my $exeoutput = $exe;
                    my $pass = $nodeconfig->{community};
                    $exeoutput =~ s/$pass/\*\*\*\*/;
                    print " Running... $exeoutput \n";
                    my $output = `$exe`;
                    print " Result: ". $output . "\n";                
                }
                # Now, test Sys with NET::SNMP
                print "\n\n*** Testing snmp with internal NMIS API \n";
                my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
                eval {
                    $S->init(name=>$node);
                }; if ($@) # load node info and Model if name exists
                {
                    print " Error init for $node\n";
                    die;
                }
                my $candosnmp = $S->open(
                    timeout      => $config->{snmp_timeout},
                    retries      => $config->{snmp_retries},
                    max_msg_size => $config->{snmp_max_msg_size},
                    max_repetitions => $config->{snmp_max_repetitions} || undef,
                    oidpkt => $config->{max_repetitions} || 10,
                );
                
                if (!$candosnmp or $S->status->{snmp_error} )
                {
                    print(" SNMP session open to $node failed: " . $S->status->{snmp_error} ."\n\n");
                } else
                {
                    print(" SNMP session open to $node success \n\n" );
                    my ( $result, $status ) = $S->getValues(
                        class   => $S->{mdl}{system}{sys},
                        section => "standard"
                    );
                    if (!$status->{error}) {
                        print ("    Result: " . $result->{'standard'}->{'sysDescr'}->{'value'});
                    } else {
                        print(" SNMP get values failed: ".Dumper($status) );
                    }
                    $S->close;
                }
                print "\n\n** Model: " . $S->{mdl}->{'system'}->{'nodeModel'} ."\n";
                return 1;
                #print Dumper($nodeobj->configuration);
            } else {
                print " Error, no node was found \n";
                return 0;
            }
    }
    else {
        print "Error, need a node to run: node=NODENAME \n";
        return 0;
    }
}

# Test rrdname
sub testsyslog
{
    my %args = @_;
    my $debug = $args{debug};
    
    print "==============================================\n";
    print "==============     Test syslog      ==========\n";
    print "==============================================\n";
    
    # load configuration table
    my $C = NMISNG::Util::loadConfTable(conf=>$args{conf},debug=>$args{debug});
    
    my $timenow = time();
    my $message = "NMIS_Event::$C->{server_name}::$timenow,$C->{server_name},Test Event,Normal,,";
    my $priority = "info";
    
    my $errors = NMISNG::Notify::sendSyslog(
        server_string => $C->{syslog_server},
        facility => $C->{syslog_facility},
        message => $message,
        priority => $priority
    );
    
    if ( !$errors ) {
        print "SUCCESS: syslog message appears to have been sent (udp is not reliable)\n";
        return 1;
    }
    else {
        print "ERROR: sending syslog message to $C->{syslog_server}\n". Dumper($errors);
        return 0;
    }
}
