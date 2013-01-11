# -*- mode: Perl -*-
######################################################################
### SNMP Request/Response Handling
######################################################################
### This library provides a wrapper around the SNMP_Session and BER
### libraries, to provide a higher level access to creating SNMP requests
### to devices.
######################################################################
### Created by:  Alan Nichols <alan.nichols@sun.com>
###
### Based on work by:
### Simon Leinen  <simon@switch.ch>     (original SNMP library in PERL)
### Tobias Oetiker <oetiker@ee.ethz.ch> (Templates for snmpget calls)
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

package SNMP_Simple;
require 5.003;

######################################################################
#

use strict;
use Exporter;
use vars qw(@ISA $VERSION @EXPORT);
use Socket;
use BER;
use SNMP_Session;
use SNMP_MIB;

######################################################################
#

$VERSION = '%R%.%L%';

@ISA = qw(Exporter);

@EXPORT = qw();

$SNMP_Simple::errmsg = '';
$SNMP_Simple::suppress_warnings = 1;
$SNMP_Simple::debug = 0;


######################################################################
#
# Create a new SNMP socket

sub open {
    my($type) = @_;
    my($session)=SNMP_Session::open(@_);
    my $self = bless { 'session' => $session }, $type;
    return $self;
}


######################################################################
#
# Close a SNMP socket

sub close {
    my($self) = @_;
    $self->{'session'}->close();
}

######################################################################
#
# For use when a function wants to return an error

sub error_return {
    my ($self, $message) = @_;
    $SNMP_Simple::errmsg = $message;
    unless ($SNMP_Simple::suppress_warnings) {
	$message =~ s/^/  /mg;
	warn ("Error:\n".$message."\n");
    }
    return undef;
}
 
######################################################################
#
# For use when a function has encountered an error, but can continue.

sub error {
    my ($self, $message) = @_;
    my $session = $self->to_string;
    $SNMP_Simple::errmsg = $message."\n".$session;
    unless ($SNMP_Simple::suppress_warnings) {
	$session =~ s/^/  /mg;
	$message =~ s/^/  /mg;
	warn ("SNMP Error:\n".$message."\n".$session."\n");
    }
    return undef;
}

######################################################################
#
# Return a string describing the contents of this object.

sub to_string {
    my($self) = shift;
    my($this) = $self->{'session'};
    my ($class,$prefix);

    $class = ref($self);
    $prefix = ' ' x (length ($class) + 2);
    ($class."->".$this->to_string());
}

######################################################################
#
# snmpget is the most simple of the SNMP get functions.  It simply
# takes a list of variables and returns a list of values, one value
# for each variable passed in.  Values are returned in the same order
# as the variables passed in.  If an error was encountered for a
# variable, an 'undef' value is returned in its place.

sub snmpget{
    my($self, @vars) = @_;
    my $this  = $self->{'session'};
    my($var, @retvals);
    foreach $var (@vars) {
	my($tmpvar) = SNMP_MIB::name2oid($var);
	my $enoid;
	if (defined($tmpvar)) {
	    # This is here so that if we have a variable in the format
	    # name.number, we assume the tailing number makes a specific
	    # oid to query for.  Otherwise, we need to append a .0 so that
	    # we can query the specific oid.
	    if ($var =~ /\./) {
		$enoid = encode_oid((split /\./, $tmpvar));
	    } else {
		$enoid = encode_oid((split /\./, "$tmpvar.0"));
	    }

	    if ($this->SNMP_Session::get_request_response(($enoid))) {
		my $response = $this->pdu_buffer;
		my ($bindings) = $this->decode_get_response ($response);
		while ($bindings) {
		    my $binding;
		    ($binding,$bindings) = decode_sequence ($bindings);
		    my ($oid,$value) = decode_by_template ($binding, "%O%@");
		    # quit if we got a mismatched oid
		    last unless BER::encoded_oid_prefix_p($enoid,$oid);
		    my $tempo = pretty_print($oid);	
		    my $tempv = pretty_print($value);
		    print "$tempo -> $tempv\n" if ($SNMP_Simple::debug);
		    push @retvals, $tempv;
		}
	    } else {
		$self->error("No answer from $this->{'remote_hostname'} for $var.\n");
		push @retvals, undef;
	    }
	} else {
	    $self->error("Unknown SNMP var $var\n");
	    push @retvals, undef;
	}
    }
    return (@retvals);
}

