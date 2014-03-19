#!/usr/bin/perl
#
## $Id: t_json.pl,v 1.1 2012/08/13 05:09:18 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;
use NMIS;
use NMIS::Timing;
use NMIS::Connect;
use JSON::XS;
use Storable;
use Fcntl qw(:DEFAULT :flock);


my @files = qw(/usr/local/data/small.nmis /usr/local/data/medium.nmis /usr/local/data/large.nmis);

#my $file = "/usr/local/nmis8/test/ipslacfg-gold.nmis";
#my $newfile = "/usr/local/nmis8/test/ipslacfg-gold-new.nmis";
#my $jsonfile = "/usr/local/nmis8/test/ipslacfg-gold.json";

my $dbfile = "/usr/local/nmis8/test/ipslacfg-gold.db";
my $table = "nodesum";
my $debug = 0;

if ( -f $dbfile ) {
	unlink($dbfile);	
}

my %nvp;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable(conf=>$nvp{conf},debug=>$nvp{debug});

#Turn on master anyway
$C->{server_master} = "true";
$C->{debug} = "true";

my $run = 3;

my $runonce = 0;
my $headers;

while ($run) {
	print "\n*** RUN $run ***\n\n";
	--$run;
	foreach my $file (@files) {
		my $newfile = "$file.nmis";	
		my $jsonfile = "$file.json";	
		my $storfile = "$file.omk";	
		print $t->markTime(). " Loading $file\n";
		my $IIDD = readFiletoHashLocal(file => $file);
		print "  done in ".$t->deltaTime() ."\n";
	
		print $t->markTime(). " Writing Data Dumper $file\n";
		writeHashtoFile(file=>$newfile,data=>$IIDD);
		print "  done in ".$t->deltaTime() ."\n";

		print $t->markTime(). " Storable serialize to file\n";
		store($IIDD,$storfile); 
		print "  done in ".$t->deltaTime() ."\n";
		
		print $t->markTime(). " Storable deserialize from file $storfile\n";
		my $II = retrieve($storfile);
		print "  done in ".$t->deltaTime() ."\n";	
						
		print $t->markTime(). " JSON serialize to file\n";
		open(my $fh, ">$jsonfile");
		print $fh encode_json($IIDD); 
		close $fh;
		print "  done in ".$t->deltaTime() ."\n";
		
		print $t->markTime(). " JSON deserialize from file $jsonfile\n";
		open(my $fh, "<$jsonfile");
		local $/ = undef;
		my $content = <$fh>;
		my $II = decode_json($content);
		close $fh;
		print "  done in ".$t->deltaTime() ."\n";	
		
		print $t->markTime(). " JSON serialize to file with pretty\n";
		open(my $fh, ">$jsonfile");
		#print $fh encode_json($II); 
		print $fh JSON::XS->new->pretty(1)->encode($II);
		close $fh;
		print "  done in ".$t->deltaTime() ."\n";

		print $t->markTime(). " JSON deserialize from file $jsonfile with pretty\n";
		open(my $fh, "<$jsonfile");
		local $/ = undef;
		my $content = <$fh>;
		my $II = decode_json($content);
		close $fh;
		print "  done in ".$t->deltaTime() ."\n";	

	}
}	

exit;


sub main {
	my %ARGS = &getArguements(@ARGV);
	my $debug = $ARGS{debug};

	my $data;
	my $headers;
	my $dbh = &getHandle(db => $ARGS{database});
	if ( defined $ARGS{file} and -f $ARGS{file} ) {
		$data = &loadCSVR($ARGS{file},$ARGS{key},"\t");
		$headers = &sqlCreate(data => $data, table => $ARGS{table}, sql => $ARGS{sql}, do => $ARGS{do}, dbh => $dbh, $debug => $ARGS{debug});
		if ( defined $ARGS{database} and defined $ARGS{table} ) {
			if ( $ARGS{db} eq "true" ) {
					&exportToDB(table => $ARGS{table}, data => $data, headers => $headers, dbh => $dbh, $debug => $ARGS{debug});
			}
		} else {
					print "need to know database and table names.\n";
					exit 0;
		}
	}
	elsif ( $ARGS{desc} eq "true" and defined $ARGS{database} and defined $ARGS{table} ) {
		&descTable(table => $ARGS{table}, dbh => $dbh, $debug => $ARGS{debug});
	}
	elsif ( defined $ARGS{delete} and $ARGS{delete} eq "true" ) {
		&sqlDelete(table => $ARGS{table}, dbh => $dbh, $debug => $ARGS{debug});
	}
	else {
		print "file thingy not defined.\n";
		exit 0;
	}
	$dbh->disconnect();
}


print $t->markTime(). " loadNodeTable\n";
my $NT = loadNodeTable(); # load global node table
print "  done in ".$t->deltaTime() ."\n";

my $servers;
foreach my $node (keys %{$NT}) {
	++$servers->{$NT->{$node}{server}};
}

foreach my $srv (sort keys %{$servers}) {
	print "Server $srv is managing $servers->{$srv} nodes\n";	
}

