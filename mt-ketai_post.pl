# $Id$

package MT::Plugin::KetaiPost;

use strict;
use warnings;
use utf8;

use MT::Plugin;
use base qw( MT::Plugin );

use vars qw($PLUGIN_NAME $VERSION);
$PLUGIN_NAME = 'KetaiPost';
$VERSION = '0.2.2';

use KetaiPost::MailBox;
use KetaiPost::Author;

sub exist_module {
    my ($name) = @_;
    eval "require $name";
    return ($@ ? 0 : 1);
}

sub plugin_description {
    my @lines = ();
    push(@lines, '<div>');
    push(@lines, '携帯メールを使った記事投稿のためのプラグイン（MT5専用）。<br /><br />');
    push(@lines, '依存モジュール：');
    push(@lines, '<ul>');
    my $ref_modules = [
	['Mail::POP3Client', 0, 'メールの受信に必要です。'],
	['MIME::Tools', 0, 'メールの解析に必要です。'],
	['IO::Socket::SSL', 1, 'SSLを使ったメールの受信（Gmailなど）に必要です。'],
	['Encode::MIME::Header::ISO_2022_JP', 1, 'メールのデコードに使用します。'],
	['Image::ExifTool', 1, '一部の携帯電話が送信する写真の向きを補正するために使用します。<br />また、写真からGPS位置情報を抽出するのにも使用します。'],
	['Image::Magick', 1, '一部の携帯電話が送信する写真の向きを補正するために使用します。'],
	['Encode::JP::Emoji', 1, '絵文字変換に利用します。'],
	['Encode::JP::Emoji::FB_EMOJI_TYPECAST', 1, '絵文字変換に利用します。'],
    ];
    foreach my $ref_option(@$ref_modules) {
	my $name = $ref_option->[0];
	my $line = "<li>";
	$line .= "$name => 利用".(&exist_module($name) ? 'できます' : 'できません');
	$line .= "(Optional)" if $ref_option->[1];
	$line .= "<br />".$ref_option->[2] if $ref_option->[2];
	$line .= "</li>";
	push(@lines, $line);
    }
    push(@lines, '</ul>');
    push(@lines, '</div>');
    
    join("", @lines);
}

use MT;
my $plugin = MT::Plugin::KetaiPost->new({
    id => 'ketaipost',
    key => __PACKAGE__,
    name => $PLUGIN_NAME,
    version => $VERSION,
    description => &plugin_description,
    doc_link => '',
    author_name => 'Yuichi Takeuchi',
    author_link => 'http://takeyu-web.com/',
    schema_version => 0.03,
    object_classes => [ 'KetaiPost::MailBox', 'KetaiPost::Author' ],
    settings => new MT::PluginSettings([
	# ここから、位置情報に関する設定
	# 位置情報を使う
	# 0 継承
	# 1 使わない
	# 2 使う（地図を表示）
	['use_latlng', { Scope => 'blog', Default => 0 }],
	['use_latlng', { Scope => 'system', Default => 1 }],
	# Google Map API Key
	['gmap_key', { Scope => 'blog', Default => '' }],
	['gmap_key', { Scope => 'system', Default => '' }],
	# 地図の大きさ (XXX,YYY)
	['gmap_width', { Scope => 'blog', Default => 0 }],
	['gmap_width', { Scope => 'system', Default => 360 }],
	['gmap_height', { Scope => 'blog', Default => 0 }],
	['gmap_height', { Scope => 'system', Default => 240 }],
	# 位置情報に関する設定ここまで
	# サムネイルの形状
	# 0 継承
	# 1 そのまま縮小
	# 2 正方形（切り取り）
	['thumbnail_shape', { Scope => 'blog', Default => 0 }],
	['thumbnail_shape', { Scope => 'system', Default => 1 }],
	# サムネイルの長辺サイズ
	['thumbnail_size', { Scope => 'blog', Default => 240 }],
	['thumbnail_size', { Scope => 'system', Default => 240 }],
	# タイトル無し
	['default_subject', { Scope => 'blog', Default => '' }],
	['default_subject', { Scope => 'system', Default => '無題' }],
	# デバッグ用ログを出力
        ['use_debuglog', { Scope => 'system', Default => 0 }],
	# 削除フラグを立てない（テスト用）
	['disable_delete_flag', { Scope => 'system', Default => 0 }],
    ]),
    blog_config_template => \&blog_config_template,
    system_config_template => \&system_config_template,
    registry => {
        object_types => {
            'ketaipost_mailbox' => 'KetaiPost::MailBox',
	    'ketaipost_author' => 'KetaiPost::Author'
        },
        tasks =>  {
            'KetaiPost' => {
                label     => 'KetaiPost',
                frequency => 1 * 60 * 5,
		# frequency => 1,
                code      => \&do_ketai_post,
            },
        },
	# 管理画面
	applications => {
	    cms => {
		menus => {
		    'settings:list_ketaipost' => {
			label => 'KetaiPost',
			order => 10100,
			mode => 'list_ketaipost',
			view => 'system',
			system_permission => "administer",
		    }
		},
		methods => {
		    list_ketaipost => '$ketaipost::KetaiPost::CMS::list_ketaipost',
		    select_ketaipost_blog => '$ketaipost::KetaiPost::CMS::select_ketaipost_blog',
		    edit_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::edit_ketaipost_mailbox',
		    save_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::save_ketaipost_mailbox',
		    delete_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::delete_ketaipost_mailbox',
		    edit_ketaipost_author => '$ketaipost::KetaiPost::CMS::edit_ketaipost_author',
		    save_ketaipost_author => '$ketaipost::KetaiPost::CMS::save_ketaipost_author',
		    delete_ketaipost_author => '$ketaipost::KetaiPost::CMS::delete_ketaipost_author',
		}
	    }
	}
    },
});

