#!/usr/bin/perl
#
## $Id: debug-master.pl,v 8.2 2012/01/10 01:49:11 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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

# 
use strict;
use NMIS;
use func;
use csv;

use Data::Dumper;
$Data::Dumper::Indent = 1;

use Fcntl qw(:DEFAULT :flock);

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div *hr);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span );
#use CGI::Debug;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

# load NMIS configuration table
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# if options, then called from command line
if ( $#ARGV > 0 ) { $C->{auth_require} = 0; } # bypass auth

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new;  # Auth::new will reap init values from NMIS config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

#======================================================================

use Data::Dumper::HTML qw(dumper_html);
$Data::Dumper::Sortkeys = 1;

#####################
#debug
####################

# print all conf files to screen
print
	$q->header(),
    $q->start_html(-title => 'NMIS Table and Var List',
    				-head  => style({type => 'text/css'},
                              join('',<DATA>), 			# slurp __DATA__
                              ),
    				-meta => { 'CacheControl' => "no-cache", 'Pragma' => "no-cache", 'Expires' => -1 }),
	$q->h2('NMIS8 Configuration and Var display for Developers '),
	$q->hr;


print <<EOF;

<style>
#toc {
    padding:5px;
    background-color:#f0f0f0;
    border:1px solid #aaaaaa;
    margin-right:auto;
    text-align:center;
}
#toc div {text-align:left;}
</style>
<script>
// Updated 11/8 with code to auto-jump
// updated 11/8 with better auto-jump code

function createTOC()
{
	// to do : gracefully handle if h2 is top level id and not h1
	
	// configuration options
	var page_block_id = 'contentcenter'; // this is the id which contains our h1's etc
	var toc_page_position =-1; // used later to remember where in the page to put the final TOC
	var top_level ="H1";// default top level.. shouldn't matter what is here it is set at line 50 anyway
	var skip_first = false;

	var w = document.getElementById(page_block_id);
	var x = w.childNodes;
	//build our table tbody tr td - structure
	y = document.createElement('table');
	y.id='toc';
	mytablebody = document.createElement('TBODY');
	myrow = document.createElement('TR');
	mycell = document.createElement('TD');
	myrow.appendChild(mycell);
	mytablebody.appendChild(myrow);
	y.appendChild(mytablebody);
	
	// create the two title strings so we can switch between the two later via the id
	var a = mycell.appendChild(document.createElement('span'));
	a.id = 'toc_hide';
	a.innerHTML = '<b>Contents</b> <small>[<a href="" onclick="javascript:showhideTOC();return false;">hide</a>]</small>';
	a.style.textAlign='center';
	var a = mycell.appendChild(document.createElement('span'));
	a.id = 'toc_show';
	a.style.display='none'
	a.innerHTML = '<b>Contents</b> <small>[<a href="" onclick="javascript:showhideTOC();return false;">show</a>]</small>';
	a.style.textAlign='center';
	
	var z = mycell.appendChild(document.createElement('div'));
	
	// set the id so we can show/hide this div block later
	z.id ='toc_contents';
	
	var toBeTOCced = new Array();
	for (var i=0;i<x.length;i++)
	{
		if (x[i].nodeName.indexOf('H') != -1 && x[i].nodeName != "HR") // added check for hr tags
		{
			toBeTOCced.push(x[i])
			if (toc_page_position == -1)
			{
				// get the first one.. don't care which level it is
				toc_page_position = 0; 
				// we should also remember which level is top of the page
				top_level = x[i].nodeName;
			}
			else if (toc_page_position == 0)
			{
				toc_page_position = i-1; // we want the toc before the first subheading
			}
		}
	}
	// array to store numeric toc prefixes
	var counterArray = new Array();
	for (var i=0;i<=7;i++)
		{counterArray[i]=0;}
	
	// quit if it is a small toc
	if (toBeTOCced.length <= 2) return;

	for (var i=0;i<toBeTOCced.length;i++)
	{
		// put the link item in the toc
		var tmp_indent =0;
		// tmp is link in toc
		var tmp = document.createElement('a');
		// tmp2 is name link for this heading ancor
		var tmp2 = document.createElement('a');	

		// we need to prefix with a number
		var level = toBeTOCced[i].nodeName.charAt(1);
		// we need to put in the upper numbers ie: 4.2 etc.
		++counterArray[level];
		
		tmp.href = '#header_' + i;
		tmp2.id = 'header_' + i;

		for (var j=2;j<=level;j++)
			if (counterArray[j] > 0)
			{
				tmp.innerHTML += counterArray[j]+'.' // add numbering before this toc entry
				tmp_indent +=10;
			}
		tmp.innerHTML +=  ' ' + toBeTOCced[i].innerHTML;
		
		// if counterArray[+1] != 1 .. reset it and all the above
		level++; // counterArray[level+1] was giving me issues... stupid javascript
		if (counterArray[level] > 0) // if we dropped back down, clear out the upper numbers
		{
			for (var j=level; j < 7; j++)
			{counterArray[j]=0;}
		}

		if (tmp_indent > 10)
			tmp.style.paddingLeft=tmp_indent -10+'px';
	
		// if NOT h1 tag, add to toc
		if (!skip_first)
		{
			z.appendChild(tmp);
			// put in a br tag after the link
			var tmp_br = document.createElement('br');
			z.appendChild(tmp_br);
		}
		else // else, act as if this item was never created.
		{
			skip_first=false;	
			// this is so the toc prefixes stay proper if the page starts with a h2 instead of a h1... we just reset the first heading to 0
			--level;
			--counterArray[level];
		}



//		if (toBeTOCced[i].nodeName == 'H1')
//		{
//			tmp.innerHTML = 'Top';
//			tmp.href = '#top';
//			tmp2.id = 'top';
//		}



		// put the a name tag right before the heading
		toBeTOCced[i].parentNode.insertBefore(tmp2,toBeTOCced[i]);
	}
	w.insertBefore(y,w.childNodes[toc_page_position+2]); // why is this +2 and not +1?



	// now we work on auto-jumping to a specific target 
	// document.location.hash has the target we want to jump to
	if (document.location.hash.length >= 9) // we now it's gotta be atleast '#header_x'
	{
		// get rid of the '#' before our target
		var new_pos = document.location.hash.substr(1,document.location.hash.length);
		// do nothing if the requested anchor isn't in the document
		if ( document.getElementById(new_pos) != null)
		{
			// stupid IE, just go to the hash again =)
			window.location.hash = '#' + new_pos;
		}
	}

}

