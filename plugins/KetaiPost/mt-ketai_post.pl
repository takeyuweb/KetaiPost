# $Id$

package MT::Plugin::KetaiPost;

use strict;
use warnings;
use utf8;

use MT::Plugin;
use base qw( MT::Plugin );

use vars qw($PLUGIN_NAME $VERSION);
$PLUGIN_NAME = 'KetaiPost';
$VERSION = '0.1';

use Encode;
use Encode::Guess qw/euc-jp shiftjis 7bit-jis/;
use File::Basename;
use File::Spec;

use MIME::Base64::Perl;
use Net::POP3;
use MIME::Parser;

use MT::Log;
use MT::Image;
use MT::Asset::Image;
use MT::Blog;
use MT::Author;
use MT::ConfigMgr;
use MT::App::CMS;
use MT::WeblogPublisher;

use KetaiPost::MailBox;
use KetaiPost::Author;

use MT;
my $plugin = MT::Plugin::KetaiPost->new({
    id => 'ketaipost',
    key => __PACKAGE__,
    name => $PLUGIN_NAME,
    version => $VERSION,
    description => "携帯メールを使った記事投稿のためのプラグイン。",
    doc_link => '',
    author_name => 'Yuichi Takeuchi',
    author_link => 'http://takeyu-web.com/',
    schema_version => 0.01,
    object_classes => [ 'KetaiPost::MailBox', 'KetaiPost::Author' ],
    settings => new MT::PluginSettings([
	['default_subject', { Scope => 'blog', Default => '' }],
	['default_subject', { Scope => 'system', Default => '無題' }],
        ['use_debuglog', { Scope => 'system', Default => 0 }],
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
                # frequency => 1 * 60 * 60,   # no more than every 1 hours
		frequency => 1,
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
		    edit_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::edit_ketaipost_mailbox',
		    save_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::save_ketaipost_mailbox',
		    delete_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::delete_ketaipost_mailbox',
		    edit_ketaipost_author => '$ketaipost::KetaiPost::CMS::edit_ketaipost_author',
		    save_ketaipost_author => '$ketaipost::KetaiPost::CMS::save_ketaipost_author',
		    delete_ketaipost_authr => '$ketaipost::KetaiPost::CMS::delete_ketaipost_author',
		}
	    }
	}
    },
});

MT->add_plugin($plugin);

sub instance { $plugin; }

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
    &write_log($msg, $ref_options);
}

sub log_debug {
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    return unless &instance->get_system_setting('use_debuglog');
    
    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::DEBUG,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    &write_log('[debug]'.$msg, $ref_options);
}

sub log_error {
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    
    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::ERROR,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    &write_log('[error]'.$msg, $ref_options);
}

sub blog_config_template {
    my $tmpl = <<'EOT';
<mtapp:setting id="default_subject" label="デフォルトの記事タイトル:">
  <input type="text" name="default_subject" value="<mt:var name="default_subject" encode_html="1" />" class="full-width" /><br />
  ブログ -> ウェブサイト -> システム の順で優先されます。
</mtapp:setting>
EOT
}

sub system_config_template {
    my $tmpl = <<'EOT';
<mtapp:setting id="default_subject" label="デフォルトの記事タイトル:">
  <input type="text" name="default_subject" value="<mt:var name="default_subject" encode_html="1" />" class="full-width" /><br />
  ブログ -> ウェブサイト -> システム の順で優先されます。
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
EOT
}