MT->add_plugin($plugin);

sub instance { $plugin; }

# 機能に関するチェック ここから

# ライブラリ使用チェック
sub use_exiftool {
    my $self = shift;
    return $self->{use_exiftool} if defined($self->{use_exiftool});

    eval { require Image::ExifTool; };
    if ($@) {
	$self->{use_exiftool} = 0;
    } else {
	$self->{use_exiftool} = 1;
    }
    $self->{use_exiftool};
}

sub use_magick {
    my $self = shift;
    return $self->{use_magick} if defined($self->{use_magick});

    eval { require Image::Magick; };
    if ($@) {
	$self->{use_magick} = 0;
    } else {
	$self->{use_magick} = 1;
    }
    $self->{use_magick};
}

# 地図表示機能を利用できるか
# use_gmap($blog_id)
sub use_gmap {
    my $self = shift;
    my ($blog_id) = @_;
    $self->use_exiftool &&
      ($self->get_setting($blog_id, 'use_latlng') == 2) &&
	$self->get_setting($blog_id, 'gmap_key');
}

# 絵文字変換機能を利用できるか
# use_emoji
sub use_emoji {
    my $self = shift;
    return $self->{use_emoji} if defined($self->{use_emoji});

    eval {
	require KetaiPost::Emoji;
    };
    if ($@) {
	$self->{use_emoji} = 0;
    } else {
	$self->{use_emoji} = 1;
    }
    $self->{use_emoji};
}

# 機能に関するチェック ここまで

# 「システム」の設定値を取得
# $plugin->get_system_setting($key);
sub get_system_setting {
    my $self = shift;
    my ($value) = @_;
    my %plugin_param;

    # 連想配列 %plugin_param にシステムの設定リストをセット
    $self->load_config(\%plugin_param, 'system');

    $plugin_param{$value}; # 設定の値を返す
}

# 「ブログ/ウェブサイト」の設定値を取得
# ウェブサイトはブログのサブクラス。
# $plugin->get_blog_setting($blog_id, $key);
sub get_blog_setting {
    my $self = shift;
    my ($blog_id, $key) = @_;
    my %plugin_param;

    $self->load_config(\%plugin_param, 'blog:'.$blog_id);

    $plugin_param{$key};
}

