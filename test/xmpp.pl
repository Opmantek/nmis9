#!/usr/bin/perl
use strict;
use Data::Dumper;
use Net::XMPP;
{
    # monkey-patch XML::Stream to support the google-added JID
    package XML::Stream;
    no warnings 'redefine';
    sub SASLAuth {
        my $self = shift;
        my $sid  = shift;
        my $first_step =
            $self->{SIDS}->{$sid}->{sasl}->{client}->client_start();
        my $first_step64 = MIME::Base64::encode_base64($first_step,"");
        $self->Send( $sid,
            "<auth xmlns='" . &ConstXMLNS('xmpp-sasl') .
            "' mechanism='" .
            $self->{SIDS}->{$sid}->{sasl}->{client}->mechanism() .
            "' " .
            q{xmlns:ga='http://www.google.com/talk/protocol/auth'
            ga:client-uses-full-bind-result='true'} . # JID
            ">".$first_step64."</auth>");
    }
}

my ($recip, $msg) = @ARGV;
if(! $recip || ! $msg) {
    print 'Syntax: $0 <recipient> <message>\n';
    exit;
}
my $con = new Net::XMPP::Client();
my $status = $con->Connect(
    hostname => 'talk.google.com',
    port => 5222,
    componentname => 'gmail.com',
    connectiontype => 'tcpip',
    tls => 1,
    ssl_verify=>0x00
    );
    
die('ERROR: XMPP connection failed') if ! defined($status);

my $sid = $con->{SESSION}{id};
$con->{STREAM}{SIDS}{$sid}{hostname} = 'gmail.com';
    
my @result = $con->AuthSend(
    hostname => 'gmail.com',
    username => 'kcsinclair',
    password => 'Carb04otter',
    resource => 'notify v1.0',
    );

print "Result: ". Dumper \@result;    

die('ERROR: XMPP authentication failed') if $result[0] ne 'ok';
die('ERROR: XMPP message failed') if ($con->MessageSend(to => $recip, body => $msg) != 0);
print "Success!\n";

