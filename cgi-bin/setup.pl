#!/usr/bin/perl
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
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
 
use strict;
use URI::Escape;

use func;
use NMIS;
use Auth;

use CGI qw(:standard *table *Tr *td *form *Select *div);

my $q = new CGI; # processes all parameters passed via GET and POST
my $Q = $q->Vars; # param values in hash

my $C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug})
		or die "Cannot read Conf table, conf=$Q->{conf}\n";

# this cgi script defaults to widget mode ON
my $wantwidget = exists $Q->{widget}? !getbool($Q->{widget}, "invert") : 1;
my $widget = $wantwidget ? "true" : "false";

# config key to display name, needed in two places so here we go
my %item2displayname = ( "server_name" => "Server Name",
												 "nmis_host" => "NMIS Host", 
												 "mail_server" => "Mail Server",
												 "mail_server_port" => "Mail Server Port",
												 "mail_user" => "Mail User", 
												 "mail_password" => "Mail Password",
												 "mail_from" => "Mail Sender Address",
												 "mail_domain" => "Mail Domain", 
												 "mail_use_tls" => "Use TLS Encryption", 
												 "mail_combine" => "Combined Emails",
												 "status_mode" => "Node Status Mode",
		);


# Before going any further, check to see if we must handle
# an authentication login or logout request

my $headeropts = {type=>'text/html',expires=>'now'};
my $AU = Auth->new(conf => $C);

if ($AU->Require) 
{
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},
															username=>$Q->{auth_username},
															password=>$Q->{auth_password},
															headeropts=>$headeropts);
}
$AU->CheckAccess("table_config_view","header");

# check for remote request, fixme - this never exits!
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }


# just two actions: showing the setup (menu/panel), handling an edit action
if ($Q->{act} eq 'setup_menu' or getbool($Q->{cancel}))
{
	display_setup();
} 
# edit submission action: returns 0 if ok, 1 otherwise (and sets $Q->{error_message})
elsif ($Q->{act} eq 'setup_doedit')
{	
	edit_config();
	display_setup();
}
else 
{ 
	print header($headeropts);
	pageStart(title => "NMIS Setup", refresh => $Q->{refresh}) if (!$wantwidget);

	print "ERROR: Setup doesn't know how to handle act=".escape($Q->{act});
	pageEnd if (!$wantwidget);
	
	exit 1;
}

# some small helpers

# neuter html, args: one string
sub escape {
	my $k = shift;
	$k =~ s/&/&amp;/g; $k =~ s/</&lt;/g; $k =~ s/>/&gt;/g;
	return $k;
}