######################################################################
#
# snmpgeta does much the same thing as snmpget.  It takes a list of
# variables and returns a associative array of values, where the 
# variable name maps to the value returned.  No entry is made in the
# associative array for invalid variable names or for error returns.

sub snmpgeta{  
    my($self, @vars) = @_;
    my($this) = $self->{'session'};
    my($var, @enoids, %retvals, %name);
    
    foreach $var (@vars) {
	my($tmpvar) = SNMP_MIB::name2oid($var);
	if (defined($tmpvar)) {
	    # This is here so that if we have a variable in the format
	    # name.number, we assume the tailing number makes a specific
	    # oid to query for.  Otherwise, we need to append a .0 so that
	    # we can query the specific oid.
	    if ($var =~ /\./) {
		push @enoids, encode_oid((split /\./, $tmpvar));
		$name{$tmpvar}= $var;
	    } else {
		push @enoids, encode_oid((split /\./, "$tmpvar.0"));
		$name{"$tmpvar.0"}= $var;
	    }
	} else {
	    $self->error("Unknown SNMP var $var\n");
	}
    }

    if ($this->get_request_response(@enoids)) {
	my $response = $this->pdu_buffer;
	my ($bindings) = $this->decode_get_response ($response);
	while ($bindings) {
	    my $binding;
	    ($binding, $bindings) = decode_sequence ($bindings);
	    my ($oid, $value) = decode_by_template ($binding, "%O%@");
	    # quit if we got a mismatched oid
	    # last unless BER::encoded_oid_prefix_p($enoid,$oid);
	    my $tempo = pretty_print($oid);	
	    my $tempv = pretty_print($value);
	    print "$tempo -> $tempv\n" if ($SNMP_Simple::debug);
	    $retvals{$name{$tempo}} = $tempv;
	}
    } else {
	$self->error("No answer from $this->{'remote_hostname'}.\n");
    }
    
    return (%retvals);
}

######################################################################
#
# snmpgettable takes a variable name and returns a list of all the
# values for that variable.  The intention is that the variable name
# is the name of a column in a table, and the result is a list of
# all the values of that variable for each row in the table.  No
# sanity checking is done, values are put on the list in FIFO
# order.  No guarantee is made that the list index will equal the row
# index.

sub snmpgettable{
    my($self, $var) = @_;
    my($this) = $self->{'session'};
    my($oid,@table);
    my($tmpvar) = SNMP_MIB::name2oid($var);
    if (!defined($tmpvar)) {
	return $self->error_return("Unknown SNMP var $var\n");
    }
    my $enoid = encode_oid(split /\./, $tmpvar);
    my $origoid = $enoid;
    do{
	$oid = undef;
	if ($this->getnext_request_response(($enoid))) {
	    my $response = $this->pdu_buffer;
	    my ($bindings) = $this->decode_get_response ($response);
	    while ($bindings) {
		my ($binding, $value);
		($binding,$bindings) = decode_sequence ($bindings);
		($oid,$value) = decode_by_template ($binding, "%O%@");
		# quit once we are outside the table
		last unless BER::encoded_oid_prefix_p($origoid,$oid);
		my $tempo = pretty_print($oid);
		my $tempv = pretty_print($value);
                print "$tempo -> '$tempv'\n" if ($SNMP_Simple::debug);
		push @table, $tempv;
	    }
	} else {
	    $self->error("No answer from $this->{'remote_hostname'}.\n");
	}
	$enoid=$oid;
    } while (BER::encoded_oid_prefix_p($origoid, $enoid));
    return (@table);
}

######################################################################
#
# snnmpgettablea takes a variable name and returns an associative
# array with all the values for that variable.  The key in the
# associative array is an OID, the value is the value retrived for
# that OID.

