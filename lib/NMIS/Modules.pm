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

require 5;

use strict;
use Fcntl qw(:DEFAULT :flock);
use func;

# Create the class and bless the vars you want to "share"
sub new {
	my ($class,%arg) = @_;

	my $debug = undef;
	if ( defined $arg{debug} ) { $debug = $arg{debug} }
	elsif ( not defined $debug ) { $debug = 0 }

	my $module_base = undef;
	if ( defined $arg{module_base} ) { $module_base = $arg{module_base} }
	elsif ( not defined $module_base ) { $module_base = "/usr/local/opmantek/" }

	my $omk_base = undef;
	if ( defined $arg{omk_base} ) { $omk_base = $arg{omk_base} }
	elsif ( not defined $omk_base ) { $omk_base = "/usr/local/omk/" }

	my $opmojo_base = undef;
	if ( defined $arg{opmojo_base} ) { $opmojo_base = $arg{opmojo_base} }
	elsif ( not defined $opmojo_base ) { $opmojo_base = "/usr/local/opmojo/" }

	my $nmis_base = undef;
	if ( defined $arg{nmis_base} ) { $nmis_base = $arg{nmis_base} }
	elsif ( not defined $nmis_base ) { $nmis_base = "/usr/local/nmis8/" }

	my $oav2_base = undef;
	if ( defined $arg{oav2_base} ) { $oav2_base = $arg{oav2_base} }
	elsif ( not defined $oav2_base ) { $oav2_base = "/usr/local/open-audit/" }

	my $nmis_cgi_url_base = undef;
	if ( defined $arg{nmis_cgi_url_base} ) { $nmis_cgi_url_base = $arg{nmis_cgi_url_base} }
	elsif ( not defined $nmis_cgi_url_base ) { $nmis_cgi_url_base = "/cgi-nmis8" }

	my $self = {
	   	modules => {},
	   	loaded => 0,
	   	installed => undef,
	   	module_base => $module_base,
	   	nmis_base => $nmis_base,
	   	oav2_base => $oav2_base,
	   	opmojo_base => $opmojo_base,
	   	omk_base => $omk_base,
	   	nmis_cgi_url_base => $nmis_cgi_url_base,
	   	debug => $debug
	};
	bless($self,$class);

	return $self;
}

sub loadModules {
	my $self = shift;
	$self->{modules} = loadTable(dir=>'conf',name=>"Modules");
	$self->{loaded} = 1;
}

sub getModules {
	my $self = shift;
	if ( not $self->{loaded} ) {
		$self->loadModules;	
	}
	return $self->{modules};	
}

sub moduleInstalled {
	my ($self,%arg) = @_;
	my $installedModules = $self->installedModules(); # fixme should be an array NOT a commastring
	# fixme this is imprecise and brittle
	if ( $installedModules =~ /$arg{module}/ ) {
		return 1;
	}
	return 0;	
}

sub installedModules {
	my $self = shift;
	my $installedModules;
	my @installed;
	
	# from the cache
	if ( defined $self->{installed} ) {
		return $self->{installed};
	}
	else {
		my $modules = $self->getModules();
		
		foreach my $mod (keys %{$modules} ) {
			if ( $modules->{$mod}{base} eq "opmantek" ) { 
				print STDERR "DEBUG: module_base=$self->{module_base} base=$modules->{$mod}{base}, $self->{module_base}$modules->{$mod}{file}\n" if $self->{debug};
				if ( -f "$self->{module_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} eq "omk" ) { 
				if ( -f "$self->{omk_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} eq "opmojo" ) { 
				if ( -f "$self->{opmojo_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} eq "open-audit" ) { 
				if ( -f "$self->{oav2_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} =~ /nmis/ ) {
				print STDERR "DEBUG: nmis_base=$self->{nmis_base} base=$modules->{$mod}{base}, $self->{nmis_base}$modules->{$mod}{file}\n" if $self->{debug};
				if ( -f "$self->{nmis_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
		}
		
		$installedModules = join(",",@installed);
		
		# cache this for later use
		$self->{installed} = $installedModules;
		return $installedModules;	
	}
}

sub installedModulesList {
	my $self = shift;
	my $installedModules;
	my @installed;
	
	# from the cache
	if ( defined $self->{installed} ) {
		return $self->{installed};
	}
	else {
		my $modules = $self->getModules();
		
		foreach my $mod (keys %{$modules} ) {
			if ( $modules->{$mod}{base} eq "opmantek" ) { 
				print STDERR "DEBUG: module_base=$self->{module_base} base=$modules->{$mod}{base}, $self->{module_base}$modules->{$mod}{file}\n" if $self->{debug};
				if ( -f "$self->{module_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} eq "omk" ) { 
				if ( -f "$self->{omk_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} eq "opmojo" ) { 
				if ( -f "$self->{opmojo_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} eq "open-audit" ) { 
				if ( -f "$self->{oav2_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
			elsif ( $modules->{$mod}{base} =~ /nmis/ ) {
				print STDERR "DEBUG: nmis_base=$self->{nmis_base} base=$modules->{$mod}{base}, $self->{nmis_base}$modules->{$mod}{file}\n" if $self->{debug};
				if ( -f "$self->{nmis_base}$modules->{$mod}{file}" ) {
					push(@installed,$modules->{$mod}{name});
				}
			}
		}
		
		$installedModules = join(",",@installed);
		
		# cache this for later use
		$self->{installed} = $installedModules;
		return @installed;	
	}
}


# returns html for a menu, works only within the main nmis gui
sub getModuleCode {
	my $self = shift;

	my $modCode;
	my $modOption;
	
	my $modules = $self->getModules();
	
	$modOption .= qq|<option value="https://opmantek.com" selected="NMIS Modules">NMIS Modules</option>\n|;
	foreach my $mod (sort { $modules->{$a}{order} <=> $modules->{$b}{order} } (keys %{$modules}) ) {
		my $link = $modules->{$mod}{link};
		my $base = $self->{module_base};
		if ( $modules->{$mod}{base} =~ /nmis/ ) {
			$base = $self->{nmis_base};
		}
		elsif ( $modules->{$mod}{base} =~ /oav2|open-audit/ ) {
			$base = $self->{oav2_base};
		}
		elsif ( $modules->{$mod}{base} =~ /opmojo/ ) {
			$base = $self->{opmojo_base};
		}
		elsif ( $modules->{$mod}{base} eq "omk" ) {
			$base = $self->{omk_base};
		}
		
		if ( not $mod =~ /Modules/ and not -f "$base$modules->{$mod}{file}" ) {
			$link = "$self->{nmis_cgi_url_base}/modules.pl?module=$mod";
		}
		$modOption .= qq|<option value="$link">$modules->{$mod}{name}</option>\n|;
	}
	
	$modCode = qq|
			<div class="left"> 
				<form id="viewpoint">
					<select name="viewselect" onchange="window.open(this.options[this.selectedIndex].value);" size="1">
						$modOption
					</select>
				</form>
			</div>|;
		
	return $modCode;
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

		my $modInstalled = ( grep { /$mod/ } @installed) ? 1 : 0;		
		my $link = $modInstalled ? $thismod->{link} : "https://opmantek.com/network-management-system-tools/";
		
		push @links, [$thismod->{name}, $link, $thismod->{tagline}];
	}
	return \@links;
}


1;
                                                                                                                                                                                                                                                        
