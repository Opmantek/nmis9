#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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
#
# Some common functions for more advanced ingtegrations with NMIS.
#

package NMIS::Integration;
our $VERSION = "1.0.0";

use strict;
use func;
use notify;
use Excel::Writer::XLSX;
use MIME::Entity;

# some global variables
our $omkBin = "/usr/local/omk/bin";

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(    
	$omkBin
	
	getNodeList
	getNodeDetails
	importNodeFromNmis
	opEventsXable
	
	emailSummary
	
	start_xlsx
	add_worksheet
	end_xlsx
	
	backupFile
);

# ask opnode_admin for a list of known nodes
# returns plain list of node names
sub getNodeList
{
	my @nodes;

	if ( not -x "$omkBin/opnode_admin.pl" ) {
		print "ERROR, opEvents required but $omkBin/opnode_admin.pl not found or not executable\n";
		die;
	}
	

	open(P, "$omkBin/opnode_admin.pl act=list 2>&1 |")
			or die "cannot run opnode_admin.pl: $!\n";
	for my $line (<P>)
	{
		chomp $line;

		if ( $line !~ /^(Node Names:|=+)$/ )
		{
			push(@nodes,$line);
		}
	}
	close(P);
	die "opnode_admin failed: $!" if ($? >> 8);
	return \@nodes;
}

sub getNodeDetails
{
	my ($node) = @_;

	if ( not -x "$omkBin/opnode_admin.pl" ) {
		print "ERROR, opEvents required but $omkBin/opnode_admin.pl not found or not executable\n";
		die;
	}
	
	if (!$node)
	{
		print "ERROR cannot get node details without node!\n";
		return undef;
	}

	# stuff from stderr won't be valid json, ever.
	my $data = `$omkBin/opnode_admin.pl act=export node=\"$node\"`;
	if (my $res = $? >> 8)
	{
		print "ERROR cannot get node $node details: $data\n";
		return undef;
	}

	return JSON::XS->new->decode($data);
}

sub opEventsXable {
	my (%args) = @_;

	my $node = $args{node};
	my $desired = $args{desired};
	my $simulate = $args{simulate} || 0;
	my $debug = $args{debug} || 0;

	if ( not -x "$omkBin/opnode_admin.pl" ) {
		print "ERROR, opEvents required but $omkBin/opnode_admin.pl not found or not executable\n";
		die;
	}
	
	if ( $simulate ) {
		print "SIMULATE: opEventsXable node=$node disable/enable=$desired\n";
	}
	else {
		my $result = `$omkBin/opnode_admin.pl act=set entry.activated.opEvents=$desired node=$node 2>&1`;
		print "opEventsXable: $result" if $debug;
		if ( $result =~ /Success/ ) {
			return 1;
		}
		else {
			return 0;
		}
	}
}

sub importNodeFromNmis {
	my (%args) = @_;

	my $node = $args{node};
	my $overwrite = $args{overwrite} || 1;
	my $simulate = $args{simulate} || 0;
	my $debug = $args{debug} || 0;

	if ( not -x "$omkBin/opeventsd.pl" ) {
		print "ERROR, opEvents required but $omkBin/opeventsd.pl not found or not executable\n";
		die;
	}
	
	my $command = "$omkBin/opeventsd.pl act=import_from_nmis overwrite=$overwrite nodes=$node";
	print "importNodeFromNmis: $command\n" if $debug;
	if ( $simulate ) {
		print "SIMULATE: importNodeFromNmis nodes=$node\n";
	}
	else {
		my $result = `$command 2>&1`;
		print "importNodeFromNmis $node: $result\n" if $debug;
		if ( $result =~ /Success/ ) {
			return 1;
		}
		else {
			return 0;
		}
	}
}


