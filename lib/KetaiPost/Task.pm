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
use MT::ObjectAsset;
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
        my $auth_mode = $mailbox->use_apop ? 'APOP' : 'PASS';

        unless ($host && $port && $account && $password) {
            $self->{plugin}->log_error("($address) ホスト名、ポート番号、アカウント名、パスワードの入力は必須です。");
            next;
        }
        
        $self->{plugin}->log_debug("$address => AUTH_MODE:$auth_mode USER:$account HOST:$host SSL:".$mailbox->use_ssl);
        my $pop3 = Mail::POP3Client->new(
            AUTH_MODE => $auth_mode,
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
                    $self->{plugin}->log_error("unknown author (".$ref_data->{from}.")", { blog_id => $blog->id });
                    $pop3->Delete($id) unless ($self->{plugin}->get_system_setting('disable_delete_flag'));
                    next;
                }
                my $author = MT::Author->load({ id => $assign->author_id });
                
                $self->{plugin}->log_debug("author: ".$author->name);
                $self->{plugin}->log_debug("subject: ".$ref_data->{subject}."\nbody:\n".$ref_data->{text});
                my $ref_images = $ref_data->{images};
                foreach my $ref_image(@$ref_images) {
                    $self->{plugin}->log_debug("filename: ".$ref_image->{filename});
                }
                my $ref_movies = $ref_data->{movies};
                foreach my $ref_movie(@$ref_movies) {
                    $self->{plugin}->log_debug("filename: ".$ref_movie->{filename});
                }
                
                # 権限のチェック
                my $perms = MT::Permission->load({blog_id => $blog->id, author_id => $author->id});
                unless ($perms && $perms->can_post) {
                    $self->{plugin}->log_error("記事の追加を試みましたが権限がありません。", {
                        blog_id => $blog->id,
                        author_id => $author->id});
                    $pop3->Delete($id) unless ($self->{plugin}->get_system_setting('disable_delete_flag'));
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
                $pop3->Delete($id) unless ($self->{plugin}->get_system_setting('disable_delete_flag'));
                
                # 処理ここから
                if (@$ref_images) {
                
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
                        
                        my @latlng = ();
                        
                        # ExifTool が必要な処理
                        if ($self->{plugin}->use_exiftool) {
                            require Image::ExifTool;
                            
                            my $exifTool = new Image::ExifTool;
                            my $ref_image_data = \($ref_image->{data});
                            my $exifInfo = $exifTool->ImageInfo($ref_image_data,
                                            'Orientation',
                                            'GPSLatitude',
                                            'GPSLongitude');
                            
                            # 必要に応じて向きを補正
                            if (1) {
                                $self->{plugin}->log_debug("向きの補正が有効になっています。");
                                
                                my $rotation = $exifInfo->{Orientation};
                                if ($rotation) {
                                    # Horizontal (normal)
                                    # Mirror horizontal
                                    # Rotate 180
                                    # Mirror vertical
                                    # Mirror horizontal and rotate 270 CW
                                    # Rotate 90 CW
                                    # Mirror horizontal and rotate 90 CW
                                    # Rotate 270 CW
                                    my $degrees = 0;
                                    if ($rotation eq 'Rotate 90 CW') {
                                        $degrees = 90;
                                    } elsif ($rotation eq 'Rotate 180') {
                                        $degrees = 180;
                                    } elsif ($rotation eq 'Rotate 270 CW') {
                                        $degrees = 270;
                                    }
                                    $self->{plugin}->log_debug("Orientation: $rotation");
                                    if ($degrees && $self->{plugin}->use_magick) {
                                        require Image::Magick;
                                        my $img = Image::Magick->new;
                                        $img->BlobToImage($ref_image->{data});
                                        $img->Rotate(degrees => $degrees);
                                        $ref_image->{data} = $img->ImageToBlob();
                                    }
                                }
                            }
                            
                            # 位置情報を取得
                            if ($self->{plugin}->use_gmap($blog->id)) {
                                my @tmp = ($exifInfo->{GPSLatitude}, $exifInfo->{GPSLongitude});
                                foreach my $geostr(@tmp) {
                                    if ($geostr && $geostr =~ /(\S+) deg (\S+)\' (.*)\"/) {
                                        my $p1 = $1;
                                        my $p2 = $2/60;
                                        my $p3 = $3/3600;
                                        push(@latlng, $p1 + $p2 + $p3);
                                    }
                                }
                                $self->{plugin}->log_debug("GPSLatitude: ".($tmp[0] || '')." GPSLongitude:".($tmp[1] || '')." => lat: ".($latlng[0] || '')." lng: ".($latlng[1] || ''));
                            }
                        }
                        
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

                        # エントリと関連づけ
                        my $obj_asset = new MT::ObjectAsset;
                        $obj_asset->blog_id($blog->id);
                        $obj_asset->asset_id($asset->id);
                        $obj_asset->object_ds('entry');
                        $obj_asset->object_id($entry->id);
                        $obj_asset->save;
                        
                        $self->{plugin}->log_debug("アイテムを登録しました id:".$asset->id."path:$file_path url:$url");
                    }
                } # 写真ここまで

                # 動画
                if (@$ref_movies && $self->{plugin}->use_ffmpeg($blog->id)) {
                    my $ffmpeg_path = $self->{plugin}->get_system_setting('ffmpeg_path');
                    $self->{plugin}->log_debug("ムービー掲載が有効です。");
                    $self->{plugin}->log_debug("FFmpeg: $ffmpeg_path");
                    

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
                    for(my $i=0; $i<@$ref_movies; $i++) {
                        my $ref_movie = $ref_movies->[$i];
                        # 新しいファイル名
                        my $new_filename = sprintf("%d_%d_%d.flv", $entry->id, $now, $i);
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

                        my $thumbnail_filename = sprintf("%d_%d_%d.jpg", $entry->id, $now, $i);
                        my $relative_thumbnail_path = $relative_dir.$thumbnail_filename; # 相対パス
                        my $thumbnail_path = File::Spec->catfile($root_path, $relative_thumbnail_path);
                        
                        $self->{plugin}->log_debug("file_path: $file_path\nurl: $url");
                        
                        # アップロード先ディレクトリ生成
                        unless($fmgr->exists($dir)) {
                            unless ($fmgr->mkpath($dir)) {
                                $self->{plugin}->log_error($fmgr->errstr);
                                next;
                            }
                        }

                        # 変換
                        my $temp_dir = $self->{plugin}->get_system_setting('temp_dir');

                        my($tmp_fh, $tmp_filename) = File::Temp::tempfile(
                            'movie_XXXXXX',
                            SUFFIX => $ref_movie->{ext},
                            UNLINK => 1,
                            DIR => $temp_dir
                        );
                        print $tmp_fh $ref_movie->{data};
                        close($tmp_fh);
                        my($tmpout_fh, $tmpout_filename) = File::Temp::tempfile(
                            'movie_XXXXXX',
                            SUFFIX => '.flv',
                            UNLINK => 1,
                            DIR => $temp_dir
                        );
                        close($tmpout_fh);
                        my($tmppasslog_fh, $tmppasslog_filename) = File::Temp::tempfile(
                            'passlog_XXXXXX',
                            SUFFIX => '.txt',
                            UNLINK => 1,
                            DIR => $temp_dir
                        );
                        close($tmppasslog_fh);

                        system("$ffmpeg_path -y -i $tmp_filename -an -r 15 -b 600k -pass 1 -passlogfile $tmppasslog_filename -vcodec flv -f flv $tmpout_filename");
                        system("$ffmpeg_path -y -i $tmp_filename -ar 44100 -acodec libmp3lame -r 15 -b 600k -pass 2 -passlogfile $tmppasslog_filename -vcodec flv -f flv $tmpout_filename");
                        my($tmpthumb_fh, $tmpthumb_filename) = File::Temp::tempfile(TEMPLATE => 'image_XXXXXX.jpg');
                        close($tmpthumb_fh);

                        system("$ffmpeg_path -y -i $tmp_filename -f image2 -ss 1 -r 1 -an -deinterlace $tmpthumb_filename");
                        
                        # 保存
                        my $bytes = $fmgr->put($tmpout_filename, $file_path, 'upload');
                        unless (defined $bytes) {
                            $self->{plugin}->log_error($fmgr->errstr);
                            next;
                        }            
                        $self->{plugin}->log_debug($ref_movie->{filename}." を ".$file_path." に書き込みました。");
                        
                        # アイテムの登録
                        my $asset = MT::Asset::Video->new;
                        # 情報セット
                        $asset->label($entry->title);
                        $asset->file_path($file_path);
                        $asset->file_name($new_filename);
                        $asset->file_ext($ref_movie->{ext});
                        $asset->blog_id($blog->id);
                        $asset->created_by($author->id);
                        $asset->modified_by($author->id);
                        $asset->url($url);
                        $asset->description('');

                        # アイテムの登録
                        unless ($asset->save) {
                            $self->{plugin}->log_error("アイテムの登録に失敗");
                            next;
                        }

                        # エントリと関連づけ
                        my $obj_asset = new MT::ObjectAsset;
                        $obj_asset->blog_id($blog->id);
                        $obj_asset->asset_id($asset->id);
                        $obj_asset->object_ds('entry');
                        $obj_asset->object_id($entry->id);
                        $obj_asset->save;
                        
                        $self->{plugin}->log_debug("アイテムを登録しました id:".$asset->id."path:$file_path url:$url");
                        
                        $bytes = $fmgr->put($tmpthumb_filename, $thumbnail_path, 'upload');
                        unless (defined $bytes) {
                            $self->{plugin}->log_error($fmgr->errstr);
                            next;
                        }            
                        $self->{plugin}->log_debug($ref_movie->{filename}." を ".$file_path." に書き込みました。");
                        

                        my ($thumbnail_basename, $thumbnail_dir, $thumbnail_ext) = fileparse($thumbnail_path, qr/\.[^.]*/);
                        my $thumbnail_url = $root_url.File::Spec->abs2rel($thumbnail_path, $root_path);
                        $self->{plugin}->log_debug("サムネイルを作成しました。 path:$thumbnail_path url:$thumbnail_url");
                        
                        # サムネイルの登録
                        my $img = MT::Image->new( Filename => $thumbnail_path );
                        my($thumb_blob, $thumb_width, $thumb_height) = $img->scale( Scale => 100 );
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
                    }
                } # 動画ここまで
                
                # 記事テンプレートの適用
                my $old_entry = $entry->clone;
                my ($new_text, $tmpl_error) = $self->build_entry_text($entry);
                if ( defined($new_text) ) {
                    $entry->text($new_text);
                    $entry->save;
                    $app->run_callbacks('cms_post_save.entry', $app, $entry, $old_entry);
                } else {
                    $self->{plugin}->log_error($tmpl_error);
                    next;
                }
                
            } # end loop
        }; # eval
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

    my $parser = MIME::Parser->new;
    $parser->output_dir($self->{tempdir});

    my $entity = $parser->parse_data($message);

    return $self->build_attributes($entity, $options);
}