#----- Task
sub do_ketai_post {
    &log_debug("do_ketai_post");

    my $app = MT::App::CMS->new;
    my $cfg = MT::ConfigMgr->instance;

    my $mailboxes_iter = KetaiPost::MailBox->load_iter({}, {});
    while (my $mailbox = $mailboxes_iter->()) {
	my $blog = MT::Blog->load($mailbox->blog_id);

	my $address = $mailbox->address;
	my $host = $mailbox->host;
	my $account = $mailbox->account;
	my $password = $mailbox->password;
	my $port = $mailbox->port;
	my $protocol = 'pop3';

	next unless $host && $port && $account && $password;
	
	&log_debug("$address(host:$host account:$account)");
	my $pop3 = Net::POP3->new($host.':'.$port, Timeout => 120) or die "Can't open POP3 host.";
	my $login = (lc($protocol) eq 'apop') ? 'apop' : 'login';
	my $count = $pop3->$login($account, $password);
	
	&log_debug("ログインしました。");
	
	# メールID/サイズのハッシュリファレンスを取得
	my $messages = $pop3->list();
	
	foreach my $id (sort (keys %{$messages})) {
	    my $message = $pop3->get($id);
	    
	    my $ref_data = parse_data($message, { To => $address });
	    next unless $ref_data;

	    my $assign = KetaiPost::Author->load({ address => $ref_data->{from} });
	    $assign ||= KetaiPost::Author->load({ address => '' });
	    unless ($assign) {
		&log_error("unknown author (".$ref_data->{from}.")", blog_id => $blog->id);
		next;
	    }
	    my $author = MT::Author->load({ id => $assign->author_id });

	    &log_debug("author: ".$author->name);
	    &log_debug("subject: ".$ref_data->{subject}."\nbody:\n".$ref_data->{text});
	    my $ref_images = $ref_data->{images};
	    foreach my $ref_image(@$ref_images) {
		&log_debug("filename: ".$ref_image->{filename});
	    }

	    # 権限のチェック
	    my $perms = MT::Permission->load({blog_id => $blog->id, author_id => $author->id});
	    unless ($perms && $perms->can_post) {
		log_error("記事の追加を試みましたが権限がありません。", {
		    blog_id => $blog->id,
		    author_id => $author->id
		});
		next;
	    }

	    # 記事登録
	    my ($subject, $text) = ($ref_data->{subject}, $ref_data->{text});
	    $subject = &instance->get_setting($blog->id, 'default_subject') || '無題' unless ($subject);
	    $text = MT::Util::encode_html($text);
	    $text =~ s/\r\n/\n/g;
	    $text =~ s/\n/<br \/>/g;
	    my $entry = create_entry($blog, $author, $subject, $text);
	    next unless $entry;
	    
	    # 写真がない場合はこれで再構築して終わる
	    unless(@$ref_images) {
		&rebuild_entry_page($entry);
		next;
	    }

	    $entry->created_on =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/;
	    my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
	    
	    # 添付写真の保存
	    # ファイルマネージャのインスタンス生成
	    my $fmgr = MT::FileMgr->new('Local');
	    unless ($fmgr) {
		&log_error(MT::FileMgr->errstr);
		next;
	    }

	    my $now = time;
	    my @t = MT::Util::offset_time_list($now, $blog);
	    for(my $i=0; $i<@$ref_images; $i++) {
		my $ref_image = $ref_images->[$i];
		# 新しいファイル名
		my $new_filename = sprintf("%d_%d_%d%s", $entry->id, $now, $i, $ref_image->{ext});
		# ブログルート
		my $root_path = $blog->site_path; # サーバ内パス
		my $root_url = $blog->site_url;   # URL
		# 保存先
		my $relative_dir = "ketai_post_files/".($t[5]+1900).'/'.($t[4]+1)."/".($t[3])."/";
		my $relative_file_path = $relative_dir.$new_filename; # 相対パス
		my $file_path = File::Spec->catfile($root_path, $relative_file_path); # サーバ内パス
		my $dir = dirname($file_path); # ディレクトリ名
		my $url = $root_url;
		$url .= '/' if $url !~ m!/$!;
		$url .= $relative_file_path; # URL
		
		&log_debug("file_path: $file_path\nurl: $url");

		# アップロード先ディレクトリ生成
		unless($fmgr->exists($dir)) {
		    unless ($fmgr->mkpath($dir)) {
			&log_error($fmgr->errstr);
			next;
		    }
		}

		# 保存
		my $bytes = $fmgr->put_data($ref_image->{data}, $file_path, 'upload');
		unless (defined $bytes) {
		    &log_error($fmgr->errstr);
		    next;
		}
		&log_debug($ref_image->{filename}." を ".$file_path." に書き込みました。");

		# アイテムの登録
		my $img = MT::Image->new( Filename => $file_path );
		my($blob, $width, $height) = $img->scale( Scale => 100 );
		my $asset = MT::Asset::Image->new;
		# 情報セット
		$asset->label($entry->title);
		$asset->file_path($file_path);
		$asset->file_name($new_filename);
		$asset->file_ext($ref_image->{ext});
		$asset->blog_id($blog->id);
		$asset->created_by($author->id);
		$asset->modified_by($author->id);
		$asset->url($url);
		$asset->description('');
		$asset->image_width($width);
		$asset->image_height($height);
		# アイテムの登録
		unless ($asset->save) {
		    &log_error("アイテムの登録に失敗");
		    next;
		}
		&log_debug("アイテムを登録しました id:".$asset->id."path:$file_path url:$url");
		
		# サムネイルの作成
		my ($thumbnail_path, $thumb_width, $thumb_height) = $asset->thumbnail_file(Square => 1,
											   Width => 200,
											   Path => $relative_dir);

		my ($thumbnail_basename, $thumbnail_dir, $thumbnail_ext) = fileparse($thumbnail_path, qr/\.[^.]*/);
		my $thumbnail_filename = $thumbnail_basename.$thumbnail_ext;
		my $thumbnail_url = $root_url.File::Spec->abs2rel($thumbnail_path, $root_path);
		&log_debug("サムネイルを作成しました。 path:$thumbnail_path url:$thumbnail_url");

		# サムネイルの登録
		my $thumbnail_asset = MT::Asset::Image->new;
		$thumbnail_asset->label('Thumbnail of '.$asset->label);
		$thumbnail_asset->file_path($thumbnail_path);
		$thumbnail_asset->file_name($thumbnail_filename);
		$thumbnail_asset->file_ext($thumbnail_ext);
		$thumbnail_asset->blog_id($blog->id);
		$thumbnail_asset->created_by($author->id);
		$thumbnail_asset->modified_by($author->id);
		$thumbnail_asset->url($thumbnail_url);
		$thumbnail_asset->description('');
		$thumbnail_asset->image_width($thumb_width);
		$thumbnail_asset->image_height($thumb_height);
		$thumbnail_asset->parent($asset->id); # 親の設定

		unless ($thumbnail_asset->save) {
		    &log_error("サムネイルのアイテム登録に失敗");
		}
		&log_debug("サムネイルを登録しました id:".$asset->id."path:$thumbnail_path url:$thumbnail_url parent_id:".$asset->id);

		# 写真を表示するように記事を編集
		my $old_entry = $entry->clone;
		my $image_html = sprintf('<a href="%s" target="_blank"><img src="%s" width="%d" height="%d" alt="%s" /></a>',
					 $url, $thumbnail_url, $thumb_width, $thumb_height, $asset->label);
		my $buf = $entry->text;
		MT::I18N::encode_text($buf, undef, 'utf-8');
		utf8::decode($buf);
		$entry->text($buf."<div>$image_html</div>");
		$entry->save;
		$app->run_callbacks('cms_post_save.entry', $app, $entry, $old_entry);
		&rebuild_entry_page($entry);
	    }

	    # $pop3->delete($id);
	}

	$pop3->quit();
    }

    &log_debug("メールサーバからログアウトしました。");
    
    1;
}