sub snmpgettablea{
    my($self, $var) = @_;
    my($this) = $self->{'session'};
    my($oid, %table);  # Output table
    my($tmpvar) = SNMP_MIB::name2oid($var);
    if (!defined($tmpvar)) {
	return $self->error_return("Unknown SNMP var $var\n");
    }
    my $enoid = encode_oid(split /\./, $tmpvar);
    my $origoid = $enoid;
    do {
	$oid = undef;
	if ($this->getnext_request_response(($enoid))) {
	    my $response = $this->pdu_buffer;
	    my ($bindings) = $this->decode_get_response ($response);
	    while ($bindings) {
		my ($binding, $value);
		($binding,$bindings) = decode_sequence ($bindings);
		($oid,$value) = decode_by_template ($binding, "%O%@");
		# quit once we are outside the table
		last unless BER::encoded_oid_prefix_p($origoid,$oid);
		my $tempo = pretty_print($oid);
		my $tempv = pretty_print($value);
		print "$tempo ->  $tempv\n" if ($SNMP_Simple::debug);
		$table{$tempo} = $tempv;
	    }
	} else {
	    $self->error("No answer from $this->{'remote_hostname'}\n");
	}
	$enoid=$oid;
    } while (BER::encoded_oid_prefix_p($origoid, $enoid));
    return (%table);
}

######################################################################
#
# snnmpgettablean takes a variable name and returns an associative
# array with all the values for that variable.  The key in the
# associative array is the index, the value is the value retrived for
# that OID.
#
# Example:
#
# my %ifDescr = $session->snmpgettablean('ifDescr');
#
# Each key in the hash returned is the ifIndex value for the row the
# ifDescr entry belongs to. 

sub snmpgettablean{
    my($self, $var) = @_;
    my($this) = $self->{'session'};
    my($oid, %table);  # Output table
    my($tmpvar) = SNMP_MIB::name2oid($var);
    if (!defined($tmpvar)) {
	return $self->error_return("Unknown SNMP var $var\n");
    }
    my $enoid = encode_oid(split /\./, $tmpvar);
    my $origoid = $enoid;
    do {
	$oid = undef;
	if ($this->getnext_request_response(($enoid))) {
	    my $response = $this->pdu_buffer;
	    my ($bindings) = $this->decode_get_response ($response);
	    while ($bindings) {
		my ($binding, $value);
		($binding,$bindings) = decode_sequence ($bindings);
		($oid,$value) = decode_by_template ($binding, "%O%@");
		# quit once we are outside the table
		last unless BER::encoded_oid_prefix_p($origoid,$oid);
		my $tempo = pretty_print($oid);
		my $tempv = pretty_print($value);
		($tempo) = ($tempo =~ /^$tmpvar\.(.+)/);
		print "$tempo ->  $tempv\n" if ($SNMP_Simple::debug);
		$table{$tempo} = $tempv;
	    }
	} else {
	    $self->error("No answer from $this->{'remote_hostname'}\n");
	}
	$enoid=$oid;
    } while (BER::encoded_oid_prefix_p($origoid, $enoid));
    return (%table);
}

######################################################################
#
# snmpgettablek takes the following parameters:
#     List of table columns (as in 'ifIndex', 'ifDescr', ...)
# And returns a list where each element in the list is a hash mapping
# variable names to values.  The table is assumed to have a simple
# (one element) index, and each element is put into the correct list
# element based on that index.
#
# Sample - Call snmpgettablek like this:
#
# my @outvars = $session->snmpgettablek('ifDescr', 'ifType');
#
# and what will be returned is an array where element 0 is undefined,
# elements 1 through $#outvars are hashes with three keys ('index',
# 'ifDescr' and 'ifType'

