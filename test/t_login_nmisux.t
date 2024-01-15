#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use NMISNG;
use Test::More;
use Test::Mojo;
use Data::Dumper;
print ("Testing nmis ux login \n");

my $url = "http://artemis.opmantek.net:8080/";
# t test for Mojolicious application NMISMojo
my $t = Test::Mojo->new('NMISMojo');

my $user = "nmis";
my $password = "Monkey42Dalek";

# # Test authentication success
$t = $t->post_ok($url.'login' => form => {username => $user, password => $password})
    ->status_is(302)
    ->header_is('Server' => 'Mojolicious (Perl)')
    ->header_is('location' => 'index')
    ->or( \&dump_response );


# # Test authentication failure
$t->post_ok($url.'login' => form => { username => 'invalid', password => 'wrong' })
  ->content_type_like(qr/text/, 'Invalid username/password combination!')
  ->or( \&dump_response );


# # Test logout
$t->get_ok('/logout')
    ->status_is(302)
    ->header_is('Server' => 'Mojolicious (Perl)')
    ->header_is('location' => '/')
    ->or( \&dump_response );

done_testing();

# function to help debug responses
sub dump_response
{
    my $response = $t->tx->res;
    if( $response->code() == 500 )
    {
        print( "context:".Dumper($t->tx->res->dom->at('div#context')->content) );
        print( "trace:".Dumper($t->tx->res->dom->at('div#trace')->content) );
    }
    else
    {
        print("Response:".Dumper($response));    
    }
}