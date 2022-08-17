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
# a command-line node import tool for NMIS 9
use strict;
our $VERSION = "9.4.1";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
    print "version=$VERSION\n";
    exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;
use Mojo::File;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS;
use Compat::Timing;

use Fcntl qw(:DEFAULT :flock);

my $bn = basename($0);
my $usage = "Usage: $bn csv=[csv file path] [extras...]

$bn will import nodes to NMIS.
ERROR: need some files to work with
usage: $bn csv=csv file simulate=t/f
eg: $bn csv=/usr/local/nmis9/admin/import_nodes_sample.csv

simulate=t [t by default] will show a report with the list of
verbose=1|0 [1 by default] 0 will suppress verbose output
nodes to update/create

The sample CSV looks like this:
--sample--
name,host,group,roleType,community,netType,activated.NMIS,activated.opConfig
import_test1,127.0.0.1,Branches,core,nmisGig8,1,1
import_test2,127.0.0.1,Sales,core,nmisGig8,lan,1,1
import_test3,127.0.0.1,DataCenter,core,nmisGig8,lan,1,1
--sample--

\n\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
                                                                                    debug => $cmdline->{debug});
die "no config available!\n" if (ref($config) ne "HASH"
                                                                 or !keys %$config);

# log to stderr if debug is given
my $logfile = $config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
                                                                 debug => $cmdline->{debug}) // $config->{log_level},
                                                             path  => (defined $cmdline->{debug})? undef : $logfile);

# now get us an nmisng object, which has a database handle and all the goods
my $nmisng = NMISNG->new(config => $config, log  => $logger);


# keith debug
#my $nodeobj = $nmisng->node(uuid => "f77a28a6-4ab8-43f7-9e27-ed61f48aa8b1");
#print Dumper $nodeobj;

# Check params
my $csvfile = $cmdline->{csv};
my $simulate = $cmdline->{simulate} // "t";
my $time = $cmdline->{time};
my $debug = $cmdline->{debug} ? undef : NMISNG::Util::getbool($cmdline->{debug});
my $verbose = $cmdline->{verbose} ? 1 : NMISNG::Util::getbool($cmdline->{verbose});

die "invalid nodes file $csvfile argument!\n" if (!-r $csvfile);

my $t = Compat::Timing->new;
print $t->elapTime(). " Begin\n" if $time;

print $t->markTime(). " Loading the Import Nodes from $csvfile\n" if $time;
my %newNodes = &myLoadCSV($csvfile,"name",",");
print "  done in ".$t->deltaTime() ."\n" if $time;

my $nodenamerule = $config->{node_name_rule} || qr/^[a-zA-Z0-9_. -]+$/;

