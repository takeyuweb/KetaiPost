# $Id$

package KetaiPost::Task;

use strict;
use warnings;
use utf8;

use Encode;
use Encode::Guess qw/euc-jp shiftjis 7bit-jis/;
use File::Basename;
use File::Spec;
use File::Temp;

use Mail::POP3Client;
use MIME::Parser; # MIME-tools

use MT::Image;
use MT::Asset::Image;
use MT::Category;
use MT::Placement;
use MT::Blog;
use MT::Author;
use MT::ConfigMgr;
use MT::App::CMS;
use MT::WeblogPublisher;

sub new {
    my $self = shift;
    my ($plugin) = @_;

    my $obj = {
	plugin => $plugin
    };
    bless $obj, $self;
    return $obj;
}

sub run {
    my $self = shift;

    # 一時ディレクトリの準備
    $self->{tempdir} = File::Temp->newdir('', {CLEANUP => 1});
    $self->{plugin}->log_debug("一時ディレクトリ ".$self->{tempdir}." を作成しました。");
    
    $self->process;
    
    1;
}

sub process {
    my $self = shift;

    my $app = MT::App::CMS->new;
    my $cfg = MT::ConfigMgr->instance;

    my @entry_ids = ();

    my $mailboxes_iter = KetaiPost::MailBox->load_iter({}, {});
    while (my $mailbox = $mailboxes_iter->()) {

	my $blog = MT::Blog->load($mailbox->blog_id);
	my $category;
	$category = MT::Category->load({id => $mailbox->category_id,
					blog_id => $blog->id}) if $mailbox->category_id;

	my $address = $mailbox->address;
	my $host = $mailbox->host;
	my $account = $mailbox->account;
	my $password = $mailbox->password;
	my $port = $mailbox->port;
	my $protocol = 'pop3';

	unless ($host && $port && $account && $password) {
	    $self->{plugin}->log_error("($address) ホスト名、ポート番号、アカウント名、パスワードの入力は必須です。");
	    next;
	}
	
	my $pop3 = Mail::POP3Client->new(
	    USER => $account,
	    PASSWORD => $password,
	    HOST => $host,
	    USESSL => $mailbox->use_ssl
	);

	my $count = $pop3->Count;
	$self->{plugin}->log_debug("$address count:$count");

	if ($count < 0) {
	    $self->{plugin}->log_error("$address $host:$port POP3接続に失敗");
	    next;
	}

	eval {
	    
	    for (my $id=1; $id<=$count; $id++) {
		my $message = $pop3->HeadAndBody($id);
		
		my $ref_data = $self->parse_data($message, { To => $address });
		next unless $ref_data;
		
		my $assign = KetaiPost::Author->load({ address => $ref_data->{from} });
		$assign ||= KetaiPost::Author->load({ address => '' });
		unless ($assign) {
		    $self->{plugin}->log_error("unknown author (".$ref_data->{from}.")", blog_id => $blog->id);
		    $pop3->Delete($id);
		    next;
		}
		my $author = MT::Author->load({ id => $assign->author_id });
		
		$self->{plugin}->log_debug("author: ".$author->name);
		$self->{plugin}->log_debug("subject: ".$ref_data->{subject}."\nbody:\n".$ref_data->{text});
		my $ref_images = $ref_data->{images};
		foreach my $ref_image(@$ref_images) {
		    $self->{plugin}->log_debug("filename: ".$ref_image->{filename});
		}
		
		# 権限のチェック
		my $perms = MT::Permission->load({blog_id => $blog->id, author_id => $author->id});
		unless ($perms && $perms->can_post) {
		    $self->{plugin}->log_error("記事の追加を試みましたが権限がありません。", {
			blog_id => $blog->id,
			author_id => $author->id
		    });
		    $pop3->Delete($id);
		    next;
		}
		
		# 記事登録
		my ($subject, $text) = ($ref_data->{subject}, $ref_data->{text});
		$subject = $self->{plugin}->get_setting($blog->id, 'default_subject') || '無題' unless ($subject);
		$text = MT::Util::encode_html($text);
		$text =~ s/\r\n/\n/g;
		$text =~ s/\n/<br \/>/g;
		my $entry = $self->create_entry($blog, $author, $subject, $text, $category);
		next unless $entry;
		
		push(@entry_ids, $entry->id);
		$pop3->Delete($id); # 削除フラグの設定
		
		# 写真がない場合はここまで
		next unless @$ref_images;
		
		$entry->created_on =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/;
		my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
		
		# 添付写真の保存
		# ファイルマネージャのインスタンス生成
		my $fmgr = MT::FileMgr->new('Local');
		unless ($fmgr) {
		    $self->{plugin}->log_error(MT::FileMgr->errstr);
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
		    
		    $self->{plugin}->log_debug("file_path: $file_path\nurl: $url");
		    
		    # アップロード先ディレクトリ生成
		    unless($fmgr->exists($dir)) {
			unless ($fmgr->mkpath($dir)) {
			    $self->{plugin}->log_error($fmgr->errstr);
			    next;
			}
		    }

		    # 保存
		    my $bytes = $fmgr->put_data($ref_image->{data}, $file_path, 'upload');
		    
		    unless (defined $bytes) {
			$self->{plugin}->log_error($fmgr->errstr);
			next;
		    }		    
		    $self->{plugin}->log_debug($ref_image->{filename}." を ".$file_path." に書き込みました。");
		    
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
			$self->{plugin}->log_error("アイテムの登録に失敗");
			next;
		    }
		    $self->{plugin}->log_debug("アイテムを登録しました id:".$asset->id."path:$file_path url:$url");
		    
		    # サムネイルの作成
		    # サイズ計算
		    my $scale;
		    if ($width > $height) {
			# 長辺は幅、これがthumbnail_sizeで収まるように
			$scale = ($self->{plugin}->get_setting($blog->id, 'thumbnail_size') || 240) / $width;
		    } else {
			# 長辺は高さ、これがthumbnail_sizeで収まるように
			$scale = ($self->{plugin}->get_setting($blog->id, 'thumbnail_size') || 240) / $height;
		    }
		    $scale = 1.0 if $scale > 1;
		    my ($thumbnail_path, $thumb_width, $thumb_height) = $asset->thumbnail_file(Scale => $scale * 100,
											       Path => $relative_dir);
		    
		    my ($thumbnail_basename, $thumbnail_dir, $thumbnail_ext) = fileparse($thumbnail_path, qr/\.[^.]*/);
		    my $thumbnail_filename = $thumbnail_basename.$thumbnail_ext;
		    my $thumbnail_url = $root_url.File::Spec->abs2rel($thumbnail_path, $root_path);
		    $self->{plugin}->log_debug("サムネイルを作成しました。 path:$thumbnail_path url:$thumbnail_url");
		    
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
			$self->{plugin}->log_error("サムネイルのアイテム登録に失敗");
		    }
		    $self->{plugin}->log_debug("サムネイルを登録しました id:".$asset->id."path:$thumbnail_path url:$thumbnail_url parent_id:".$asset->id);
		    
		    # 写真を表示するように記事を編集
		    my $old_entry = $entry->clone;

		    my $alt = $asset->label;
		    MT::I18N::encode_text($alt, undef, 'utf-8');
		    utf8::decode($alt);
		    my $image_html = sprintf('<a href="%s" target="_blank"><img src="%s" width="%d" height="%d" alt="%s" /></a>',
					     $url, $thumbnail_url, $thumb_width, $thumb_height, $alt);
		    my $buf = $entry->text;
		    MT::I18N::encode_text($buf, undef, 'utf-8');
		    utf8::decode($buf);
		    $entry->text("<p>$image_html</p>".$buf);
		    $entry->save;
		    $app->run_callbacks('cms_post_save.entry', $app, $entry, $old_entry);
		}
	    }
	    
	};
	$self->{plugin}->log_error($@) if $@;

	$pop3->Close();
    }

    # まとめて再構築
    # 再構築時点でデータをリロードしないとうまく機能しない
    foreach my $entry_id(@entry_ids) {
	$self->rebuild_entry_page(MT::Entry->load($entry_id));
    }

    1;
}