sub parse_data {
    my ($message, $options) = @_;
    $options ||= {};

    my $cfg = MT::ConfigMgr->instance;

    my @imagetype = ('.jpg','.jpeg', '.gif','.png');
    my $parser = MIME::Parser->new;

    my $entity = $parser->parse_data($message);
    my $head = $entity->head;
    $head->decode;
    
    # 宛先取り出し
    my @recipients;
    my $recipient = $head->get('to');
    chomp($recipient);
    my @addrs = Mail::Address->parse($recipient);
    foreach my $addr (@addrs) {
	push(@recipients, $addr->address);
    }
    # 宛先メールアドレスの制限
    if (my $to = $options->{To}) {
	return unless grep(/\Q$to/, @recipients) > 0;
    }

    #送信者取り出し
    my $umail = $head->get('From');
    my $uname;
    chomp $umail;
    @addrs = Mail::Address->parse($umail);
    foreach my $addr (@addrs) {
	$umail = $addr->address;
	$uname = $addr->name;
    }
    &log_debug("umail: $umail uname: $uname");
    
    my $subject = $head->get('Subject');
    $subject = MT::I18N::encode_text($subject, 'jis', undef);
    if ($subject) {
	$subject =~ s/[\x00-\x1f]//g;
	$subject = MT::Util::encode_html($subject);
    }
    
    my ($text, $text_charset);
    
    my @images;
    
    unless ($entity->is_multipart) {
	$text = $entity->bodyhandle->as_string;
	$text_charset = $1 if $head->get('Content-Type') =~ /charset="(.+)"/;
    } else {
	#パートの数（本文と添付ファイルの合計数）
	my $maxbytes = $cfg->CGIMaxUpload;
	my $count = $entity->parts;
	for(my $i = 0; $i < $count; $i++){
	    my $part = $entity->parts($i);
	    my $type = $part->mime_type;
	    if ($type =~ /text\/plain|text\/html/) {
		#本文
		$text = $part->bodyhandle->as_string;
		$text_charset = $1 if $part->head->get('Content-Type') =~ /charset="(.+)"/;
	    } else {
		#添付
		#ファイル名を含むパスを取り出し
		my $path = $part->bodyhandle->path;
		#ファイル名を取り出し
		my $fname = (fileparse($path))[0];
		foreach my $type(@imagetype){
		    if($fname =~ /$type$/i){#認められた形式の画像ファイルか
			my $data;

			# 容量制限
			my $handle = $part->bodyhandle;
			my $io = $handle->open("r");
			my $bytes = $io->read($data, $maxbytes + 1);
			$io->close;
			if($bytes > $maxbytes) {
			    &log_error("添付ファイルのサイズが大きすぎます。スキップしました。（最大 $maxbytes Bytes）");
			    next;
			}
			
			my $ref_image = {
			    data => $data,
			    filename => $fname,
			    ext => $type
			};
			push(@images, $ref_image);
		    }
		}
	    }
	}
    }
    
    $text_charset = {
	'shift_jis'=>'sjis',
	'iso-2022-jp'=>'jis',
	'euc-jp'=>'euc',
	'utf-8'=>'utf8'
    }->{lc $text_charset} || 'jis';
    
    $text = MT::I18N::encode_text($text, $text_charset, undef);
    
    my $ref_data = {
	recipients => \@recipients,
	from => $umail,
	subject => $subject,
	text => $text,
	images => \@images
    };

    return $ref_data;
}

