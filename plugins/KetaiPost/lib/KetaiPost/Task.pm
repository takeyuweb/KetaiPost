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

use Image::Size qw( imgsize );

use MT::Image;

use MT::ConfigMgr;
use MT::WeblogPublisher;

use KetaiPost::Util qw(log_debug log_info log_error log_security get_blog_setting get_website_setting get_system_setting get_setting
                       use_exiftool use_magick use_gmap use_emoji use_ffmpeg use_escape use_xatena use_notify if_can_on_blog );

use MT::Util qw( is_valid_email );

our $plugin = MT->component( 'KetaiPost' );

sub new {
    my $self = shift;

    my $obj = {};
    bless $obj, $self;
    return $obj;
}

sub run {
    my $self = shift;
    my ( $terms, $params, $args ) = @_;

    # 一時ディレクトリの準備
    my $tempdir = get_system_setting( 'tempdir' ) || '/tmp';
    unless ( -d $tempdir ) {
        eval {
            require File::Path;
            File::Path::mkpath $tempdir;
        };
        if ( my $errstr = $@ ) {
            MT->log({
                level => MT::Log::ERROR(),
                message => $plugin->translate(
                    "Unable to generate a temporary directory ([_1]). Use the '/ tmp'.",
                    $tempdir ),
            });
            $tempdir = '/tmp';
        }
    }
    $self->{tempdir} = File::Temp->newdir( 'ketaipost_XXXXXXXX', DIR => $tempdir );
    log_debug("一時ディレクトリ ".$self->{tempdir}." を作成しました。");
    
    $self->process( $terms, $params, $args );
    
    1;
}