# 指定のブログがウェブサイトに属する場合、その設定値を返す
# ウェブサイトが見つからない場合は、undef を返す
# $value = $plugin->get_website_setting($blog_id);
# if(defined($value)) ...
sub get_website_setting {
    my $self = shift;
    my ($blog_id, $key, $ctx) = @_;

    require MT::Blog;
    require MT::Website;
    my $blog = MT::Blog->load($blog_id);
    return undef unless (defined($blog) && $blog->parent_id);
    my $website = MT::Website->load($blog->parent_id);
    return undef unless (defined($website));

    $self->get_blog_setting($website->id, $key);
}

# ブログ -> ウェブサイト -> システム の順に設定を確認
sub get_setting {
    my $self = shift;
    my ($blog_id, $key) = @_;

    my $website_value = $self->get_website_setting($blog_id, $key);
    my $value = $self->get_blog_setting($blog_id, $key);
    if ($value) {
	return $value;
    } elsif (defined($website_value)) {
	return $website_value || $self->get_system_setting($key);;
    }
    $self->get_system_setting($key);
}

use MT::Log;

sub write_log {
    my $self = shift;
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
    my $self = shift;
    my ($msg, $ref_options) = @_;
    $self->write_log($msg, $ref_options);
}

sub log_debug {
    my $self = shift;
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    return unless instance->get_system_setting('use_debuglog');
    
    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::DEBUG,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    $self->write_log('[debug]'.$msg, $ref_options);
}

sub log_error {
    my $self = shift;
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    
    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::ERROR,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    $self->write_log('[error]'.$msg, $ref_options);
}

sub blog_config_template {
    my $tmpl = <<'EOT';
<mtapp:setting id="geo" label="GPS位置情報:">
  <mtapp:setting id="use_latlng" label="GPS位置情報:">
    <mt:if name="use_latlng" eq="2">
      <input type="radio" id="use_latlng_2" name="use_latlng" value="2" checked="checked" /><label for="use_latlng_2">する</label>&nbsp;
      <input type="radio" id="use_latlng_1" name="use_latlng" value="1" /><label for="use_latlng_1">しない</label>&nbsp;
      <input type="radio" id="use_latlng_0" name="use_latlng" value="0" /><label for="use_latlng_0">親の設定を継承</label><br />
      「する」に設定すると、写真データに位置情報が埋め込まれている場合に地図を表示します。（オプションモジュール Image::ExifTool が必要です）
    </mt:if>
    <mt:if name="use_latlng" eq="1">
      <input type="radio" id="use_latlng_2" name="use_latlng" value="2" /><label for="use_latlng_2">する</label>&nbsp;
      <input type="radio" id="use_latlng_1" name="use_latlng" value="1" checked="checked" /><label for="use_latlng_1">しない</label>&nbsp;
      <input type="radio" id="use_latlng_0" name="use_latlng" value="0" /><label for="use_latlng_0">親の設定を継承</label><br />
      「する」に設定すると、写真データに位置情報が埋め込まれている場合に地図を表示します。（オプションモジュール Image::ExifTool が必要です）
    </mt:if>
    <mt:unless name="use_latlng">
      <input type="radio" id="use_latlng_2" name="use_latlng" value="2" /><label for="use_latlng_2">する</label>&nbsp;
      <input type="radio" id="use_latlng_1" name="use_latlng" value="1" /><label for="use_latlng_1">しない</label>&nbsp;
      <input type="radio" id="use_latlng_0" name="use_latlng" value="0" checked="checked" /><label for="use_latlng_0">親の設定を継承</label><br />
      「する」に設定すると、写真データに位置情報が埋め込まれている場合に地図を表示します。（オプションモジュール Image::ExifTool が必要です）
    </mt:unless>
  </mtapp:setting>
  <mtapp:setting id="gmap_key" label="Google Map API Key:">
    <input type="text" name="gmap_key" value="<mt:var name="gmap_key" encode_html="1" />" class="full-width" /><br />
    地図の表示に使用します。<br />
    空白の場合は、ブログ -> ウェブサイト -> システム の優先度で利用します。
  </mtapp:setting>
  <mtapp:setting id="gmap_size" label="地図のサイズ:">
    <input type="text" name="gmap_width" value="<mt:var name="gmap_width" encode_html="1" />" style="width: 50px;" /> × <input type="text" name="gmap_height" value="<mt:var name="gmap_height" encode_html="1" />" style="width: 50px;" /><br />
  空白または0場合は、ブログ -> ウェブサイト -> システム の優先度で利用します。
  </mtapp:setting>
</mtapp:setting>
<mtapp:setting id="thumbnail_shape" label="サムネイルの形状:">
  <mt:if name="thumbnail_shape" eq="2">
    <input type="radio" id="thumbnail_shape_2" name="thumbnail_shape" value="2" checked="checked" /><label for="thumbnail_shape_2">正方形（切り取り）</label>&nbsp;
    <input type="radio" id="thumbnail_shape_1" name="thumbnail_shape" value="1" /><label for="thumbnail_shape_1">縦横比率を維持して縮小</label>&nbsp;
    <input type="radio" id="thumbnail_shape_0" name="thumbnail_shape" value="0" /><label for="thumbnail_shape_0">親の設定を継承</label>
  </mt:if>
  <mt:if name="thumbnail_shape" eq="1">
    <input type="radio" id="thumbnail_shape_2" name="thumbnail_shape" value="2" /><label for="thumbnail_shape_2">正方形（切り取り）</label>&nbsp;
    <input type="radio" id="thumbnail_shape_1" name="thumbnail_shape" value="1" checked="checked" /><label for="thumbnail_shape_1">縦横比率を維持して縮小</label>&nbsp;
    <input type="radio" id="thumbnail_shape_0" name="thumbnail_shape" value="0" /><label for="thumbnail_shape_0">親の設定を継承</label>
  </mt:if>
  <mt:unless name="thumbnail_shape">
    <input type="radio" id="thumbnail_shape_2" name="thumbnail_shape" value="2" /><label for="thumbnail_shape_2">正方形（切り取り）</label>&nbsp;
    <input type="radio" id="thumbnail_shape_1" name="thumbnail_shape" value="1" /><label for="thumbnail_shape_1">縦横比率を維持して縮小</label>&nbsp;
    <input type="radio" id="thumbnail_shape_0" name="thumbnail_shape" value="0" checked="checked" /><label for="thumbnail_shape_0">親の設定を継承</label>
  </mt:unless>
</mtapp:setting>
<mtapp:setting id="thumbnail_size" label="サムネイルの長辺の長さ:">
  <input type="text" name="thumbnail_size" value="<mt:var name="thumbnail_size" encode_html="1" />" style="width: 50px;" /> ピクセル<br />
  空白または0の場合は、ブログ -> ウェブサイト -> システム の優先度で利用します。
</mtapp:setting>
<mtapp:setting id="default_subject" label="デフォルトの記事タイトル:">
  <input type="text" name="default_subject" value="<mt:var name="default_subject" encode_html="1" />" class="full-width" /><br />
  空白の場合は、ブログ -> ウェブサイト -> システム の優先度で利用します。
</mtapp:setting>
EOT
}