print "\n" if $verbose;
my $sum = initSummary();
print $t->markTime(). " Processing nodes \n" if $time;
foreach my $node (keys %newNodes)
{
    print $t->markTime(). " Processing $node \n" if $time;
    die "Invalid node name \"$node\"\n"
            if ($node !~ $nodenamerule);

    if ( $newNodes{$node}{name} ne ""
             and $newNodes{$node}{host} ne ""
             and $newNodes{$node}{roleType} ne ""
             and $newNodes{$node}{community} ne ""
    ) {

        my $nodename = $newNodes{$node}{name};
        my $nodeuuid = $newNodes{$node}{uuid};
        ++$sum->{total};

        my $nodemodel = $nmisng->get_nodes_model(filter => {name => $nodename, uuid => $nodeuuid});
        my $isnew = 0;
        my $operation;

        if (!$nodemodel->count) {
            print "ADDING: node=$newNodes{$node}{name} host=$newNodes{$node}{host} group=$newNodes{$node}{group}\n" if $verbose;
            ++$sum->{add};
            $isnew = 1;
            $operation = "create";
        } elsif ($nodemodel->count == 1 ) {
            print "UPDATE: node=$newNodes{$node}{name} host=$newNodes{$node}{host} group=$newNodes{$node}{group}\n" if $verbose;
            ++$sum->{update};
            $operation = "update";
        } else {
            print "ERROR: node=$newNodes{$node}{name} returning more than one node. Skipping. \n" if $verbose;
            ++$sum->{error};
            last;
        }

        my $nodeobj;
        
        # New node!
        if ( $isnew == 1 ) {
            $newNodes{$node}{uuid} ||= NMISNG::Util::getUUID($newNodes{$node}{name});
            $nodeobj = $nmisng->node(uuid => $newNodes{$node}{uuid}, create => 1);
            # It will be a local node
            $newNodes{$node}{cluster_id} ||= $config->{cluster_id};
            $newNodes{$node}{threshold} ||= 'true';
            $nodeobj->name($newNodes{$node}{name});

            # what other defaults should we set
            if ( not defined $newNodes{$node}{netType} or (defined $newNodes{$node}{netType} and $newNodes{$node}{netType} eq "" ) ) {
                $newNodes{$node}{netType} = "lan";
            }


        } else {
            $nodeobj = $nmisng->node(name => $newNodes{$node}{name});
        }
        
        my $curconfig = $nodeobj->configuration;
        my $curoverrides = $nodeobj->overrides;
        my $curactivated = $nodeobj->activated;
        my $curextras = $nodeobj->unknown;
        my $curarraythings = { aliases => $nodeobj->aliases,
                                                     addresses => $nodeobj->addresses };
        my $anythingtodo;

        print "curractivated 1: ". Dumper $curactivated if $debug > 2;

        print "new node: ". Dumper $newNodes{$node} if $debug > 2;

        for my $name (keys %{$newNodes{$node}})
        {
            ++$anythingtodo;

            print "Processing $node name=$name value=$newNodes{$node}{$name}\n" if $debug;

            my $value = $newNodes{$node}{$name};
            undef $value if ($value eq "undef");
            $name =~ s/^entry\.//;

            # translate the backwards-compatibility configuration.active, which shadows activated.NMIS
            $name = "activated.NMIS" if ($name eq "configuration.active");

            # where does it go? overrides.X is obvious...
            if ($name =~ /^overrides\.(.+)$/)
            {
                $curoverrides->{$name} = $value;
            }
            # ...name, cluster_id a bit less...
            elsif ($name =~ /^(name|cluster_id)$/)
            {
                $nodeobj->$name($value);
            }
            # ...and activated.X not at all
            elsif ($name =~ /^activated\.(.+)$/)
            {
                print "Translating activated name=$name value=$value regex=$1\n" if $debug;
                $curactivated->{$1} = $value;
            }
            # ...and then there's the unknown unknowns
            elsif ($name =~ /^unknown\.(.+)$/)
            {
                print "Unknown $name $value\n" if $debug > 1;
                $curextras->{$name} = $value;
            }
            # and aliases and addresses, but these are ARRAYS
            elsif ($name =~ /^((aliases|addresses)\.(.+))$/)
            {
                $curarraythings->{$name} = $value;
            }
            # configuration.X
            elsif ($name =~ /^configuration\.(.+)$/)
            {
                $curconfig->{$name} = $value;
            }
            else
            {
                # Property will be added to configuration?
                
                #print "\t Adding $name val $value \n";
                print "Else $name $value\n" if $debug > 1;
                $curconfig->{$name} = $value;
                #$logger->error("Unknown property \"$name\"!");
                #print "\tUnknown property \"$name\"!\n";
                #last;
            }

            # these have to be set to something if blank
            $curactivated->{NMIS} = 1 if ( not defined $curactivated->{NMIS} );
            $curconfig->{active} = "true" if ( not defined $curconfig->{active} );
            $curconfig->{collect} = "true" if ( not defined $curconfig->{collect} );
            $curconfig->{ping} = "true" if ( not defined $curconfig->{ping} );
        }
        if (!$anythingtodo) {
            $logger->error("No changes for node \"$node\"!");
            print "\tNo changes for node \"$node\"!\n";
            last;
        }

        print "curractivated 2: ". Dumper $curactivated if $debug > 2;

        for ([$curconfig, "configuration"],
                 [$curoverrides, "override"],
                 [$curactivated, "activated"],
                 [$curarraythings, "addresses/aliases" ],
                 [$curextras, "unknown/extras" ])
        {
            my ($checkwhat, $name) = @$_;
            my $error = NMISNG::Util::translate_dotfields($checkwhat) if ($checkwhat);
            if ($error) {
                $logger->error("translation of $name arguments failed: $error");
                print "\ttranslation of $name arguments failed: $error \n";
                #last;
            }
        }

        print "curractivated 3: ". Dumper $curactivated if $debug > 2;
        print Dumper $curconfig if $debug > 2;

        $nodeobj->overrides($curoverrides);
        $nodeobj->configuration($curconfig);
        $nodeobj->activated($curactivated);
        $nodeobj->addresses($curarraythings->{addresses});
        $nodeobj->aliases($curarraythings->{aliases});
        $nodeobj->unknown($curextras);

        if ($simulate eq "f")
        {
            (my $op, $error) = $nodeobj->save;
            if ($op <= 0) { # zero is no saving needed
                $logger->error("Failed to save $node: $error");
                print "\tFailed to save $node! $error \n";
                next;
            }
            print STDERR "\t=> Successfully ${operation}d node $node.\n" if $verbose;              
            #print Dumper($nodeobj);
            
        } else {
            print STDERR "\t=> Node $node not saved. Simulation mode.\n" if $verbose;  
            print Dumper($nodeobj) if $debug > 1;
        }
    }
    else {
        print STDERR "One of the required node fields is blank\n";
        print STDERR "$node field 'name' is blank\n" if $newNodes{$node}{name} eq "";
        print STDERR "$node field 'host' is blank\n" if $newNodes{$node}{host} eq "";
        print STDERR "$node field 'roleType' is blank\n" if $newNodes{$node}{roleType} eq "";
        print STDERR "$node field 'community' is blank\n" if $newNodes{$node}{community} eq "";
    }
    print $t->markTime(). " Processing $node end \n" if $time;
}
print $t->markTime(). " End processing nodes \n" if $time;

    print qq|$sum->{total} nodes processed
