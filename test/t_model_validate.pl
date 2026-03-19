#!/usr/bin/perl
#
#  Test script for validating NMIS9 model files against JSON Schema
#
#  Usage:
#    perl test/t_model_validate.pl all=true              # validate all model files
#    perl test/t_model_validate.pl model=Model-Default.nmis  # validate a single file
#    perl test/t_model_validate.pl type=Graph             # validate only Graph-* files
#    perl test/t_model_validate.pl type=Common            # validate only Common-* files
#    perl test/t_model_validate.pl type=Model             # validate only Model-* files
#    perl test/t_model_validate.pl dir=/path/to/models    # custom model directory
#    perl test/t_model_validate.pl schema=/path/to/schema # custom schema file
#
use strict;
use warnings;

use FindBin;
use File::Spec;
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);

# Resolve base directory from the script's actual file location
my $script_dir = abs_path(dirname(__FILE__));
my $base_dir   = abs_path("$script_dir/..");

use lib "$FindBin::Bin/../lib";

use Test::More;
use JSON::Validator;
use JSON::PP;
use File::Glob qw(:bsd_glob);

# Parse key=value arguments
my %args;
for my $arg (@ARGV) {
	if ($arg =~ /^(\w+)=(.*)$/) {
		$args{$1} = $2;
	}
}

my $model_dir   = $args{dir}    || "$base_dir/models-default";
my $schema_file = $args{schema} || "$base_dir/conf-default/nmis_model_schema.json";

# Load schema
die "Schema file not found: $schema_file\n" unless -f $schema_file;
my $schema_json = do {
	local $/;
	open my $fh, '<', $schema_file or die "Cannot open $schema_file: $!\n";
	<$fh>;
};
my $schema = JSON::PP::decode_json($schema_json);

# Build file list
my @files;
if ($args{model}) {
	my $path = "$model_dir/$args{model}";
	die "Model file not found: $path\n" unless -f $path;
	push @files, $path;
}
elsif ($args{type}) {
	@files = sort glob("$model_dir/$args{type}-*.nmis");
	die "No files found matching type=$args{type} in $model_dir\n" unless @files;
}
elsif ($args{all}) {
	@files = sort glob("$model_dir/*.nmis");
	# Exclude Model.nmis (the selector file) and any .nmis8 backup files
	@files = grep { basename($_) ne 'Model.nmis' && $_ !~ /\.nmis8$/ } @files;
	die "No .nmis files found in $model_dir\n" unless @files;
}
else {
	# Default: validate all
	@files = sort glob("$model_dir/*.nmis");
	@files = grep { basename($_) ne 'Model.nmis' && $_ !~ /\.nmis8$/ } @files;
	if (!@files) {
		plan skip_all => "No .nmis files found in $model_dir";
		exit 0;
	}
}

# Build sub-schemas for each file type
my $defs = $schema->{'$defs'} || $schema->{definitions} || {};

sub build_subschema {
	my ($def_name) = @_;
	# Return a complete schema document that references the definition inline
	# We embed $defs so JSON::Validator can resolve internal refs
	return {
		'$schema' => 'http://json-schema.org/draft-07/schema#',
		'$defs'   => $defs,
		'$ref'    => "#/\$defs/$def_name",
	};
}

my $model_common_schema = build_subschema('modelCommonFile');
my $graph_schema        = build_subschema('graphFile');
my $selector_schema     = build_subschema('modelSelectorFile');

# Validate each file
for my $file (@files) {
	my $basename = basename($file);

	# Load .nmis file via eval (Perl data structure)
	my $content = do {
		local $/;
		open my $fh, '<', $file or do {
			fail("$basename - cannot open: $!");
			next;
		};
		<$fh>;
	};

	my %hash;
	{
		# .nmis files assign to %hash
		no strict;
		no warnings;
		%hash = eval($content);
	}
	if ($@) {
		fail("$basename - parse error: $@");
		next;
	}

	# Select appropriate schema based on filename prefix
	my $sub_schema;
	if ($basename =~ /^Graph-/) {
		$sub_schema = $graph_schema;
	}
	elsif ($basename eq 'Model.nmis') {
		$sub_schema = $selector_schema;
	}
	else {
		$sub_schema = $model_common_schema;
	}

	# Validate
	my $jv = JSON::Validator->new;
	$jv->schema($sub_schema);
	my @errors = $jv->validate(\%hash);

	ok(!@errors, "$basename validates against schema")
		or do {
			for my $err (@errors) {
				diag("  $err");
			}
		};
}

done_testing();