sub system_config_template {
    my $tmpl = <<'EOT';
<mtapp:setting id="geo" label="GPS位置情報:">
  <mtapp:setting id="use_latlng" label="地図表示:">
    <mt:if name="use_latlng" eq="2">
      <input type="radio" id="use_latlng_2" name="use_latlng" value="2" checked="checked" /><label for="use_latlng_2">する</label>&nbsp;
      <input type="radio" id="use_latlng_1" name="use_latlng" value="1" /><label for="use_latlng_1">しない</label><br />
      「する」に設定すると、写真データに位置情報が埋め込まれている場合に地図を表示します。（オプションモジュール Image::ExifTool が必要です）
    </mt:if>
    <mt:if name="use_latlng" eq="1">
      <input type="radio" id="use_latlng_2" name="use_latlng" value="2" /><label for="use_latlng_2">する</label>&nbsp;
      <input type="radio" id="use_latlng_1" name="use_latlng" value="1" checked="checked" /><label for="use_latlng_1">しない</label><br />
      「する」に設定すると、写真データに位置情報が埋め込まれている場合に地図を表示します。（オプションモジュール Image::ExifTool が必要です）
    </mt:if>
  <mt:unless name="use_latlng">
      <input type="radio" id="use_latlng_2" name="use_latlng" value="2" /><label for="use_latlng_2">する</label>&nbsp;
      <input type="radio" id="use_latlng_1" name="use_latlng" value="1" /><label for="use_latlng_1">しない</label><br />
      「する」に設定すると、写真データに位置情報が埋め込まれている場合に地図を表示します。（オプションモジュール Image::ExifTool が必要です）
    </mt:unless>
  </mtapp:setting>
  <mtapp:setting id="gmap_key" label="Google Map API Key:">
    <input type="text" name="gmap_key" value="<mt:var name="gmap_key" encode_html="1" />" class="full-width" /><br />
    地図の表示に使用します。
  </mtapp:setting>
  <mtapp:setting id="gmap_size" label="地図のサイズ:">
    <input type="text" name="gmap_width" value="<mt:var name="gmap_width" encode_html="1" />" style="width: 50px;" /> × <input type="text" name="gmap_height" value="<mt:var name="gmap_height" encode_html="1" />" style="width: 50px;" />
  </mtapp:setting>
</mtapp:setting>
<mtapp:setting id="thumbnail_shape" label="サムネイルの形状:">
  <mt:if name="thumbnail_shape" eq="2">
    <input type="radio" id="thumbnail_shape_2" name="thumbnail_shape" value="2" checked="checked" /><label for="thumbnail_shape_2">正方形（切り取り）</label>&nbsp;
    <input type="radio" id="thumbnail_shape_1" name="thumbnail_shape" value="1" /><label for="thumbnail_shape_1">縦横比率を維持して縮小</label>
  <mt:else>
    <input type="radio" id="thumbnail_shape_2" name="thumbnail_shape" value="2" /><label for="thumbnail_shape_2">正方形（切り取り）</label>&nbsp;
    <input type="radio" id="thumbnail_shape_1" name="thumbnail_shape" value="1" checked="checked" /><label for="thumbnail_shape_1">縦横比率を維持して縮小</label>
  </mt:if>
</mtapp:setting>
<mtapp:setting id="thumbnail_size" label="サムネイルの長辺の長さ:">
  <input type="text" name="thumbnail_size" value="<mt:var name="thumbnail_size" encode_html="1" />" style="width: 50px;" /> ピクセル
</mtapp:setting>
<mtapp:setting id="default_subject" label="デフォルトの記事タイトル:">
  <input type="text" name="default_subject" value="<mt:var name="default_subject" encode_html="1" />" class="full-width" />
</mtapp:setting>
<mtapp:setting id="use_debuglog" label="デバッグログ出力:">
  <mt:if name="use_debuglog">
    <input type="radio" id="use_debuglog_1" name="use_debuglog" value="1" checked="checked" /><label for="use_debuglog_1">する</label>&nbsp;
    <input type="radio" id="use_debuglog_0" name="use_debuglog" value="0" /><label for="use_debuglog_0">しない</label>
  <mt:else>
    <input type="radio" id="use_debuglog_1" name="use_debuglog" value="1" /><label for="use_debuglog_1">する</label>&nbsp;
    <input type="radio" id="use_debuglog_0" name="use_debuglog" value="0" checked="checked" /><label for="use_debuglog_0">しない</label>
  </mt:if>
</mtapp:setting>
<mtapp:setting id="disable_delete_flag" label="受信後サーバから削除:">
  <mt:if name="disable_delete_flag">
    <input type="radio" id="disable_delete_flag_0" name="disable_delete_flag" value="0" /><label for="disable_delete_flag_0">する</label>&nbsp;
    <input type="radio" id="disable_delete_flag_1" name="disable_delete_flag" value="1" checked="checked" /><label for="disable_delete_flag_1">しない</label>
  <mt:else>
    <input type="radio" id="disable_delete_flag_0" name="disable_delete_flag" value="0" checked="checked" /><label for="disable_delete_flag_0">する</label>&nbsp;
    <input type="radio" id="disable_delete_flag_1" name="disable_delete_flag" value="1" /><label for="disable_delete_flag_1">しない</label>
  </mt:if>
  <br />「しない」場合、メールが削除されないので繰り返し投稿されます。（デバッグ用）
</mtapp:setting>
EOT
}

#----- Task

sub do_ketai_post {
    require KetaiPost::Task;
    my $task = KetaiPost::Task->new(instance);
    $task->run;
}

1;
