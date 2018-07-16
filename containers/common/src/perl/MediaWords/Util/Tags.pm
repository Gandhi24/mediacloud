package MediaWords::Util::Tags;

# various functions for editing feed and medium tags
#
# FIXME move everything to "Tags" / "Tag sets" models?

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;


# save tag info for the given object (medium or feed) from a space separated list of tag names.
# oid is the object id (eg the media_id), and table is the name of the table for which to save
# the tag associations (eg media).
sub save_tags_by_name
{
    my ( $db, $oid, $table, $tag_names_list ) = @_;

    my $oid_field = "${table}_id";

    my $tag_names = [ split( /\s*,\s*/, $tag_names_list ) ];

    my $tags = [];
    map { push( @{ $tags }, lookup_or_create_tag( $db, $_ ) ) } @{ $tag_names };

    $db->query( "delete from ${ table }_tags_map where ${ table }_id = ?", $oid );

    for my $tag ( @{ $tags } )
    {
        my $tag_exists = $db->query( <<END, $tag->{ tags_id }, $oid )->hash;
select * from ${ table }_tags_map where tags_id = ? and ${ table }_id = ?
END
        if ( !$tag_exists )
        {
            $db->create( "${table}_tags_map", { tags_id => $tag->{ tags_id }, $oid_field => $oid } );
        }
    }
}

# lookup the tag given the tag_set:tag format
sub lookup_tag
{
    my ( $db, $tag_name ) = @_;

    if ( $tag_name !~ /^([^:]*):(.*)$/ )
    {
        WARN "Unable to parse tag name '$tag_name'";
        return undef;
    }

    my ( $tag_set_name, $tag ) = ( $1, $2 );

    return $db->query(
        "select t.* from tags t, tag_sets ts where t.tag_sets_id = ts.tag_sets_id " . "    and t.tag = ? and ts.name = ?",
        $tag, $tag_set_name )->hash;
}

# lookup the tag given the tag_set:tag format.  create it if it does not already exist
sub lookup_or_create_tag
{
    my ( $db, $tag_name ) = @_;

    if ( $tag_name !~ /^([^:]*):(.*)$/ )
    {
        WARN "Unable to parse tag name '$tag_name'";
        return undef;
    }

    my ( $tag_set_name, $tag_tag ) = ( $1, $2 );

    my $tag_set = lookup_or_create_tag_set( $db, $tag_set_name );
    my $tag = $db->find_or_create( 'tags', { tag => $tag_tag, tag_sets_id => $tag_set->{ tag_sets_id } } );

    return $tag;
}

# lookup the tag_set given.  create it if it does not already exist
sub lookup_or_create_tag_set
{
    my ( $db, $tag_set_name ) = @_;

    my $tag_set = $db->find_or_create( 'tag_sets', { name => $tag_set_name } );

    return $tag_set;
}

# assign the given tag in the given tag_set to the given medium.  if the tag or tag_set does not exist, create it.
sub assign_singleton_tag_to_medium
{
    my ( $db, $medium, $tag_set, $tag ) = @_;

    $tag_set = $db->find_or_create( 'tag_sets', $tag_set );

    $tag->{ tag_sets_id } = $tag_set->{ tag_sets_id };

    $tag = $db->find_or_create( 'tags', $tag );

    # make sure we only update the tag in the db if necessary; otherwise we will trigger solr re-imports unnecessarily
    my $existing_tag = $db->query( <<SQL, $tag_set->{ tag_sets_id }, $medium->{ media_id } )->hash;
select t.* from tags t join media_tags_map mtm using ( tags_id ) where t.tag_sets_id = \$1 and mtm.media_id = \$2
SQL

    return if ( $existing_tag && ( $existing_tag->{ tags_id } == $tag->{ tags_id } ) );

    if ( $existing_tag )
    {
        $db->query( <<SQL, $existing_tag->{ tags_id }, $medium->{ media_id } );
delete from media_tags_map where tags_id = \$1 and media_id = \$2
SQL
    }

    $db->query( <<SQL, $tag->{ tags_id }, $medium->{ media_id } );
insert into media_tags_map ( tags_id, media_id ) values ( \$1, \$2 )
SQL

}

1;