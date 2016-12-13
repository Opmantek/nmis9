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
package NMIS::Modules;
our $VERSION = "1.1.0";

use strict;
use Fcntl qw(:DEFAULT :flock);
use func;

sub new 
{
	my ($class,%arg) = @_;

	my $self = bless(
		{
			modules => {},
			loaded => 0,
			installed => undef,
			# match and value
			searchbases => { 
				qr/^nmis8$/ => ($arg{nmis_base} ||  "/usr/local/nmis8"),
				qr/^(oav2|open-audit)$/ => ($arg{oav2_base} || "/usr/local/open-audit"),
				qr/^opmojo$/ => ($arg{opmojo_base} || "/usr/local/opmojo"),
				qr/^omk$/ => ($arg{omk_base} || "/usr/local/omk/"),
			},
			# link constuction, not search
			nmis_cgi_url_base => 	$arg{nmis_cgi_url_base} || "/cgi-nmis8",
		}, $class);
	return $self;
}

sub loadModules 
{
	my $self = shift;
	$self->{modules} = loadTable(dir=>'conf',name=>"Modules");
	$self->{loaded} = 1;
}

sub getModules 
{
	my $self = shift;
	if ( not $self->{loaded} ) {
		$self->loadModules;
	}
	return $self->{modules};
}

# args: module (= name)
# returns: 1 if installed, 0 if not
sub moduleInstalled 
{
	my ($self,%arg) = @_;
	return grep($_ eq $arg{module}, $self->installedModulesList)? 1 : 0;
}

# args: none
# returns: string, comma-separated list of module names
sub installedModules 
{
	my $self = shift;
	return join(",", $self->installedModulesList);
}

# args: none
# returns: list of installed modules (maybe empty)
sub installedModulesList 
{
	my $self = shift;

	# cache?
	return @{$self->{installed}} if (ref($self->{installed}) eq "ARRAY");

	my @result;
	my $modules = $self->getModules();
	foreach my $modname (keys %{$modules} ) 
	{
		my $thismod = $modules->{$modname};
		# at most one search base is expected to match!
		my ($basetag) = (sort grep($thismod->{base} =~ $_, keys %{$self->{searchbases}}));
		my $basedir = $self->{searchbases}->{$basetag} || ''; # no match means absolute file at fs root
		push @result, $thismod->{name} if (-f "$basedir/".$thismod->{file});
	}
	$self->{installed} = \@result;
	return @result;
}

# returns html for a menu, works only within the main nmis gui
sub getModuleCode 
{
	my $self = shift;

	my $modOption .= qq|<option value="https://opmantek.com/" selected="NMIS Modules">NMIS Modules</option>\n|;

	my $modules = $self->getModules();
	foreach my $mod (sort { $modules->{$a}{order} <=> $modules->{$b}{order} } 
									 (keys %{$modules}) ) 
	{
		my $base = $modules->{$mod}->{base};
		# use the first match, there should be at most one
		my ($basetag) = (sort grep($base =~ $_, keys %{$self->{searchbases}})); 

		# which link to show? base+file defined, show link if installed or modules.pl if not,
		# not base or not file? show link
		my $link = ((!$base and !$modules->{$mod}->{file})
								or ($base && -f (($self->{searchbases}->{$basetag} || "")."/".$modules->{$mod}->{file})))?
								$modules->{$mod}->{link} : $self->{nmis_cgi_url_base}."/modules.pl?module=$mod";
		$modOption .= qq|<option value="$link">$modules->{$mod}{name}</option>\n|;
	}

	return qq|
			<div class="left">
				<form id="viewpoint">
					<select name="viewselect" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
						$modOption
					</select>
				</form>
			</div>|;
}

# returns an array ref of [module title, link, tagline]
# for every known module (installed or not)
sub getModuleLinks
{
	my ($self) = @_;
	my @links;

	my $modules = $self->getModules();
	my @installed = $self->installedModulesList();
	foreach my $mod
			(sort { $modules->{$a}{order} <=> $modules->{$b}{order} } (keys %{$modules}) )
	{
		my $thismod = $modules->{$mod};

		# skip "More Modules" and other fudged up stuff...
		next if ((!$thismod->{base} and !$thismod->{file})
						 or $thismod->{name} eq "opService"); # on the way out

		my $modInstalled = grep($_ eq $mod, @installed) ? 1 : 0;
		my $link = $modInstalled ? $thismod->{link} : "https://opmantek.com/network-management-system-tools/";

		push @links, [$thismod->{name}, $link, $thismod->{tagline}];
	}
	return \@links;
}


1;
