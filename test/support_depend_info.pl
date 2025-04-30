
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

my $usage       = "$0 act=? data_dir=?
act=dump override=0/1 redact=0/1
  override - replace existing dump file (off by default)
  redact - remove sensitive config items (on by default)
  
act=restore
  localise_ids=0/1 (on by default)

(debug)
  db_name - change nmis db_name to this, helpful to test restore to a different db
    
  ";
die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));


use strict;
use warnings;

use NMISNG::Util;
use NMISNG;
use Data::Dumper;

my $cmdline = NMISNG::Util::get_args_multi_quiet(@ARGV);
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir, debug => $cmdline->{debug});

# override dbname for testing
$config->{db_name} = $cmdline->{db_name} if( $cmdline->{db_name} );

# log to stdout
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(debug => $cmdline->{debug}) // $config->{log_level} );
my $nmisng = NMISNG->new(config => $config, log  => $logger);

my $data_dir = $cmdline->{data_dir};
die "data_dir required" if( !$data_dir );
my $me = getpwuid($<);

if( $cmdline->{act} eq 'dump') 
{
  my $md = $nmisng->get_inventory_model( filter => { "concept" => ["lldp","cdp"]}, fields_hash => { "node_uuid" => 1, "node_name" => 1 } );
  if( my $error = $md->error ) {
      print "Error getting cdp/lldp inventory: $error\n";
      exit 1;
  }
  my $override = $cmdline->{override};
  my $redact = $cmdline->{redact} // 1;

  my $exported_nodes = {};
  while( my $entry = $md->next_value ) {
      my $uuid = $entry->{node_uuid};
      next if( $exported_nodes->{$uuid} );
      
      # my ($nodename, $uuid, $file) = @{$cmdline}{"node","uuid","file"}; # uuid is safer than node name
      # die "Cannot dump node data without node/uuid and file arguments!\n" if (!$file || (!$nodename && !$uuid));
      my %options = ( historic_events => 0, opstatus_limit => 1, rrd => 0 );
      my $file = $data_dir."/$uuid";
      my $res = $nmisng->dump_node( uuid => $uuid, target => $file, options => \%options, override => $override, redact => $redact);
      die "Failed to dump node data: $res->{error}\n" if (!$res->{success});
      $exported_nodes->{$uuid} = 1;

      $logger->info("Successfully dumped node data to file $file");
  }
}
elsif( $cmdline->{act} eq 'restore') 
{
  my $localiseme = NMISNG::Util::getbool_cli("localise_ids", $cmdline->{localise_ids}, 1);
  opendir my $dir, $data_dir or die "Cannot open directory: $!";
  my @files = readdir $dir;
  closedir $dir;
  foreach my $file (@files) {
    next if $file eq '.' || $file eq '..';
    $logger->debug("Restoring file:$file");

    my $meta = {
        what => "Restore node",
        who => $me,
        how => "node_admin",
        details => "Restore node "
    };

    my $res = $nmisng->undump_node(source  => "$data_dir/$file", localise_ids => $localiseme );
    die "Failed to restore node data: $res->{error}\n" if (!$res->{success});

    $logger->info("Successfully restored node $res->{node}->{name} ($res->{node}->{uuid})");        

    NMISNG::Util::audit_log(who => $me,
              what => "restored node",
              where => "restored node $res->{node}->{name}",
              how => "node_admin",
              details => "Restore node ". $res->{node}->{name},
              when => time)
    if ($res->{success});
  }	
} else {
  print $usage;
}

  