var TOCstate = 'block';

function showhideTOC()
{
	TOCstate = (TOCstate == 'none') ? 'block' : 'none';
	// flip the toc contents
	document.getElementById('toc_contents').style.display = TOCstate;
	// now flip the headings
	if (TOCstate == 'none')
	{
		document.getElementById('toc_show').style.display = 'inline';
		document.getElementById('toc_hide').style.display = 'none';
	}
	else
	{
		document.getElementById('toc_show').style.display = 'none';
		document.getElementById('toc_hide').style.display = 'inline';
	}
}

// now attache the createTOC() to the onload
window.onload = createTOC;
</script>


</head>
<body>
EOF
=pod
<div class="container">
<!-- Header -->
<div id="logo"></div>
<div id="navbar"></div>
<!-- Main Content -->
<div id="column_left"></div>
<div id="sidebar"></div>
<!-- Footer -->
<div id="footer"></div>
</div>
=cut


print qq|<div class="container">|;
print qq|<div id="column_left"></div>|;
print "<div id=\"contentcenter\">";
print "<h1></h1>";


print "<h1>Static Tables</h1>";

print "<h2>NMIS Config Table</h2>";
print dumper_html($C);

# slave servers

if ($C->{master_dash} eq "true") {
	
	my $ext = getExtension(dir=>'var');

	print "<h1>Master/Slave communications</h1>";
	my $ST = loadTable(dir=>'conf',name=>'Servers');
	
	print "<h2>Slaves Table</h2>";
	print dumper_html($ST);
	
	foreach my $name ( keys %{$ST}) {

		print qq|<b>Derived Slave '$name' CGI_URL: </b>$ST->{$name}{protocol}://$ST->{$name}{host}:$ST->{$name}{port}$ST->{$name}{cgi_url_base}/scriptname.pl<br>|;
		print qq|<b>Derived Slave '$name' BASE_URL: </b>$ST->{$name}{protocol}://$ST->{$name}{host}:$ST->{$name}{port}$ST->{$name}{url_base}/html.htm<br>|;
		print qq|<b>Derived Master to Slave '$name' connect url:  </b>$ST->{$name}{protocol}://$ST->{$name}{host}:$ST->{$name}{port}$ST->{$name}{cgi_url_base}/connect.pl<br>|;

		my $slaveNodes = readFiletoHash(file=>"$C->{'<nmis_var>'}/$name-nodes");	

		print "<br><h2>$name-nodes.$ext</h2><b>last modified  @{[ int ((-M \"$C->{Slaves_Table}\") *24*60) ]} minutes ago</b><br>";
		print dumper_html($slaveNodes);

	
		foreach my $summary ( qw( summary8h summary16h ) ) {
			my $summaryHash = readFiletoHash(file=>"$C->{'<nmis_var>'}/$name-$summary");

			print "<h2>$name-$summary</h2><b>last updated  @{[ int ((-M \"$FindBin::Bin/../var/$name-$summary.$ext\") *24*60) ]} minutes ago</b><br>";
			print dumper_html($summaryHash);
		}
	}
}

my $NS = loadNodeSummary();
print "<h2>Node Summary</h2>";
print dumper_html($NS);
	

print "<br>END</br>";
print "</body></html>";


exit();


# here's a stylesheet incorporated directly into the page

__DATA__

/* ---------------------------- */
/* STANDARD HTML TAG RESET */
/* ---------------------------- */
body,
h1, h2, h3,
p, ul, li,
form {
border:0;
margin:0px;
padding:0px;
}
/* ---------------------------- */
/* STANDARD HTML TAG DEFINITION */
body,
form, input {
color:#000000;
font-family:Arial, Helvetica, sans-serif;
font-size:12px;
color:#000000;
}
h1{font-size:24px; /* ...other properties... */}
h2{font-size:18px; /* ...other properties... */}
h3{font-size:13px; /* ...other properties... */}
a:link, a:visited{color:#0033CC;}
a:hover {color:#666666;}

/* ----------------------------*/
/* PAGE ELEMENTS */
/* ----------------------------*/
.container{
margin:0 auto;
width:855px;
}
/* ---------------------------*/
/* LOGO */
#logo{
background:url(/* ...URL image... */);
height:60px;
}
/* ---------------------------*/
/* NAVIGATION */
#navbar{
background:#000000;
height:30px;
}
/* ----------------------------*/
/* COLUMN LEFT */
#column-left{
float:left;
margin-right:30px;
width:472px;
}
#column-left h1{
border-bottom:solid 1px #DEDEDE;
font-family:Georgia;
margin-bottom:20px;
}
#column-left p{
font-size:14px;
color:#333333;
}
/* ---------------------------*/
/* COLUMN RIGHT (Sidebar */
#sidebar{
float:left;
width:353px;
}
/* ---------------------------*/
/* FOOTER (Sidebar */
#footer{
clear:both;
color:#666666;
font-size:11px;
}
