package KetaiPost::Plugin;

use strict;
use warnings;

use MT;
use MT::Util qw( encode_html );
use KetaiPost::Util qw( if_can_administer_blog get_system_setting log_debug
                        if_can_edit_ketaipost_author if_can_edit_mailboxes );

our $plugin = MT->component( 'KetaiPost' );

sub check_permission {
    my ( $blog ) = @_;
    my $app = MT->instance;
    if_can_edit_mailboxes( $app->user, $blog );
}

sub check_list_ketaipost_author_permission {
    my ( $blog ) = @_;
    my $app = MT->instance;
    return 1 if check_permission( $blog );

    my $perms = MT->model( 'permission' )->count( {
        author_id => $app->user->id,
        blog_id => {
            not => 0
        },
        permissions => {
            like => "%'administer_%"
        }
    } );
    return $perms;
}

sub update_null_columns {
    my $app = MT->instance;
    my $iter = MT->model( 'ketaipost_author' )->load_iter({ enable_sync => \'IS NULL' });
    while ( my $author = $iter->() ) {
        $author->enable_sync( 0 );
        $author->save
          or return $app->error( $author->errstr );
    }

    1;
}

sub hdlr_task {
    require KetaiPost::Task;
    KetaiPost::Task->new()->run();
    1;
}

1;
