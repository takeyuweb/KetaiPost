package KetaiPost::Util;

use strict;
use base 'Exporter';

our @EXPORT_OK = qw( log_debug log_info log_error log_security get_blog_setting get_website_setting get_system_setting get_setting
                     use_exiftool use_magick use_gmap use_emoji use_ffmpeg use_escape use_xatena use_notify if_can_administer_blog
                     update_or_create_ketaipost_author if_can_edit_ketaipost_author if_can_edit_mailboxes if_can_view_mailbox_addresses
                     if_can_on_blog if_module_exists get_module_version get_module_error );

use MT;
use MT::Log;

our $plugin = MT->component( 'KetaiPost' );


# 機能に関するチェック ここから

sub if_module_exists {
    my ($name) = @_;
    eval "require $name";
    return ($@ ? 0 : 1);
}

sub get_module_version {
    my ($name) = @_;
    if_module_exists( $name ) ? eval "require $name; return \$@{[$name]}::VERSION;" : undef;
}

sub get_module_error {
    my ($name) = @_;
    return undef if if_module_exists( $name );
    eval "use $name;";
    return $@;
}

# ライブラリ使用チェック
sub use_exiftool {
    return $plugin->{use_exiftool} if defined($plugin->{use_exiftool});

    eval { require Image::ExifTool; };
    if ($@) {
    $plugin->{use_exiftool} = 0;
    } else {
    $plugin->{use_exiftool} = 1;
    }
    $plugin->{use_exiftool};
}

sub use_magick {
    return $plugin->{use_magick} if defined($plugin->{use_magick});

    eval { require Image::Magick; };
    if ($@) {
    $plugin->{use_magick} = 0;
    } else {
    $plugin->{use_magick} = 1;
    }
    $plugin->{use_magick};
}

# 地図表示機能を利用できるか
# use_gmap($blog_id)
sub use_gmap {
    my ($blog_id) = @_;
    my $use_latlng = get_setting($blog_id, 'use_latlng');
    use_exiftool && defined $use_latlng && $use_latlng == 2 && get_setting($blog_id, 'gmap_key');
}

# 絵文字変換機能を利用できるか
# use_emoji
sub use_emoji {
    return $plugin->{use_emoji} if defined($plugin->{use_emoji});

    eval {
    require KetaiPost::Emoji;
    };
    if ($@) {
    $plugin->{use_emoji} = 0;
    } else {
    $plugin->{use_emoji} = 1;
    }
    $plugin->{use_emoji};
}

sub use_ffmpeg {
    my ($blog_id) = @_;
    return $plugin->{use_ffmpeg} if defined($plugin->{use_ffmpeg});

    my $path;
    if(get_system_setting('ffmpeg_path') =~ /(\S+)\s*$/) {
    $path = $1;
    }

    if (-f $path && get_setting($blog_id, 'use_ffmpeg') == 2) {
    $plugin->{use_ffmpeg} = 1;
    } else {
    $plugin->{use_ffmpeg} = 0;
    }
    $plugin->{use_ffmpeg};
}

# HTMLエスケープを行うか
sub use_escape {
    my ($blog_id) = @_;
    return $plugin->{enable_escape} if defined($plugin->{enable_escape});


    if (get_setting($blog_id, 'enable_escape') == 2) {
        $plugin->{enable_escape} = 1;
    } else {
        $plugin->{enable_escape} = 0;
    }
    $plugin->{enable_escape};
}

# はてな記法を使うか
sub use_xatena {
    my ($blog_id) = @_;
    return $plugin->{enable_xatena} if defined($plugin->{enable_xatena});

    if (get_setting($blog_id, 'enable_xatena') == 2) {
        $plugin->{enable_xatena} = 1;
    } else {
        $plugin->{enable_xatena} = 0;
    }
    $plugin->{enable_xatena};
}

# 公開通知
sub use_notify {
    my ($blog_id) = @_;
    my $app = MT->instance;
    return 0 unless $app->config->EnableAddressBook;

    return $plugin->{enable_notify} if defined($plugin->{enable_notify});

    if (get_setting($blog_id, 'enable_notify') == 2) {
        $plugin->{enable_notify} = 1;
    } else {
        $plugin->{enable_notify} = 0;
    }

    $plugin->{enable_notify};
}

# 機能に関するチェック ここまで

# 「システム」の設定値を取得
# get_system_setting($key);
sub get_system_setting {
    my ($value) = @_;
    my %plugin_param;
    # 連想配列 %plugin_param にシステムの設定リストをセット
    $plugin->load_config(\%plugin_param, 'system');
    
    $plugin_param{ 'sys_' . $value }; # 設定の値を返す
}

# 「ブログ/ウェブサイト」の設定値を取得
# ウェブサイトはブログのサブクラス。
# get_blog_setting($blog_id, $key);
sub get_blog_setting {
    my ($blog_id, $key) = @_;
    my %plugin_param;

    $plugin->load_config(\%plugin_param, 'blog:'.$blog_id);

    $plugin_param{$key};
}

# 指定のブログがウェブサイトに属する場合、その設定値を返す
# ウェブサイトが見つからない場合は、undef を返す
# $value = get_website_setting($blog_id);
# if(defined($value)) ...
sub get_website_setting {
    my ($blog_id, $key, $ctx) = @_;

    require MT::Blog;
    require MT::Website;
    my $blog = MT::Blog->load($blog_id);
    return undef unless (defined($blog) && $blog->parent_id);
    my $website = MT::Website->load($blog->parent_id);
    return undef unless (defined($website));

    get_blog_setting($website->id, $key);
}

