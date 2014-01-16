#
## $Id: UUID.pm,v 1.6 2012/08/13 05:05:00 keiths Exp $
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
package NMIS::UUID;

require 5;

use strict;
use Fcntl qw(:DEFAULT :flock);
use NMIS;
use func;
use Data::UUID;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION );

$VERSION = "1";

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(auditNodeUUID createNodeUUID getUUID);


# check which nodes do not have UUID's.
sub auditNodeUUID {
	#load nodes
	#foreach node
	# Does it have a UUID?
	# Print exception
	#done
	my $C = loadConfTable();
	my $success = 1;
	my $LNT = loadLocalNodeTable();
	my $UUID_INDEX;
	foreach my $node (sort keys %{$LNT}) {
	  if ( $LNT->{$node}{uuid} eq "" ) {	  	
	    #'uuid_namespace_type' => 'NameSpace_URL',
	    #'uuid_namespace' => 'www.domain.com'
	    print "ERROR: $node does not have a UUID\n";
		}
		else {
			print "Node: $node, UUID: $LNT->{$node}{uuid}\n" if $C->{debug};
			if ($UUID_INDEX->{$LNT->{$node}{uuid}} ne "" ) {
				print "ERROR: the improbable has happened, a UUID conflict has been found for $LNT->{$node}{uuid}, between $node and $UUID_INDEX->{$LNT->{$node}{uuid}}\n";
			}
			else {
				$UUID_INDEX->{$LNT->{$node}{uuid}} = $node;
				$UUID_INDEX->{$node} = $LNT->{$node}{uuid};
			}
		}
	}
	writeHashtoFile(file => "$C->{'<nmis_conf>'}/UUID", data => $UUID_INDEX);
	return $success;
}

sub createNodeUUID {
	#load nodes
	#foreach node
	# Does it have a UUID?
	# create one, assign it
	#done
	#save nodes

	my $C = loadConfTable();
	my $success = 1;
	my $LNT = loadLocalNodeTable();
	my $ug = new Data::UUID;
	my $UUID_INDEX;
	foreach my $node (sort keys %{$LNT}) {
	  if ( $LNT->{$node}{uuid} eq "" ) {
			print "CREATE UUID for $node\n" if $C->{debug};
	    #'uuid_namespace_type' => 'NameSpace_URL',
	    #'uuid_namespace' => 'www.domain.com'
	    my $uuid;
	    if ( $C->{'uuid_namespace_type'} ne "" and $C->{'uuid_namespace_name'} ne "" and $C->{'uuid_namespace_name'} ne "www.domain.com" ) {
		    $uuid = $ug->create_from_name_str($C->{'uuid_namespace_type'}, $C->{'uuid_namespace_name'});
			}
			else {
		    $uuid = $ug->create_str();
			}
			$LNT->{$node}{uuid} = $uuid;
		}
		print "Node: $node, UUID: $LNT->{$node}{uuid}\n" if $C->{debug};
		if ($UUID_INDEX->{$LNT->{$node}{uuid}} ne "" ) {
			print "ERROR: the improbable has happened, a UUID conflict has been found for $LNT->{$node}{uuid}, between $node and $UUID_INDEX->{$LNT->{$node}{uuid}}\n";
		}
		else {
			$UUID_INDEX->{$LNT->{$node}{uuid}} = $node;
		}
	}
	my $ext = getExtension(dir=>'conf');
	backupFile(file => "$C->{'<nmis_conf>'}/Nodes.$ext", backup => "$C->{'<nmis_conf>'}/Nodes.$ext.bak");
	writeHashtoFile(file => "$C->{'<nmis_conf>'}/Nodes", data => $LNT);
	writeHashtoFile(file => "$C->{'<nmis_conf>'}/UUID", data => $UUID_INDEX);
	return $success;
}

sub getUUID {
	my $ug = new Data::UUID;
  my $uuid;
	my $C = loadConfTable();
  if ( $C->{'uuid_namespace_type'} ne "" and $C->{'uuid_namespace_name'} ne "" and $C->{'uuid_namespace_name'} ne "www.domain.com" ) {
    $uuid = $ug->create_from_name_str($C->{'uuid_namespace_type'}, $C->{'uuid_namespace_name'});
	}
	else {
    $uuid = $ug->create_str();
	}
	return $uuid;
}

1;
                                                                                                                                                                                                                                                        
