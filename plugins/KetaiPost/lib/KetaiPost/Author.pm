# KetaiPost (C) 2010 Yuichi Takeuchi
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id: Author.pm $


package KetaiPost::Author;
use warnings;
use strict;
use Carp;

use MT::Util qw( encode_html );
use KetaiPost::Util qw( if_can_administer_blog get_system_setting log_debug
                        if_can_edit_ketaipost_author );

use MT::Object;
@KetaiPost::Author::ISA = qw( MT::Object );

__PACKAGE__->install_properties ({
    column_defs => {
        'id' => 'integer not null auto_increment',
        'author_id' => 'integer not null',
        'address' => 'string(255)',
        'enable_sync' => 'boolean',
    },
    indexes => {
        author_id_enable_sync => {
            columns => [ 'author_id', 'enable_sync' ],
        }
    },
    child_of => 'MT::Author',
    datasource => 'ketaipost_author',
    primary_key => 'id',
});

sub set_defaults {
    my $self = shift;
    $self->SUPER::set_defaults(@_);

    $self->set_values_internal({
        enable_sync => 0,
    });

    return $self;
}


sub author {
    my $self = shift;
    return undef unless $self->author_id;

    MT->model( 'author' )->load( $self->author_id );
}

sub list_properties {
    my $props = {
        id => {
            base  => '__virtual.id',
            order => 10,
            condition => sub { 1 }
        },
        address => {
            auto => 1,
            order => 100,
            label => 'Mail Address',
            display => 'force',
            html => sub { _address( @_ ); },
        },
        author_id => {
            auto => 1,
            order => 200,
            label => 'Author',
            display => 'force',
            html => sub { _author( @_ ); }
        },
        enable_sync => {
            auto => 1,
            order => 300,
            label => 'Enable Sync',
            display => 'force',
            html => sub { _enable_sync( @_ ); }
        },
    };
}

sub list_actions {
    my $actions = {
        'delete' => {
            button      => 1,
            label       => 'Delete',
            mode        => 'delete',
            class       => 'icon-action',
            return_args => 1,
            args        => { _type => 'ketaipost_author' },
            order       => 300,
        },
    };
    return $actions;
}

sub content_actions {
    my ( $meth, $component ) = @_;

    my $app = MT->instance;
    my $plugin = MT->component( 'KetaiPost' );

    return {
        'new' => {
            mode => 'edit_ketaipost_author',
            class => 'icon-create',
            label => 'Add Author',
            return_args => 1,
            order => 100,
            args => {
                _type => 'ketaipost_author'
            },
        },
        'sync_authors' => {
            mode => 'sync_ketaipost_authors',
            class => 'icon-mini-rebuild',
            label => sub {
                $plugin->translate( $app->user->is_superuser ? 'Add All Authors' : 'Add Blog Authors' );
            },
            return_args => 1,
            confirm_msg => sub {
                $plugin->translate(
                    $app->user->is_superuser ?
                      'Do you add all authors?' :
                        'Do you add blog authors?' );
            },
            order => 200,
            args => {
                _type => 'ketaipost_mailbox'
            },
        },
    };
}

sub _address {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    my $edit_uri;

    my $plugin = MT->component( 'KetaiPost' );

    $edit_uri = $app->uri(
        mode => 'edit_ketaipost_author',
        args => {
            id => $obj->id,
        },
    );

    if_can_edit_ketaipost_author( $app->user, $obj ) ?
      '<a href="'. $edit_uri .'" class="mt-open-dialog">'. encode_html( $obj->address ) .'</a>' :
        $plugin->translate( '(Not Permitted)' );
}

sub _author {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    $obj->author ? $obj->author->name : ''
}

sub _enable_sync {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    my $plugin = MT->component( 'KetaiPost' );
    $obj->enable_sync ? $plugin->translate( 'Enabled' ) : $plugin->translate( 'Disabled' );
}


1;

__END__
