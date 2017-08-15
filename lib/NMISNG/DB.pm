# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND LICENSED
# BY OPMANTEK.
#
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
#
# This code is NOT Open Source
#
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3)
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE, THIS
# AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU AND
# OPMANTEK LTD.
#
# Opmantek is a passionate, committed open source software company - we really
# are.  This particular piece of code was taken from a commercial module and
# thus we can't legally supply under GPL. It is supplied in good faith as
# source code so you can get more out of NMIS.  According to the license
# agreement you can not modify or distribute this code, but please let us know
# if you want to and we will certainly help -  in most cases just by emailing
# you a different agreement that better suits what you want to do but covers
# Opmantek legally too.
#
# contact opmantek by emailing code@opmantek.com
#
# All licenses for all software obtained from Opmantek (GPL and commercial)
# are viewable at http://opmantek.com/licensing
#
#*****************************************************************************
package NMISNG::DB;
use strict;

BEGIN
{
	our ( $VERSION, $ABI, $MAGIC ) = ( "4.0.0", "2.0.0", "DEADCHICKEN" );

	if ( scalar(@ARGV) == 1 && $ARGV[0] eq "--module-version" )
	{
		print __PACKAGE__. " version=$VERSION\n" . __PACKAGE__ . " abi=$ABI\n" . __PACKAGE__ . " magic=$MAGIC\n";
		exit(0);
	}
}

use Data::Dumper;
use JSON::XS;
use Try::Tiny;
use boolean;         # do NOT use -truth! deprecated, segfaults in perl 5.20 and impossible with 5.22+
use MongoDB;
use Safe::Isa;       # provides $_isa, recommended by MongoDB driver for error handling
use Time::Moment;    # opCharts needs times (for TTL) and using this is much faster
use Carp;

use version 0.77;    # needed to check driver version

# this is a little bit unfriendly, but required because mongo uses boolean::true or ::false,
# and json::xs's silly REQUIREMENT that bools be JSON::XS::true or ::false. very annoying.
#
# note that you have to do your json encoding with JSON::XS->new->convert_blessed(1)->utf8(1)->encode(...)
# if your records have real booleans (but at least with this TO_JSON fudge convert_blessed does work)
*boolean::TO_JSON = sub { my $x = shift; return ( boolean($x)->isTrue ? JSON::XS::true : JSON::XS::false ); };

my $error_string;

# in some spots (TTL indices) downstream code must distinguish between driver flavours,
# so let's expose that as $OMK::DB::new_driver
our $new_driver = ( version->parse($MongoDB::VERSION) >= version->parse("1.0.0") ) ? 1 : 0;

if ( !$new_driver )
{
	die "MongoDB driver version 1.0.0 or greater required\n";
}

# args:
# 	- collection
# 	- count, return a total record count, even if ssl values are set (means pipe is run twice)
# 	- pre_count_pipeline (part of pipe to run before count if asked for)
# 	- post_count_pipeline (part of pipe to run after count if asked for)
# 	- sort/skip/limit
#   - allowtempfiles (0/1, default 0) - NOT passed if it's set to undef (for mongo < 2.6)
#   - cursor 0/1, old driver only, new driver always returns cursor
#   - batch_size, implies cursor=>1, INITIAL batch size of cursor
# returns:
#   - list of ( array of records, count, error ), count is = 0 if not asked for
sub aggregate
{
	my (%arg)               = @_;
	my $collection          = $arg{collection};
	my $pre_count_pipeline  = $arg{pre_count_pipeline};
	my $post_count_pipeline = $arg{post_count_pipeline};

	my $cursor = $arg{cursor};

	# new driver always returns cursors
	$cursor = 1 if ($new_driver);

	# this one option MUST be a boolean, 1/0 isn't good enough :-/
	# it also MUST NOT be passed to a mongo older than 2.6.
	my $aggoptions
		= ( defined $arg{allowtempfiles} ) ? {allowDiskUse => ( $arg{allowtempfiles} ? true : false )} : {};
	if ( $arg{batch_size} )
	{
		if ($new_driver)
		{
			$aggoptions->{batchSize} = $arg{batch_size};
		}
		else
		{
			$cursor = 1;
			$aggoptions->{cursor} = {batchSize => $arg{batch_size}};
		}
	}

	$aggoptions->{cursor} = 1
		if ( $cursor && !$new_driver );    # new driver always does cursor

	return ( [], undef, "Aggregation pipeline must be an array of operations" )
		if ( ( defined($pre_count_pipeline) && ref($pre_count_pipeline) ne "ARRAY" )
		or ( defined($post_count_pipeline) && ref($post_count_pipeline) ne "ARRAY" )
		or ( !$pre_count_pipeline and !$post_count_pipeline ) );
	my $count = 0;

	# count = before sort/skip/limit do a count because the system needs to know the total # of records
	if ( $arg{count} )
	{

		# run modified pipeline to get the count, which is a single document
		my @count_pipeline = (@$pre_count_pipeline);
		push( @count_pipeline, {'$group' => {'_id' => undef, count => {'$sum' => 1}}} );

		# for some reason or another, BOTH the aggregate call AND the cursor accesses
		# can throw  exceptions on timeout, independent of each other!
		# eval{} didn't seem to cut it fully, might as well use try/catch...
		my $err;

		try
		{
			my $result = $collection->aggregate( \@count_pipeline, $aggoptions );
			if ($cursor)
			{
				my $only = $result
					->next;   # somehow using count() on cursor count_out doesn't work in v0.70X, always returns zero...
				$count = $only->{count} if ( ref($only) eq "HASH" );
			}
			else
			{
				$count = $result->[0]{count} if ( ref($result) eq "ARRAY" && @$result > 0 );
			}
		}
		catch
		{
			$err = $_;
		};
		return ( [], undef, "pre-count aggregation failed: $err" ) if ($err);
	}

	if ( $arg{sort} )
	{
		push( @$post_count_pipeline, {'$sort' => $arg{sort}} );
	}
	if ( $arg{skip} )
	{
		push( @$post_count_pipeline, {'$skip' => $arg{skip} + 0} );
	}
	if ( $arg{limit} )
	{
		push( @$post_count_pipeline, {'$limit' => $arg{limit} + 0} );
	}

	my @pipeline = ();
	@pipeline = @$pre_count_pipeline if ( ref($pre_count_pipeline) eq "ARRAY" && @$pre_count_pipeline );
	push @pipeline, @$post_count_pipeline if ( ref($post_count_pipeline) eq "ARRAY" && @$post_count_pipeline );

	# see note above: both aggregate and cursor throw timeout exceptions, separately...
	my ( $out, $err );
	try
	{
		my $result = $collection->aggregate( \@pipeline, $aggoptions );
		if ($cursor)
		{
			my @all = $result->all();
			$out = \@all;
		}
		else
		{
			$out = $result;
		}
	}
	catch
	{
		$err = $_;
	};
	return ( [], undef, "post-count aggregation failed: $err" ) if ($err);

	return ( $out, $count, undef );
}

