package MediaWords::Controller::Admin::Profile;

use strict;
use warnings;

use Moose;
use namespace::autoclean;

use MediaWords::Util::Config;
use MediaWords::DBI::Auth;
use MediaWords::DBI::Auth::Limits;

use List::MoreUtils qw/ any /;

BEGIN { extends 'Catalyst::Controller'; }

sub index : Path : Args(0)
{
    my ( $self, $c ) = @_;

    my $db    = $c->dbis;
    my $email = $c->user->username;

    my $userinfo;
    eval { $userinfo = MediaWords::DBI::Auth::user_info( $db, $email ); };
    if ( $@ or ( !$userinfo ) )
    {
        die "Unable to find user with email '$email'";
    }

    my $userauth;
    eval { $userauth = MediaWords::DBI::Auth::user_auth( $db, $email ); };
    if ( $@ or ( !$userauth ) )
    {
        die "Unable to find authentication roles for email '$email'";
    }

    my $roles = $userauth->{ roles };

    my $weekly_requests_limit        = $userinfo->{ weekly_requests_limit } + 0;
    my $weekly_requested_items_limit = $userinfo->{ weekly_requested_items_limit } + 0;

    # Admin users are effectively unlimited
    my $roles_exempt_from_user_limits = MediaWords::DBI::Auth::Limits::roles_exempt_from_user_limits();
    foreach my $exempt_role ( @{ $roles_exempt_from_user_limits } )
    {
        if ( any { $_ eq $exempt_role } @{ $roles } )
        {
            $weekly_requests_limit        = 0;
            $weekly_requested_items_limit = 0;
        }
    }

    # Prepare the template
    $c->stash->{ c }         = $c;
    $c->stash->{ email }     = $userinfo->{ email };
    $c->stash->{ full_name } = $userinfo->{ full_name };
    $c->stash->{ api_key }   = $userinfo->{ api_key };
    $c->stash->{ notes }     = $userinfo->{ notes };

    $c->stash->{ weekly_requests_sum }          = $userinfo->{ weekly_requests_sum } + 0;
    $c->stash->{ weekly_requested_items_sum }   = $userinfo->{ weekly_requested_items_sum } + 0;
    $c->stash->{ weekly_requests_limit }        = $weekly_requests_limit;
    $c->stash->{ weekly_requested_items_limit } = $weekly_requested_items_limit;

    $c->stash( template => 'auth/profile.tt2' );

    # Prepare the "change password" form
    my $form = $c->create_form(
        {
            load_config_file => $c->path_to() . '/root/forms/auth/changepass.yml',
            method           => 'POST',
            action           => $c->uri_for( '/admin/profile' ),
        }
    );

    $form->process( $c->request );
    unless ( $form->submitted_and_valid() )
    {

        # No change password attempt
        $c->stash->{ form } = $form;
        return;
    }

    # Change the password
    my $password_old        = $form->param_value( 'password_old' );
    my $password_new        = $form->param_value( 'password_new' );
    my $password_new_repeat = $form->param_value( 'password_new_repeat' );

    eval {
        MediaWords::DBI::Auth::change_password_via_profile( $c->dbis, $c->user->username, $password_old, $password_new,
            $password_new_repeat );
    };
    if ( $@ )
    {
        my $error_message = "Unable to change password: $@";

        $c->stash->{ form } = $form;
        $c->stash( error_msg => $error_message );
    }
    else
    {
        $c->stash->{ form } = $form;
        $c->stash( status_msg => "Your password has been changed. An email was sent to " .
              "'" . $c->user->username . "' to inform you about this change." );
    }
}

# Regenerate API key
sub regenerate_api_key : Local
{
    my ( $self, $c ) = @_;

    my $db    = $c->dbis;
    my $email = $c->user->username;

    my $userinfo;
    eval { $userinfo = MediaWords::DBI::Auth::user_info( $db, $email ); };
    if ( $@ or ( !$userinfo ) )
    {
        die "Unable to find user with email '$email'";
    }

    # Delete user
    eval { MediaWords::DBI::Auth::regenerate_api_key( $db, $email ); };
    if ( $@ )
    {
        my $error_message = "Unable to regenerate API key: $@";

        $c->response->redirect( $c->uri_for( '/admin/profile', { error_msg => $error_message } ) );
        return;
    }

    $c->response->redirect( $c->uri_for( '/admin/profile', { status_msg => "API key has been regenerated." } ) );

}

__PACKAGE__->meta->make_immutable;

1;