sub snmpgettablek {
    my($self, @oidlist) = @_;
    my($this) = $self->{'session'};
    my($oid, @table);  # Output table
    my($oidentry, %oida, %namea);
    foreach $oidentry (@oidlist) {
	my($ltmpvar) = SNMP_MIB::name2oid($oidentry);
	print "$oidentry -> $ltmpvar\n" if ($SNMP_Simple::debug);
	if (!defined($ltmpvar)) {
	    $self->error("Unknown SNMP var $oidentry\n");
	    next;
	}
	$oida{$ltmpvar} = 0;
	$namea{$ltmpvar} = $oidentry;
    }
    # $ticks keeps track of how many variables we read in each cycle.  If no variables are read in,
    # then we have reached the end of the table and need to quit.
    my ($ticks);
    do {
	my (@enoids, $enoid);
	$ticks = 0;
	foreach $enoid (keys %oida) {
	    push @enoids, encode_oid(split /\./, "$enoid.$oida{$enoid}");
	}
	$oid = undef;
	if ($this->getnext_request_response(@enoids)) {
	    my $response = $this->pdu_buffer;
	    my ($bindings) = $this->decode_get_response ($response);
	    while ($bindings) {
		my ($binding, $value, $base);
		($binding,$bindings) = decode_sequence ($bindings);
		($oid,$value) = decode_by_template ($binding, "%O%@");
		my $tempo = pretty_print($oid);
		my $tempv = pretty_print($value);
		($base, $tempo) = ($tempo =~ /^(.*)\.(\d+)/);
		# Continue if this is not one of the variables we want the value for
		next unless defined($oida{$base});
		print "$tempo ->  $tempv\n" if ($SNMP_Simple::debug);
		# Continue if we should have already seen this variable.
		next if $oida{$base} >= $tempo;
		$oida{$base} = $tempo;
		$ticks++;
		$table[$tempo] = { "index" => $tempo } unless
		    defined($table[$tempo]);
		$table[$tempo]->{$namea{$base}} = $tempv;
	    }
	} else {
	    $self->error("No answer from $this->{'remote_hostname'}\n");
	}
    } while ($ticks > 0);
    
    return (@table);
}

######################################################################
#
# snmpgettableka takes the following parameters:
#     Number of keys for the table
#     List of table columns (as in 'ifIndex', 'ifDescr', ...)
# And returns an associtave array where each element is a hash mapping
# variable names to values, and the key is the index in the table for
# those elements. 
#
# Sample - Call snmpgettableka like this:
#
# my @outvars = $session->snmpgettableka(1, 'ifDescr', 'ifType');
#
# and what will be returned is an associative array with a key for
# each valid row in the interfaces table, and each element is a hashe
# with three keys ('index', 'ifDescr' and 'ifType')

sub snmpgettableka{
    my($self, $keys, @oidlist) = @_;
    my($this) = $self->{'session'};

    return $self->error_return("Need a positive key\n") if $keys <= 0;

    my($basekey, $i);
    $basekey = "0";
    foreach $i (2..$keys) {
	$basekey .= ".0";
    }

    my($oid, %table);  # Output table
    my($oidentry, %oida, %namea);
    foreach $oidentry (@oidlist) {
	my($ltmpvar) = SNMP_MIB::name2oid($oidentry);
	if (!defined($ltmpvar)) {
	    $self->error("Unknown SNMP var $oidentry\n");
	    next;
	}
	$oida{$ltmpvar} = $basekey;
	$namea{$ltmpvar} = $oidentry;
    }
    # $ticks keeps track of how many variables we read in each cycle.  If no variables are read in,
    # then we have reached the end of the table and need to quit.
    my ($ticks);
    do {
	my (@enoids, $enoid);
	$ticks = 0;
	foreach $enoid (keys %oida) {
	    push @enoids, encode_oid(split /\./, "$enoid.$oida{$enoid}");
	}

	if ($this->getnext_request_response(@enoids)) {
	    my $response = $this->pdu_buffer;
	    my ($bindings) = $this->decode_get_response ($response);
	    while ($bindings) {
		my ($binding, $value, $oid, $base);
		($binding,$bindings) = decode_sequence ($bindings);
		($oid,$value) = decode_by_template ($binding, "%O%@");
		my $tempo = pretty_print($oid);
		my $tempv = pretty_print($value);
		($base, $tempo) = ($tempo =~ /^(\d+(?:\.\d+)*)((?:\.\d+){$keys})$/);
		($tempo) = ($tempo =~ /^\.(.*)$/);
		next unless defined($oida{$base});
		# Continue if we should have already seen this variable.
		next unless gtOID($tempo, $oida{$base});
		print "$namea{$base} -> $tempo ->  $tempv\n" if ($SNMP_Simple::debug);
		$oida{$base} = $tempo;
		$ticks++;
		$table{$tempo} = { "index" => $tempo } unless
		    defined($table{$tempo});
		$table{$tempo}->{$namea{$base}} = $tempv;
	    }
	} else {
	    $self->error("No answer from $this->{'remote_hostname'}\n");
	}
    } while ($ticks > 0);
    return (%table);
}