# args: collection (handle), records (array ref of records to insert), optional safe
# arg: ordered, set 1 if the records must be inserted in order, defaults to 0 (false)
# returns: hashref with success/error/count/ids
sub batch_insert
{
	my %arg = @_;

	my $collection = $arg{collection};
	my $records    = $arg{records};
	my $ordered    = $arg{ordered} // 0;

	my $safe = $arg{safe} // 1;

	return {error => "cannot batch-insert with invalid collection argument!"}
		if ( ref($collection) ne "MongoDB::Collection" );

	return {error => "cannot batch-insert with invalid records argument!"}
		if ( ref($records) ne "ARRAY" or !@$records );

	my $result = {success => 1, ids => []};    # we hope

	if ($new_driver)
	{
		try
		{
			my @requests = ( insert_many => $records );
			my $res = $collection->bulk_write( [@requests] );
			if ( $res->acknowledged )
			{
				my $inserted_ids_hash = $res->inserted_ids;
				@{$result->{ids}} = values(%$inserted_ids_hash);
			}
			$result->{success} = 1;
		}
		catch
		{
			$result->{success}    = 0;
			$result->{error}      = $_->message;
			$result->{error_type} = ref($_);
		}
	}
	else
	{
		try
		{
			@{$result->{ids}} = $collection->batch_insert( $records, {safe => $safe} );
		}
		catch
		{
			$result->{error}   = $_;
			$result->{success} = 0;
		};

		if ($safe)
		{
			my $database = $collection->can("database") ? $collection->database() : $collection->_database();
			my $error = getLastError( db => $database, w => $safe );
			if ( $error->{err} )
			{
				$result->{error}   = $error->{err};
				$result->{success} = 0;
			}
		}
	}

	return $result;
}

# Start a "bulk" write operation
# params:
#   collection
#   ordered - are the ops ordered, see mongo docs for more (unordered continues on error)
# returns: the bulk op object
sub begin_bulk
{
	my (%arg) = @_;
	my $collection = $arg{"collection"};
	my $ordered = $arg{'ordered'} // 0;

	return $collection->initialize_ordered_bulk_op   if ($ordered);
	return $collection->initialize_unordered_bulk_op if ( !$ordered );
}

# small helper function that asks for a count of matching results
# args: collection, query (both required), verbose (optional, 0/1, default 0)
# no sorting, skipping, limiting is supported.
#
# returns: if verbose 0, just the count or undef if it failed.
# if verbose 1, hashref with keys success, error, count.
sub count
{
	my %arg        = @_;
	my $collection = $arg{collection};
	my $query      = $arg{query};
	my $verbose    = $arg{verbose};

	my ( $errmsg, $result );

	return $verbose ? {error => "cannot count without collection!"} : undef
		if ( !$collection );

	try
	{
		$result = $collection->count($query);
	}

	catch
	{
		$errmsg = $_;
	};

	return (
		$verbose
		? {error => $errmsg, count => $result, success => !$errmsg}
		: $result
	);
}

# small helper function that asks mongo for collection status info
# args: db (handle, required), collection (name, required),
# scale (optional, default 1), verbose (optional, 0/1, default 0)
#
# returns: result record plus error, success fields
sub coll_stats
{
	my %arg        = @_;
	my $db         = $arg{db};
	my $collection = $arg{collection};
	my $verbose    = $arg{verbose};
	my $scale      = $arg{scale} || 1;

	return {error => "db is required for collStats!"}         if ( ref($db) ne "MongoDB::Database" );
	return {error => "collection is required for collStats!"} if ( !$collection );

	# old driver failure: error text. new driver: exception...
	my $result;
	try
	{
		$result = $db->run_command(
			[   collStats => $collection,
				scale     => $scale,
				verbose   => $verbose
			]
		);
		$result = {ok => 0, error => $result} if ( !ref($result) );
	}
	catch
	{
		$result = {error => $_};
	};

	$result->{success} = !$result->{error};
	return $result;
}

