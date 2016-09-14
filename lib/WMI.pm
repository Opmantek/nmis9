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
#
# this module queries WMI services via the standalone wmic executable
package WMI;
our $VERSION = "1.0.0";

use strict;
use File::Temp;
use Encode 2.23;								# core module, version is what came with 5.10.0 which we can make do with

# the constructor is not doing much at this time, merely checks that the arguments are sufficient
#
# args: host, username, (required), password, timeout, program (optional),
# program: full path to wmic, if not given wmic is expected to be in the PATH
#
# returns: wmi object, or error message
sub new
{
	my ($class, %args) = @_;

	my $self = bless(
		{
			username => $args{username},
			password => $args{password},
			host => $args{host},
			timeout => $args{timeout},
			program => $args{program} || "wmic",
		},
		$class);

	# sanity check - password is optional
	for my $missing (qw(host username))
	{
		return "invalid argument $missing!"
				if (!defined($self->{$missing}) or !$self->{$missing});
	}

	return $self;
}


# retrieves X fields from a single wmi result row
# if the query happens to return more than one row, only the first data row is considered
# if the query happens to return multiple classes, only a random single class is considered
#
# args: wql (query, required), fields (list of fieldnames, optional)
# no fields means all fields.
#
# returns: (undef, hashref of fieldname->value, hashref of metadata) or (error message)
# meta: contains classname
sub get
{
	my ($self, %args) = @_;

	my ($wql, $fields) = @args{"wql","fields"};
	my @wantedfields = @$fields if (ref($fields) eq "ARRAY");
	return "query missing" if (!$wql);

	my %raw = $self->_run_query(query => $wql, timeout => $self->{timeout});
	return "get failed: $raw{error}" if (!$raw{ok});

	my $classname = (keys %{$raw{data}})[0];
	my $row = $raw{data}->{$classname}->[0];
	my $goods = @wantedfields? { map { $_ => $row->{$_}; } (@wantedfields) } : $row;

	return (undef, $goods, { classname => $classname});
}