$sum->{add} nodes added
$sum->{update} nodes updated
$sum->{error} nodes with error
|;

exit 1;

sub initSummary {
    my $sum;

    $sum->{add} = 0;
    $sum->{update} = 0;
    $sum->{error} = 0;
    $sum->{total} = 0;

    return $sum;
}

sub myLoadCSV {
    my $file = shift;
    my $key = shift;
    my $seperator = shift;
    my $reckey;
    my $line = 1;

    if ( $seperator eq "" ) { $seperator = "\t"; }

    my $passCounter = 0;

    my $i;
    my @rowElements;
    my @headers;
    my %headersHash;
    my @keylist;
    my $row;
    my $head;

    my %data;

    if (sysopen(DATAFILE, "$file", O_RDONLY)) {
        flock(DATAFILE, LOCK_SH) or warn "can't lock filename: $!";

        while (<DATAFILE>) {
            s/[\r\n]*$//g;
            #$_ =~ s/\n$//g;
            # If it is the first pass load the column headers into an array and a hash.
            if ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter == 0 ) {
                ++$passCounter;
                $_ =~ s/\"//g;
                @headers = split(/$seperator|\n/, $_);
                for ( $i = 0; $i <= $#headers; ++$i ) {
                    $headersHash{$headers[$i]} = $i;
                }
            }
            elsif ( $_ !~ /^#|^;|^ |^\n|^\r/ and $_ ne "" and $passCounter > 0 ) {
                $_ =~ s/\"//g;
                @rowElements = split(/$seperator|\n/, $_);
                if ( $key =~ /:/ ) {
                    $reckey = "";
                    @keylist = split(":",$key);
                    for ($i = 0; $i <= $#keylist; ++$i) {
                        $reckey = $reckey.lc("$rowElements[$headersHash{$keylist[$i]}]");
                        if ( $i < $#keylist )  { $reckey = $reckey."_" }
                    }
                }
                else {
                    $reckey = lc("$rowElements[$headersHash{$key}]");
                }
                if ( $#headers > 0 and $#headers != $#rowElements ) {
                    $head = $#headers + 1;
                    $row = $#rowElements + 1;
                    print STDERR "ERROR: $0 in csv.pm: Invalid CSV data file $file; line $line; record \"$reckey\"; $head elements in header; $row elements in data.\n";
                }
                #What if $reckey is blank could form an alternate key?
                if ( $reckey eq "" or $key eq "" ) {
                    $reckey = join("-", @rowElements);
                }

                for ($i = 0; $i <= $#rowElements; ++$i) {
                    if ( $rowElements[$i] eq "null" ) { $rowElements[$i] = ""; }
                    $data{$reckey}{$headers[$i]} = $rowElements[$i];
                }
            }
            ++$line;
        }
        close (DATAFILE) or warn "can't close filename: $!";
    } else {
        $logger->error("cannot open file $file, $!");
    }

    return (%data);
}