sub parse_data {
    my $self = shift;
    my ($message, $options) = @_;
    $options ||= {};

    my $cfg = MT::ConfigMgr->instance;

    my @imagetype = ('.jpg','.jpeg', '.gif','.png');
    my $parser = MIME::Parser->new;
    $parser->output_dir($self->{tempdir});
    $parser->decode_headers(1);

    my $entity = $parser->parse_data($message);
    my $head = $entity->head;
    
    # 宛先取り出し
    my @recipients;
    my $recipient = $head->get('to');
    chomp($recipient);
    my @addrs = Mail::Address->parse($recipient);
    foreach my $addr (@addrs) {
	my $buf = $addr->address;
	# 変なメールアドレスは""で囲まれている可能性があるので外しとく
	$buf =~ s/^"(.+)"(@.+)$/$1$2/;
	push(@recipients, $buf);
    }
    # 宛先メールアドレスの制限
    if (my $to = $options->{To}) {
	$self->{plugin}->log_debug("to:$to recipients:".join(',', @recipients));
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
    $self->{plugin}->log_debug("umail: $umail uname: $uname");
    
    my $subject = $head->get('Subject');
    my $subject_enc = Encode::Guess->guess($subject);
    my $subject_charset = 'shiftjis';
    $subject_charset = $subject_enc->name if (ref($subject_enc));
    $self->{plugin}->log_debug("charset: $subject_charset (guess:".ref($subject_enc).")");
    $subject = MT::I18N::encode_text($subject, $subject_charset, undef);
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
	    if ($type =~ /text\/plain/) {
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
			    $self->{plugin}->log_error("添付ファイルのサイズが大きすぎます。スキップしました。（最大 $maxbytes Bytes）");
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
    my $self = shift;
    my ($blog, $author, $subject, $text, $category) = @_;

    my $app = MT::App::CMS->new;
    my $publisher = MT::WeblogPublisher->new;
    my $entry  = MT::Entry->new;
    
    $self->{plugin}->log_debug("エントリを投稿します");
    
    $entry->blog_id($blog->id);
    $entry->category_id($category->id) if $category;
    $entry->author_id($author->id);
    $entry->status($blog->status_default); # ブログの設定、新しく作った記事が「公開」になるか「下書き」になるか
    $entry->title($subject);
    $entry->text($text);
    $entry->allow_comments($blog->allow_comments_default); # コメントを受け付けるか
    $entry->allow_pings($blog->allow_pings_default); # トラックバックpingを受け付けるか
    if($entry->save) {
	# 記事とカテゴリの関連付け
	if($category) {
	    my $place = MT::Placement->new;
	    $place->entry_id($entry->id);
	    $place->blog_id($entry->blog_id);
	    $place->category_id($category->id);
	    $place->is_primary(1);
	    $place->save;
	}

	my $title = $entry->title;
	utf8::decode($title);
	$self->{plugin}->log_info("'".$author->name."'がブログ記事'".$title."'(ID:".$entry->id.")を追加しました。", {
	    author_id => $author->id,
	    blog_id => $blog->id,
	});
	$self->{plugin}->log_debug($entry->permalink);

	$app->run_callbacks('cms_post_save.entry', $app, $entry);
	
	return $entry;
    } else {
	$self->{plugin}->log_debug("投稿失敗");
    }

    return;
}

# 記事が「公開」なら再構築
sub rebuild_entry_page {
    my $self = shift;
    my ($entry) = @_;

    return unless $entry->status == 2; # 公開(2)
    
    my $publisher = MT::WeblogPublisher->new;
    my $ret = $publisher->rebuild_entry(
	Entry => $entry,
	Blog => $entry->blog,
	BuildDependencies => 1
    );

    $self->{plugin}->log_debug("ID:".$entry->id."を再構築しました。", {
	author_id => $entry->author_id,
	blog_id => $entry->blog_id,
    });

    $ret;
}

1;