# retrieves X fields from a wmi query
# if the query happens to return multiple classes, only a random single class is considered!
# args: wql (query, required), index, fields
#
# index is fieldname to index the result by. not present means return with row number as index.
# if the desired index field is not unique, the result is ALSO returned indexed by row number!
#
# fields is list of fieldnames, optional; no fields means all fields.
#
#
# returns (undef, hashref of indexed field => hash of other fields -> values, hashref of metadata),
# or (error message)
# metadata: contains classname, index (fieldname echoed or undef if row number), future extras...
sub gettable
{
	my ($self, %args) = @_;
	my ($wql, $indexfield, $fields) = @args{"wql","index","fields"};
	my @wantedfields = @$fields if (ref($fields) eq "ARRAY");

	return "query missing" if (!$wql);

	my %raw = $self->_run_query(query => $wql, timeout => $self->{timeout});
	return "gettable failed: $raw{error}" if (!$raw{ok});

	my (%goods,%meta);
	$meta{classname} = (keys %{$raw{data}})[0]; # this is not necessarily the first observed class!

	my $rows = $raw{data}->{$meta{classname}};
	# can we use the desired index field? check for existence and uniqueness across the rows
	if ($indexfield)
	{
		my %seen;
		for my $thisrow (@$rows)
		{
			if (!defined($thisrow->{$indexfield})
					or $seen{$thisrow->{$indexfield}}++)
			{
				undef $indexfield;
				last;
			}
		}
	}
	$meta{index} = $indexfield;

	for my $i (0..$#{$rows})
	{
		my $target = $indexfield? $rows->[$i]->{$indexfield} : $i;

		if (!@wantedfields)
		{
			$goods{$target} = $rows->[$i];
		}
		else
		{
			$goods{$target} = { map { $_ => $rows->[$i]->{$_}; } (@wantedfields) };
		}
	}
	return (undef, \%goods, \%meta);
}

# internal work horse
# args: query (required), timeout (optional)
# returns: hash (not ref), may have error
sub _run_query
{
	my ($self,%args) = @_;
	my $query = $args{query};
	return ( error => "query missing" ) if (!$query);
	my $timeout = $args{timeout};

	# prep tempfile for wmic's stderr
	my ($tfh, $tfn) = File::Temp::tempfile("/tmp/wmic.XXXXXXX");
	# random column delimiter, 10 letters should do
	my $delim = join('', map { ('a'..'z')[rand 26] } (0..9));
	my (@rawdata, $exitcode, %result);

	# fork and pipe
	my $pid = open(WMIC, "-|");
	if (!defined $pid)
	{
		unlink($tfn);
		return (error => "cannot fork to run wmic: $!");
	}
	elsif ($pid)
	{
		# parent: save and restore any previously running alarm,
		# but don't bother subtracting time spent here
		my $remaining = alarm(0);
		eval
		{
			local $SIG{ALRM} = sub { die "alarm\n"; };
			alarm($timeout) if ($timeout); # setup execution timeout

			close $tfh;									# not ours to use
			@rawdata = <WMIC>;					# read the goodies from the child
			close(WMIC);
			$exitcode = $?;
			alarm(0);
		};
		alarm($remaining) if ($remaining);
		if ($@ and $@ eq "alarm\n")
		{
			# don't want the wmic process to hang around, we stopped consuming its output
			# and it can't do anything useful anymore
			kill("SIGKILL",$pid);
			unlink($tfn);
			return (error => "timeout after $timeout seconds");
		}
	}
	else
	{
		# child
		open(STDIN, "<", "/dev/null");
		open(STDERR, ">&", $tfh);		# stderr to go there, please

		my @cmdargs = ($self->{program},
									 "--delimiter=$delim",
									 "--user=".$self->{username},
									 ($self->{password}? ("--password=".$self->{password}): "--no-pass"),
									 "//".$self->{host},
									 $query);
		exec(@cmdargs);
		die "exec failed: $!\n";
	}

	# failed? read tempfile for error msgs
	if ($exitcode)
	{
		$result{error} = "wmic failed: ";
		if (-s $tfn && open(F, $tfn)) # has data
		{
			$result{error} .= join(" ", <F>);
			close(F);
		}
		else
		{
			$result{error} .= " exit code ".($exitcode>>8);
		}
	}
	else
	{
		# worked? extract class, fieldnames
		# produce hash for each class, array of subhashes for the rows
		my ($classname, @fieldnames, %nicedata);
		for my $line (@rawdata)
		{
			chomp $line;
			# wmic may very well return utf-8 encoded data, e.g. for Caption in win32_operatingsystem on 6.0.6001
			# so let's try to be nice and decode it into native unicode
			my $validunicode = eval { decode('utf-8', $line, Encode::FB_CROAK); };
			$line = $validunicode if (!$@);

			# CLASS: Win32_PerfRawData_PerfOS_PagingFile
			if ($line =~ /^class:\s+(\S+)\s*$/i)
			{
				$classname = $1;
				undef @fieldnames;	# next line must be field names
			}
			else
			{
				# should be either list of names or list of values, with delim
				my @columns = split(qr/$delim/, $line);
				if (!@fieldnames)
				{
					@fieldnames = @columns;
				}
				else
				{
					return (error => "response contains data without classname!") if (!$classname);
					return (error => "response data doesn't contain correct number of columns!")
							if (@columns != @fieldnames);

					# the only transformation we perform is replacing the common '(null)' value with undef.
					my %thisrow = (map { $fieldnames[$_] => defined($columns[$_])
																	 && $columns[$_] ne '(null)'? $columns[$_] : undef  }
												 (0..$#fieldnames));
					$nicedata{$classname} ||= [];
					push @{$nicedata{$classname}}, \%thisrow;
				}
			}
		}
		$result{ok} = 1;
		$result{data} = \%nicedata;
	}
	unlink $tfn;

	return %result;
}

1;