# MIME::Entityを受け取り内容をチェックし、投稿が可能であれば連想配列でデータを返す
sub build_attributes {
    my $self = shift;
    my ($entity, $options) = @_;

    my $carrier;
    
    require KetaiPost::Emoji if ($self->{plugin}->use_emoji);

    my $cfg = MT::ConfigMgr->instance;

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
        $uname = $addr->name || '';
    }
    if ($umail =~ /docomo\.ne\.jp\z/) {
        $carrier = 'docomo';
    } elsif ($umail =~ /ezweb\.ne\.jp\z/) {
        $carrier = 'kddi';
    } elsif ($umail =~ /(softbank\.ne\.jp|vodafone\.ne\.jp|disney\.ne\.jp)\z/) {
        $carrier = 'softbank';
    }
    
    $self->{plugin}->log_debug("umail: $umail uname: $uname");
    
    # 時刻
    # HTTP::Date が使えればメールの日付を取得
    #my $written_time;
    #if ($self->{plugin}->use_http_date) {
    #require HTTP::Date;
    #my $datestr = $head->get('Date');
    #$witten_time = HTTP::Date::str2time($datestr);
    #}

    # 件名
    # Encode.pm でMIMEデコードができればそれを使う
    # できなければ MIME::Base64を使う
    my $subject = $head->get('Subject');
    eval { require Encode::MIME::Header::ISO_2022_JP; };
    # 絵文字を使う時はMIME-Headerを使うと
    # エスケープされてうまくいかなかったのでとりあえず自前のBase64で
    unless ($@ || $self->{plugin}->use_emoji) {
        $self->{plugin}->log_debug("Encode によるMIMEデコードを行います");
        $subject = decode('MIME-Header', $subject);
    } else {
        if ($subject =~ /=\?([^\?]+)\?B\?([^\?]+)/) {
            $self->{plugin}->log_debug("MIME::Base64 によるMIMEデコードを行います");
            require MIME::Base64;
            
            my @lines = split("\n", $subject);
            my $charset;
            my $encoded;
            foreach my $line(@lines) {
                next unless $line =~ /=\?([^\?]+)\?B\?([^\?]+)/;
                $charset = $1;
                $encoded .= $2;
            }
            $self->{plugin}->log_debug("encoded_subject: $encoded");
            my $decoded = MIME::Base64::decode_base64($encoded);
            if ($self->{plugin}->use_emoji) {
                $subject = KetaiPost::Emoji::decode2utf8($carrier, $charset, $decoded);
            } else {
                $subject = encode('utf-8', decode($charset, $decoded));
            }
        }
    }
    $self->{plugin}->log_debug("subject: $subject");
    utf8::encode($subject) if utf8::is_utf8($subject); # フラグを落とす
    $subject = MT::I18N::encode_text($subject, 'utf-8', undef);
    
    if ($subject) {
        $subject =~ s/[\x00-\x1f]//g;
        $subject = MT::Util::encode_html($subject);
    }
    
    # 本文・添付ファイルの取り出し
    my $default_charset = 'iso-2022-jp';
    $default_charset = $1 if $head->get('Content-Type') =~ /charset="?([\w_-]+)"?/i;
    my ($text, $ref_images, $ref_movies) = $self->_extract_mail_entity($carrier, $entity, $default_charset);

    my @images = @$ref_images;
    my @movies = @$ref_movies;

    my $ref_data = {
        recipients => \@recipients,
        from => $umail,
        #time => $witten_time,
        subject => $subject,
        text => $text,
        images => \@images,
        movies => \@movies
    };

    return $ref_data;
}

