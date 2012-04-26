#!/usr/bin/env perl

# accept a list of urls and file names on standard input and get those in parallel.  for each url, store the
# Storable of the response in the associated file name.
#
# input format:
# <file>:<url>
# <file>:<url>
# ...
#
# This is executed by MediaWords::Util::Web to avoid forking the existing, big process which may muck up database
# handles and have other side effects

use strict;

use LWP::UserAgent;
use Parallel::ForkManager;
use Storable;

use constant NUM_PARALLEL      => 10;
use constant MAX_DOWNLOAD_SIZE => 1024 * 1024;
use constant TIMEOUT           => 20;
use constant MAX_REDIRECT      => 15;
use constant BOT_FROM          => 'mediacloud@cyber.law.harvard.edu';
use constant BOT_AGENT         => 'mediacloud bot (http://mediacloud.org)';

sub main
{
    my $requests;

    while ( my $line = <STDIN> )
    {
        chomp( $line );
        if ( $line =~ /^([^:]*):(.*)/ )
        {
            push( @{ $requests }, { file => $1, url => $2 } );
        }
        else
        {
            warn( "Unable to parse line: $line" );
        }

    }

    if ( !$requests || !@{ $requests } )
    {
        return;
    }

    my $pm = new Parallel::ForkManager( NUM_PARALLEL );

    my $ua = LWP::UserAgent->new();

    $ua->from( BOT_FROM );
    $ua->agent( BOT_AGENT );

    $ua->timeout( TIMEOUT );
    $ua->max_size( MAX_DOWNLOAD_SIZE );
    $ua->max_redirect( MAX_REDIRECT );

    my $i     = 0;
    my $total = scalar( @{ $requests } );

    $SIG{ ALRM } = sub { die( "web request timed out" ); };

    for my $request ( @{ $requests } )
    {
        $i++;

        alarm( TIMEOUT );
        $pm->start and next;

        print STDERR "fetch [$i/$total] : $request->{ url }\n";

        my $response = $ua->get( $request->{ url } );

        print STDERR "got [$i/$total]: $request->{ url }\n";

        Storable::store( $response, $request->{ file } );

        $pm->finish;

        alarm( 0 );
    }

    $pm->wait_all_children;
}

main();
