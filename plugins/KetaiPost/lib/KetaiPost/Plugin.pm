package KetaiPost::Plugin;

use strict;
use warnings;

use utf8;

use lib $ENV{MT_HOME} ? "$ENV{MT_HOME}/plugins/KetaiPost/extlib" : 'plugins/KetaiPost/extlib';

use MT;
use MT::Util qw( encode_html );
use KetaiPost::Util qw( if_can_administer_blog get_system_setting log_debug
                        if_can_edit_ketaipost_author if_can_edit_mailboxes if_can_view_mailbox_addresses
                        if_module_exists get_module_version get_module_error );

our $plugin = MT->component( 'KetaiPost' );

sub check_view_mailbox_addresses_permission {
    my ( $blog ) = @_;
    my $app = MT->instance;
    if_can_edit_mailboxes( $app->user, $blog );
    if_can_view_mailbox_addresses( $app->user, $blog );
}

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
    unless ( MT->config->KetaiPostSkipPeriodicTasks ) {
        require KetaiPost::Task;
        KetaiPost::Task->new()->run();
    }
    1;
}

sub description {
    my @lines = ();
    push(@lines, '<div>');
    push(@lines, '携帯メールを使った記事投稿のためのプラグイン（MT5.1専用）。<br /><br />');
    push(@lines, '依存モジュール：');
    push(@lines, '<ul>');

    my $ref_modules = [
        ['Mail::POP3Client', 0, 'メールの受信に必要です。'],
        ['MIME::Parser', 0, 'メールの解析に必要です。（MIME::Toolsに含まれます）'],
        ['File::Temp', 0, 'MIME::Toolsに必要ですが、バージョンの組み合わせによっては互換性がなく、MIME::Tools（MIME::Parser）が動作しません。'],
        ['IO::Socket::SSL', 1, 'SSLを使ったメールの受信（Gmailなど）に必要です。'],
        ['Encode::MIME::Header::ISO_2022_JP', 1, 'メールのデコードに使用します。'],
        ['Image::ExifTool', 1, '一部の携帯電話が送信する写真の向きを補正するために使用します。<br />また、写真からGPS位置情報を抽出するのにも使用します。'],
        ['Image::Magick', 1, '一部の携帯電話が送信する写真の向きを補正するために使用します。'],
        ['Encode::JP::Emoji', 1, '絵文字変換に利用します。'],
        ['Encode::JP::Emoji::FB_EMOJI_TYPECAST', 1, '絵文字変換に利用します。'],
        ['Text::Xatena', 1, 'はてな記法っぽい記法を利用する場合に必要です。'],
    ];
    for ( my $i=0; $i<@$ref_modules; $i++ ) {
        my $ref_option = $ref_modules->[$i];
        my $name = $ref_option->[0];
        my $err = get_module_error($name);
        my $errid = 'ketaipost-module-err'.$i;
        my $line = '<li>';
        $line .= "$name => 利用".(if_module_exists( $name ) ? 'できます(バージョン:'.get_module_version($name).')'  : 'できません(<a href="javascript:void(0);" onclick="jQuery(\'#'.$errid.'\').slideToggle(\'fast\'); return false;">エラーメッセージ</a>)');
        $line .= "(Optional)" if $ref_option->[1];
        $line .= "<p>@{[ $ref_option->[2] ]}" if $ref_option->[2];
        if ( $err ) {
            $err =~ s/\r?\n/<br>/g;
            $line .= '<div id="'.$errid.'" style="display: none; border: 1px solid #CCC; background-color: #EFEFEF; padding: 5px; font-size: 0.9em; color: #666;">'.$err.'</div>';
        }
        $line .= "</li>";
        push(@lines, $line);
    }
    push(@lines, '</ul>');
    push(@lines, '</div>');
    
    join("", @lines) . "<br />依存モジュールは MT_DIR/extlib のほか、plugins/KetaiPost/extlib に置いても動くようになりました。";
}

1;
