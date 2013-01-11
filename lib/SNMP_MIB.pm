# -*- mode: Perl -*-
######################################################################
### SNMP MIB parsing 
######################################################################
### This library provides a way to load and access SNMP mibs in user
### programs. 
###
######################################################################
### Created by:  Alan Nichols <alan.nichols@sun.com>
###
### Based on work by:
### Simon Leinen  <simon@switch.ch>
### Mike Mitchell <mcm@unx.sas.com> (MIB parsing)
######################################################################
# Copyright (c) 1999 Sun Microsystems, Inc.  All Rights Reserved.
#
# SUN MAKES NO REPRESENTATIONS OR WARRANTIES ABOUT THE SUITABILITY OF
# THE SOFTWARE, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
# TO THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE, OR NON-INFRINGEMENT. SUN SHALL NOT BE LIABLE FOR
# ANY DAMAGES SUFFERED BY LICENSEE AS A RESULT OF USING, MODIFYING OR
# DISTRIBUTING THIS SOFTWARE OR ITS DERIVATIVES.
######################################################################
#

package SNMP_MIB;
require 5.003;

######################################################################
#

use strict;
use Exporter;
use vars qw(@ISA $VERSION @EXPORT);

######################################################################
#

$VERSION = '%R%.%L%';

@ISA = qw(Exporter);

@EXPORT = qw(byOID cmpOID ltOID gtOID eqOID);

$SNMP_MIB::errmsg = '';
$SNMP_MIB::suppress_warnings = 0;
$SNMP_MIB::debug = 0;

my %ENUMS;
my %TYPES;

# Load in a few base defs 
my %OIDS  = ('iso' => '1',
	     'org' => '1.3',
	     'dod' => '1.3.6',
	     'internet' => '1.3.6.1',
	     'directory' => '1.3.6.1.1',
	     'mgmt' => '1.3.6.1.2',
	     'mib-2' => '1.3.6.1.2.1',
	     'experimental' => '1.3.6.1.3',
	     'private' => '1.3.6.1.4',
	     'enterprises' => '1.3.6.1.4.1'
	     );

my %NAMES = ('1' => 'iso',
	     '1.3' => 'org',
	     '1.3.6' => 'dod',
	     '1.3.6.1' => 'internet',
	     '1.3.6.1.2' => 'mgmt',
	     '1.3.6.1.2.1' => 'mib-2', 
	     '1.3.6.1.3' => 'experimental',
	     '1.3.6.1.4' => 'private',
	     '1.3.6.1.4.1' => 'enterprises'
	     );

######################################################################
#
# For use when a function wants to return an error

sub error_return {
    my ($message) = @_;
    $SNMP_MIB::errmsg = $message;
    unless ($SNMP_MIB::suppress_warnings) {
	$message =~ s/^/  /mg;
	warn ("SNMP_MIB Error:\n".$message."\n");
    }
    return undef;
}
 
######################################################################
#
# For use when a function has encountered an error, but can continue.

sub error {
    my ($message) = @_;
    $SNMP_MIB::errmsg = $message."\n";
    unless ($SNMP_MIB::suppress_warnings) {
	$message =~ s/^/  /mg;
	warn ("SNMP_MIB Error:\n".$message."\n");
    }
    return undef;
}

######################################################################
#
# compare two OIDS - usable for a sort.

sub byOID {
    cmpOID($a, $b);
}

######################################################################
#
# compare two OIDS - usable for a sort.

sub cmpOID($$) {
    my($foo1, $foo2) = @_;
    my(@oida) = split(/\./, $foo1);
    my(@oidb) = split(/\./, $foo2);
    my($vala, $valb);
    do {
	$vala = shift @oida;
	$valb = shift @oidb;
	my $tmpval = int($vala) <=> int($valb);
    } while ((int($vala) == int($valb)) && scalar @oida && scalar @oidb);
    return int($vala) <=> int($valb) if ((@oida == 0) && (@oidb == 0));
    return -1 if ((int($vala) == int($valb)) && ((@oida == 0) && (@oidb > 0)));
    return 1 if ((int($vala) == int($valb)) && ((@oida > 0) && (@oidb == 0)));
    return int($vala) <=> int($valb);
}

######################################################################
#
# Return true if OID a is less than OID b

