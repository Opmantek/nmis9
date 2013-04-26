#!/usr/bin/perl

use strict;
#use warnings;
use DirHandle;
use Data::Dumper;
#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
#use File::Copy;
use File::Find;
#use File::Path;
use Cwd;

my $site;

my $install = 0;
my $debug = 0;
my $GML = 0;


print qx|clear|;
print <<EOF;
This script will check for CPAN libraries and determine what is missing.
EOF
#
print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Checking Perl version...
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

my $ver = ref($^V) eq 'version' ? $^V->normal : ( $^V ? join('.', unpack 'C*', $^V) : $] );
my $perl_ver_check = '';
if ($] < 5.006001) {  # our minimal requirement for support
	print qq|The version of Perl installed on your server is lower than the minimum supported version 5.6.1. Please upgrade to at least Perl 5.6.1|;
}
else {
	print qq|The version of Perl installed on your server $ver is OK\n|;
}

print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Checking for required Perl modules
++++++++++++++++++++++++++++++++++++++++++++++++++++++

This script checks for installed modules,
first by parsing the src code to build a list of used modules.
THen by checking that the module exists in the src code
or is found in the perl standard @INC directory list.

If the check reports that a required module is missing, this script will install the module, or you may quit or skip 
the script if some unforeseen error occurs.

 		perl -MCPAN -e shell
		 install [module name]

EOF
#

my $src = cwd() . $ARGV[0];
$src = input_str("Full path to distribution folder:", $src);
my $libPath = "$src/lib";


my %nmisModules;			# local modules used in our scripts
my $mod;

# Check that all the local libaries required by NMIS8, are available to us.
# when a module is found, parse it for its own reqired modules, so we build a complete install list
# the nmis base is assumed to be one dir above us, as we should be run from <nmisbasedir>/install folder

# nowlist the missing 1 by 1, and install if user says OK.
while ( input_yn("Check for NMIS required modules and install:") ) {
	# loop over the check and install script

	find(\&getModules, "$src");

	# now determine if installed or not.
	foreach my $mod ( keys %nmisModules ) {

		my $mFile = $mod . '.pm';
		# check modules that are multivalued, such as 'xx::yyy'	and replace :: with directory '/'
		$mFile =~ s/::/\//g;
		# test for local include first
		if ( -e "$libPath/$mFile" ) {
			$nmisModules{$mod}{file} = "$libPath/$mFile" . "\t\t" . &moduleVersion("$libPath/$mFile");
		}
		else {
			# Now look in @INC for module path and name
			foreach my $path( @INC ) {
				if ( -e "$path/$mFile" ) {
					$nmisModules{$mod}{file} = "$path/$mFile" . "\t\t" . &moduleVersion("$path/$mFile");
				}
			}
		}

	}

	listModules();
	
	saveDependancyGml();
	
	if ( $install ) {
		print "\n\n";
		foreach my $k (sort {$nmisModules{$a}{file} cmp $nmisModules{$b}{file}} keys %nmisModules) {
			next unless $nmisModules{$k}{file} eq 'NFF';
			
			# handle some special case
			# rrdtool
			if ( $k eq 'RRDs' ) {
				modInstallYUM('rrdtool perl-rrdtool');
			}
			if ( $k =~/^(?:GD|GD::Graph)/ ) {
				modInstallYUM('perl-GD perl-GDGraph');
			}
			if ( $k eq 'SNMP_Session' ) {
				modInstallMake($k);
			}
			modInstallCPAN($k);
		}
	}
}

sub modInstallCPAN {
	
	my $ki = shift;
	if (  input_yn("Install using shell cmd: perl -MCPAN -e \"install $ki\",  yes to install, no to skip") ) {
		open(PH,"perl -MCPAN -e \"install $ki\" |") || die "Failed to run shell command: perl -MCPAN -e \"install $ki\" $!\n";
			while ( <PH> ) {
				print;
			}
		close PH;
	}
}

