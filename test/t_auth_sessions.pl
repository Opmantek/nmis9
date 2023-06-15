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
use NMISNG::Util;
use NMISNG::Auth;
use Compat::Timing;

my %nvp;

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = NMISNG::Util::loadConfTable();
my $auth = NMISNG::Auth->new();
my $user = "testuser";

runSessionsTest();

print "\n############\n\n";

runLockTest();

# run Sessions Test
sub runSessionsTest {
    my ($error, $counter) = $auth->get_live_session_counter(user => $user);
    if ($counter == 0) {
        print "** Ok, No live sessions for user $user \n";
    } else {
         print "** NOT Ok, No live sessions for user $user \n";
    }
    
    $C->{auth_expire_seconds} = 3600;
    my $exp = $auth->not_expired(time_exp => time);
    if ($counter == 0) {
        print "** Ok, Not expired time \n";
    } else {
         print "**NOT Ok, Not expired time \n";
    }

    #
    $C->{'max_sessions'} = 10;
    my $max_sessions = $auth->get_max_sessions(user => $user);
    if ($max_sessions == 10) {
        print "** Ok, Max session global \n";
    } else {
         print "**NOT Ok, Max session global $max_sessions \n";
    }

    my $UT = NMISNG::Util::loadTable(dir=>'conf',name=>"Users");
    $UT->{$user}{max_sessions} = 5;
    NMISNG::Util::writeTable(data => $UT, name => "Users", dir => $C->{'nmis_dir'}."/conf/Users.nmis");
    $max_sessions = $auth->get_max_sessions(user => $user);
     if ($max_sessions == 5) {
        print "** Ok, Max session global \n";
    } else {
         print "**NOT Ok, Max session global $max_sessions \n";
    }
    
    delete $UT->{$user}{max_sessions};
    NMISNG::Util::writeTable(data => $UT, name => "Users", dir => $C->{'nmis_dir'}."/conf/Users.nmis");
    
}

# run Lock Test
sub runLockTest {
    $C->{expire_users} = "true";
    $C->{expire_users_after} = 5;
    
    my $expire = $auth->get_expire_at(user => $user);
    if ($expire == 5) {
        print "** Ok, $user global expired time \n";
    } else {
         print "** NOT Ok, $user global expired time \n";
    }
 
    my $UT = NMISNG::Util::loadTable(dir=>'conf',name=>"Users");
    $UT->{$user}{expire_after} = 10;
  
    NMISNG::Util::writeTable(dir => $C->{'nmis_dir'}."/conf", data => $UT, name => "Users");
    my $expire = $auth->get_expire_at(user => $user);
    if ($expire == 10) {
        print "** Ok, Expired time overwritten \n";
    } else {
         print "** NOT Expired time overwritten \n";
    }
    
    delete $UT->{$user}{expire_after};
    NMISNG::Util::writeTable(dir => $C->{'nmis_dir'}."/conf", data => $UT, name => "Users");
    
    my $time = time;
    my ($last_login, $error) = $auth->update_last_login(user => $user, lastlogin => $time);
    ($last_login, $error) = $auth->get_last_login(user => $user);
    if ($time == $last_login) {
        print "** Ok, Last login correct \n";
    } else {
         print "** NOT Last login correct \n";
    }
}