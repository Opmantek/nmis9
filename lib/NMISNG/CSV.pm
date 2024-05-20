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
package NMISNG::CSV;
our $VERSION = "9.4.8";

use strict;
use Text::CSV;

# backwards-compatible function that loads a given file,
# and rearranges the data in a hash with outer key being from
# the given named column, and value being a hash of all columns.
#
# note that this REQUIRES that the csv was written with
# the first line being the column names.
#
# args: filename, column name (both required)
# returns: (undef, hash) or (error)
sub loadCSV
{
	my ($csvfile, $keycolname) = @_;

	return "cannot load csv file without file and column arguments!"
			if (!$csvfile or !$keycolname);

	open(F, $csvfile) or return "cannot open $csvfile: $!";
	my @inputdata = <F>;
	close(F);

	my $csv = Text::CSV->new({binary => 1});
	my $headings = shift @inputdata;
	chomp $headings;

	my $isok = $csv->parse($headings);
	return("invalid input \"$headings\": ".$csv->error_diag) if (!$isok);

	my @collist = $csv->fields;
	# column name as per heading -> index of the column
	my %knowncols = map { $collist[$_] => $_; } (0..$#collist);
	return "duplicate columns in \"$headings\"!"
			if (scalar keys %knowncols != @collist);
	return "key column not present in input!"
			if (!defined $knowncols{$keycolname});

	my %response;
	for my $line (@inputdata)
	{
		chomp $line;
		$isok = $csv->parse($line);
		return("invalid input \"$line\": ".$csv->error_diag) if (!$isok);

		my @fields = $csv->fields;
		$response{ $fields[$knowncols{$keycolname}] } =
		{ map { $_ => $fields[$knowncols{$_}] } (keys %knowncols) };
	}

	return (undef, %response);
}

# todo9: maybe bring back _some_ form of writeCSV for hash of hashes?
# not used by any mainstream code