sub modInstallYUM {
	
	my $ki = shift;
	if (  input_yn("install using shell cmd: yum install $ki , yes to install, no to skip") ) {
		open(PH,"yum install $ki |") || die "Failed to run shell command: yum install $ki $!\n";
			while ( <PH> ) {
				print;
			}
		close PH;
	}
}

sub modInstallMake {
	
	my $ki = shift;
	print <<EOF;
	-------------------------------------------------------------------	
	Please install using shell cmds as follows, then re-run this script
	tar -xvzf $ki-1.12.tar.gz
	cd $ki-1.12
 	perl Makefile.PL
 	make
 	make test
 	make install
 	------------------------------------------------------------------
EOF
}

# this is called for every file found
sub getModules {

	my $file = $File::Find::name;		# full path here

	return if ! -r $file;
	return unless $file =~ /\.pl|\.pm$/;
	parsefile( $file );
}

# this could be used again to find all module dependancies - TBD
sub parsefile {
	my $f = shift;

	open my $fh, '<', $f or print "couldn't open $f\n" && return;

	while (my $line = <$fh>) {
		chomp $line;
		next unless $line;
		
		# test for module use 'xxx' or 'xxx::yyy' or 'xxx::yyy::zzz'
		if ( $line =~ m/^#/ ) {
			next;
		}
		elsif ( 
			$line =~ m/^(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ 
			or $line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+)/ 
			or $line =~ m/(use|require)\s+(\w+);/ 
		) {
			my $mod = $2;
			if ( defined $mod and $mod ne '' ) {
				$nmisModules{$mod}{file} = 'NFF';					# set all as 'NFF' here, will check installation status of '$mod' next
				$nmisModules{$mod}{type} = $1;
				if (not grep {$_ eq $f} @{$nmisModules{$mod}{by}}) {
					push(@{$nmisModules{$mod}{by}},$f);
				}
			}
		}
		elsif ($line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ ) {
			print "PARSE $f: $line\n" if $debug;
		}

	}	#next line of script
	close $fh;
}



# get the module version
# this is non-optimal, but gets the task done with no includes or 'use modulexxx'
# whhich would kill this script :-)
sub moduleVersion {
	my $mFile = shift;
	open FH,"<$mFile" or return 'FileNotFound';
	while (<FH>) {
		if ( /(?:our\s+\$VERSION|my\s+\$VERSION|\$VERSION|\s+version|::VERSION)/i ) {
			/(\d+\.\d+(?:\.\d+)?)/;
			if ( defined $1 and $1 ne '' ) {
				return " $1";
			}
		}
	}
	close FH;
	return ' ';
}

sub listModules {

	# list modules found/NFF
	my $f1;
	my $f2;
	my $f3;

	format =
  @<<<<<<<<<<<<<<<<<<<<   @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   @>>>>>>>>>
  $f1,                    $f2,                                       $f3
.

	foreach my $k (sort {$nmisModules{$a}{file} cmp $nmisModules{$b}{file} } keys %nmisModules) {
		$f1 = $k;
		( $f2 , $f3) = split /\s+/, $nmisModules{$k}{file}, 2;
		$f3 = ' ' if !$f3;
		write();
	}
	print Dumper \%nmisModules;
}



print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Configuring installation path...
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

# If this script was ran from the root of the extracted archive, the 'nmis-xxx' folder should be here:
# use FindBin qw($Bin);

# copy it out to master and slaves
my $base = input_str("Folder to install NMIS in : ", 'nmis8');
my $path = input_str("Path from / to NMIS install folder :", '/mnt/hgfs/Master');
$site = "$path/$base";			# default it



print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Copying NMIS system files...
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

# should include a standalone/masterslave switch here
# then create master/slave files, and copy out slave src as appropiate
# suggest slave config be copied to slave server, but if that is not accessiale, then give option
# to copy to local directory.