sub create_entry {
    my ($blog, $author, $subject, $text) = @_;

    my $app = MT::App::CMS->new;
    my $publisher = MT::WeblogPublisher->new;
    my $entry  = MT::Entry->new;
    
    &log_debug("エントリを投稿します");
    
    $entry->blog_id($blog->id);
    $entry->author_id($author->id);
    $entry->status($blog->status_default); # ブログの設定、新しく作った記事が「公開」になるか「下書き」になるか
    $entry->title($subject);
    $entry->text($text);
    $entry->allow_comments($blog->allow_comments_default); # コメントを受け付けるか
    $entry->allow_pings($blog->allow_pings_default); # トラックバックpingを受け付けるか
    if($entry->save) {
	my $title = $entry->title;
	utf8::decode($title);
	&log_info("'".$author->name."'がブログ記事'".$title."'(ID:".$entry->id.")を追加しました。", {
	    author_id => $author->id,
	    blog_id => $blog->id,
	});
	&log_debug($entry->permalink);

	$app->run_callbacks('cms_post_save.entry', $app, $entry);
	
	return $entry;
    } else {
	&log_debug("投稿失敗");
    }

    return;
}

# 記事が「公開」なら再構築
sub rebuild_entry_page {
    my ($entry) = @_;

    return unless $entry->status == 2; # 公開(2)
    
    my $publisher = MT::WeblogPublisher->new;
    my $ret = $publisher->rebuild_entry(
	Entry => $entry,
	Blog => $entry->blog,
	BuildDependencies => 1
    );

    &log_debug("ID:".$entry->id."を再構築しました。", {
	author_id => $entry->author_id,
	blog_id => $entry->blog_id,
    });

    $ret;
}

1;