sub emailSummary {
	my (%args) = @_;

	die "Need to know NMIS Config using \$C\n" if not defined $args{C};
	my $C = $args{C};

	my $from_address = $args{from_address} || $C->{mail_from};

	my $subject = $args{subject} . " " . returnDateStamp() || "Email Summary ". returnDateStamp();

	my $SUMMARY = $args{summary};

	my $email = $args{email};
	my $file_name = $args{file_name};	
	my $file_path_name = $args{file_path_name};	
	
	my @recipients = split(/\,/,$email);
		
	
	my $entity = MIME::Entity->build(From=>$C->{mail_from}, 
																	To=>$email,
																	Subject=> $subject,
																	Type=>"multipart/mixed");

	my @lines;
	push @lines, $subject;
	#insert some blank lines (a join later adds \n
	push @lines, ("","");

	if ( defined $SUMMARY ) {
		push (@lines, @{$SUMMARY});
		push @lines, ("","");
	}
		
	print "Sending summary email to $email\n";

	my $textover = join("\n", @lines);
	$entity->attach(Data => $textover,
									Disposition => "inline",
									Type  => "text/plain");

	$entity->attach(Path => $file_path_name,
									Disposition => "attachment",
									Filename => $file_name,
									Type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");																		

	my ($status, $code, $errmsg) = sendEmail(
	  # params for connection and sending 
		sender => $from_address,
		recipients => \@recipients,

		mailserver => $C->{mail_server},
		serverport => $C->{mail_server_port},
		hello => $C->{mail_domain},
		usetls => $C->{mail_use_tls},
		ipproto => $C->{mail_server_ipproto},
		
		username => $C->{mail_user},
		password => $C->{mail_password},

		# and params for making the message on the go
		to => $email,
		from => $C->{mail_from},
		subject => $subject,
		mime => $entity
	);

	if (!$status)
	{
		print "ERROR: Sending email to $email failed: $code $errmsg\n";
	}
	else
	{
		print "Summary Email sent to $email\n";
	}	
}

sub start_xlsx {
	my (%args) = @_;

	my ($xls);
	if ($args{file})
	{
		$xls = Excel::Writer::XLSX->new($args{file});
		die "Cannot create XLSX file ".$args{file}.": $!\n" if (!$xls);
	}
	else {
		die "ERROR need a file to work on.\n";
	}
	return ($xls);
}

sub add_worksheet {
	my (%args) = @_;

	my $xls = $args{xls};

	my $sheet;
	if ($xls)
	{
		my $shorttitle = $args{title};
		$shorttitle =~ s/[^a-zA-Z0-9 _\.-]+//g; # remove forbidden characters
		$shorttitle = substr($shorttitle, 0, 31); # xlsx cannot do sheet titles > 31 chars
		$sheet = $xls->add_worksheet($shorttitle);

		if (ref($args{columns}) eq "ARRAY")
		{
			my $format = $xls->add_format();
			$format->set_bold(); $format->set_color('blue');

			for my $col (0..$#{$args{columns}})
			{
				$sheet->write(0, $col, $args{columns}->[$col], $format);
			}
		}
	}
	return ($xls, $sheet);
}

sub end_xlsx {
	# closes the spreadsheet, returns 1 if ok.
	my (%args) = @_;

	my $xls = $args{xls};

	if ($xls)
	{
		return $xls->close;
	}
	else {
		die "ERROR need an xls to work on.\n";
	}
	return 1;
}


sub backupFile {
	my %arg = @_;
	my $buff;
	if ( not -f $arg{backup} ) {			
		if ( -r $arg{file} ) {
			open(IN,$arg{file}) or warn ("ERROR: problem with file $arg{file}; $!");
			open(OUT,">$arg{backup}") or warn ("ERROR: problem with file $arg{backup}; $!");
			binmode(IN);
			binmode(OUT);
			while (read(IN, $buff, 8 * 2**10)) {
			    print OUT $buff;
			}
			close(IN);
			close(OUT);
			return 1;
		} else {
			print STDERR "ERROR: backupFile file $arg{file} not readable.\n";
			return 0;
		}
	}
	else {
		print STDERR "ERROR: backup target $arg{backup} already exists.\n";
		return 0;
	}
}

1;