exit unless input_yn("OK to copy NMIS distribution files from $src to $site :");
print "Copying source files from $src to $site...\n";
baseDirCopy( to=>$site, from=>$src );




print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Setting default permissions on all files

++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

# set the distro to user group = nmis
qx|chmod 0775 -R $site|;
qx|chown nmis:nmis -R $site|;
	


print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Copying distrubution install files to conf directory.
If file already exists in conf directory,
check differences and update if required.
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF


my @fl = plainfiles( "$site/install" );
my $cf;
foreach $cf ( @fl ) {
	next unless $cf =~ /\.nmis$/;

	# file may not exist if new install
	if ( ! -f "$site/conf/$cf" ) {
		print "File $cf does not exist in conf directory, copying file from install directory\n";
		print qx|cp -v $site/install/$cf $site/conf/$cf|;
		next;
	}


	# readability
	my $new = "$site/install/$cf";
	my $cur = "$site/conf/$cf";

	my $tnew = qx|awk 'NR==2 {print;exit}' $new|;
	my $tcur = qx|awk 'NR==2 {print;exit}' $cur|;

	print "Checking headers of $cf\n";

	if ( $tnew eq $tcur ) {
		print "\t$cf headers matches $cur headers\n";
		print "\t$tnew\n\t$tcur\n";
		print "Checking if the contents differ\n";
		my $r = qx|diff -wqr -I '$:' $new $cur 2>&1|;
		print "$r\n";
		if ( $r ) {
			if ( input_yn("Contents differ, copy $cf over $cur :") ) {
				print qx|cp -vb $new $cur|, "\n";
			}
		} else {
			#print "Files content match - Copying $new over $cur\n";
			#     print qx|cp -vb $new $cur|, "\n";
		}
	}	else {
		print "\t!!! $cf header does not match $cur!!!\n";
		print "\t$tnew\n\t$tcur\n";
		if ( input_yn("Copy $cf to $site and backup $cur :") ) {
			print qx|cp -vb $new $cur|, "\n";
		}
	}
}
exit unless input_yn("\n\tAll configuration files copied to conf directory - Proceed ");

print "Copying remaining files from $site/install to $site/conf...\n";
my @filelist = qw| users.dat outage.dat logrotate.conf |;
my $f;
foreach $f ( @filelist ) {
	if ( -e "$site/conf/$f" ) {
		if ( input_yn("File $f exists in $site/conf/ directory - Copy over ") ) {
			print qx|cp -v $site/install/$f $site/conf/$f|;
		}
	}
	else {
		print qx|cp -v $site/install/$f $site/conf/$f|;
	}
}
exit unless input_yn("\nCopy completed - Proceed ");


print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Confgure conf/Config.nmis
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

print "Please confirm or edit the base Config.nmis parameters\n";

my @para = ( 	
		[ '<nmis_base>', $site],
		['server_name', 'Master' ],
		['auth_require', 'true' ],
		['server_master', 'true'],
		['master_dash', 'true'],
		['master_report', 'true'],
		['auth_src_ip', '192.168.30.100'],
		['domain_name', 'nmis.co.nz'],
		['nmis_host', 'master.nmis.co.nz'],
		['group_list', 'NMIS'],
		['<cgi_url_base>', "/cgi-$base" ],
		['<url_base>', "/$base" ],
		['<menu_url_base>', "/$base" ]
#		['database_root', '<nmis_data>/database']
);

foreach my $i ( 0 .. $#para ) {
	my $r = input_str( qq|Set parameter "$para[$i][0]"|, $para[$i][1] );
	my $replace = qq|'$para[$i][0]' => '$r'|;
	fileFindReplace( file=>"$site/conf/Config.nmis", f=>"'$para[$i][0]'", r=>$replace);
}

print "Done with configuration folder\n\n";



print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Configuring the event database on MySql

++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF
# connect to the Database
use DBI;