# ブログ -> ウェブサイト -> システム の順に設定を確認
sub get_setting {
    my ($blog_id, $key) = @_;

    my $website_value = get_website_setting($blog_id, $key);
    my $value = get_blog_setting($blog_id, $key);
    if ($value) {
        return $value;
    } elsif (defined($website_value)) {
        return $website_value || get_system_setting($key);;
    }
    get_system_setting($key);
}

sub write_log {
    my ($msg, $ref_options) = @_; 
    return unless defined($msg);

    $ref_options ||= {};
    my $ref_default_options = {
        level => MT::Log::INFO,
    };

    $ref_options = {%{$ref_default_options}, %{$ref_options}};
    $ref_options->{message} = '[KetaiPost]'.$msg;

    
    MT->log($ref_options);
}

sub log_info {
    my ($msg, $ref_options) = @_;
    write_log($msg, $ref_options);
}

sub log_debug {
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    return unless get_system_setting('use_debuglog');
    
    $ref_options ||= {};
    my $ref_default_options = {
        level => MT::Log::DEBUG,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    write_log($msg, $ref_options);
}

sub log_error {
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    
    $ref_options ||= {};
    my $ref_default_options = {
    level => MT::Log::ERROR,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    write_log($msg, $ref_options);
}

sub log_security {
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    
    $ref_options ||= {};
    my $ref_default_options = {
        level => MT::Log::SECURITY(),
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    write_log($msg, $ref_options);
}


sub if_can_administer_blog {
    my ( $user, $blog ) = @_;

    if ( $blog && ( ref $blog ne 'MT::Blog' ) ) {
        $blog = undef;
    }
    return 0 unless $blog;

    return 1 if $user->is_superuser;

    return 0 unless my $perm = $user->permissions( $blog->id );

    return 1 if $perm->can_administer_website;
    return 1 if $perm->can_administer_blog;

    return 0;
}

sub if_can_edit_ketaipost_author {
    my ( $user, $ketaipost_author ) = @_;
    my $can_edit_ketaipost_author = 0;
    if ( $user->is_superuser ) {
        $can_edit_ketaipost_author = 1;
    } else {
        my @blogs;
        my $iter = $ketaipost_author->author->blog_iter;
        while( my $blog = $iter->() ) {
            push @blogs, $blog;
        }
        my $user_blog_iter = $user->blog_iter;
        while( my $blog = $user_blog_iter->() ) {
            next unless $user->can_do('administer_blog', at_least_one => 1, blog_id => $blog->id) ||
              $user->can_do('administer_website', at_least_one => 1, blog_id => $blog->id);
            if ( grep { $_->id == $blog->id } @blogs ) {
                $can_edit_ketaipost_author = 1;
                last;
            }
        }
    }
    return $can_edit_ketaipost_author;
}

sub update_or_create_ketaipost_author {
    my ( $app, $obj, $options ) = @_;
    $options ||= {};

    return 1 unless $obj && ref($obj) eq 'MT::Author';
    
    my $class = MT->model( 'ketaipost_author' );

    my $ketaipost_author = $class->load({
        author_id => $obj->id,
        enable_sync => 1,
    });
    
    my $created = 0;
    unless ( defined $ketaipost_author ) {
        return 1 unless get_system_setting( 'sync_authors' ) || $options->{force_create};

        $ketaipost_author = $class->new;
        $ketaipost_author->author_id( $obj->id );
        $ketaipost_author->enable_sync( 1 );
        $created = 1;
    }
    return 1 if $obj->email eq $ketaipost_author->address;
    
    $ketaipost_author->address( $obj->email );
    $ketaipost_author->save
      or return $app->error( $ketaipost_author->errstr );

    log_debug( $obj->name . "'s KetaiPost Author @{[ $created ? 'Created' : 'Updated' ]}.(".$obj->email.')' );
    
    return 1;
}

# 指定のブログのメールボックス編集権限があるか
sub if_can_edit_mailboxes {
    my ( $user, $blog ) = @_;
    my $app = MT->instance();

    if ( $blog && ( ref $blog ne 'MT::Blog' ) ) {
        $blog = undef;
    }
    $blog = $app->blog unless $blog;
    return 1 if $user->is_superuser;

    if_can_administer_blog( $user, $blog );
}

# 受付先メールアドレス一覧を表示できるか
sub if_can_view_mailbox_addresses {
    my ( $user, $blog ) = @_;
    my $app = MT->instance();

    if ( $blog && ( ref $blog ne 'MT::Blog' ) ) {
        $blog = undef;
    }
    $blog = $app->blog unless $blog;
    return 1 if $user->is_superuser;

    return 1 if if_can_administer_blog( $user, $blog );
    
    if_can_on_blog( $user, $blog, 'create_post' );
}

# 指定のブログで指定の操作が可能か
# if_can_on_blog( $user, $blog, 'create_post' );
sub if_can_on_blog {
    my ( $user, $blog, $action ) = @_;
    return 0 unless $blog;
    my $perms = MT::Permission->load({
        blog_id => $blog->id,
        author_id => $user->id});
    $perms && $perms->can_do( $action );
}


1;
