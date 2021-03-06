#!/usr/bin/env perl

# swap the live and staging solr collections

use strict;
use warnings;

use MediaWords::DB;
use MediaWords::Solr;

sub main
{
    my $db = MediaWords::DB::connect_to_db;

    MediaWords::Solr::swap_live_collection( $db );
}

main();

__END__