print "\nMySQL DB will be dropped and re-initialized, bail now if you dont want this!\n";
print "Assuming usernames, passwords as used for domain authentication, change if you dont like that.\n";
print "We require admin access to MySQL to create the NMIS database , tables and users\n";

my $adminuser = input_str( "MySQL admin user: ", 'root');
my $adminpass = input_str( "MySQL admin password for user $adminuser: ", 'root@nmis');
my $sqlhost = input_str( "MySQL assumed to be on localhost : ", 'localhost');
my $sqldb = input_str( "NMIS DB name recommended to be same as base install dir: ", $base);
my $dbuser = input_str( "MySQL $sqldb user: ", 'nmis');
my $dbpass = input_str( "MySQL $sqldb user $dbuser password: ", 'nmis');
chomp($adminuser,$adminpass,$sqlhost, $sqldb, $dbuser, $dbpass);

print "Checking MySQL version\n----------------------------------------------------------------------\n";	

my $dbh = DBI->connect("DBI:mysql:mysql:$sqlhost", "$adminuser", "$adminpass", { RaiseError => 1, AutoCommit => 1});

my $mysqlVer;
my $sth = $dbh->prepare("SELECT VERSION()");
$sth->execute();
while ((my @f) = $sth->fetchrow) {
	$mysqlVer = $f[0];
}
print "MySQL Version   : $mysqlVer\n";
print "Creating MySQL Database $sqldb\n ----------------------------------------------------------------------\n";	

exit if !input_yn("Drop and Create $sqldb database - this will delete all records if database $sqldb exists, proceed: ");
$dbh->do("DROP DATABASE IF EXISTS $sqldb") or warn ("$dbh->errstr");

print "Old MySQL:$sqldb dropped!\n";

print "Creating database $sqldb for $dbuser\@$sqlhost\n----------------------------------------------------------------------\n";
$dbh->do(qq|CREATE DATABASE if not exists $sqldb|) or warn ("$dbh->errstr");

print "Creating MySQL user $dbuser\n----------------------------------------------------------------------\n";	

$dbh->do("GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,DROP ON $sqldb.* TO \'$dbuser\'\@\'$sqlhost\' IDENTIFIED BY \'$dbpass\'") or warn ("$dbh->errstr");
if ($mysqlVer =~ /5\./) {                #fix for mysql 5.0 with old client libs
	$dbh->do("SET PASSWORD FOR \'$dbuser\'\@\'$sqlhost\' = OLD_PASSWORD(\'$dbpass\')") or warn ("$dbh->errstr");
}
$dbh->do(qq|FLUSH PRIVILEGES|) or warn ("$dbh->errstr");

$sth->finish if $sth;
$dbh->disconnect();
print "Creating table 'event' in database $sqldb wth user $dbuser\n----------------------------------------------------------------------\n";	

$dbh = DBI->connect("DBI:mysql:$sqldb:$sqlhost", "$dbuser", "$dbpass", { RaiseError => 1, AutoCommit => 0}) or warn ("$dbh->errstr");

$dbh->do(qq|DROP TABLE IF EXISTS `event`|) or warn ("$dbh->errstr");

$dbh->do("CREATE TABLE `event` (
							`startdate` varchar(12) NOT NULL,
							`lastchange` varchar(12) NOT NULL,
							`node` varchar(50) NOT NULL,
							`event` varchar(200) NOT NULL,
							`event_level` varchar(20) NOT NULL,
							`details` varchar(200) NOT NULL,
							`ack` varchar(5) NOT NULL,
							`escalate` tinyint(4) NOT NULL,
							`notify` varchar(50) NOT NULL,
							PRIMARY KEY  (`node`,`event`,`details`)
			) ENGINE=InnoDB DEFAULT CHARSET=latin1 CHECKSUM=1 DELAY_KEY_WRITE=1 ROW_FORMAT=DYNAMIC") or warn ("$dbh->errstr");

$dbh->commit;