print $t->elapTime(). " loadServersTable\n";
my $ST = loadServersTable();
for my $srv (keys %{$ST}) {
	print $t->elapTime(). " server ${srv}\n";

	print $t->markTime(). " curlDataFromRemote sumnodetable\n";
	my $data = curlDataFromRemote(server => $srv, func => "sumnodetable", format => "text");
	print "  done in ".$t->deltaTime() ."\n";	
	
}

print $t->markTime(). " loadNodeSummary master=$C->{server_master}\n";
my $NS = loadNodeSummary(master => "true");
print "  done in ".$t->deltaTime() ."\n";	

my $summary;
foreach my $node (keys %{$NS}){
	++$summary->{roleType}{$NS->{$node}{roleType}};
	++$summary->{nodeType}{$NS->{$node}{nodeType}};
	++$summary->{group}{$NS->{$node}{group}};
}

print "\n";
foreach my $sum (sort keys %{$summary}) {
	foreach my $ele (sort keys %{$summary->{$sum}}) {
		print "Summary $sum $ele $summary->{$sum}{$ele}\n";
	}
}

print $t->elapTime(). " End\n";


### read file with lock containing data generated by Data::Dumper, option = lock
###
sub readFiletoHashLocal {
	my %args = @_;
	my $file = $args{file};
	my $lock = $args{lock}; # option
	my %hash;
	my $handle;
	my $line;

	$file .= ".nmis" if $file !~ /\./;

	if ( -r $file ) {
		if (open($handle, "$file")) {
			my $lines;
			while (<$handle>) { 
				$line .= $_;
				++$lines;
				#print "."; 
			}
			print $t->markTime(). "  $lines lines loaded, starting EVAL\n";
			# convert data to hash
			%hash = eval $line;
			print "  EVAL done in ".$t->deltaTime() ."\n";	
		
			if ($@) {
				print STDERR ("ERROR convert $file to hash table, $@\n");
				close $handle;
				return;
			}
			return (\%hash,$handle) if ($lock eq 'true');
			# else
			close $handle;
			return \%hash;
		} else{
			print STDERR ("ERROR cannot open file=$file, $!\n");
		}
	} else {
		if ($lock eq 'true') {
			# create new empty file
			open ($handle,">", "$file") or warn "ERROR readFiletoHash: can't create $file: $!\n";
			return (\%hash,$handle)
		}
		print STDERR ("ERROR file=$file does not exist\n");
	}
	return;
}

sub writeHashtoFileLocal {
	my %args = @_;
	my $file = $args{file};
	my $data = $args{data};
	my $handle = $args{handle}; # if handle specified then file is locked EX

	$file .= '.nmis' if $file !~ /\./;

	dbg("write data to $file");
	if ($handle eq "") {
		if (open($handle, "+<$file")) {
			flock($handle, LOCK_EX) or warn "ERROR writeHashtoFile, can't lock $file, $!\n";
			seek($handle,0,0) or warn "writeHashtoFile, ERROR can't seek file: $!";
			truncate($handle,0) or warn "writeHashtoFile, ERROR can't truncate file: $!";
		} else {
			open($handle, ">$file")  or warn "writeHashtoFile: ERROR cannot open $file: $!\n";
			flock($handle, LOCK_EX) or warn "writeHashtoFile: ERROR can't lock file $file, $!\n";
		}
	} else {
		seek($handle,0,0) or warn "writeHashtoFile, ERROR can't seek file: $!";
		truncate($handle,0) or warn "writeHashtoFile, ERROR can't truncate file: $!";
	}
	if ( not print $handle Data::Dumper->Dump([$data], [qw(*hash)]) ) {
		logMsg("ERROR cannot write file $file: $!");
	}
	close $handle;

	setFileProt($file);
}


sub getArguements {
	my @argue = @_;
	my (%nvp, $name, $value, $line, $i);
	for ($i=0; $i <= $#argue; ++$i) {
		if ($argue[$i] =~ /.+=/) {
			($name,$value) = split("=",$argue[$i]);
			$nvp{$name} = $value;
		}
		else { print "Invalid command argument: $argue[$i]\n"; }
	}
	return %nvp;
}

sub checkArgs {
	if ( $#ARGV < 0 ) {
		print <<EO_TEXT;
$0 process CSV and puts in DB!
command line options are:
  [file=<filename>]\tsource CSV file.
  [database=<database name>]\tDatabase to use.
  [table=<table name>]\tTable to make.
  [db=<true|false>]\tPush into DB.
  [do=<true|false>]\tActually execute the SQL Table Create.
  [debug=<true|false|0-9>]\tTurn on debugging.
EO_TEXT
		exit(0);
	}
} # checkArgs


sub getHandle {
	my %arg = @_;
	my $dbfile = $arg{dbfile};
	
	my $dbargs = {AutoCommit => 0, PrintError => 1};

	print "DBI->connect($dbfile)\n";

  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","",$dbargs);
  return($dbh) ;
    
	#my $databaseName = "DBI:mysql:$arg{db}";
	#my $databaseUser = "admin";
	#my $databaseUser = "root";
	##my $databaseUser = "query";
	#my $databasePw = "An1m0n42";
	#my $dbh = DBI->connect($databaseName, $databaseUser, $databasePw) || die "Connect failed: $DBI::errstr\n";
}