######################################################################
#
# Do a SNMP set of the given variable to the given value.  Need to also pass in 
# a variable type for encoding purposes - need to do the correct BER encoding of the
# value.
#
# Parameters: Variable name, Variable type, Value to set.  Returns value returned by
# SNMP set, or undef if anything went wrong.

sub snmpset{
    my($self, $var,  $type, $value) = @_;
    my $this  = $self->{'session'};
    my($tmpvar) = SNMP_MIB::name2oid($var);
    if (defined($tmpvar)) {
	my($enoid, $envar);
	# This is here so that if we have a variable in the format
	# name.number, we assume the tailing number makes a specific
	# oid to query for.  Otherwise, we need to append a .0 so that
	# we can query the specific oid.
	if ($var =~ /\./) {
	    $enoid = encode_oid((split /\./, $tmpvar));
	} else {
	    $enoid = encode_oid((split /\./, "$tmpvar.0"));
	}

	# Encode the variable to set based on the $type string
	if ($type eq 'string') {
	    $envar = encode_string($value);
	} elsif ($type eq 'ip') {
	    $envar = encode_ip_address($value);
	} elsif ($type eq 'int') {
	    $envar = encode_int($value);
	} elsif ($type eq 'oid') {
	    my($tmpenvar) = SNMP_MIB::name2oid($value);
	    if ($value =~ /\./) {
		$envar = encode_oid((split /\./, $tmpenvar));
	    } else {
		$envar = encode_oid((split /\./, "$tmpenvar.0"));
	    }
	} else {
	    $self->error("Undefined variable type $type\n");
	    return undef;
	}
	
	if ($this->SNMP_Session::set_request_response(([$enoid, $envar]))) {
	    my $response = $this->pdu_buffer;
	    my ($bindings) = $this->decode_get_response ($response);
	    while ($bindings) {
		my $binding;
		($binding,$bindings) = decode_sequence ($bindings);
		my ($oid,$value) = decode_by_template ($binding, "%O%@");
		# quit if we got a mismatched oid
		last unless BER::encoded_oid_prefix_p($enoid,$oid);
		my $tempo = pretty_print($oid);	
		my $tempv = pretty_print($value);
		print "$tempo -> $tempv\n" if ($SNMP_Simple::debug);
		return $tempv;
	    }
	} else {
	    $self->error("No answer from $this->{'remote_hostname'} for $var");
	    return undef; 
	} 
    } else {
	$self->error("Unknown SNMP var $var\n");
	return undef;
    } 
 
    return undef;
}

######################################################################
#
# Do a SNMP set of the given variables to the given values.  Need to also pass in 
# a variable type for encoding purposes - need to do the correct BER encoding of the
# value.
#
# Parameters: list of arrays, each array is a triple: Variable name, Variable type, Value to set. 
# Returns a list of values returned by  SNMP set, or undef if anything went wrong.

