#!/usr/bin/env perl

use strict;
use warnings;
no warnings('once');

use PipelineAWE;
use Getopt::Long;
use File::Basename;
use Data::Dumper;
use Cwd;
umask 000;

# options
my $input     = "";
my $metadata  = "";
my $project   = "";
my $help      = 0;
my $options   = GetOptions (
    "input=s"     => \$input,
    "metadata=s"  => \$metadata,
    "project=s"   => \$project,
    "help!"       => \$help
);

if ($help){
    print get_usage();
    exit 0;
}elsif (length($input)==0){
    PipelineAWE::logger('error', "input parameters file was not specified");
    exit 1;
}elsif (! -e $input){
    PipelineAWE::logger('error', "input parameters file [$input] does not exist");
    exit 1;
}

my $params = PipelineAWE::read_json($input);
my $mdata  = ($metadata && (-s $metadata)) ? PipelineAWE::read_json($metadata) : undef;

unless ($mdata || $project) {
    PipelineAWE::logger('error', "must have one of --metadata or --project");
    exit 1;
}

my $auth = $ENV{'USER_AUTH'} || undef;
my $api  = $ENV{'MGRAST_API'} || undef;
unless ($auth && $api) {
    PipelineAWE::logger('error', "missing authentication ENV variables");
    exit 1;
}

# get inbox list
my $inbox = PipelineAWE::obj_from_url($api."/inbox", $auth);
my %seq_files = map { $_->{filename}, $_ } grep { exists($_->{data_type}) && ($_->{data_type} eq 'sequence') } @{$inbox->{files}};

my $to_submit   = {}; # file_name => mg_name
my $no_inbox    = {}; # file_name
my $no_metadata = {}; # file_name

# check that input files in inbox
my $in_inbox = {}; # file_name w/o extension => file_name
foreach my $fname (@{$params->{files}}) {
    if (exists $seq_files{$fname}) {
        my $basename = fileparse($fname, qr/\.[^.]*/);
        $in_inbox->{$basename} = $fname;
    } else {
        $no_inbox->{$fname} = 1;
    }
}
foreach my $miss (keys %$no_inbox) {
    print STDOUT "no_inbox\t$miss\n";
}

# populate to_submit from in_inbox or mg_names
# if metadata, check that input files in metadata
# extract metagenome names
# need to create project before submitted
if ($mdata && $params->{metadata}) {
    if ($mdata->{id} && ($mdata->{id} =~ /^mgp/)) {
        $project = $mdata->{id};
    }
    my %md_names = (); # file w/o extension => mg name
    foreach my $sample ( @{$mdata->{samples}} ) {
        next unless ($sample->{libraries} && scalar(@{$sample->{libraries}}));
        foreach my $library (@{$sample->{libraries}}) {
            next unless (exists $library->{data});
            my $mg_name = "";
            my $file_name = "";
            if (exists $library->{data}{metagenome_name}) {
                $mg_name = $library->{data}{metagenome_name}{value};
            }
            if (exists $library->{data}{file_name}) {
                $file_name = fileparse($library->{data}{file_name}{value}, qr/\.[^.]*/);
            } else {
                $file_name = $mg_name;
            }
            if ($mg_name && $file_name) {
                $md_names{$file_name} = $mg_name;
            }
        }
    }
    while (my ($basename, $fname) = each %$in_inbox) {
        if (exists $md_names{$basename}) {
            $to_submit->{$fname} = $md_names{$basename};
        } else {
            $no_metadata->{$fname} = 1;
        }
    }
    foreach my $miss (keys %$no_metadata) {
        print STDOUT "no_metadata\t$miss\n";
    }
}
if ($project) {
    unless ($mdata && $params->{metadata}) {
        while (my ($basename, $file_name) = each %$in_inbox) {
            $to_submit->{$file_name} = $basename;
        }
    }
    my $pinfo = PipelineAWE::obj_from_url($api."/project/".$project, $auth);
    unless ($project eq $pinfo->{id}) {
        PipelineAWE::logger('error', "project $project does not exist");
    }
}

my $submitted = {}; # file_name => [name, awe_id, mg_id]

# submit one at a time / add to project as submitted
my $mgids = [];
FILES: foreach my $fname (keys %$to_submit) {
    my $info = $seq_files{$fname};
    # see if already exists for this submission (due to re-start)
    my $mg_by_md5 = PipelineAWE::obj_from_url($api."/metagenome/md5/".$info->{stats_info}{checksum}, $auth);
    if ($mg_by_md5 && ($mg_by_md5->{total_count} > 0)) {
        foreach my $mg (@{$mg_by_md5->{data}}) {
            next if ($mg->{status} =~ /deleted/);
            if ($mg->{submission} && ($mg->{submission} eq $params->{submission})) {
                my $awe_id = exists($mg->{pipeline_id}) ? $mg->{pipeline_id} : "";
                $submitted->{$fname} = [$mg->{name}, $awe_id, $mg->{id}];
                print STDOUT join("\t", ("submitted", $fname, $mg->{name}, $awe_id, $mg->{id}))."\n";
                push @$mgids, $mg->{id};
                next FILES;
            }
        }
    }
    # reserve and create job
    my $reserve_job = PipelineAWE::obj_from_url($api."/job/reserve", $auth, {name => $to_submit->{$fname}, input_id => $info->{id}});
    my $mg_id = $reserve_job->{metagenome_id};
    my $create_data = $params->{parameters};
    $create_data->{metagenome_id} = $mg_id;
    $create_data->{input_id}      = $info->{id};
    $create_data->{submission}    = $params->{submission};
    my $create_job = PipelineAWE::obj_from_url($api."/job/create", $auth, $create_data);
    # project
    PipelineAWE::obj_from_url($api."/job/addproject", $auth, {metagenome_id => $mg_id, project_id => $project});
    # submit it
    my $submit_job = PipelineAWE::obj_from_url($api."/job/submit", $auth, {metagenome_id => $mg_id, input_id => $info->{id}});
    $submitted->{$fname} = [$to_submit->{$fname}, $submit_job->{awe_id}, $mg_id];
    print STDOUT join("\t", ("submitted", $fname, $to_submit->{$fname}, $submit_job->{awe_id}, $mg_id))."\n";
    push @$mgids, $mg_id;
}

if (@$mgids == 0) {
    PipelineAWE::logger('error', "no metagenomes created for submission");
    exit 1;
}

# apply metadata
if ($mdata && $params->{metadata}) {
    my $import = {node_id => $params->{metadata}, metagenome => $mgids};
    my $result = PipelineAWE::obj_from_url($api."/metadata/import", $auth, $import);
    # no success
    if (scalar(@{$result->{added}}) == 0) {
        if ($result->{errors} && (@{$result->{errors}} > 0)) {
            PipelineAWE::logger('error', "unable to import metadata: ".join(", ", @{$result->{errors}}));
        } else {
            PipelineAWE::logger('error', "unable to import any metadata");
        }
        exit 1;
    }
    # partial success
    if (scalar(@{$result->{added}}) < scalar(@$mgids)) {
        my %success = map { $_, 1 } @{$result->{added}};
        my @list = ();
        foreach my $m (@$mgids) {
            unless ($success{$m}) {
                push @list, $m;
            }
        }
        if (@list > 0) {
            PipelineAWE::logger('error', "unable to import metadata for the following: ".join(", ", @list));
        }
    }
}


sub get_usage {
    return "USAGE: awe_submit_to_mgrast.pl -input=<pipeline parameter file> [-metadata=<metadata file>, -project=<project id>]\n";
}