sub process {
    my $self = shift;
    my ( $terms, $params, $args ) = @_;

    $args ||= {};
    my %opts = ( combine_accounts => 1 );
    %opts = ( %opts, %$args );

    $terms ||= {};
    $params ||= {};

    my $app = MT->instance;
    my $cfg = MT::ConfigMgr->instance;

    my @entry_ids = ();
    my %mailbox_ids_map = (); # チェック済のメールボックス

    my $mailboxes_iter = MT->model( 'ketaipost_mailbox' )->load_iter($terms, $params);
    while (my $mailbox = $mailboxes_iter->()) {
        next if $mailbox_ids_map{ $mailbox->id };
        $mailbox_ids_map{ $mailbox->id } = 1;

        # このアカウントの記事の送信先
        my %targets = ();
        my $target = {
            blog => MT->model( 'blog' )->load($mailbox->blog_id),
            category => $mailbox->category_id ? MT->model( 'category' )->load({id => $mailbox->category_id, blog_id => $mailbox->blog_id}) : undef,
        };

        unless ( $target->{ 'blog' } ) {
            log_debug( "(@{[ $mailbox->address ]}) ブログが見つかりません。（blog_id:@{[ $mailbox->blog_id ]}）" );
            next;
        }
        $targets{ $mailbox->address } = $target;

        # POP3アカウントのものは一度に処理
        my $host = $mailbox->host;
        my $account = $mailbox->account;
        my $password = $mailbox->password;
        my $port = $mailbox->port;
        my $use_apop = $mailbox->use_apop;
        my $use_ssl = $mailbox->use_ssl;
        unless ($host && $port && $account && $password) {
            log_error("(@{[ $mailbox->address ]}) ホスト名、ポート番号、アカウント名、パスワードの入力は必須です。");
            next;
        }

        unless ( $opts{ combine_accounts } ) {
            log_debug("統合チェック機能が無効です。");
        } else {
            my $iter = MT->model( 'ketaipost_mailbox' )->load_iter(
                {
                    id => \"!= @{[ $mailbox->id ]}",
                    host => $host,
                    account => $account,
                    password => $password,
                    port => $port,
                    use_apop => $use_apop,
                    use_ssl => $use_ssl },
                undef
            );
            while ( my $other_mailbox = $iter->() ) {
                $mailbox_ids_map{ $other_mailbox->id } = 1;
            
                my $target = {
                    blog => MT->model( 'blog' )->load($other_mailbox->blog_id),
                    category => $other_mailbox->category_id ? MT->model( 'category' )->load({id => $other_mailbox->category_id, blog_id => $other_mailbox->blog_id}) : undef,
                };
            
                unless ( $target->{ 'blog' } ) {
                    log_debug( "(@{[ $other_mailbox->address ]}) ブログが見つかりません。（blog_id:@{[ $other_mailbox->blog_id ]}）" );
                    last;
                }
                $targets{ $other_mailbox->address } = $target;
            }
        }

        log_debug( "ACCOUNT:$account チェック対象のメールアドレス:@{[ join( ', ', keys %targets ) ]}" );
        
        my $auth_mode = $use_apop ? 'APOP' : 'PASS';
        log_debug("ACCOUNT:$account => AUTH_MODE:$auth_mode USER:$account HOST:$host SSL:".$use_ssl);
        my $pop3 = Mail::POP3Client->new(
            AUTH_MODE => $auth_mode,
            USER => $account,
            PASSWORD => $password,
            HOST => $host,
            USESSL => $use_ssl
        );

        my $count = $pop3->Count;
        log_debug("ACCOUNT:$account count:$count");

        if ($count < 0) {
            log_error("ACCOUNT:$account $host:$port POP3接続に失敗");
            next;
        }
        
        
        my $start = 1;
        if ( my $pop_download_mails = get_system_setting( 'pop_download_mails' ) ) {
            $start = $count - $pop_download_mails + 1;
            $start = 1 if $start < 1;
        }
        if ( $count > 0 ) {
            log_debug( "$start - $count 番目のメールを受信します。" );
        }
          
        eval {
            
            for (my $id=$start; $id<=$count; $id++) {
            
                my $message = $pop3->HeadAndBody($id);
                
                my ( $address, $category, $blog, $ref_data );
                foreach my $key ( keys %targets ) {
                    $ref_data = $self->parse_data($message, { To => $key });
                    next unless $ref_data;
                    $address = $key;
                    $category = $targets{ $key }->{ category };
                    $blog = $targets{ $key }->{ blog };
                    last;
                }
                next unless $blog;
                
                my $assign = MT->model( 'ketaipost_author' )->load({ address => $ref_data->{from} });
                $assign ||= MT->model( 'ketaipost_author' )->load({ address => '' });
                unless ($assign) {
                    log_error("unknown author (".$ref_data->{from}.")", { blog_id => $blog->id });
                    $pop3->Delete($id) unless (get_system_setting('disable_delete_flag'));
                    next;
                }
                my $author = MT->model( 'author' )->load({ id => $assign->author_id });
                
                log_debug("author: ".$author->name);
                log_debug("subject: ".$ref_data->{subject}."\nbody:\n".$ref_data->{text});
                my $ref_images = $ref_data->{images};
                foreach my $ref_image(@$ref_images) {
                    log_debug("filename: ".$ref_image->{filename});
                }
                my $ref_movies = $ref_data->{movies};
                foreach my $ref_movie(@$ref_movies) {
                    log_debug("filename: ".$ref_movie->{filename});
                }
                
                # 権限のチェック
                unless ( if_can_on_blog( $author, $blog, 'create_post' ) ) {
                    log_error("記事の追加を試みましたが権限がありません。", {
                        blog_id => $blog->id,
                        author_id => $author->id});
                    $pop3->Delete($id) unless (get_system_setting('disable_delete_flag'));
                    next;
                }
                
                # 記事登録
                my ($subject, $text) = ($ref_data->{subject}, $ref_data->{text});
                $subject = get_setting($blog->id, 'default_subject') || '無題' unless ($subject);
                if ( use_escape($blog->id) ) {
                    $subject = MT::Util::encode_html($subject);
                    $text = MT::Util::encode_html($text);
                    $text =~ s/\r\n/\n/g;
                    $text =~ s/\n/<br \/>/g;
                } else {
                    # HTMLエスケープしない場合改行の扱いがネック br と 改行コード
                    # brタグが含まれるなら改行コードの変換を行わない
                    # そうでないなら改行コードをbrタグに変換 で暫定対処
                    if ( $text =~ m|<br\s*/?>| ) {
                        # 含まれるなら改行変換をしない
                    } else {
                        $text =~ s/\r\n/\n/g;
                        $text =~ s/\n/<br \/>/g;
                    }
                }

                if ( use_xatena( $blog->id ) ) {
                    log_debug( "はてな記法が有効です。" );
                    
                    $text =~ s/<br \/>\n?/\n/g;

                    require Text::Xatena;
                    my $syntaxes = [
                        'Text::Xatena::Node::SeeMore',
                        'Text::Xatena::Node::SuperPre',
                        'Text::Xatena::Node::StopP',
                        'Text::Xatena::Node::Blockquote',
                        'Text::Xatena::Node::Pre',
                        'Text::Xatena::Node::List',
                        'Text::Xatena::Node::DefinitionList',
                        'Text::Xatena::Node::Table',
                        'Text::Xatena::Node::Section',
                        'Text::Xatena::Node::Comment',
                        'Text::Xatena::Node::KetaiPost'
                    ];
                    my $thx = Text::Xatena->new( syntaxes => $syntaxes );
                    
                    #my $inline = Text::Xatena::Inline->new;
                    require Text::Xatena::Inline::KetaiPost;
                    my $inline = Text::Xatena::Inline::KetaiPost->new;
                    my $formatted = $thx->format( decode( 'utf8', $text ) , inline => $inline );
                    my $out = '';
                    $out .= '<div class="body">';
                    $out .= $formatted;
                    $out .= '</div>';
                    $out .= '<div class="notes">';
                    for my $footnote (@{ $inline->footnotes }) {
                        $out .= sprintf('<div class="footnote" id="#fn%d">*%d: %s</div>',
                                        $footnote->{number},
                                        $footnote->{number},
                                        $footnote->{note},
                                    );
                    }
                    $out .= '</div>';
                    $text = encode( 'utf8', $out );
                }

                my $entry = $self->create_entry($blog, $author, $subject, $text, $category);
                next unless $entry;
                
                push(@entry_ids, $entry->id);
                $pop3->Delete($id) unless (get_system_setting('disable_delete_flag'));
                
                # 処理ここから
                # ファイルアップロード権限ある場合のみ処理する
                unless ( if_can_on_blog( $author, $blog, 'upload' ) ) {
                    log_debug( "ファイルアップロード権限がありません。", {
                        blog_id => $blog->id,
                        author_id => $author->id } );
                } else {
                    if ( @$ref_images) {
                
                        $entry->created_on =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/;
                        my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
                    
                        # 添付写真の保存
                        # ファイルマネージャのインスタンス生成
                        my $fmgr = MT::FileMgr->new('Local');
                        unless ($fmgr) {
                            log_error(MT::FileMgr->errstr);
                            next;
                        }
                    
                        my $now = time;
                        my @t = MT::Util::offset_time_list($now, $blog);
                        for (my $i=0; $i<@$ref_images; $i++) {
                            my $ref_image = $ref_images->[$i];
                            # 新しいファイル名
                            my $new_filename = sprintf("%d_%d_%d.%s", $entry->id, $now, $i, $ref_image->{ext});
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
                        
                            log_debug("file_path: $file_path\nurl: $url");
                        
                            my @latlng = ();
                        
                            # ExifTool が必要な処理
                            if (use_exiftool) {
                                require Image::ExifTool;
                            
                                my $exifTool = new Image::ExifTool;
                                my $ref_image_data = \($ref_image->{data});
                                my $exifInfo = $exifTool->ImageInfo($ref_image_data,
                                                                    'Orientation',
                                                                    'GPSLatitude',
                                                                    'GPSLongitude');
                            
                                # 必要に応じて向きを補正
                                if (1) {
                                    log_debug("向きの補正が有効になっています。");
                                
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
                                        log_debug("Orientation: $rotation");
                                        if ($degrees && use_magick) {
                                            require Image::Magick;
                                            my $img = Image::Magick->new;
                                            $img->BlobToImage($ref_image->{data});
                                            $img->Rotate(degrees => $degrees);
                                            $ref_image->{data} = $img->ImageToBlob();
                                        }
                                    }
                                }
                            
                                # 位置情報を取得
                                if (use_gmap($blog->id)) {
                                    my @tmp = ($exifInfo->{GPSLatitude}, $exifInfo->{GPSLongitude});
                                    foreach my $geostr (@tmp) {
                                        if ($geostr && $geostr =~ /(\S+) deg (\S+)\' (.*)\"/) {
                                            my $p1 = $1;
                                            my $p2 = $2/60;
                                            my $p3 = $3/3600;
                                            push(@latlng, $p1 + $p2 + $p3);
                                        }
                                    }
                                    log_debug("GPSLatitude: ".($tmp[0] || '')." GPSLongitude:".($tmp[1] || '')." => lat: ".($latlng[0] || '')." lng: ".($latlng[1] || ''));
                                }
                            }
                        
                            # アップロード先ディレクトリ生成
                            unless($fmgr->exists($dir)) {
                                unless ($fmgr->mkpath($dir)) {
                                    log_error($fmgr->errstr);
                                    next;
                                }
                            }
                            # 保存
                            my $bytes = $fmgr->put_data($ref_image->{data}, $file_path, 'upload');
                        
                            unless (defined $bytes) {
                                log_error($fmgr->errstr);
                                next;
                            }            
                            log_debug($ref_image->{filename}." を ".$file_path." に書き込みました。");
                        
                            unless ( get_setting($blog->id, 'remove_exif') == 1 ) {
                                log_debug('Exif除去有効');
                                if ( use_magick && -f $file_path ) {
                                    require Image::Magick;
                                    my $thumb = Image::Magick->new();
                                    $thumb->Read( $file_path );
                                    if ( $thumb->[0] ) {
                                        $thumb->Profile( name=>"*", profile=>"" );
                                        $thumb->[0]->Write( filename => $file_path );
                                    }
                                }
                            }
                        
                            # アイテムの登録
                            my ( $width, $height ) = imgsize( $file_path );
                            my $asset = MT->model( 'image' )->new;
                            # 情報セット
                            $asset->label($entry->title);
                            $asset->file_path($file_path);
                            $asset->file_name($new_filename);
                            $asset->file_ext($ref_image->{ext});
                            $asset->mime_type( $ref_image->{type} );
                            $asset->blog_id($blog->id);
                            $asset->created_by($author->id);
                            $asset->modified_by($author->id);
                            $asset->url($url);
                            $asset->description('');
                            $asset->image_width($width);
                            $asset->image_height($height);
                            # アイテムの登録
                            unless ($asset->save) {
                                log_error("アイテムの登録に失敗");
                                next;
                            }

                            # エントリと関連づけ
                            my $obj_asset = MT->model( 'objectasset' )->new();
                            $obj_asset->blog_id($blog->id);
                            $obj_asset->asset_id($asset->id);
                            $obj_asset->object_ds('entry');
                            $obj_asset->object_id($entry->id);
                            $obj_asset->save;
                        
                            log_debug("アイテムを登録しました id:".$asset->id."path:$file_path url:$url");
                        }
                    }           # 写真ここまで

                    # 動画
                    if (@$ref_movies && use_ffmpeg($blog->id)) {
                        my $ffmpeg_path = get_system_setting('ffmpeg_path');
                        log_debug("ムービー掲載が有効です。");
                        log_debug("FFmpeg: $ffmpeg_path");
                    

                        $entry->created_on =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/;
                        my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
                    
                        # 添付写真の保存
                        # ファイルマネージャのインスタンス生成
                        my $fmgr = MT::FileMgr->new('Local');
                        unless ($fmgr) {
                            log_error(MT::FileMgr->errstr);
                            next;
                        }
                    
                        my $now = time;
                        my @t = MT::Util::offset_time_list($now, $blog);
                        for (my $i=0; $i<@$ref_movies; $i++) {
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
                        
                            log_debug("file_path: $file_path\nurl: $url");
                        
                            # アップロード先ディレクトリ生成
                            unless($fmgr->exists($dir)) {
                                unless ($fmgr->mkpath($dir)) {
                                    log_error($fmgr->errstr);
                                    next;
                                }
                            }

                            # 変換
                            my $temp_dir = get_system_setting('temp_dir');

                            my($tmp_fh, $tmp_filename) = File::Temp::tempfile(
                                'movie_XXXXXX',
                                SUFFIX => ".@{[ $ref_movie->{ext} ]}",
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

                            system("$ffmpeg_path -y -i $tmp_filename -an -pass 1 -passlogfile $tmppasslog_filename -vcodec flv -f flv -b 5M $tmpout_filename");
                            system("$ffmpeg_path -y -i $tmp_filename -ar 44100 -acodec libmp3lame -pass 2 -passlogfile $tmppasslog_filename -vcodec flv -f flv -b 5M $tmpout_filename");

                            my($tmpthumb_fh, $tmpthumb_filename) = File::Temp::tempfile(
                                TEMPLATE => 'image_XXXXXX',
                                SUFFIX => '.jpg',
                                UNLINK => 1,
                                DIR => $temp_dir
                            );
                            close($tmpthumb_fh);

                            system("$ffmpeg_path -y -i $tmp_filename -f image2 -ss 1 -r 1 -an -deinterlace $tmpthumb_filename");
                        
                            # 保存
                            my $bytes = $fmgr->put($tmpout_filename, $file_path, 'upload');
                            unless (defined $bytes) {
                                log_error($fmgr->errstr);
                                next;
                            }            
                            log_debug($ref_movie->{filename}." を ".$file_path." に書き込みました。");
                        
                            # アイテムの登録
                            my $asset = MT->model( 'video' )->new;
                            # 情報セット
                            $asset->label($entry->title);
                            $asset->file_path($file_path);
                            $asset->file_name($new_filename);
                            $asset->file_ext($ref_movie->{ext});
                            $asset->mime_type( $ref_movie->{type} );
                            $asset->blog_id($blog->id);
                            $asset->created_by($author->id);
                            $asset->modified_by($author->id);
                            $asset->url($url);
                            $asset->description('');

                            # アイテムの登録
                            unless ($asset->save) {
                                log_error("アイテムの登録に失敗");
                                next;
                            }

                            # エントリと関連づけ
                            my $obj_asset = MT->model( 'objectasset' )->new();
                            $obj_asset->blog_id($blog->id);
                            $obj_asset->asset_id($asset->id);
                            $obj_asset->object_ds('entry');
                            $obj_asset->object_id($entry->id);
                            $obj_asset->save;
                        
                            log_debug("アイテムを登録しました id:".$asset->id."path:$file_path url:$url");
                        
                            $bytes = $fmgr->put($tmpthumb_filename, $thumbnail_path, 'upload');
                            unless (defined $bytes) {
                                log_error($fmgr->errstr);
                                next;
                            }            
                            log_debug($ref_movie->{filename}." を ".$file_path." に書き込みました。");
                        

                            my ($thumbnail_basename, $thumbnail_dir, $thumbnail_ext) = fileparse($thumbnail_path, qr/\.[^.]*/);
                            my $thumbnail_url = $root_url.File::Spec->abs2rel($thumbnail_path, $root_path);
                            log_debug("サムネイルを作成しました。 path:$thumbnail_path url:$thumbnail_url");
                        
                            # サムネイルの登録
                            my ( $thumb_width, $thumb_height ) = imgsize( $thumbnail_path );
                            my $thumbnail_asset = MT->model( 'image' )->new;
                            $thumbnail_asset->label('Thumbnail of '.$asset->label);
                            $thumbnail_asset->file_path($thumbnail_path);
                            $thumbnail_asset->file_name($thumbnail_filename);
                            $thumbnail_asset->file_ext($thumbnail_ext);
                            $thumbnail_asset->mime_type( 'image/jpeg' );
                            $thumbnail_asset->blog_id($blog->id);
                            $thumbnail_asset->created_by($author->id);
                            $thumbnail_asset->modified_by($author->id);
                            $thumbnail_asset->url($thumbnail_url);
                            $thumbnail_asset->description('');
                            $thumbnail_asset->image_width($thumb_width);
                            $thumbnail_asset->image_height($thumb_height);
                            $thumbnail_asset->parent($asset->id); # 親の設定
                        
                            unless ($thumbnail_asset->save) {
                                log_error("サムネイルのアイテム登録に失敗");
                            }
                            log_debug("サムネイルを登録しました id:".$asset->id."path:$thumbnail_path url:$thumbnail_url parent_id:".$asset->id);
                        }
                    } # 動画ここまで
                    
                }
                # 記事テンプレートの適用
                my $old_entry = $entry->clone;
                my ($new_text, $tmpl_error) = $self->build_entry_text($entry);
                if ( defined($new_text) ) {
                    utf8::decode($new_text) unless utf8::is_utf8($new_text);
                    $entry->text($new_text);
                    $entry->save;
                } else {
                    log_error($tmpl_error);
                    next;
                }
                
            } # end loop
        }; # eval
        log_error($@) if $@;

        $pop3->Close();
    }

    foreach my $entry_id(@entry_ids) {
        my $obj = MT->model( 'entry' )->load( $entry_id );
        $self->rebuild_entry_page( $obj );
        $self->send_entry_notify( $obj );
        $self->run_callbacks( $obj );
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
    
    require KetaiPost::Emoji if (use_emoji);

    my $cfg = MT::ConfigMgr->instance;

    my $head = $entity->head;

    # 宛先取り出し
    my @recipients;
    my $recipient = $head->get('to');
    chomp($recipient) if $recipient;
    my @addrs = Mail::Address->parse($recipient);
    foreach my $addr (@addrs) {
        my $buf = $addr->address;
        # 変なメールアドレスは""で囲まれている可能性があるので外しとく
        $buf =~ s/^"(.+)"(@.+)$/$1$2/;
        push(@recipients, $buf);
    }
    # 宛先メールアドレスの制限
    if (my $to = $options->{To}) {
        log_debug("to:$to recipients:".join(',', @recipients));
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
    } elsif ($umail =~ /(softbank\.ne\.jp|vodafone\.ne\.jp|disney\.ne\.jp|i\.softbank\.jp)\z/) {
        $carrier = 'softbank';
    }
    
    log_debug("umail: $umail uname: $uname");
    
    # 時刻
    # HTTP::Date が使えればメールの日付を取得
    #my $written_time;
    #if (use_http_date) {
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
    unless ($@ || use_emoji) {
        log_debug("Encode によるMIMEデコードを行います");
        $subject = decode('MIME-Header', $subject);
    } else {
        if ($subject =~ /=\?([^\?]+)\?B\?([^\?]+)/) {
            log_debug("MIME::Base64 によるMIMEデコードを行います");
            require MIME::Base64;
            
            my @lines = split("\n", $subject);
            my $charset;
            my $encoded;
            foreach my $line(@lines) {
                next unless $line =~ /=\?([^\?]+)\?B\?([^\?]+)/;
                $charset = $1;
                $encoded .= $2;
            }
            log_debug("encoded_subject: $encoded");
            my $decoded = MIME::Base64::decode_base64($encoded);
            if (use_emoji) {
                $subject = KetaiPost::Emoji::decode2utf8($carrier, $charset, $decoded);
            } else {
                $subject = encode('utf-8', decode($charset, $decoded));
            }
        }
    }
    log_debug("subject: $subject");
    utf8::encode($subject) if utf8::is_utf8($subject); # フラグを落とす
    $subject = MT::I18N::encode_text($subject, 'utf-8', undef);
    $subject =~ s/[\x00-\x1f]//g if $subject;
    
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
    
    my %imagetypes = ('image/pjpeg' => 'jpg',
                      'image/jpeg' => 'jpg',
                      'image/gif' => 'gif',
                      'image/png' => 'png');
    my %movietypes = ('video/3gpp2' => '3gp',
                      'video/3gpp' => '3gp',
                      'video/mp4' => 'mp4');
    
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
            log_debug("part: $type (bodyhandle ".($part->bodyhandle ? 'found' : 'not found').")");
            
            if ( $type =~ /multipart\/alternative/ || $type =~ /multipart\/related/ ) {
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
                my $buf = $self->_encode_text( $carrier, $part->bodyhandle->as_string, $text_charset );
                next if $buf =~ /\A\s*\z/m;
                $text .= $buf;
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
                            log_error("添付ファイルのサイズが大きすぎます。スキップしました。（最大 $maxbytes Bytes）");
                            next;
                        }
                        
                        my $ref_image = {
                            data => $data,
                            filename => $fname,
                            ext => $extname,
                            type => $type,
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
                            log_error("添付ファイルのサイズが大きすぎます。スキップしました。（最大 $maxbytes Bytes）");
                            next;
                        }
                        my $ref_movie = {
                            data => $data,
                            filename => $fname,
                            ext => $extname,
                            type => $type,
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
    log_debug("body charset: ".(lc $text_charset)." ($normalized_text_charset)");

    if (use_emoji) {
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

    my $app = MT->instance;
    my $publisher = MT::WeblogPublisher->new;
    my $entry  = MT->model( 'entry' )->new;
    
    log_debug("エントリを投稿します");
    
    my ( $subject2, $text2 ) = ($subject, $text);
    # MT::Objectに入れるものはフラグを立てる
    utf8::decode($subject2) unless utf8::is_utf8($subject2);
    utf8::decode($text2) unless utf8::is_utf8($text2);

    $entry->blog_id($blog->id);
    $entry->category_id($category->id) if $category;
    $entry->author_id($author->id);
    # 公開権限がない時は下書きにする あるときはブログの既定

    $entry->status( if_can_on_blog( $author, $blog, 'publish_post' ) ?
                      $blog->status_default :
                        MT->model( 'entry' )->HOLD() );
    $entry->title($subject2);
    $entry->text($text2);
    $entry->allow_comments($blog->allow_comments_default);
    $entry->allow_pings($blog->allow_pings_default);
    if($entry->save) {
        # 記事とカテゴリの関連付け
        if($category) {
            my $place = MT->model( 'placement' )->new;
            $place->entry_id($entry->id);
            $place->blog_id($entry->blog_id);
            $place->category_id($category->id);
            $place->is_primary(1);
            $place->save;
        }

        log_info("'".$author->name."'がブログ記事'".$entry->title."'(ID:".$entry->id.")を追加しました。", {
            author_id => $author->id,
            blog_id => $blog->id,
        });
        log_debug($entry->permalink);

        return $entry;
    } else {
        log_debug("投稿失敗");
    }

    return;
}

# 記事テンプレートの取得
sub load_entry_tmpl {
    my $self = shift;
    my ( $blog_id ) = @_;
    my $template_id = get_setting($blog_id, 'entry_text_template_id');
    log_debug( "template_id: @{[ defined $template_id ? $template_id : '' ]}" );
    my $tmpl;
    $tmpl = MT->model('template')->load({
        id => $template_id,
        type => 'custom'
    }) if defined $template_id;
    return $tmpl if $tmpl;
    
    $tmpl = $plugin->load_tmpl( 'entry.tmpl' );
    return $tmpl;
}

# 本文の構築
sub build_entry_text {
    my $self = shift;
    my ( $entry, $tmpl ) = @_;
    
    my $blog = MT->model( 'blog' )->load( $entry->blog_id );
    my $category = $entry->category;
    
    $tmpl = $self->load_entry_tmpl( $entry->blog_id ) unless $tmpl;
    
    $tmpl = $tmpl->text
    	if ( ( ref $tmpl ) eq 'MT::Template' );
    
    require MT::Template::Context;
	my $ctx = MT::Template::Context->new;

    $ctx->stash( 'entry', MT->model( 'entry' )->load( $entry->id ) );
    $ctx->stash( 'blog',  $blog );
    $ctx->stash( 'category', $category ) if $category;
    $ctx->{current_timestamp} = $entry->created_on;
    
    my %params = (
        thumbnail_width => get_setting($blog->id, 'thumbnail_size') || 240,
        movie_width => get_setting($blog->id, 'player_size') || 360,
    );
    my $thumbnail_shape = get_setting($blog->id, 'thumbnail_shape');
    if ( $thumbnail_shape == 1 ) {
        # 縮小
        $params{thumbnail_square} = 0;
    } elsif ( $thumbnail_shape == 2 ) {
        # 切り抜き
        $params{thumbnail_square} = 1;
    }
    
    #my $html = $tmpl->output( \%params );
    #my $error = $tmpl->errstr;
    
    for my $key ( keys %params ) {
        $ctx->{ __stash }->{ vars }->{ $key } = $params{ $key };
    }
    my $build = MT::Builder->new;
    my $tokens = $build->compile( $ctx, $tmpl );
    return ( undef, $build->errstr ) unless ( $tokens );

    my $html = $build->build( $ctx, $tokens );
    return ( undef, $build->errstr ) unless ( defined $html );

    return ( $html, undef );
}

# 記事が「公開」なら再構築
sub rebuild_entry_page {
    my $self = shift;
    my ($entry) = @_;

    return unless $entry->status == MT::Entry::RELEASE();
    
    my $publisher = MT::WeblogPublisher->new;
    my $ret = $publisher->rebuild_entry(
        Entry => $entry,
        Blog => $entry->blog,
        BuildDependencies => 1
    );

    log_debug("ID:".$entry->id."を再構築しました。", {
        author_id => $entry->author_id,
        blog_id => $entry->blog_id,
    });

    $ret;
}

# 記事が「公開」なら通知
sub send_entry_notify {
    my $self = shift;
    my ( $entry ) = @_;

    my $app = MT->instance;

    unless ( use_notify( $entry->blog_id ) ) {
        log_debug( '公開通知の送信が無効か、または利用できません。', { blog_id => $entry->blog_id } );
        return 0;
    }
    log_debug( '公開通知の送信が有効です。', { blog_id => $entry->blog_id } );

    return 0 unless $entry->status == MT::Entry::RELEASE();

    my $entry_id = $entry->id or return 0;
    
    my $blog = MT->model( 'blog' )->load( $entry->blog_id );

    my $author = $entry->author;

    my $cols = 72;
    my %params;
    $params{ blog }   = $blog;
    $params{ entry }  = $entry;
    $params{ author } = $author;

    $params{ message } = 'メール投稿により記事を公開しました。（このメールは自動送信です。）';

    $params{ send_body } = 1;

    my $addrs;
    my $iter = MT->model( 'notification' )->load_iter( { blog_id => $blog->id } );
    while ( my $note = $iter->() ) {
        next unless is_valid_email( $note->email );
        $addrs->{ $note->email } = 1;
    }

    unless ( keys %$addrs ) {
        log_info( $app->translate( "No valid recipients found for the entry notification." ), {
            blog_id => $entry->blog_id,
            author_id => $entry->author_id
        });
        return 0;
    }

    my $body = $app->build_email( 'notify-entry.tmpl', \%params );

	my $tmpl = get_setting( $blog->id, 'notify_subject' );
	my ( $subj, $tmpl_error ) = $self->build_entry_text($entry, $tmpl);
	unless ( defined($subj) ) {
		log_error($tmpl_error);
		return;
	}
    if ( $app->current_language ne 'ja' ) {
        $subj =~ s![\x80-\xFF]!!g;
    }

    my $from = $author->email || $app->config->EmailAddressMain;
    my %head = (
        id      => 'notify_entry',
        Subject => $subj,
        $from ? ( From => $from ) : (),
    );

    my $charset = $app->config( 'MailEncoding' ) || $app->charset;
    $head{ 'Content-Type' } = qq(text/plain; charset="$charset");
    my $i = 1;
    require MT::Mail;

    log_debug( 'addrs:' . Data::Dumper->Dump( [ $addrs ] ) );
    log_debug( 'header: '.Data::Dumper->Dump( [\%head] ) . ' body:' . $body );

    foreach my $email ( keys %{$addrs} ) {
        next unless $email;
        if ( $app->config( 'EmailNotificationBcc' ) ) {
            push @{ $head{Bcc} }, $email;
            if ( $i++ % 20 == 0 ) {
                unless ( MT::Mail->send( \%head, $body ) ) {
                    log_error( $app->translate( "Error sending mail ([_1]); try another MailTransfer setting?",
                                                MT::Mail->errstr
                                              ) );
                    return 0;
                }
                @{ $head{ Bcc } } = ();
            }
        } else {
            $head{ To } = $email;
            unless ( MT::Mail->send( \%head, $body ) ) {
                log_error( $app->translate( "Error sending mail ([_1]); try another MailTransfer setting?",
                                            MT::Mail->errstr
                                          ) );
                return 0;
            }
            delete $head{To};
        }
    }

    if ( $head{Bcc} && @{ $head{Bcc} } ) {
        unless ( MT::Mail->send( \%head, $body ) ) {
            log_error( $app->translate( "Error sending mail ([_1]); try another MailTransfer setting?",
                                        MT::Mail->errstr
                                      ) );
            return 0;
        }
    }
    return 1;
}

sub run_callbacks {
    my $self = shift;
    my ( $entry ) = @_;
    my $app = MT->instance;
    MT->run_callbacks('cms_post_save.entry', $app, $entry);
}

1;
