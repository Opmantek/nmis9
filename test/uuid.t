#!/usr/bin/perl
use strict;
use Test::More;
use UUID::Tiny qw(:std);

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMISNG::Util;

my $C = NMISNG::Util::loadConfTable();
$C->{uuid_namespace_type} = "NameSpace_URL"; # those two must line up
my $type = UUID_NS_URL;					# those two must line up
$C->{uuid_namespace_name} = "NMIS SERVER";

my $name1 = "routera";
my $name2 = "routerb";

my $uuid1 = NMISNG::Util::getUUID($name1);
is(version_of_uuid($uuid1),UUID_SHA1,"getuuid creates namespaced uuid");

my $uuid2 = create_uuid_as_string(UUID_V5, $type, 
																	$C->{uuid_namespace_name} . $name1);
is(equal_uuids($uuid1,$uuid2), 1, 'getuuid creates correct namespaced uuid');
	 
my $uuid3 = NMISNG::Util::getUUID($name2);
isnt(equal_uuids($uuid1,$uuid3),1, "getuuid creates unique namespaced uuids");

my $comp = NMISNG::Util::getComponentUUID("four",7,"fiddlestix");
is(version_of_uuid($comp), UUID_SHA1, "getcomponentuuid makes namespaced uuid");
my $notcomp = NMISNG::Util::getComponentUUID("four",7,"fiddlestix","and more");
isnt(equal_uuids($comp,$notcomp),1, "getcomponentuuid uses all components");

# check if we get random ones if the namespace_name component is n/a
$C->{uuid_namespace_name} = '';
my $one = NMISNG::Util::getUUID($name1);
is(version_of_uuid($one), UUID_RANDOM, "unnamespaced uuids are random/v4");
my $two = NMISNG::Util::getUUID($name2);
isnt(equal_uuids($one,$two),1, "unnamespaced uuids are unique");

my $newcomp = NMISNG::Util::getComponentUUID("four",7,"fiddlestix");
isnt(equal_uuids($comp,$newcomp),1,"getcomponentuuid does make use of namespace config");
is(version_of_uuid($comp), UUID_SHA1, "getcomponentuuid with no namespace config still makes namespaced uuid");

# check that the default config makes random uuids, too!
$C->{uuid_namespace_name} = 'www.domain.com';
$one = NMISNG::Util::getUUID($name1);
is(version_of_uuid($one), UUID_RANDOM, "default config makes random/v4 uuids");

my $stillnewercomp = NMISNG::Util::getComponentUUID("four",7,"fiddlestix");
is(equal_uuids($newcomp,$stillnewercomp),1,"getcomponentuuid with default config behaves like no namespace config");


done_testing();