sub snmpseta{
    my($self, @triples) = @_;
    my $this  = $self->{'session'};
    my ($triple, @retvals);
    foreach $triple (@triples) {
	my ($var, $type, $value) = @{$triple};
	my($tmpvar) = SNMP_MIB::name2oid($var);
	if (defined($tmpvar)) {
	    my($enoid, $envar);
	    # This is here so that if we have a variable in the format
	    # name.number, we assume the tailing number makes a specific
	    # oid to query for.  Otherwise, we need to append a .0 so that
	    # we can query the specific oid.
	    if ($var =~ /\./) {
		$enoid = encode_oid((split /\./, $tmpvar));
	    } else {
		$enoid = encode_oid((split /\./, "$tmpvar.0"));
	    }
	    
	    # Encode the variable to set based on the $type string
	    if ($type eq 'string') {
		$envar = encode_string($value);
	    } elsif ($type eq 'int') {
		$envar = encode_int($value);
	    } elsif ($type eq 'ip') {
		$envar = encode_ip_address($value);
	    } elsif ($type eq 'oid') {
		my($tmpenvar) = SNMP_MIB::name2oid($value);
		if ($value =~ /\./) {
		    $envar = encode_oid((split /\./, $tmpenvar));
		} else {
		    $envar = encode_oid((split /\./, "$tmpenvar.0"));
		}
	    } else {
		$self->error("Undefined variable type $type\n");
		push(@retvals, undef);
		next;
	    }
	    
	    if ($this->SNMP_Session::set_request_response(([$enoid, $envar]))) {
		my $response = $this->pdu_buffer;
		my ($bindings) = $this->decode_get_response ($response);
		while ($bindings) {
		    my $binding;
		    ($binding,$bindings) = decode_sequence ($bindings);
		    my ($oid,$value) = decode_by_template ($binding, "%O%@");
		    # quit if we got a mismatched oid
		    last unless BER::encoded_oid_prefix_p($enoid,$oid);
		    my $tempo = pretty_print($oid);	
		    my $tempv = pretty_print($value);
		    print "$tempo -> $tempv\n" if ($SNMP_Simple::debug);
		    push (@retvals, $tempv);
		}
	    } else {
		$self->error("No answer from $this->{'remote_hostname'} for $var");
		push(@retvals, undef); 
	    } 
	} else {
	    $self->error("Unknown SNMP var $var\n");
	    push(@retvals, undef); 
	} 
    }
    return (@retvals);
}

######################################################################

package SNMPv2c_Simple;
use strict qw(vars subs);	# see above
use vars qw(@ISA);
use SNMP_Session;
use SNMP_Simple;
use BER;

@ISA = qw(SNMP_Simple);

######################################################################
#
# Create a new SNMP socket

sub open {
    my($type) = @_;
    my($session)=SNMPv2c_Session::open(@_);
    my $self = bless { 'session' => $session }, $type;
    return $self;
}

######################################################################
#
# snmpget is the most simple of the SNMP get functions.  It simply
# takes a list of variables and returns a list of values, one value
# for each variable passed in.  Values are returned in the same order
# as the variables passed in.  If an error was encountered for a
# variable, an 'undef' value is returned in its place.

sub snmpget{
    my($self, @vars) = @_;
    my $this  = $self->{'session'};
    my($var, @enoids, @retvals);
    foreach $var (@vars) {
	my($tmpvar) = SNMP_MIB::name2oid($var);
	if (defined($tmpvar)) {
	    # This is here so that if we have a variable in the format
	    # name.number, we assume the tailing number makes a specific
	    # oid to query for.  Otherwise, we need to append a .0 so that
	    # we can query the specific oid.
	    if ($var =~ /\./) {
		push @enoids, encode_oid((split /\./, $tmpvar));
	    } else {
		push @enoids, encode_oid((split /\./, "$tmpvar.0"));
	    }
	} else {
	    $self->error("Unknown SNMP var $var\n");
	    push @enoids, encode_oid((split /\./, "1.3.6.1.2.1.1"));
	}
    }

    if ($this->SNMP_Session::get_request_response(@enoids)) {
	my $response = $this->pdu_buffer;
	my ($bindings) = $this->decode_get_response ($response);
	while ($bindings) {
	    my $binding;
	    ($binding,$bindings) = decode_sequence ($bindings);
	    my ($oid,$value) = decode_by_template ($binding, "%O%@");
	    # quit if we got a mismatched oid
	    #last unless BER::encoded_oid_prefix_p($enoid,$oid);
	    my $tempo = pretty_print($oid);	
	    my $tempv = pretty_print($value);
	    print "$tempo -> $tempv\n" if ($SNMP_Simple::debug);

	    push @retvals, $tempv;
	}
    } else {
	$self->error("No answer from $this->{'remote_hostname'}.\n");
	push @retvals, undef;
    }
    return (@retvals);
}

######################################################################

1;

