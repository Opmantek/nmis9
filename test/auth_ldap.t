#!/usr/bin/perl
#!/usr/bin/perl
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

#
use strict;
use Carp;
use Test::More;
use Test::Deep;
use Data::Dumper;
use NMISNG;
use NMISNG::Auth;
use NMISNG::Util;

#this test uses https://github.com/rroemhild/docker-test-openldap
my $testname = "ldap_verify_test";

my $log = Mojo::Log->new;

my $test_priv = {
    "admin_staff" => {
        "privilege"=> "admin",
        "groups"=> "all",
        "priority"=> 1,
        "level" => "0"
    },
    "Ship_crew"=> {
        "privilege"=> "operator",
        "groups"=> "group1,group2",
        "priority"=> 2,
        "level" => "1"
    }
};


my $error = NMISNG::Util::writeHashtoFile(file=> "/usr/local/nmis9/conf/TEST_auth_ldap_privs_file.nmis", data=>$test_priv);
if ($error) {
    diag("Error writing to file: $error");
    exit 1;
}

#now lets write out the file



diag("Testing ldap_verify with Docker LDAP structure");


my $config = NMISNG::Util::loadConfTable();

# LDAP configuration for the Docker image
$config->{auth_ldap_server} = 'localhost:10389';  # Assuming the Docker container is running on localhost
$config->{auth_ldap_base} = 'dc=planetexpress,dc=com';
$config->{auth_ldap_attr} = 'uid';
$config->{auth_ldap_acc} = 'cn=admin,dc=planetexpress,dc=com';
$config->{auth_ldap_psw} = 'GoodNewsEveryone';
$config->{auth_ldap_privs_file} = 'TEST_auth_ldap_privs_file.nmis';
$config->{auth_ldap_privs} = 1;

my $auth = NMISNG::Auth->new(conf => $config);

# Test cases
my @test_cases = (
    { username => 'professor', password => 'professor', expected => 1, description => 'Valid user (Professor Farnsworth)' },
    { username => 'fry', password => 'fry', expected => 1, description => 'Valid user (Philip J. Fry)' },
    { username => 'leela', password => 'leela', expected => 1, description => 'Valid user (Turanga Leela)' },
    { username => 'bender', password => 'bender', expected => 1, description => 'Valid user (Bender)' },
    { username => 'zoidberg', password => 'zoidberg', expected => 1, description => 'Valid user (Zoidberg)' },
    { username => 'amy', password => 'amy', expected => 1, description => 'Valid user (Amy Wong)' },
    { username => 'hermes', password => 'hermes', expected => 1, description => 'Valid user (Hermes Conrad)' },
    { username => 'fry', password => 'wrong_password', expected => 0, description => 'Invalid password for existing user' },
    { username => 'non_existent', password => 'password', expected => 0, description => 'Non-existent user' },
);

diag("Testing with non-secure LDAP");
for my $test_case (@test_cases) {
    my $result = $auth->_ldap_verify(
        $test_case->{username},
        $test_case->{password},
        'ldap'  # Using non-secure LDAP for this test
    );
    is($result, $test_case->{expected}, $test_case->{description});
}

diag("Testing with secure LDAP");
#now test the same with ldaps
$config->{auth_ldaps_server} = 'ldaps://localhost:10636';  # Assuming the Docker container is running on localhost
for my $test_case (@test_cases) {
    my $result = $auth->_ldap_verify(
        $test_case->{username},
        $test_case->{password},
        'ldaps'  # Using non-secure LDAP for this test
    );
    is($result, $test_case->{expected}, $test_case->{description});
}


my @test_cases = (
    { 
        username => 'professor', 
        expected_privilege => 'admin',
        expected_groups => 'all',
        description => 'Admin staff member (Professor Farnsworth)'
    },
    { 
        username => 'hermes', 
        expected_privilege => 'admin',
        expected_groups => 'all',
        description => 'Admin staff member (Hermes Conrad)'
    },
    { 
        username => 'leela', 
        expected_privilege => 'operator',
         expected_groups => 'group1,group2',
        description => 'Ship crew member (Turanga Leela)'
    },
    { 
        username => 'fry', 
        expected_privilege => 'operator',
        expected_groups => 'group1,group2',
        description => 'Ship crew member (Philip J. Fry)'
    },
    # { 
    #     username => 'bender', 
    #     expected_privilege => 'operator',
    #     expected_groups => 'group1,group2',
    #     description => 'Ship crew member (Bender)'
    # }, #Currently broken due to the way the docker container is set up
    { 
        username => 'zoidberg', 
        expected_privilege => 0,
        expected_groups => undef,
        description => 'User not in any mapped group (Zoidberg)'
    },
    { 
        username => 'non_existent', 
        expected_privilege => 0,
        expected_groups => undef,
        description => 'Non-existent user'
    },
);

diag("Testing LDAP priv groups");

for my $test_case (@test_cases) {
    my ($privilege, $groups) = $auth->_get_ldap_privs(user => $test_case->{username});
    
    is($privilege, $test_case->{expected_privilege}, "Correct privilege for " . $test_case->{description});
    is($groups, $test_case->{expected_groups}, "Correct groups for " . $test_case->{description});
}


# Clean up
unlink '/usr/local/nmis9/conf/TEST_auth_ldap_privs_file.nmis';


done_testing;