$dbh->disconnect;

print "Finished with MySQL initilisation for NMIS $base\n----------------------------------------------------------------------\n";	


print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
Done configuring NMIS Server $base

++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

#end...........

# subs


# question , return true if y, else 0 if no, default is yes.
sub input_yn {

	print STDOUT qq|$_[0] ? <Enter> to accept, any other key for 'no'|;
	my $input = <STDIN>;
	chomp $input;
	return 1 if $input eq '';
	return 0;
}
# question, default answer
sub input_str {

		my $str = $_[1];
		
	while (1) {{
		print STDOUT qq|$_[0]: [$str]: type new value or <Enter> to accept default: |;
		my $input = <STDIN>;
		chomp $input;
		$str = $input if $input ne '';
		print qq|You entered [$str] -  Is this correct ? <Enter> to accept, or any other key to go back: |;
		$input = <STDIN>;
		chomp $input;
		return $str if !$input;			# accept default
		
	}}
}


# copy dir tree
# leave 'conf' for more specfic file copy that follows
# use the shell to copy the contents, perl copy is not simple

sub baseDirCopy  {
	my %args = @_;

	if ( ! -d $args{to} ) { mkdir( $args{to}) }		# parent
	if ( ! -d "$args{to}/conf" ) { mkdir( "$args{to}/conf" ) };


	my @dirs = <<EOF =~ m/(\S.*\S)/g;
admin
bin
cgi-bin
database
htdocs
install
lib
logs
menu
var
mibs
models
var
htdocs/images
database/health
database/interface
database/metrics
database/misc
install/scripts
lib/Authen
lib/NMIS
menu/css
menu/images
menu/img
menu/js
EOF
	push( @dirs, '*' );				# pick up files in nmis root - README etc

	for ( @dirs ) {
		my $item = $_;
		if ( ! -d "$args{to}/$item" ) { mkdir( "$args{to}/$item" ) };
		`cp -r  $args{from}/$item $args{to} 2>/dev/null`;
		# if error code, return it
		if ($?)
		{ print "Copy error, check src $args{from}/$item and dest $args{to}/$item arguments\n";
		}
		else {
			print "Copied $args{from}/$item $args{to}/$item\n";
		}
	}

	# create logs
	foreach my $f ( qw|cisco.log ciscopix.log nmis.log event.log remoteaccess.log switch.log unclassified.log | ) {
		print 'Created', qx|touch -m "$args{to}/logs/$f" && ls "$args{to}/logs/$f"|;
	}
}


sub plainfiles {
	my $dir = shift;
	my @list;
	opendir(DIR,"$dir") || die "NO SUCH Directory: $dir";
	@list = readdir(DIR);
	closedir(DIR);
	my @fl = grep {  !/^\./   } @list;
	return @fl;
}

# change a line in a file 'inplace'

sub fileFindReplace {

	# file=<filename>
	# f = str to be replaced
	# r = str that replaces  'f'
	# b = backup  1 or 0

	my %args = @_;
	my $file=$args{file};
	my $f = $args{f};
	my $r = $args{r};

	print qx|cp -v $file "$file.bak"|;
	if ( -f "$file.tmp" ) { unlink( "$file.tmp" ) }

	open my $in,  '<',  $file or die "Can't read old file: $!";
	open my $out, '>', "$file.tmp" or die "Can't write tmp file: $!";

	while ( <$in> ) {
		chomp;					 # drop the newline
		if (/^(\s+)$f/ ) {
			print $out "$1$r";
			if (/.*,$/)	{		# trailing comma ?
				print $out ',';
			}
			print $out "\n";
		} else {
			print $out $_."\n";
		}
	}

	close $in;
	close $out;
	print qx|mv "$file.tmp" $file|;

}