# display the editing forms/panels for the essential options
# args: none, but uses $C
# returns: nothing
sub display_setup
{
	my (%args) = @_;

	print header($headeropts);
	pageStart(title => "NMIS Setup", refresh => $Q->{refresh}) 
			if (!$wantwidget);

	# get the current config, structure unflattened; and the default config too!
	my $rawconf = readFiletoHash(file => $C->{'<nmis_conf>'}."/$C->{conf}"); 
	my $defaultconf = readFiletoHash(file => $C->{'<nmis_base>'}."/install/$C->{conf}");

	my $iconok = "<img src='".$C->{'<menu_url_base>'}."/img/v8/icons/icon_accept.gif'>";
	my $iconbad = "<img src='".$C->{'<menu_url_base>'}."/img/v8/icons/icon_alert.gif'>";

	print qq|<div ><strong>Welcome to the NMIS Setup interface!</strong><br/>
In this menu you'll find the most essential settings for getting started with NMIS.
Entries that likely need to be adjusted are marked with $iconbad.|;

  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmissetup", -href=>url(-absolute=>1)."?")
			. hidden(-override => 1, -name => "conf", -value => $Q->{conf})
			. hidden(-override => 1, -name => "act", -value => "setup_doedit")
			. hidden(-override => 1, -name => "widget", -value => $widget)
			. hidden(-override => 1, -name => "cancel", -value => '', -id=> "cancelinput");

	print start_table;
	if (defined $Q->{error_message} && $Q->{error_message} ne "" )
	{
		print Tr(td({class=>'Fatal', align=>'center', colspan => 3}, "Error: $Q->{error_message}"));
	}
	elsif (defined $Q->{success_message} && $Q->{success_message} ne "" )
	{
		print Tr(td({class=>'Normal', align=>'center', colspan => 3}, "$Q->{success_message}"));
	}

	foreach (
		# section, item,  tooltip/help text
		["system", "server_name", 
		 "This is the primary name of this NMIS server. It's used in lots of places and really must be set."],

		["system", "nmis_host", 
		 "This is the FQDN (or IP address) of the NMIS server, and is used in emails and other notifications for creating links back to this system."],
		
		["email", "mail_server",
		 "The FQDN (or IP address) of your outgoing mail server. NMIS needs that to send you email notifications."],
		
		["email", "mail_server_port", 
		 "The port number your mail server listens on for SMTP conversations. Common choices are 25 and 587, but note that 587 commonly requires authentication!"],

		["email", "mail_user",
		 "This is the mail user name for authenticating at your mail server. Leave this blank if you don't need to authenticate at your mail server."],

		["email", "mail_password",
		 "This is the password for authenticating at your mail server. 
Leave this blank if you don't need to authenticate at your mail server."],
		
		["email", "mail_from", 
		 "This is the From address for email notifications."],
		["email", "mail_domain",
		 "This is required for some mail servers that enforce strict HELO messages. Using your company domain here is a good idea."],
		["email", "mail_use_tls",
		 "If you select true here, then NMIS will try to negotiate STARTTLS encryption with your mail server. Not useful if your mail server is localhost."],

		["email", "mail_combine", 
		 "Do you want to get separate NMIS mails for every event or should NMIS combine multiple messages into one mail?"],

		["dummy", "status_mode", "NMIS has three methods for classifying a node's status, which are documented in detail <a href='https://community.opmantek.com/display/NMIS/NMIS+Node+Status' target='_blank'>on this page</a>. Classic is the default." ],
			)
	{
		my ($section, $item, $tooltip) = @$_;
		my $title = $item2displayname{$item};

		my $curval = $rawconf->{$section}->{$item} if defined ($rawconf->{$section}); # catch a dummy!
		my $displayinfo = findCfgEntry(section => $section, item => $item) || {};
		my $entryisok = 1;

		if ($item eq "status_mode")	#  doesn't exist as single item in config
		{
			$displayinfo = { display => "popup", value => ['classic', 'coarse', 'fine-grained' ]};
			$curval = getbool($rawconf->{system}->{overall_node_status_coarse})? "coarse" : getbool($rawconf->{system}->{node_status_uses_status_summary})? "fine-grained" : "classic";
			$entryisok = 1;
		}

		if ($displayinfo->{display} eq "text"
				and defined($defaultconf->{$section}) 
				and $curval eq $defaultconf->{$section}->{$item})
		{
			$entryisok=0;
		}

		# some options inter-depend, add their colorings here
		# mail port: 25 and 587 are ok, none other are
		if ($item eq "mail_server_port")
		{
			$entryisok = $curval =~ /^(25|587)$/? 1 : 0;
		}
		if ($item eq "mail_user" or $item eq "mail_password")
		{
			# mail port 587 -> likely needs auth
			# and if only one of password/user are set, then change color of both
			if ($rawconf->{email}->{mail_server_port} eq "587"
					or (($rawconf->{email}->{mail_user} ne "") xor ($rawconf->{email}->{mail_password} ne "")))
			{
				$entryisok=0;
			}
			elsif ($rawconf->{email}->{mail_user} eq "" and $rawconf->{email}->{mail_password} eq "")
			{
				$entryisok=1;
			}
		}

		# display edit field; if text, then show it UNescaped;
		my $displayval = escape($curval);

		print start_Tr;
		print td({class=>"header", width => "20%", }, 
						 ($entryisok ? $iconok : $iconbad) . " &nbsp; ". $title);

		if (!defined $displayinfo->{display} or $displayinfo->{display} eq "text")
		{
			print td({class=>"infolft Plain"},
							 ($entryisok? '' : $iconbad." &nbsp; "),
							 textfield(-name => "option/$section/$item", -value => $curval,
												 -override => 1 ));
		}
		elsif ($displayinfo->{display} eq "popup")
		{
			print td({class=>'infolft Plain'},
							 popup_menu(-name => "option/$section/$item",
													-values => $displayinfo->{value},
													-default => $curval,
													-override => 1));
		}
		print td({class=>"infolft Plain"}, $tooltip);
		print end_Tr;
	}

	# do the add nodes and add groups rows

	my $havecustomgroups = $rawconf->{system}->{group_list} ne $defaultconf->{system}->{group_list};
	print start_Tr(), td({class => "header", width => "20%"},
											 ($havecustomgroups? $iconok: $iconbad) . "&nbsp; Groups");
	print td({class => "infolft Plain"},  ($havecustomgroups? '' : $iconbad) . "&nbsp; "
					 # make the link into a button, same styling as elsewhere
					 . button(-name => "add_groups", -value => "Add or Edit Groups",
										-onclick => $wantwidget? "createDialog({id: 'cfg_groups', url: 'config.pl?conf=$Q->{conf}&amp;act=config_nmis_edit&amp;section=system&amp;item=group_list&amp;widget=$widget', title: 'Edit Groups'})" : "document.location='config.pl?conf=$Q->{conf}&amp;act=config_nmis_edit&amp;section=system&amp;item=group_list&amp;widget=$widget'" )),
			
			td({class => "infolft Plain"},
				 ($havecustomgroups? "You have configured ".
					scalar(split(/\s*,\s*/, $rawconf->{system}->{group_list})). " groups" : 
					"You have only the default NMIS groups.")."<br/>Use the button to the left to edit groups."),
					end_Tr;

	my $NT = loadLocalNodeTable();
	my $havecustomnodes = (keys %$NT > 1);
	print start_Tr(), 
	td({class => "header", width => "20%"},
		 ($havecustomnodes? $iconok : $iconbad). "&nbsp; Nodes"),
	td({class => "infolft Plain"}, ($havecustomnodes? '': $iconbad) . "&nbsp; "
		 . button(-name => "add_nodes", -value => "Add Nodes",
							-onclick => $wantwidget? "createDialog({id: 'cfg_nodes', url: 'tables.pl?conf=$Q->{conf}&amp;act=config_table_add&amp;table=Nodes&amp;widget=$widget', title: 'Add Nodes'})" : "document.location='tables.pl?conf=$Q->{conf}&amp;act=config_table_add&amp;table=Nodes&amp;widget=$widget'" )),

			td({class => "infolft Plain"}, ($havecustomnodes? "You have configured ".(scalar keys %$NT)." nodes": "Your configuration contains only the single default node.")."<br/>Use the button to the left to add nodes."), end_Tr;
	
	print end_table;

	# and at the end include  the 'don't show this again button!'
	print "<span title='The Setup window will reappear automatically unless you tick this box and save the settings.'>",
	checkbox(-name => "option/system/hide_setup_widget", -value => "true", -checked => getbool($rawconf->{system}->{hide_setup_widget}),
					 -label => "Don't show this setup window again.", -override => 1 ),
	"</span><p/>",
	button(-name=>"submitbutton", 
				 onclick=> ( $wantwidget? "get('nmissetup');" : "submit()" ), 
				 -value=> "Save Settings"),
	"&nbsp;",
	button(-name=>"cancelbutton",
				 # yuck.
				 onclick => ( $wantwidget? "var id = \$(this).parents('.ui-dialog').attr('id'); \$('div#NMISV8').data('NMISV8'+id).widgetHandle.dialog('close');" : "document.location = '$C->{nmis}?conf=$Q->{conf}';" ),
				 
# $("#cancelinput").val("true");' . ($wantwidget? "get('nmissetup');" : 'submit();'),
				 -value=>"Done");

	print end_form;
	print "</div>";
	pageEnd if (!$wantwidget);
}


# updates the configuration, 
# args: none, but uses $C and $Q
# returns: 1 if all ok, 0 if not and sets $Q->{success_message} or $Q->{error_message}
sub edit_config
{
	my (%args) = @_;

	return 1 if (getbool($Q->{cancel})); # shouldn't get here in the cancel case
	$AU->CheckAccess("Table_Config_rw");

	# read the current config in raw, unflattened form
	my $rawconf = readFiletoHash(file => $C->{'<nmis_conf>'}."/$C->{conf}"); 

	my $changes;
	# elements are handed to us as option/<section>/<item>
	for my $update (keys %$Q)
	{
		my ($static, $section, $item) = split(/\//,$update,3);
		next if ($static ne "option" or !$section or !$item);
		my $value = $Q->{$update};

		# sanity check the values
		# things that mustn't be blank
		if ($value eq "" and ( $item eq "nmis_host" or $item eq "mail_server" or $item eq "server_name"
				or $item eq "mail_from" ))
		{
			$Q->{error_message} = $item2displayname{$item}." cannot be blank!";
			return 0;
		}
		elsif ($item eq "status_mode" and $value !~ /^(coarse|fine-grained|classic)$/)
		{
			$Q->{error_message} = $item2displayname{$item}." must be one of coarse, fine-grained or classic!";
			return 0;
		}
		elsif (($item eq "nmis_host" or $item eq "mail_server")  
					 and $value !~ /^([a-zA-Z0-9_\.-]+|[0-9\.]+|[0-9a-fA-F\:]+)$/)
		{
			$Q->{error_message} = $item2displayname{$item}." contains invalid characters!";
			return 0;
		}
		elsif ($item eq "mail_server_port" and ( $value !~ /^\d+$/ or $value > 65535) )
		{
			$Q->{error_message} = "Mail Server Port must be a number between 0 and 65535!";
			return 0;
		}
		# this is crude, using email::valid would be a better choice; note that _ is actually NOT
		# allowed in the domain/hostname part but we don't bother.
		elsif ($item eq "mail_from" and $value !~ /[^@]+\@([a-zA-Z0-9_\.-]+|[0-9\.]+|[0-9a-fA-F\:]+)$/)
		{
			$Q->{error_message} = $item2displayname{$item}." is not a valid email address";
			return 0;
		}
		elsif (($item eq "mail_use_tls" or $item eq "mail_combine") and $value !~ /^(true|false)$/)
		{
			$Q->{error_message} = "Value for ".$item2displayname{$item}." must be true or false.";
			return 0;
		}

		if ($item eq "status_mode")	# catch a dummy - section is virtual
		{
			my $curval = getbool($rawconf->{system}->{overall_node_status_coarse})? "coarse" : getbool($rawconf->{system}->{node_status_uses_status_summary})? "fine-grained" : "classic";
			if ($value ne $curval)
			{
				$changes = 1;
				if ($value eq "coarse")
				{
					$rawconf->{system}->{overall_node_status_coarse} = 'true';
					# quietly set a default color if the current value is a dud
					$rawconf->{system}->{overall_node_status_level} = 'Critical'
							if (!defined $rawconf->{system}->{overall_node_status_level}
									or $rawconf->{system}->{overall_node_status_level} !~ /^(Normal|Warning|Minor|Major|Critical|Fatal)$/);
					$rawconf->{system}->{node_status_uses_status_summary} = 'false';
					$rawconf->{system}->{display_status_summary} = 'false';
				}
				elsif ($value eq "classic")
				{
					$rawconf->{system}->{overall_node_status_coarse} = 'false';
					$rawconf->{system}->{node_status_uses_status_summary} = 'false';
					$rawconf->{system}->{display_status_summary} = 'false';
				}
				else										# fine-grained
				{
					$rawconf->{system}->{overall_node_status_coarse} = 'false';
					$rawconf->{system}->{node_status_uses_status_summary} = 'true';
					$rawconf->{system}->{display_status_summary} = 'true';
				}
			}
		}
		else
		{
			if (!defined $rawconf->{$section})
			{
				$Q->{error_message} = "Error: Attempting to set unknown item $update!";
				return 0;
			}
			# then adjust the entries in question and record that changes were made
			my $curval = $rawconf->{$section}->{$item};
			if ($curval ne $value)
			{
				$rawconf->{$section}->{$item} = $value;
				$changes=1;
			}
		}
	}
	
	# and finally if there were changes, write the config data back
	if ($changes)
	{
		writeConfData(data => $rawconf);
		$Q->{success_message} = "Successfully saved all settings.";
	}
	else
	{
		$Q->{success_message} = "No changes to save.";
	}
	return 1;
}
