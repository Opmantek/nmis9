package NMISNG::RPC;

our $VERSION = "9.4.8";

use Mojo::Base -base;
use Carp;
use JSON::XS;
use Mojo::UserAgent;

#Wraps Mojo user agent to make JSON-RPC 2.0 requests, inspired by MojoX::JSONRPC2::HTTP;
#We will need a long requesttime out for large snmp requests
use constant REQUEST_TIMEOUT    => 300;
has ua      => sub {
    Mojo::UserAgent->new
        ->inactivity_timeout(0)
        ->request_timeout(REQUEST_TIMEOUT)
};
#TODO make this configurable   
has url => 'http://localhost:9000/rpc';


sub call  { return shift->_request('call',@_) }

sub _request {
    my ($self, $func, $method, @params) = @_;

    #Make sure we have params to pass or set to empty array
    @params = () unless @params;

    #TODO fix this for async
    my $id = 1;
    #Make a post request with our JSON-RPC payload
    #No notify yet just a simple request

    my $json = {
        jsonrpc => '2.0',
        method => $method,
        params => \@params,
        id => $id,
    };

    use Data::Dumper;
    print(Dumper($json));

    my $tx = $self->ua->post(
       $self->url,
        { 
            'Content-Type' => 'application/json',
            'Accept' => 'application/json',
        },
        json => $json
    );

    my $res = $tx->res;

    my ($error, $result);
     # transport error (we don't have HTTP reply)
    if ($res->error && !$res->error->{code}) {
        $error = $res->error->{message};
    }
    # HTTP error or JSON-RPC error
    elsif ($res->is_error) {
        $error = $res->error->{message};
        #Check if we have an error message in the JSON-RPC responses
        $error = $res->json->{error} if $res->json->{error};
        
    }
    # JSON-RPC result
    else {
        $result = $res->json->{result};
        #check the ids match
        if ($res->json->{id} != $id) {
            $error = "Invalid response id";
        }
    }
    #Return the result or die
    return ($error, $result);

}


1;
