package MediaWords::Crawler::Provider;
use Modern::Perl "2015";
use MediaWords::CommonLibs;

=head1 NAME

Mediawords::Crawler::Provider - provision downloads for the crawler engine's in memory downloads queue

=head1 SYNOPSIS

    # this is a simplified version of the code used by $engine->crawl() to interact with the crawler provider

    my $crawler = MediaWords::Crawler::Engine->new();

    my $provider = MediaWords::Crawler::Provider->new( $crawler );

    my $queued_downloads;
    while ( 1 )
    {
        if ( !@{ $queued_downloads } )
        {
            $queued_downloads = $provider->provide_download_ids();
        }

        my $download = shift( @{ $queued_downloads } );
        # hand out a download
    }

=head1 DESCRIPTION

The provider is responsible for provisioning downloads for the engine's in memory downloads queue.  The basic job
of the provider is just to query the downloads table for any downloads with `state = 'pending'`.  As detailed in the
handler section below, most 'pending' downloads are added by the handler when the url for a new story is discovered
in a just download feed.

But the provider is also responsible for periodically adding feed downloads to the queue.  The provider uses a back off
algorithm that starts by downloading a feed five minutes after a new story was last found and then doubles the delay
each time the feed is download and no new story is found, until the feed is downloaded only once a week.

The provider is also responsible for throttling downloads by site, so only a limited number of downloads for each site
are provided to the the engine each time the engine asks for a chunk of new downloads.

=cut

use strict;
use warnings;

use Data::Dumper;
use Readonly;

use MediaWords::DB;
use MediaWords::Util::Config;

# how often to download each feed (seconds)
Readonly my $STALE_FEED_INTERVAL => 60 * 60 * 24 * 7;

# how often to check for feeds to download (seconds)
Readonly my $STALE_FEED_CHECK_INTERVAL => 60 * 30;

# timeout for download in fetching state (seconds)
Readonly my $STALE_DOWNLOAD_INTERVAL => 60 * 5;

# downloads.error_message value for downloads timed out by _timeout_stale_downloads
Readonly my $DOWNLOAD_TIMED_OUT_ERROR_MESSAGE => 'Download timed out by Fetcher::_timeout_stale_downloads';

=head1 METHODS

=head2 new

Create a new provider.  Must pass a MediaWords::Crawler::Engine object.

=cut

sub new
{
    my ( $class, $engine ) = @_;

    my $self = {};
    bless( $self, $class );

    $self->engine( $engine );

    $self->pending_hosts( {} );

    # last time a stale feed check was run
    $self->{ last_stale_feed_check } = 0;

    # last time a stale download check was run
    $self->{ last_stale_download_check } = 0;

    # has setup run once?
    $self->{ setup_was_run } = 0;

    return $self;
}

# run before forking engine to perform one time setup tasks
sub _setup
{
    my ( $self ) = @_;

    unless ( $self->{ setup_was_run } )
    {
        TRACE( "_setup" );
        $self->{ setup_was_run } = 1;

        $self->engine->dbs->query( "UPDATE downloads set state = 'pending' where state = 'fetching'" );
    }
}

# delete downloads in fetching mode more than five minutes old.
# this shouldn't technically happen, but we want to make sure that
# no hosts get hung b/c a download sits around in the fetching state forever
sub _timeout_stale_downloads
{
    my ( $self ) = @_;

    if ( $self->{ last_stale_download_check } > ( time() - $STALE_DOWNLOAD_INTERVAL ) )
    {
        return;
    }
    $self->{ last_stale_download_check } = time();

    my $dbs = $self->engine->dbs;
    $dbs->query(
        <<SQL,
        UPDATE downloads SET
            state = 'error',
            error_message = ?,
            download_time = NOW()
        WHERE state = 'fetching'
          AND download_time < now() - interval '5 minutes'
SQL
        $DOWNLOAD_TIMED_OUT_ERROR_MESSAGE
    );

}

