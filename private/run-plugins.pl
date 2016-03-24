#!/usr/bin/perl

#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use Sys;
use NMIS::UUID;
use NMIS::Timing;
use Data::Dumper;
use Excel::Writer::XLSX;

# Variables for command line munging
my %arg = getArguements(@ARGV);

if ( $arg{node} eq "" ) {
	usage();
	exit 1;
}


# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";


my @active_plugins = &load_plugins;

my $node = $arg{node};

runPlugins($node);

print $t->elapTime(). " End\n";

exit 1;

sub runPlugins {
	my $name = shift;


	my $S = Sys::->new; # get system object
	$S->init(name=>$name,snmp=>'false'); # load node info and Model if name exists


	# done with the standard work, now run any plugins that offer update_plugin()
	for my $plugin (@active_plugins)
	{
		my $funcname = $plugin->can("update_plugin");
		next if (!$funcname);

		dbg("Running update plugin $plugin with node $name");
		my ($status, @errors);
		eval { ($status, @errors) = &$funcname(node => $name, sys => $S, config => $C); };
		if ($status >=2 or $status < 0 or $@)
		{
			logMsg("Error: Plugin $plugin failed to run: $@") if ($@);
			for my $err (@errors)
			{
				logMsg("Error: Plugin $plugin: $err");
			}
		}
		elsif ($status == 1)						# changes were made, need to re-save the view and info files
		{
			dbg("Plugin $plugin indicated success, updating node and view files");
			$S->writeNodeView;
			$S->writeNodeInfo;
		}
		elsif ($status == 0)
		{
			dbg("Plugin $plugin indicated no changes");
		}
	}
}	


sub usage {
	print "need nodename $0 node=nodename";
}


# a function to load the available code plugins,
# returns the list of package names that have working plugins
sub load_plugins
{
	my @activeplugins;

	# check for plugins enabled and the dir
	return () if (!getbool($C->{plugins_enabled})
								or !$C->{plugin_root} or !-d $C->{plugin_root});

	if (!opendir(PD, $C->{plugin_root}))
	{
		logMsg("Error: cannot open plugin dir $C->{plugin_root}: $!");
		return ();
	}
	my @candidates = grep(/\.pm$/, readdir(PD));
	closedir(PD);

	for my $candidate (@candidates)
	{
		my $packagename = $candidate;
		$packagename =~ s/\.pm$//;

		# read it and check that it has precisely one matching package line
		dbg("Checking candidate plugin $candidate");
		if (!open(F,$C->{plugin_root}."/$candidate"))
		{
			logMsg("Error: cannot open plugin file $candidate: $!");
			next;
		}
		my @plugindata = <F>;
		close F;
		my @packagelines = grep(/^\s*package\s+[a-zA-Z0-9_:-]+\s*;\s*$/, @plugindata);
		if (@packagelines > 1 or $packagelines[0] !~ /^\s*package\s+$packagename\s*;\s*$/)
		{
			logMsg("Plugin $candidate doesn't have correct \"package\" declaration. Ignoring.");
			next;
		}

		# do the actual load and eval
		eval { require $C->{plugin_root}."/$candidate"; };
		if ($@)
		{
			logMsg("Ignoring plugin $candidate as it isn't valid perl: $@");
			next;
		}

		# we're interested if one or more of the supported plugin functions are provided
		push @activeplugins, $packagename
				if ($packagename->can("update_plugin")
						or $packagename->can("collect_plugin")
						or $packagename->can("after_collect_plugin")
						or $packagename->can("after_update_plugin") );
	}

	return sort @activeplugins;
}