sub saveDependancyGml {	
	my $gml;
	my $x;
	my $y;
	my $nodeid;
	my %nodeIdx;
	
	my $nmisBase = "/usr/local/nmis8";
	
	my %usedBy;
	foreach my $mod (sort {$nmisModules{$a}{file} cmp $nmisModules{$b}{file}} keys %nmisModules) {
		foreach my $src (@{$nmisModules{$mod}{by}}) {
			# convert Package files to Package names.
			my $filename = $src;
			$filename =~ s/$nmisBase/\./g;
			my $name = $filename;

			if ( $src =~ /$nmisBase\/lib/ ) {
				#this is a module!
				$name =~ s/\.\/lib\///g;
				$name =~ s/\.pm//g;
				$name =~ s/\//::/g;
				print "DEBUG: $filename = $name \n";
			}
			
			$usedBy{$filename}{name} = $name;
			$usedBy{$filename}{file} = $filename;
			if (not grep {$_ eq $mod} @{$usedBy{$filename}{modules}}) {
				push(@{$usedBy{$filename}{modules}},$mod);
			}
		}
	}
	
	# Transform the current HASH;
	
	$gml .= "Creator \"NMIS Opmantek\"\n";
	$gml .= "directed 1\n";
	$gml .= "graph [\n";

	foreach my $file (sort {$usedBy{$a}{name} cmp $usedBy{$b}{name}} keys %usedBy) {
		++$nodeid;
		my $name = $usedBy{$file}{name};
		if ( $nodeIdx{$name} eq "" ) {
			++$y;
			++$x;
			$nodeIdx{$name} = $nodeid;
			my $label = $name;
			my $fill = getFill("nmis");
			if ( $usedBy{$file}{file} ne $usedBy{$file}{name} ) {
				$label = "$name\n$file";
				$fill = getFill("nmis-lib");
			}
			$gml .= getNodeGml($nodeid,$label,$fill,$x,$y);
		}
	}


	foreach my $file (sort {$usedBy{$a}{name} cmp $usedBy{$b}{name}} keys %usedBy) {
		++$nodeid;
		my $name = $usedBy{$file}{name};
		
		foreach my $mod (@{$usedBy{$file}{modules}}) {
			++$nodeid;
			if ( $nodeIdx{$mod} eq "" ) {
				++$y;
				++$x;
				$nodeIdx{$mod} = $nodeid;
				my $fill = getFill("cpan");
				$gml .= getNodeGml($nodeid,$mod,$fill,$x,$y);
			}
			$gml .= getEdgeGml($nodeIdx{$name},$nodeIdx{$mod},"");
			print "DEBUG: $name -> $mod\n";
		}
	}


	$gml .= "]\n";

	my $file = "NMIS-Dependancies.gml";
	open(GML,">$file") or die "Problem with $file: $!\n";
	print GML $gml;
	close(GML);
	print "NMIS Depenancy Graph saved to $file\n";
	
}

sub getFill {
	my $type = shift;
	
	my $fill = "#0099FF";
	
	$fill = "#00FF99" if $type eq "nmis";
	$fill = "#9900FF" if $type eq "nmis-lib";
	
	return $fill;	
}

sub getNodeGml {
	my $nodeid = shift;
	my $label = shift;
	my $fill = shift;
	my $x = shift;
	my $y = shift;
	return qq|
	node [
		id $nodeid
		label "$label"
		graphics [
			x $x.000000
			y $y.0000000
			w 95.00000000
			h 56.00000000
			fill	"$fill"
			outline	"#000000"
		]
		LabelGraphics [
			alignment	"center"
			autoSizePolicy	"node_width"
			anchor	"c"
		]
	]
|;

}

sub getEdgeGml {
	my $source = shift;
	my $target = shift;
	my $label = shift;
	
	my $width = 3;
	my $color = "#000000";
	my $linestyle = "arrow";
	
	return qq|
	edge [
		source $source
		target $target
		label	"$label"
		graphics
		[
			width	$width
			style	"$linestyle"
			fill "$color"
			arrow "last"
		]
	]
|;

}