sub ltOID($$) {
    my($a, $b) = @_;
    return (cmpOID($a, $b) == -1);
}

######################################################################
#
# Return true if OID a is less than OID b

sub gtOID($$) {
    my($a, $b) = @_;
    return (cmpOID($a, $b) == 1);
}

######################################################################
#
# Return true if OID a is less than OID b

sub eqOID($$) {
    my($a, $b) = @_;
    return (cmpOID($a, $b) == 0);
}

######################################################################
#
# subroutine to load in a list of SNM .oid file, into the package 
# associatve arrays OIDS and NAMES.
#
# Takes as parameters a directory to look for the .oid files, and a list of
# the names of the .oid file (without the .oid extension)

sub loadoids {
    my($dir, @mibs) = @_;
    my($mib);
    return error_return("Directory $dir does not exist\n") unless (-d $dir);
    foreach $mib (@mibs) {
	my($mibfile) = "$dir/$mib-MIB.oid";
	if ( -f $mibfile) {
	    open(MIBFILE, "<$mibfile");
	    my($line);
	    while(defined($line = <MIBFILE>)) {
		if (!($line =~ /^\#/)) {
		    my ($name, $oid) = ($line =~ /\"(.*)\".*\"(.*)\"/);
		    add_mapping($oid, $name, undef);
		}
	    }
	    close(MIBFILE);
	} else {
	    error("Mibfile $mibfile does not exist\n");
	}
    }
}

sub loadoids_file {
    my($dir, @mibs) = @_;
    my($mib);
    return error_return("Directory $dir does not exist\n") unless (-d $dir);
    foreach $mib (@mibs) {
        my($mibfile) = "$dir/$mib";
        if ( -f $mibfile) {
            open(MIBFILE, "<$mibfile");
            my($line);
            while(defined($line = <MIBFILE>)) {
                if (!($line =~ /^\#/)) {
                    my ($name, $oid) = ($line =~ /\"(.*)\".*\"(.*)\"/);
                    add_mapping($oid, $name, undef);
                }
            }
            close(MIBFILE);
        } else {
            error("Mibfile $mibfile does not exist\n");
        }
    }
}


######################################################################
#
# subroutine to load in a list of .def files, into the package 
# associatve arrays OIDS and NAMES, and TYPES
#
# Takes as parameters a directory to look for the .defs files, and a list of
# the names of the .defs files.

sub loaddefs{
    my($dir, @mibs) = @_;
    my($mib);
    return error_return("Directory $dir does not exist\n") unless (-d $dir);
    foreach $mib (@mibs) {
	my($mibfile) = "$dir/$mib";
	if ( -f $mibfile) {
	    open(MIBFILE, "<$mibfile");
	    my($line);
	    while(defined($line = <MIBFILE>)) {
		chomp $line;
		next if ($line =~ /^--/);   # -- is a comment
		next if ($line =~ /^\s*$/); # Skip blank lines
		
		my ($name, $base, $type, $access, $status) = 
		    split(" ", $line, 5);
		my ($oid) = name2oid($base);
		if (!defined($oid)) {
		    error("Base name $base does not translate to an OID\n");
		    next;
		}
		add_mapping($oid, $name, $type);
	    }
	    close(MIBFILE);
	} else {
	    error("Mibfile $mibfile does not exist\n");
	}
    }
}

######################################################################
#
# subroutine to load in a list of .def files, into the package 
# associatve arrays OIDS and NAMES, and TYPES
#
# Takes as parameters a directory to look for the .defs files, and a list of
# the names of the .defs files.
#
# Read in the passed list of MIB files, parsing them
# for their text-to-OID mappings
#
sub loadmib($@) {
    my($dir, @args) = @_;
    my($quote, $buf, $var, $code, $val, $tmp, $tmpv, $strt);
    my($ret);
    my($arg);
    my(%Link) = (
	'org' => 'iso',
	'dod' => 'org',
	'internet' => 'dod',
	'directory' => 'internet',
	'mgmt' => 'internet',
	'mib-2' => 'mgmt',
	'experimental' => 'internet',
	'private' => 'internet',
	'enterprises' => 'private',
    );

    foreach $arg (@args) {
	if (!open(MIB, "$dir/$arg")){
	    error("loadmib: Can't open $arg: $!");
	    next;
	}
	$ret = 0;
	while(<MIB>) {
	    s/--.*--//g;		# throw away comments (-- anything --)
	    s/--.*//;		# throw away comments (-- anything EOL)
	    if ($quote)
	    {
		next unless /\"/;
		$quote = 0;
	    }
	    chop;
	    $buf = "$buf $_";
	    $buf =~ s/\s+/ /g;
	    
	    
	    if ($buf =~ / DEFINITIONS ::= BEGIN/)
	    {
		undef %Link;
		%Link = (
			 'org' => 'iso',
			 'dod' => 'org',
			 'internet' => 'dod',
			 'directory' => 'internet',
			 'mgmt' => 'internet',
			 'mib-2' => 'mgmt',
			 'experimental' => 'internet',
			 'private' => 'internet',
			 'enterprises' => 'private',
			 );
	    }
	    
	    $buf =~ s/OBJECT-TYPE/OBJECT IDENTIFIER/;
	    $buf =~ s/MODULE-IDENTITY/OBJECT IDENTIFIER/;
	    $buf =~ s/ IMPORTS .*\;//;
	    $buf =~ s/ SEQUENCE {.*}//;
	    $buf =~ s/ ([\w\-]+) ::= TEXTUAL-CONVENTION .* SYNTAX INTEGER \{/ $1 ::= INTEGER \{/;
	    $buf =~ s/ [\w\-]+ ::= TEXTUAL-CONVENTION .* SYNTAX//;
	    $buf =~ s/ SYNTAX INTEGER \{/ ::= INTEGER \{/;
	    $buf =~ s/ ([\w\-]+) OBJECT IDENTIFIER ::= INTEGER \{/ $1 OBJECT IDENTIFIER ::= $1 ::= INTEGER \{/;
	    $buf =~ s/ SYNTAX .*//;
	    $buf =~ s/ [\w-]+ ::= OBJECT IDENTIFIER//;
	    $buf =~ s/ OBJECT IDENTIFIER .* ::= \{/ OBJECT IDENTIFIER ::= \{/;
	    $buf =~ s/".*"//;
	    if ($buf =~ /\"/) { 
		$quote = 1;
	    }
	    
	    if ($buf =~ / ([\w\-]+) ::= INTEGER \{(.*)\}/) {
		$var = $1;
		my $bindings = $2;
		my %enum;
		my ($key);
		foreach $key (split(/,/, $bindings)) {
		    my($evar, $evalue) = ($key =~ /([\w\-]+)\((\d+)\)/);
		    $enum{$evalue} = $evar;
		}
		$ENUMS{$var} = \%enum;
	    }
	    
	    $buf =~ s/ ([\w\-]+) ::= INTEGER \{(.*)\}//;
	    
	    if ($buf =~ / ([\w\-]+) OBJECT IDENTIFIER ::= \{([^\}]+)\}/) {
		$var = $1;
		$buf = $2;
		undef $val;
		$buf =~ s/ +$//;
		($code, $val) = split(' ', $buf, 2);
		
		if (length($val) <= 0) {
		    add_mapping($code, $var, undef);
		    $ret++;
		} else {

		    $strt = $code;
		    
		    while($val =~ / /) {
			($tmp, $val) = split(' ', $val, 2);
			if ($tmp =~ /([\w\-]+)\((\d+)\)/) {
			    $tmp = $1;
			    $tmpv = "$OIDS{$strt}.$2";
			    $Link{$tmp} = $strt;
			    if (defined($OIDS{$tmp})) {
				if ($tmpv ne $OIDS{$tmp}) {
				    $strt = "$strt.$tmp";
				    add_mapping($tmpv, $strt, undef);
				    $ret++;
				}
			    } else {
				add_mapping($tmpv, $tmp, undef);
				$ret++;
				$strt = $tmp;
			    }
			}
		    }
		    
		    if (!defined($OIDS{$strt})) {
			error("loadmib: $arg: \"$strt\" prefix unknown, load the parent MIB first.\n");
			next;
		    }
		    
		    $Link{$var} = $strt;
		    $val = "$OIDS{$strt}.$val";
		    if (defined($OIDS{$var})) {
			if ($val ne $OIDS{$var})
			{
			    $var = "$strt.$var";
			}
		    }
		    
		    add_mapping($val, $var, undef);
		    $ret++;
		    
		}
		undef $buf;
	    }
	}
	close(MIB);
    }
    return $ret;
}


######################################################################
#
# Add an entry into the NAMES <=> OIDS <=> TYPES lookup table.

sub add_mapping($$$) {
    my($oid, $name, $type) = @_;
    if (defined($OIDS{$name}) && $OIDS{$name} ne $oid) {
	error("Name Conflict: $name refers to OID $oid as well as $OIDS{$name}\n");
    } elsif (defined($NAMES{$oid}) && $NAMES{$oid} ne $name) {
	error("OID Conflict: $oid has name $name as well as $NAMES{$oid}\n");
    } else {
	$OIDS{$name} = $oid;
	$NAMES{$oid} = $name;
	$TYPES{$oid} = $type if defined($type);
	print("$name -> $oid, $type\n") if ($SNMP_MIB::debug > 5);
    }
}

######################################################################
#
# Print out the contents of the OIDS -> NAMES mapping

sub dump_names() {
    my($key, $val);
    foreach $key (sort byOID keys %NAMES) {
	print "$key\t\t$NAMES{$key}\n";
    }
}

######################################################################
#
# Print out the contents of the NAMES -> OIDS mapping
sub dump_oids() {
    my($key, $val);
    foreach $key (sort keys %OIDS) {
	print "$key\t\t$OIDS{$key}\n";
    }
}

sub dump_oids_file() {
    my($key, $val);
    foreach $key (sort {
    	$OIDS{$a} cmp $OIDS{$b}
    } keys %OIDS) {
	print "\"$key\"\t\t\"$OIDS{$key}\"\n";
    }
}

######################################################################
#
# Print out the contents of the NAMES -> OIDS mapping

sub dump_enums() {
    my($key, $val);
    foreach $key (sort keys %ENUMS) {
	print "ENUM $key -> { ";
	my($inkey);
	foreach $inkey (sort { $a <=> $b } keys %{$ENUMS{$key}}) {
	    print "$ENUMS{$key}->{$inkey}($inkey), ";
	}
	print "}\n";
    }
}

######################################################################
#
# Retrieve an enumeration

sub getEnum($) {
    my($key) = @_;
    return %{$ENUMS{$key}} if (defined $ENUMS{$key});
    return {};
}

######################################################################
#
# Take a name and return the unencoded OID for that name.  If the OID
# is not found, undef is returned.

sub name2oid{
    my($name) = @_;
    if ($name =~ /\./) {
	my($tmpname, $tail) = split(/\./, $name, 2);
	return "$OIDS{$tmpname}.$tail" if (defined($OIDS{$tmpname}));
    } else {
	return $OIDS{$name} if (defined($OIDS{$name}));
    }
    return undef;
}

######################################################################
#
# Take an OID and return a name.  If there is no hit the first time,
# trim off the last component and try again.  Repeat until found.  If
# no name is found, undef is returned.

sub oid2name {
    my($tmpoid) = @_;
    return $NAMES{$tmpoid} if (defined($NAMES{$tmpoid}));
    
    my($tail, $tailoid);
    ($tmpoid, $tail) = ($tmpoid =~ /(.*)\.(\d+)/ );
    while (($tmpoid ne "") && (!defined($NAMES{$tmpoid}))) {
	($tmpoid, $tailoid) = ($tmpoid =~ /(.*)\.(\d+)/ );
	$tail = "$tailoid.$tail";
    }

    return "$NAMES{$tmpoid}.$tail" if ($tmpoid ne "");

    return undef;
}


######################################################################
#
# Take an OID and return a type.  If there is no hit the first time,
# trim off the last component and try again.  Repeat until found.  If
# no type is found, undef is returned.

sub oid2type {
    my($tmpoid) = @_;
    return $TYPES{$tmpoid} if (defined($TYPES{$tmpoid}));

    my($tail, $tailoid);
    ($tmpoid, $tail) = ($tmpoid =~ /(.*)\.(\d+)/ );
    while (($tmpoid ne "") && (!defined($TYPES{$tmpoid}))) {
	($tmpoid, $tailoid) = ($tmpoid =~ /(.*)\.(\d+)/ );
	$tail = "$tailoid.$tail";
    }

    return $TYPES{$tmpoid} if ($tmpoid ne "");

    return undef;
}

1;