# add pending downloads for all stale feeds
sub _add_stale_feeds
{
    my ( $self ) = @_;

    if ( ( time() - $self->{ last_stale_feed_check } ) < $STALE_FEED_CHECK_INTERVAL )
    {
        return;
    }

    my $stale_feed_interval = $STALE_FEED_INTERVAL;

    $self->{ last_stale_feed_check } = time();

    my $dbs = $self->engine->dbs;

    # If the table doesn't exist, PostgreSQL sends a NOTICE which breaks the "no warnings" unit test
    $dbs->query( 'SET client_min_messages=WARNING' );
    $dbs->query( 'DROP TABLE IF EXISTS feeds_to_queue' );
    $dbs->query( 'SET client_min_messages=NOTICE' );

    $dbs->query( <<"SQL" );
        CREATE TEMPORARY TABLE feeds_to_queue AS
        SELECT feeds_id,
               url
        FROM feeds
        WHERE active = 't'
          AND url ~ 'https?://'
          AND (
            -- Never attempted
            last_attempted_download_time IS NULL

            -- Feed was downloaded more than $stale_feed_interval seconds ago
            OR (last_attempted_download_time < (NOW() - interval '$stale_feed_interval seconds'))

            -- (Probably) if a new story comes in every "n" seconds, refetch feed every "n" + 5 minutes
            OR (
                (NOW() > last_attempted_download_time + ( last_attempted_download_time - last_new_story_time ) + interval '5 minutes')

                -- "web_page" feeds are to be downloaded only once a week,
                -- independently from when the last new story comes in from the
                -- feed (because every "web_page" feed download provides a
                -- single story)
                AND type != 'web_page'
            )
          )
SQL

    $dbs->query( <<"SQL" );
        UPDATE feeds
        SET last_attempted_download_time = NOW()
        WHERE feeds_id IN (SELECT feeds_id FROM feeds_to_queue)
SQL

    my $downloads = $dbs->query( <<"SQL" )->hashes;
    WITH inserted_downloads as (
        INSERT INTO downloads (feeds_id, url, host, type, sequence, state, priority, download_time, extracted)
        SELECT feeds_id,
               url,
               LOWER(SUBSTRING(url from '.*://([^/]*)' )),
               'feed',
               1,
               'pending',
               0,
               NOW(),
               false
        FROM feeds_to_queue
        RETURNING *
    )

    select d.*, f.media_id as _media_id
        from inserted_downloads d
            join feeds f using ( feeds_id )
SQL

    $dbs->query( "drop table feeds_to_queue" );

    DEBUG "added stale feeds: " . scalar( @{ $downloads } );
}

=head2 provide_download_ids

Hand out a list of pending download ids, throttling the downloads by host, so that a download is
only handed our for each site each $self->engine->throttle seconds.

Every $STALE_FEED_INTERVAL, add downloads for all feeds that are due to be downloaded again according to
the back off algorithm.

=cut

sub provide_download_ids
{
    my ( $self ) = @_;

    # It appears that the provider is sleep()ing while waiting for the "engine"
    # to process a single download, and if the queue is not yet finished at the
    # end of the sleep(), provider will refuse to provide any downloads.
    #
    # In its original iteration, provide_download_ids() was sleeping for 1 second
    # before continuing, but UserAgent()'s rewrite made fetch_download()
    # + handle_download() slightly slower, so now the sleep() period has been
    # slightly increased.
    sleep( 5 ) if $self->engine->test_mode;

    $self->_setup();

    $self->_timeout_stale_downloads();

    $self->_add_stale_feeds();

    my $db = $self->engine->dbs;

    my $pending_download_ids = [];

    DEBUG( "querying pending downloads ..." );

    my $downloads = $db->query( <<SQL )->hashes();
select distinct on (host) downloads_id, host
    from downloads_pending
    order by host, priority, downloads_id desc nulls last;
SQL

    DEBUG( "provide downloads unthrottled hosts: " . scalar( @{ $downloads } ) );

    for my $download ( @{ $downloads } )
    {
        my $host         = $download->{ host };
        my $downloads_id = $download->{ downloads_id };

        $self->pending_hosts->{ $host } ||= 0;

        if ( $self->pending_hosts->{ $host } > ( time() - $self->engine->throttle ) )
        {
            TRACE "provide downloads: skipping host $host because of throttling";
            next;
        }

        $self->pending_hosts->{ $host } = time();

        push( @{ $pending_download_ids }, $downloads_id );
    }

    DEBUG "provide downloads throttled hosts: " . scalar( @{ $pending_download_ids } );

    if ( scalar( @{ $pending_download_ids } ) < 1 )
    {
        sleep( 1 ) unless $self->engine->test_mode;
    }

    return $pending_download_ids;
}

=head2 engine

getset engine - the crawler engine calling the provider

=cut

sub engine
{
    if ( $_[ 1 ] )
    {
        $_[ 0 ]->{ engine } = $_[ 1 ];
    }

    return $_[ 0 ]->{ engine };
}

=head2 pending_hosts 

getset pending_hosts - hash of hosts with pending downloads, pointing to last queue time for each

=cut

sub pending_hosts
{
    if ( $_[ 1 ] )
    {
        $_[ 0 ]->{ pending_hosts } = $_[ 1 ];
    }

    return $_[ 0 ]->{ pending_hosts };
}

1;