# MIME::Entityを受け取って本文及びその文字コード、画像配列のリファレンス、動画配列のリファレンスを得る
# multipart/alternativeへの対応のため再帰を行う
sub _extract_mail_entity {
    my $self = shift;
    my ( $carrier, $entity, $default_charset ) = @_;
    
    my %imagetypes = ('image/pjpeg' => '.jpg',
              'image/jpeg' => '.jpg',
              'image/gif' => '.gif',
              'image/png' => '.png');
    my %movietypes = ('video/3gpp2' => '.3gp',
              'video/3gpp' => '.3gp',
              'video/mp4' => '.mp4');
    
    my ($text, @images, @movies);
    
    unless ($entity->is_multipart) {
        $text = $self->_encode_text( $carrier, $entity->bodyhandle->as_string, $default_charset);
    } else {
        #パートの数（本文と添付ファイルの合計数）
        my $maxbytes = MT::ConfigMgr->instance->CGIMaxUpload;
        my $count = $entity->parts;
        for(my $i = 0; $i < $count; $i++){
            my $part = $entity->parts($i);
            my $type = $part->mime_type;
            $self->{plugin}->log_debug("part: $type (bodyhandle ".($part->bodyhandle ? 'found' : 'not found').")");
            
            if ( $type =~ /multipart\/alternative/ ) {
                my ($alt_text, $ref_alt_images, $ref_alt_movies) = $self->_extract_mail_entity( $carrier, $part, $default_charset );
                $text .= $alt_text;
                push(@images, @$ref_alt_images);
                push(@movies, @$ref_alt_movies);
                next;
            }
            
            next unless $part->bodyhandle;
            
            if ($type =~ /text\/plain/) {
                #本文
                my $text_charset = $default_charset;
                my $contenttype = $part->head->get('Content-Type');
                $text_charset = $1 if $contenttype && $contenttype =~ /charset="?([\w_-]+)"?/i;
                $text .= $self->_encode_text( $carrier, $part->bodyhandle->as_string, $text_charset );
            } else {
                #添付
                #ファイル名を含むパスを取り出し
                my $path = $part->bodyhandle->path;
                #ファイル名を取り出し
                my $fname = (fileparse($path))[0];
                # 画像ファイル取りだし
                foreach my $imagetype( keys( %imagetypes ) ){
                    my $extname = $imagetypes{$imagetype};
                    if( $type =~ /$imagetype/i ) {#認められた形式の画像ファイルか
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
                            ext => $extname
                        };
                        push(@images, $ref_image);
                    }
                }

                # 動画ファイル取り出し
                foreach my $movietype(keys(%movietypes)){
                    my $extname = $movietypes{$movietype};
                    if($type =~ m|$movietype|i){
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
                        my $ref_movie = {
                            data => $data,
                            filename => $fname,
                            ext => $extname
                        };
                        push(@movies, $ref_movie);
                    }
                }

            }
        }
    }
    
    return ($text, \@images, \@movies);
}

