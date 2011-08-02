# KetaiPost (C) 2010 Yuichi Takeuchi
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id: MailBox.pm $


package KetaiPost::MailBox;
use warnings;
use strict;
use Carp;

use MT::Util qw( encode_html );
use KetaiPost::Util qw( if_can_administer_blog get_system_setting log_debug
                        if_can_edit_mailboxes if_can_edit_ketaipost_author );


use MT::Object;
@KetaiPost::MailBox::ISA = qw( MT::Object );

__PACKAGE__->install_properties ({
    column_defs => {
        'id' => 'integer not null auto_increment',
        'blog_id' => 'integer not null',
        'category_id' => 'integer',
        'address' => 'string(255) not null',
        'account' => 'string(255) not null',
        'password' => 'string(255) not null',
        'host' => 'string(255) not null',
        'port' => 'integer not null',
        'use_ssl' => 'boolean',
        'use_apop' => 'boolean',
    },
    indexes => {
    },
    child_of => 'MT::Blog',
    datasource => 'ketaipost_mailbox',
    #audit => 1,
    primary_key => 'id',
});

sub blog {
    my $self = shift;
    defined $self->blog_id ? MT->model( 'blog' )->load( $self->blog_id ) : undef;
}

sub list_properties {
    my $app = MT->instance;
    my $props = {
        address => {
            auto => 1,
            order => 100,
            label => 'Mail Address',
            display => 'force',
            html => sub { _address( @_ ); }
        },
        account => {
            auto    => 1,
            order => 200,
            label => 'Mail Account',
            condition => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
        },
        host => {
            auto    => 1,
            order => 300,
            label => 'Host',
            condition => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
        },
        port => {
            auto    => 1,
            order => 400,
            label => 'Port',
            condition => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
        },
        use_ssl => {
            auto => 1,
            order => 500,
            label => 'SSL',
            condition => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
            html => sub { _use_ssl( @_ ); }
        },
        use_apop => {
            auto => 1,
            order => 600,
            label => 'APOP',
            condition => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
            html => sub { _use_apop( @_ ); }
        },
        category_id => {
            auto => 1,
            base  => '__virtual.string',
            order => 10000,
            label => 'Category',
            display => 'force',
            html => sub { _category( @_ ); }
        },
    };
}

sub list_actions {
    my $app = MT->instance;
    my $actions = {
        'delete' => {
            button      => 1,
            label       => 'Delete',
            mode        => 'delete',
            class       => 'icon-action',
            return_args => 1,
            args        => { _type => 'ketaipost_mailbox' },
            order       => 300,
            condition   => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
        },
        check => {
            label => 'Mail Check',
            button => 1,
            mode => 'check_ketaipost_mailbox',
            args        => { _type => 'ketaipost_mailbox' },
            class       => 'icon-action',
            return_args => 1,
            order       => 900,
            condition   => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
        },
    };
    return $actions;
}

sub content_actions {
    my ( $meth, $component ) = @_;

    my $app = MT->instance;

    return {
        'new' => {
            mode => 'select_ketaipost_blog',
            class => 'icon-create',
            label => 'Add Mailbox',
            return_args => 1,
            order => 100,
            args => {
                _type => 'ketaipost_mailbox'
            },
            condition   => sub { if_can_edit_mailboxes( $app->user, $app->blog ); },
        },
    };
}

sub _address {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    my $edit_uri;

    if ( if_can_edit_mailboxes( $app->user, $app->blog ) ) {
        $edit_uri = $app->uri(
            mode => 'select_ketaipost_blog',
            args => {
                id => $obj->id,
                blog_id => $obj->blog_id,
            },
        );
        
        '<a href="'. $edit_uri .'" class="mt-open-dialog">'. encode_html( $obj->address ) .'</a>';
    } else {
        encode_html( $obj->address )
    }
}

sub _category {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    my $category = MT::Category->load($obj->category_id);
    $category ? $category->label : '';
}

sub _use_ssl {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    my $plugin = MT->component( 'KetaiPost' );
    $obj->use_ssl ? $plugin->translate( 'Yes' ) : $plugin->translate( 'No' );
}

sub _use_apop {
    my $prop = shift;
    my ( $obj, $app, $opts ) = @_;
    my $plugin = MT->component( 'KetaiPost' );
    $obj->use_apop ? $plugin->translate( 'Yes' ) : $plugin->translate( 'No' );
}

1;

__END__