# helper to sanitize records for mongo
# mongodb doesn't allow "." in keys, we need to clean that up or mongo
# will throw things back. not all code completely controls
# the record keys, so this helper function is essential.
#
# in addition to that, data sourced from json::xs may contain
# objects blessed as json::xs::boolean, json::pp::boolean,
# or Types::Serialiser::Boolean (which is just an alias for "JSON::PP::Boolean")
# these need conversion into boolean::true and ::false. any other blessed things are passed
# through as-is.
#
# args: record, any depth
# returns: a reworked clone of the record
sub constrain_record
{
	my %arg    = @_;
	my $record = $arg{record};

	die "cannot enforce record constraint without record!\n" if ( !exists $arg{record} );

	if ( ref($record) eq "ARRAY" )
	{
		my @newarray;

		# check every element for deeper structure
		for my $idx ( 0 .. $#{$record} )
		{
			# should the record be self-referential, DO NOT follow that loop!
			if (ref($record->[$idx]) && $record->[$idx] eq $record)
			{
				Carp::confess("constrain_record encountered self-referntial record!\n");
			}
			else
			{
				$newarray[$idx]
						= ref( $record->[$idx] )
						? constrain_record( record => $record->[$idx] )
						: $record->[$idx];
			}
		}
		return \@newarray;
	}
	elsif ( ref($record) eq "HASH" )
	{
		# check all keys, rename if needed; then check deeper.
		my %newhash;
		foreach my $key ( keys %$record )
		{
			# . is not allowd in key, globally replace with _
			my $original_key = $key;
			$key =~ s/\./_/g;

			# should the record be self-referential, DO NOT follow that loop!
			if (ref($record->{$original_key}) && $record->{$original_key} eq $record)
			{
				Carp::confess("constrain_record encountered self-referntial record!\n");
			}
			else
			{
				$newhash{$key}
				= ref( $record->{$original_key} )
						? constrain_record( record => $record->{$original_key} )
						: $record->{$original_key};
			}
		}
		return \%newhash;
	}
	elsif ( ref($record) =~ /^JSON::(PP|XS)::Boolean$/ )
	{
		return ( boolean::boolean($record) );    # cast into the desired boolean type
	}
	else
	{
		# any other stuff we pass through as is.
		# we MUST NOT do a blanket stringify here, because there are legitimate cases
		# for blessed things (e.g. mongo oid, mongo bson types etc)!
		return $record;
	}
}

# this function converts or creates a collection in capped form
# args: connection (raw connection handle), db (handle!), collection, size (in bytes), all required
# simulate: optional, if 1 then only the stats are returned.
#
# note: indices are NOT retained when converting, nor when dropping-and-creating-as-capped.
# note: caller SHOULD have upped the db timeout, as these ops can take a while!
#
# returns: result hash (with success, error, notes, changed, size keys)
sub create_capped_collection
{
	my (%arg) = @_;
	my ( $conn, $db, $collection, $wantsize ) = @arg{"connection", "db", "collection", "size"};

	return {error => "cannot create capped collection with invalid connection argument!"}
		if ( ref($conn) ne "MongoDB::MongoClient" );

	return {error => "cannot create capped collection with invalid db argument!"}
		if ( ref($db) ne "MongoDB::Database" );

	return {error => "cannot create capped collection without collection argument!"}
		if ( !$collection );
	return {error => "cannot create capped collection without size argument!"}
		if ( !$wantsize );

	# desired wantsize: ensure its a multiple of 256, round up to nearest
	$wantsize += 256 - ( $wantsize % 256 ) if ( $wantsize % 256 );

	my $new_driver = ( version->parse($MongoDB::VERSION) >= version->parse("1.0.0") ) ? 1 : 0;

	# figure out how much space there is on disk
	# required because capped collections pre-allocate all the space they need
	# commandline opts are visible only on the admin database...

	my $cmdline = OMK::DB::run_command(
		db      => $conn->get_database("admin"),
		command => {"getCmdLineOpts" => 1}
	);
	my $db_location = $cmdline->{parsed}->{storage}->{dbPath} // $cmdline->{parsed}->{dbpath};
	return {error => "db location could not be determined!"} if ( !$db_location or !-d $db_location );

	# figure out how much space the whole db takes right now
	my $result = OMK::DB::run_command(
		db      => $db,
		command => [dbStats => 1, scale => 1]
	);
	return {error => "dbStats failed: $result->{error}"} if ( !$result->{ok} );
	my $dbsize = $result->{storageSize};
	return {error => "could not determine current db size!"} if ( !defined $dbsize );

	# meh. parsing df isn't good. access to statfs or statvfs system call would be cleaner
	$db_location =~ s/[`"'\$]//g;    # sanitize it at least
	                                 # note: osx does not like B for blocksize, can only do k for kb
	my $flavour  = ( $^O eq "darwin" ? "-Pk" : "-PB1" );
	my @dfout    = `df $flavour $db_location 2>/dev/null`;
	my $exitcode = $?;

	# filesys totalblocks usedblocks freeblocks percent mountpoint
	my ( $totalbytes, $freebytes ) = ( split( /\s+/, $dfout[1] ) )[1, 3];
	if ( $^O eq "darwin" )
	{
		$freebytes  *= 1024;
		$totalbytes *= 1024;
	}

	return {error => "could not determine free disk at $db_location: $!"}

		if ( $exitcode or $exitcode >> 8 or !$freebytes );

	# check whether the collection exists
	my @currentcolls = $db->collection_names;

	my $alreadypresent = grep( $collection eq $_, @currentcolls );
	my ( $maxsize, $isempty, $iscapped );

	# setup db timeouts - requires a new database (fixme: and also new connection for socket_timeout)
	if ($new_driver)
	{
		if ( $conn->max_time_ms )
		{

			# new driver doesn't let you set these on existing connections or databases :-(
			my $blockingdb = eval { $conn->get_database( $db->name, {max_time_ms => 0} ) };
			return {error => "Failed to get database with suitable timeout!"} if ( !$blockingdb );
			$db = $blockingdb;
		}
	}
	else
	{
		$conn->query_timeout(-1);
	}

	if ($alreadypresent)
	{

		# check if the collection is capped already, and get the current size
		my $stats = OMK::DB::CollStats(
			db         => $db,
			collection => $collection,
			scale      => 1
		);
		return {error => "collstats failed: $stats->{error}"}
			if ( !$stats->{success} );

		$maxsize = $stats->{maxSize} // 0;    #this is only defined if capped is true
		$isempty  = $stats->{count}  ? 0 : 1;
		$iscapped = $stats->{capped} ? 1 : 0;
	}

	# prep the stats for simulate
	my %stats;
	%stats = (
		notes             => "no changes were made",
		collection_exists => $alreadypresent,
		collection_capped => $iscapped,
		collection_empty  => $isempty,
		collection_size   => $maxsize,
		db_size           => $dbsize,
		free_space        => $freebytes,
		total_space       => $totalbytes
	) if ( $arg{simulate} );

	# existent and capped and the same size? nothing to do
	if ( $alreadypresent and $iscapped and $maxsize == $wantsize )
	{
		return {success => 1, %stats} if ( $arg{simulate} );
		return {
			success => 1,
			size    => $wantsize,
			changed => 0,
			notes   => "$collection already capped at desired size $wantsize"
		};
	}

	# existent and not empty, and not capped or not the right size? convert if there is enough space
	elsif ( $alreadypresent and !$isempty and ( $maxsize != $wantsize or !$iscapped ) )
	{

		# when converting the collection is cloned (into $wantsize collection), then the old one deleted
		# and the new one renamed to the old name, BUT nothing is freed!
		# this means the disk usage will increase by $wantsize

		# to do any freeing, repairDatabase can be used BUT requires LOTS of space:
		# (total current space)*2 + 2gb - officially total current space + 2gb

		# and total current at repair time would be current db plus new capped size
		my $repairsize = ( $dbsize + $wantsize ) * 2 + 2 * ( 1 << 30 );

		return {
			error =>
				"Not enough free diskspace for repairDatabase after conversion. Repair space: $repairsize, Free space: $freebytes",
			%stats
			}
			if ( $repairsize > $freebytes );

		return {
			error => "Not enough free diskspace for conversion. Desired size: $wantsize, Free space: $freebytes",
			%stats
			}
			if ( $wantsize > $freebytes );

		return {success => 1, %stats} if ( $arg{simulate} );

		$result = OMK::DB::run_command(
			db      => $db,
			command => [
				convertToCapped => $collection,
				size            => $wantsize
			]
		);
		return {error => "Convert to capped failed: $result->{error}"} if ( !$result->{ok} );

		return {
			success => 1,
			size    => $wantsize,
			changed => 1,
			notes   => "$collection converted to capped"
		};
	}
	else
	{
		# existent but empty and not capped? drop and create as capped if enough space
		if ( $alreadypresent and $isempty )
		{

			# maxsize bytes will be freed by the drop
			return {
				error =>
					"Not enough free diskspace for capped collection. Desired size: $wantsize, Free space: $freebytes",
				%stats
				}
				if ( $wantsize > $freebytes + $maxsize );

			return {success => 1, %stats} if ( $arg{simulate} );

			my $res = OMK::DB::run_command(
				db      => $db,
				command => {'drop' => $collection}
			);
			return {error => "Could not drop collection $collection: $res->{error}"} if ( !$res->{ok} );
			$alreadypresent = 0;
		}

		# non existent? create as capped if enough space
		else
		{
			return {
				error =>
					"Not enough free diskspace for capped collection. Desired size: $wantsize, Free space: $freebytes",
				%stats
				}
				if ( $wantsize > $freebytes );
		}

		return {success => 1, %stats} if ( $arg{simulate} );

		# fixme timeouts

		my $result = OMK::DB::run_command(
			db      => $db,
			command => [
				"create" => $collection,
				"capped" => 1,
				"size"   => $wantsize
			]
		);
		$result = {error => $result}
			if ( ref($result) ne "HASH" );    # apparently this cmd can return a plain string, too.
		return {error => "Creation of capped $collection failed: $result->{error}"} if ( !$result->{ok} );

		return {success => 1, changed => 1, notes => "$collection (re)created as capped", size => $wantsize};
	}

	# not reached
}

# asks mongodb for the distinct values for key K in collection X,
# optionally limited with query Q.
# args: key K, collection object (if 1.x driver) or collection NAME plus db (either driver), all required;
# optional query
# returns undef if there's a fault, listref of values otherwise
sub distinct
{
	my %arg = @_;
	my ( $db, $collname, $key, $query ) = @arg{qw(db collection key query)};

	# with new driver collection MAY be handle
	if ($new_driver && (ref($collname) eq "MongoDB::Collection"))
	{
		return if (!$key);
		my $result;
		try
		{
			my $qres = $collname->distinct($key, $query);
			$result = [ $qres->all ] ;
		};
		return $result;
	}
	else
	{
		# note: could use collection object in old driver, too, but  while that has official name attrib,
		# database is under _database... new driver has name and database attributes.

		# old driver: collname MUST be a string only, as the perl driver doesn't
		# have a collection.distinct wrapper yet.
		return if ( !$collname or ref($collname) or !$db or !$key );

		my $res = $db->run_command(
			[   'distinct' => $collname,
					'key'      => $key,
					'query'    => $query
			]
				);
		return $res->{ok} ? $res->{values} : undef;
	}
}

# End/execute bulk write operation.
# returns object with success/error and some results
sub end_bulk
{
	my (%arg)   = @_;
	my $bulk    = $arg{"bulk"};
	my $success = undef;
	my ( $error, $error_type ) = ( undef, undef );
	my $result = {};
	try
	{
		my $res = $bulk->execute;
		if ( $res->acknowledged )
		{
			$result->{inserted_count} = $res->inserted_count;
			$result->{upserted_count} = $res->upserted_count;
			$result->{modified_count} = $res->modified_count;
			$result->{op_count}       = $res->op_count;
			$result->{matched_count}  = $res->matched_count;
		}
	}
	catch
	{
		$success    = 0;
		$error      = $_->message;
		$error_type = ref($_);
	};
	return {success => $success, result => $result, error => $error, error_type => $error_type};
}

# a wrapper around ensure_index that optionally removes unwanted indices
# args: db (optionanl if collection is an object),
# collection (collection name or collection object), indices (array),
# drop_unwanted (0/1, optional, default 0)
# background (0/1, optional, default 0) - create indices in background, can also be put
#   into index options, this will override what is in options if this is set
#
# indices list must be array of arrays, inner: [ spec, options]. options optional, e.g. unique;
# spec must be array ref or hash ref or tie::ixhash.
#
# returns: undef or error message
sub ensure_index
{
	my (%args) = @_;

	my ( $db, $coll, $indexlist ) = @args{"db", "collection", "indices"};
	my $drop       = $args{drop_unwanted};
	my $background = $args{background};

	return "cannot ensureIndex with invalid db argument!"    # only required if coll is not collection object
		if ( !ref($coll) && ref($db) ne "MongoDB::Database" );
	return "cannot ensureIndex without one or more index specs!" if ( ref($indexlist) ne "ARRAY"
		or !@$indexlist );

	# string is ok, so is collection object
	return "cannot ensureIndex with invalid collection argument!"
		if (
		!$coll
		or (    ref($coll)
			and ref($coll) ne "MongoDB::Collection" )
		);

	$coll = getCollection( db => $db, name => $coll ) if ( !ref($coll) );
	return "failed to getCollection $coll!" if ( !$coll );

	my ( @currentindices, %desiredindices );
	@currentindices = $coll->get_indexes if ($drop);    # not needed if unwanteds are ignored

	for my $oneidx (@$indexlist)
	{
		return "cannot ensureIndex with invalid index specification!"
			if (
			ref($oneidx) ne "ARRAY" or !@$oneidx or @$oneidx > 2    # spec, options
			or ref( $oneidx->[0] ) !~ /^(ARRAY|HASH|Tie::IxHash)$/  # spec can be any of these
			or ( ref( $oneidx->[1] ) and ref( $oneidx->[1] ) ne "HASH" )
			);                                                      # options must be hash

		my $spec = $oneidx->[0];
		my $options = $oneidx->[1] // {};
		$options->{background} = $background if ($background);

		eval { $coll->ensure_index( $spec, $options ); };
		return "ensure_index on $coll->{name} failed: $@" if ($@);

		# mark the index as desired, go by the index name (= key_dir_key_dir)
		if ($drop)
		{
			my $thisname = ( ref($spec) eq "Tie::IxHash" )
				?

				# each doesn't work on a tie::ixhash object :-(
				join( "_", map { ( $_, $spec->FETCH($_) ) } ( $spec->Keys ) )
				: ( ref($spec) eq "HASH" ) ? join( "_", %$spec )    # hash case should have only one elem
				:                            join( "_", @$spec );   # array case has any number of elems

			$desiredindices{$thisname} = 1;
		}
	}

	if ($drop)
	{
		for my $maybe (@currentindices)
		{
			next if ( $maybe->{name} eq "_id_" );                   # always indexed and required
			if ( !$desiredindices{$maybe->{name}} )
			{

				# print STDERR "removing index $maybe->{name} from collection $coll->{name}\n";
				eval { $coll->drop_index( $maybe->{name} ); };
				return "drop_index on $coll->{name} failed: $@" if ($@);
			}
		}
	}

	return;
}

# combines arguments into a query pipeline for mongodb, and fires that
# returns the resulting mongodb cursor, or undef if the args are duds
# sets the error_string if problems are encountered.
#
# args: collection and query are required,
# sort, skip and limit are optional.
# fields_hash takes a hash of { field1 => 1, field2 => 1, ... }
sub find
{
	my %arg        = @_;
	my $collection = $arg{collection};
	my $query      = $arg{query};

	# print "OMK::DB::Find skip: $arg{skip}, limit: $arg{limit}, sort: ".Dumper($arg{sort})."\n";

	if ( ref($collection) ne "MongoDB::Collection" )
	{
		$error_string = "Cannot use Find with invalid collection argument!";
		return;
	}
	my $retval;

	try
	{
		$retval = $collection->find($query);

		if ( defined $arg{fields_hash} )
		{
			$retval = $retval->fields( $arg{fields_hash} );
		}

		if ( defined $arg{sort} )
		{
			$retval = $retval->sort( $arg{sort} );
		}

		if ( defined $arg{skip} )
		{
			$retval = $retval->skip( $arg{skip} );
		}

		if ( defined $arg{limit} )
		{
			$retval = $retval->limit( $arg{limit} );
		}
	}
	catch
	{
		$error_string = $_;
	};

	return $retval;
}

# a thin wrapper around get_collection
# mainly for future-proofing at this point - but might get additional functionality, eg. index making
# args: db, name (both required)
# returns: collection handle or undef on failure (consult getErrorString in that case)
sub get_collection
{
	my (%args) = @_;
	my ( $db, $collname ) = @args{"db", "name"};

	if ( ref($db) ne "MongoDB::Database" or !$collname )
	{
		$error_string = "Invalid args passed to getCollection!";
		return;
	}
	my $coll = eval { $db->get_collection($collname); };
	if ($@)
	{
		$error_string = $@;
		return;
	}
	return $coll;
}

sub get_db
{
	my %args = @_;
	my $CONF = $args{conf};
	my $conn = get_db_connection( conf => $CONF );
	return $conn->get_database( $CONF->{db_name} );
}

# opens a new connection to the configured db server
# args: app_key, conf; optional: connection_timeout, query_timeout
#  conf must have a db_server entry, dealing with errors because of no conf down the road
#   us much harder than finding out earlyu
#
# if app_key is given, it's used to select application-specific db settings where available
# fall back is always to the global db_XXX settings.
# attention: app_key must be all lowercase to match our config key rules!
#
# if connection_timeout is given, the xxx_db_connection_timeout config is ignored.
# both are given in ms, -1 means no timeout.
#
# if query_timeout is given, the xxx_db_query_timeout config is ignored.
# both are given in ms. -1 means no timeout.
#
# returns the db handle, or undef in case of errors (and then $error_string is set)
sub get_db_connection
{
	my %args    = @_;
	my $app_key = $args{app_key} // '';
	my $CONF    = $args{conf};

	if( ref($CONF) ne 'HASH' || $CONF->{db_server} eq '' )
	{	
		$error_string = "No config provided to get_db_connection, not attempting any type of connection\n";
		return;
	}

	my $server  = $CONF->{db_server} // 'localhost';
	my $port    = $CONF->{db_port}   // '27017';
	my $db_name = $CONF->{db_name}   // 'nmisng';
	my $username = $CONF->{db_username};
	my $password = $CONF->{db_password};

	my $timeout       = $CONF->{db_connection_timeout} // 5000;
	my $query_timeout = $CONF->{db_query_timeout}      // 5000;
	my $write_concern = $CONF->{db_write_concern}      // 1;

	my $new_conn;
	eval {
		$new_conn = MongoDB::MongoClient->new(
			host          => "$server:$port",
			w             => $write_concern,
			timeout       => $timeout,
			query_timeout => $query_timeout,

			# manpage claims that reconnects trigger re-auth but that's not true :-(
			# so, with auto_reconnect on we get a connection that doesn't work because not authed,
			# but there is no command to test auth short of doing a count() or something on a collection....
			auto_reconnect => 0,

# NOTE: driver 1.X uses these BUT they DO bother the old driver, if undef - fails to start with "type constraint violated"
# and with defined but blank string the auth fails if the server is running without auth
# NOTE2: added a couple other timeout values as well, connect_timeout_ms is timeout from above (renamed)
			username           => $username,
			password           => $password,
			connect_timeout_ms => $timeout,

			# for socket_timeout_ms -1 means no timeout, but for max_time_ms it MUST be zero!
			max_time_ms => ( $query_timeout > 0 ) ? $query_timeout : 0,

			# if no timeout wanted -> set none, and ditch the socket timeout in that case, too
			socket_timeout_ms => ( $query_timeout > 0 ) ? ( $query_timeout + 5000 ) : -1,
			heartbeat_frequency_ms => 5000
		);

		# max_bson_size => 8 * 1024*1024) };
	};

	if ($@)
	{
		$error_string = "Error Connecting to Database $server:$port: $@";
		return;
	}

	if ($new_driver)
	{
		try
		{
			my $status = $new_conn->db('admin')->run_command( [ismaster => 1] );
		}
		catch
		{
			$error_string = "Error Connecting to Database $server:$port: $_";
		};
		return if ($error_string);
	}

	# If we can't authenticate we must be using the new driver
	if ( $username eq '' || !$new_conn->can("authenticate") )
	{
		return $new_conn;
	}
	# authenticate to the dbs
	foreach my $db ('admin',$db_name)
	{
		try
		{
			# authenticate to admin so we can run serverStatus
			my $auth = $new_conn->authenticate( $db, $username, $password );		
			if ( $auth =~ /auth fail/ || ref($auth) eq "HASH" && $auth->{ok} != 1 )
			{
				$error_string = "Error authenticating to MongoDB db:$db database\n";
				return;
			}
		}
		catch
		{
			$error_string = "Error attempting to authenticate, parameters incorrect.\nError info:$_";
		};
		return if ($error_string);
	}
	return $new_conn;
}

sub get_error_string
{
	return $error_string;
}

## takes DB, not CONN, and not collection!
# args: w -- write concern, see http://search.cpan.org/~mongodb/MongoDB-v0.705.0.0/lib/MongoDB/MongoClient.pm#w
# returns: hash with "err" key
sub get_last_error
{
	my %args = @_;
	my $db   = $args{db};

	return {err => "cannot call last_error with invalid db argument!"}
		if ( ref($db) ne "MongoDB::Database" );

	my $write_concern = $args{w} // 1;

	return $db->last_error( {w => $write_concern} );
}

# args: and_part, no_auto_oid, no_regex, or_part
# no_auto_oid: if true then _id is not transformed into a mongodb::oid object (e.g. in nodes collection where name used as _id)
# if no_regex is 'true', then "regex:" is not treated specially as a column value
#
# ATTENTION: getquery cannot produce ORs anywhere except as a subclause of a set of ANDs!
# so (a AND b) OR (c AND d) cannot be created! see OMK-887 for details.
#
# returns: query structure, sanitized (blank parts are omitted)
sub get_query
{
	my (%arg) = @_;
	my (%ret_hash, @or_hash);
	# set defaults
	my %options = ( no_auto_oid => $arg{no_auto_oid} // 'false',
									no_regex => $arg{no_regex} // 'false' );
	delete $arg{no_auto_oid};
	delete $arg{no_regex};

	while ( my ( $key, $value ) = each( %{$arg{and_part}} ) )
	{
		my $new_query_part = get_query_part( $key, $value, \%options);
		if ( $new_query_part ne "" )
		{
			@ret_hash{keys %{$new_query_part}} = values %{$new_query_part};
		}
	}

	while ( my ( $key, $value ) = each( %{$arg{or_part}} ) )
	{
		my $new_query_part = get_query_part( $key, $value, \%options );
		if ( $new_query_part ne "" )
		{
			push( @or_hash, $new_query_part );
		}
	}

	if ( @or_hash > 0 )
	{
		$ret_hash{"\$or"} = \@or_hash;
	}

	return \%ret_hash;
}

# break down each key/value pair (column name and value) and map it into
# a hash that works as a mongodb query
# args: name (string), value (anything), options (a hashref with no_regex, no_auto_oid )
# returns: empty string (for omit) or a hashref
#
# if value is not defined or empty, then the column is not added to the hash.
#
# if the value is a hash, each value is checked, and only the ones that exist 
# and are nonblank are added as a hash for that column. 
# exception: if the key is $eq or $ne then undef is passed through as-is.
#
# if the value is an array, then the query is set to $in all array values
#
# if the value starts with "regex:" then a case insenstive regex is created unless _no_regex is set
#
# if the column value starts with type: then the query is rewritten as $type for that column
#
# if the column name is text_search then a text search for that value is run
#
# if column name is _id the value is turned into an oid object, unless _no_auto_oid is set
#
# all other cases: key/value is used as it is
#
sub get_query_part
{
	my ($col_name, $col_value, $options) = @_;
	my $ret_val = "";
	my $ret_hash = {};
	$options ||= {};

	if (!defined($col_value) or  $col_value eq "" )
	{
		# don't add this column to the query
		return "";
	}
	elsif( ref($col_value) eq "HASH" )
	{
		my %definedones = ();
		while( my ($key, $value) = each(%{$col_value}) )
		{
			# special cases for the mongodb operators where undef makes sense, ie. $eq and $ne
			# pass-through, value defined or not
			if (($key =~ m!^\$(eq|ne)$!)
					or (defined($value) and $value ne ''))
			{
				$definedones{$key} = $value;
			}
		}
		if( scalar(keys %definedones) > 0 )
		{
			$ret_hash->{$col_name} = \%definedones
		}
	}
	elsif( ref($col_value) eq "ARRAY" )
	{
		$ret_hash->{$col_name} = { '$in' => $col_value } ;
	}
	elsif ( $col_value =~ /regex:(.*)/ && $options->{no_regex} ne "true" )
	{
		my $regex = $1;
		$ret_hash->{$col_name} = { '$regex' => $regex , '$options' => 'i' } ;
		# $ret_hash->{$col_name} = qr/$regex/;
	}
	elsif ( $col_value =~ /type:(.*)/ )
	{
		my $type = $1;
		$ret_hash->{$col_name} = { '$type' => $type+0 } ;
	}
	elsif ( $col_name eq "text_search" )
	{
		$ret_hash->{'$text'} = { '$search' => $col_value, '$language' => 'none' } ;
	}
	elsif ( $col_name eq "_id" && $options->{no_auto_oid} eq "false" )
	{
		if( ref($col_value) eq "MongoDB::OID" ) {
			$ret_hash->{$col_name} = $col_value;
		}
		else 
		{
			# constructor dies if the input isn't valid as oid value (== 24 char hex string)
			$col_value = "badc0ffee0ddf00ddeadbabe" # that's valid but won't match, which is good
					if ($col_value !~ /^[0-9a-fA-F]{24}$/);
			$ret_hash->{$col_name} = MongoDB::OID->new(value => $col_value);
		}
	}
	else
	{
		$ret_hash->{$col_name} = $col_value;
	}
	return $ret_hash;
}



# args: constraints is optional, by default it will constrain, IFF given and 0 then no record munging is performed.
# 	otherwise the record is sanitized by renaming all keys with "."
# args: safe, optional allows setting write concern, see http://search.cpan.org/~mongodb/MongoDB-v0.705.0.0/lib/MongoDB/MongoClient.pm#w
# returns: hashref, { succes: bool, id: inserted_id, error: message if error }
sub insert
{
	my %arg        = @_;
	my $collection = $arg{collection};
	my $record     = $arg{record};
	my $safe       = $arg{safe} // 1;
	my $bulk       = $arg{bulk} // undef;
	my $id         = undef;
	my $new_record = $record;
	$new_record = constrain_record( record => $record ) if ( !defined( $arg{constraints} ) || $arg{constraints} );
	my $success = undef;
	my ( $error, $error_type ) = ( undef, undef );

	if ($new_driver)
	{
		if ($bulk)
		{
			$bulk->insert_one($new_record);
			$success = 1;
			$id      = "bulk";
		}
		else
		{
			try
			{
				my $result = $collection->insert_one($new_record);
				if ( $result->acknowledged )
				{
					$id = $result->inserted_id;
				}
				$success = 1;
			}
			catch
			{
				$success    = 0;
				$error      = $_->message;
				$error_type = ref($_);

				# example of errors from doc, possibly this should be passed on to the caller to handle?
				# if ( $_->$_isa("MongoDB::DuplicateKeyError" ) {

				# }
				# else {
				# 		...
				# }
			};
		}
	}
	else
	{
		try
		{
			$id = $collection->insert( $new_record, {safe => 0} );
			$success = 1;
		}
		catch
		{
			$success = 0;
			$error   = $_;
		};
		if ($safe)
		{
			my $database = $collection->can("database") ? $collection->database() : $collection->_database();
			my $error_hash = get_last_error( db => $database, w => $safe );
			if ( $error_hash->{err} )
			{
				$success = 0;
				$error = $error_hash->{errmsg} // $error_hash->{err};
			}
		}
	}

	return {success => $success, id => $id, error => $error, error_type => $error_type};
}

# trivial wrapper around MongoDB::BSON::Binary, mainly
# to keep the "use mongodb" out of client modules
# returns binary blob obj from data argument
sub make_binary
{
	my (%arg) = @_;
	return MongoDB::BSON::Binary->new( data => $arg{data} );
}

# Trivial wrapper around MongdoDB::OID, again
#  to keep mongo use out of modules
sub make_oid
{
	my ($value) = @_;
	return $value if ( ref($value) eq "MongoDB::OID" );
	return MongoDB::OID->new( value => $value ) if ($value);
	return MongoDB::OID->new();
}

# takes the same arguments as getdbconnection, plus optional existing "connection" handle
# verifies that the given connection is still alive; if not, creates a new connection
#
# new driver: if the args connection_timeout or query_timeout are given, then the connection's values
# are compared to these as part of the liveness test.
# old driver: query_timeout is updated  if necessary
#
# returns: connection handle or undef, plus sets error_string
sub reget_db_connection
{
	my %args      = @_;
	my $maybelive = $args{connection};

	my $ping_to = $args{conf}->{db_ping_timeout} || 1000;    # one second default

	# Driver 1.X query_timeout is readonly, and it tries to handle reconnect itself
	# TODO: until more testing can be done just assume it's working
	if ( ref($maybelive) eq "MongoDB::MongoClient" && $new_driver )
	{
		my $status = undef;
		try
		{
			# new driver lets us set a timeout per database
			$status = $maybelive->get_database( 'admin', {max_time_ms => $ping_to} )->run_command( {ping => 1} );
		}
		catch
		{
			my $exception = $_;
			print STDERR "ReGetDbConnection: " . $exception->message . "\n";
			warn "make sure admin is the correct databaes to be trying this on";
			$status = undef;
		};

		undef $status
			if (
			$status
			&& ((   defined( $args{connection_timeout} )    # zero is useless but technically ok
					&& $maybelive->connect_timeout_ms != $args{connect_timeout}
				)
				|| (   defined( $args{query_timeout} )
					&& $args{query_timeout} == -1
					&& $maybelive->socket_timeout_ms
					!= $args{query_timeout} )               # fixme unverified: in that case, max_time_ms should be 0
				|| (   defined( $args{query_timeout} )
					&& $args{query_timeout} > 0
					&& $maybelive->max_time_ms != $args{query_timeout} )
			)
			);    # fixme unverified: in that case, socket_timeout_ms should be a bit more than max_time_ms

		return $maybelive if ($status);
	}

	# old driver
	elsif ( ref($maybelive) eq "MongoDB::MongoClient" )
	{
		my $finaltimeout = $args{query_timeout} // $maybelive->query_timeout;
		my $status = try
		{

			# optionally: wait less long for ping responses
			$maybelive->query_timeout($ping_to) if ( $finaltimeout != $ping_to );
			$maybelive->get_database('admin')->run_command( {ping => 1} );
		};

		# reset the timeout if required
		$maybelive->query_timeout($finaltimeout) if ( $finaltimeout != $ping_to );
		return $maybelive if ($status);
	}

	return get_db_connection(%args);
}

# args: safe, optional allows setting write concern, see http://search.cpan.org/~mongodb/MongoDB-v0.705.0.0/lib/MongoDB/MongoClient.pm#w
# from docs: safe If the update fails and safe is set, this function will croak. ( version < 1.0 )
sub remove
{
	my %arg        = @_;
	my $collection = $arg{collection};
	my $query      = $arg{query} // {};
	my $safe       = $arg{safe} // 1;

	my $return_info = {};

	my $removed_records = 0;
	my $success         = undef;
	my ( $error, $error_type ) = ( undef, undef );
	my $options = {safe => $safe};
	$options->{just_one} = 1 if ( $arg{just_one} );

	if ($new_driver)
	{

		# NOTE: safe does not apply here
		try
		{
			my $result;
			if ( $options->{just_one} )
			{
				$result = $collection->delete_one($query);
			}
			else
			{
				$result = $collection->delete_many($query);
			}
			if ( $result->acknowledged )
			{
				$removed_records = $result->deleted_count;
			}
			$success = 1;
		}
		catch
		{
			$success    = 0;
			$error      = $_->message;
			$error_type = ref($_);
		}

	}
	else
	{
		try
		{
			$return_info = $collection->remove( $query, $options );

			# return # of rows removed if safe is 1 (which it could be depending on the write
			# concern in the connection)
			if ( ref($return_info) eq "HASH" && defined( $return_info->{n} ) )
			{
				$removed_records = $return_info->{n};
			}
			else
			{
				# if $safe is set the error check below will return the # of records, if not
				# set something here as we can only assume
				$removed_records = 1;
			}
			$success = 1;
		}
		catch
		{
			$success = 0;
			$error   = $_;
		};

		if ($safe)
		{
			my $database = $collection->_database();
			my $error_hash = get_last_error( db => $database, w => $safe );
			if ( $error_hash->{err} )
			{
				$success = 0;
				$error = $error_hash->{errmsg} // $error_hash->{err};
			}
			else
			{
				$removed_records = $error_hash->{n};
			}
		}
	}

	return {success => $success, removed_records => $removed_records, error => $error, error_type => $error_type};
}

# a thin wrapper around run_command
# args: db, command (= array, or tie::ixhash or plain hashref), both required
# returns: result hash with ok => (maybe 0), errmsg/err/error
#
# errmsg is extracted from exception with new driver, err and error are returned by some commands...
# code clones from errmsg, err or error (in that order) - no guarantees with the old driver, may not be hash!
sub run_command
{
	my (%args) = @_;
	return {ok => 0, errmsg => "Insufficient arguments"} if ( !$args{db} or !$args{command} );
	my $result;
	try
	{
		$result = $args{db}->run_command( $args{command} );
	}
	catch
	{
		my $gotcha = $_;
		$result = {
			ok     => 0,
			errmsg => ( $gotcha->isa("MongoDB::Error") ? $gotcha->message : $gotcha )
		};
	};

	# success with new driver -> hash, failure -> exception
	# success with old  driver -> hash, failure -> ERROR TEXT!
	$result = {ok => 0, errmsg => $result} if ( !ref($result) );

	if ( ref($result) eq "HASH" )
	{
		my $theerror = $result->{errmsg} || $result->{err} || $result->{error};
		$result->{err} = $result->{errmsg} = $result->{error} = $theerror;
	}

	return $result;
}

# does an update for the given query with the given record, returns status hash
# args: collection (a handle!), query, record - all required
# args: upsert is optional, changes the update to an 'upsert'
# args: constraints is optional, by default it will constrain, IFF given and 0 then no record munging is performed.
# 	otherwise the record is sanitized by renaming all keys with "."
# args: freeform, if set the record has to be deep structure with mongodb update operators
# otherwise '$set' is used with the record.
# args: multiple is optional. if not given only one record is updated.
# args: safe, optional allows setting write concern, see http://search.cpan.org/~mongodb/MongoDB-v0.705.0.0/lib/MongoDB/MongoClient.pm#w
sub update
{
	my %arg         = @_;
	my $collection  = $arg{collection};
	my $query       = $arg{query};
	my $record      = $arg{record};
	my $safe        = $arg{safe} // 1;
	my $return_info = undef;
	my $new_record  = $record;
	$new_record = constrain_record( record => $record ) if ( !defined( $arg{constraints} ) || $arg{constraints} );

	my $updated_records = 0;
	my $matched_records = 0;
	my $success         = undef;
	my ( $error, $error_type ) = ( undef, undef );
	my $upsert   = $arg{upsert}   || 0;
	my $multiple = $arg{multiple} || 0;
	my $updates = ( $arg{freeform} ) ? $new_record : {'$set' => $new_record};

	if ($new_driver)
	{
		try
		{
			my $result;
			if ($multiple)
			{
				$result = $collection->update_many( $query, $updates, {upsert => $upsert} );
			}
			else
			{
				$result = $collection->update_one( $query, $updates, {upsert => $upsert} );
			}
			if ( $result->acknowledged )
			{
				$updated_records = $result->modified_count;
				$matched_records = $result->matched_count;
			}
			$success = 1;
		}
		catch
		{
			my $result = $_;
			$success    = 0;
			$error      = $result->message;
			$error_type = ref($_);
		}
	}
	else
	{
		try
		{
			$return_info
				= $collection->update( $query, $updates, {upsert => $upsert, multiple => $multiple, safe => 0} );

			# return # of rows updated if safe is 1 (which it could be depending on the write concern in the connection)
			if ( ref($return_info) eq "HASH" && defined( $return_info->{n} ) )
			{
				$updated_records = $return_info->{n};
			}
			else
			{
   # if $safe is set the error check below will return the # of records, if not set something here as we can only assume
				$updated_records = 1;
			}
			$success = 1;
		}
		catch
		{
			$success = 0;
			$error   = $_;
		};

		if ($safe)
		{
			my $database = $collection->can("database") ? $collection->database() : $collection->_database();
			my $error_hash = get_last_error( db => $database, w => $safe );
			if ( $error_hash->{err} )
			{
				$success = 0;
				$error = $error_hash->{errmsg} // $error_hash->{err};
			}
			else
			{
				$updated_records = $error_hash->{n};
			}
		}
	}

	return {
		success         => $success,
		updated_records => $updated_records,
		matched_records => $matched_records,
		error           => $error,
		error_type      => $error_type
	};
}

1;