sub _encode_text {
    my $self = shift;
    my ( $carrier, $text, $text_charset ) = @_;
    
    my $normalized_text_charset = {
        'shift-jis'=>'sjis',
        'shift_jis'=>'sjis',
        'iso-2022-jp'=>'jis',
        'euc-jp'=>'euc',
        'utf-8'=>'utf8'
    }->{lc $text_charset} || 'jis';
    $self->{plugin}->log_debug("body charset: ".(lc $text_charset)." ($normalized_text_charset)");

    if ($self->{plugin}->use_emoji) {
        $text = KetaiPost::Emoji::decode2utf8($carrier, $normalized_text_charset, $text);
        $text = MT::I18N::encode_text($text, 'utf8', undef);
    } else {
        $text = MT::I18N::encode_text($text, $normalized_text_charset, undef);
    }
    
    return $text;
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

# 記事テンプレートの取得
sub load_entry_tmpl {
    my $self = shift;
    my ( $blog_id ) = @_;
    my $template_id = $self->{plugin}->get_setting($blog_id, 'entry_text_template_id');
    $self->{plugin}->log_debug( "template_id: $template_id" );
    my $tmpl;
    $tmpl = MT->model('template')->load({
        id => $template_id,
        type => 'custom'
    }) if $template_id > 0;
    return $tmpl if $tmpl;
    
    $tmpl = $self->{plugin}->load_tmpl( 'entry.tmpl' );
    return $tmpl;
}

# 本文の構築
sub build_entry_text {
    my $self = shift;
    my ( $entry ) = @_;
    
    my $blog = MT::Blog->load( $entry->blog_id );
    my $category = $entry->category;
    
    my $tmpl = $self->load_entry_tmpl( $entry->blog_id );
    my $ctx = $tmpl->context;
    $ctx->stash( 'entry', $entry );
    $ctx->stash( 'blog',  $blog );
    $ctx->stash( 'category', $category ) if $category;
    $ctx->{current_timestamp} = $entry->created_on;
    
    my %params = (
        thumbnail_width => $self->{plugin}->get_setting($blog->id, 'thumbnail_size') || 240,
        movie_width => $self->{plugin}->get_setting($blog->id, 'player_size') || 360,
    );
    my $thumbnail_shape = $self->{plugin}->get_setting($blog->id, 'thumbnail_shape');
    if ( $thumbnail_shape == 1 ) {
        # 縮小
        $params{thumbnail_square} = 0;
    } elsif ( $thumbnail_shape == 2 ) {
        # 切り抜き
        $params{thumbnail_square} = 1;
    }
    
    my $html = $tmpl->output( \%params );
    my $error = $tmpl->errstr;
    return ( $html, $error );
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
