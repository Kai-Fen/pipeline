#!/usr/bin/env perl

use strict;
use warnings;
no warnings('once');

use PipelineAWE_Conf;

use JSON;
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request::Common;
use Data::Dumper;

# options
my $job_id    = "";
my $shock_url = "";
my $help      = 0;

my $options = GetOptions (
        "job_id=s"    => \$job_id,
		"shock_url=s" => \$shock_url,
		"help!"       => \$help
);

if ($help) {
    print get_usage();
    exit 0;
} elsif (! $job_id) {
    print STDERR "ERROR: A job identifier is required.\n";
    exit 1;
}

my $agent = LWP::UserAgent->new();
$agent->timeout(3600);
my $json = JSON->new;
$json = $json->utf8();
$json->max_size(0);
$json->allow_nonref;

# get default urls
my $vars = $PipelineAWE_Conf::template_keywords;
if ($shock_url) {
    $vars->{shock_url} = $shock_url;
}

# get job shock nodes
my @nids = ();
my $gres = undef;
my $nget = $agent->get(
    $vars->{shock_url}.'/node?query&type=metagenome&job_id='.$job_id,
    'Authorization', 'OAuth '.$PipelineAWE_Conf::shock_pipeline_token
);
eval {
    $gres = $json->decode($nget->content);
};
if ($@) {
    print STDERR "ERROR: Return from shock is not JSON:\n".$nget->content."\n";
    exit 1;
}
if ($gres->{error}) {
    print STDERR "ERROR: (shock) ".$gres->{error}[0]."\n";
    exit 1;
}

# get input node
my $input_node = '';
foreach my $n (@{$gres->{data}}) {
    push @nids, $n->{id};
    if (exists($n->{atributes}{stage_name}) && ($n->{atributes}{stage_name} = 'upload')) {
        $input_node = $n->{id};
    }
}
unless ($input_node) {
    print STDERR "ERROR: missing upload shock node\n";
    exit 1;
}

# submit job
my $status = system(('submit_to_awe.pl', '--job_id', $job_id, '--input_node', $input_node));
if ($status != 0) {
    print STDERR "ERROR: submit_to_awe.pl returns value $status\n";
    exit $status >> 8;
}

# delete old nodes
print "deleting nodes\t".join(',', @nids)."\n";
foreach my $n (@nids) {
    my $dres = undef;
    my $ndel = $agent->delete(
        $vars->{shock_url}.'/node/'.$n,
        'Authorization', 'OAuth '.$PipelineAWE_Conf::shock_pipeline_token
    );
    eval {
        $dres = $json->decode($ndel->content);
    };
    if ($@) {
        print STDERR "ERROR: Return from shock is not JSON:\n".$ndel->content."\n";
        exit 1;
    }
    if ($dres->{error}) {
        print STDERR "ERROR: (shock) ".$dres->{error}[0]."\n";
        exit 1;
    }
}

sub get_usage {
    return "USAGE: resubmit_to_awe.pl -job_id=<job identifier> [-shock_url=<shock url>]\n";
}

# enable hash-resolving in the JSON->encode function
sub TO_JSON { return { %{ shift() } }; }