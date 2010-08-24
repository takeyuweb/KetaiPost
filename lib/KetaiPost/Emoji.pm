# $Id$

package KetaiPost::Emoji;

use strict;
use warnings;
use utf8;

use Encode;
use Encode::JP::Emoji;
use Encode::JP::Emoji::FB_EMOJI_TYPECAST;
my $image_base = '';
my $html_format = '<emoticons base="%s" name="%s" alt="%s" />';
$Encode::JP::Emoji::FB_EMOJI_TYPECAST::HTML_FORMAT = $html_format;
$Encode::JP::Emoji::FB_EMOJI_TYPECAST::IMAGE_BASE = $image_base;

our @EXPORT = qw(decode);

my $ENCODING_TABLE = {
    docomo => {
	sjis => 'x-sjis-e4u-docomo',
	utf8 => 'x-utf8-e4u-docomo',
    },
    kddi => {
	sjis => 'x-sjis-e4u-kddiapp',
	utf8 => 'x-utf8-e4u-kddiapp',
    },
    softbank => {
	sjis => 'x-sjis-e4u-softbank2g',
	utf8 => 'x-utf8-e4u-softbank2g'
    }
};

# 絵文字をTypeCast形式で表記したUTF-8文字列に変換
# キャリアと文字コードを指定
# KetaiPost::Emoji::decode2utf8('docomo', 'sjis', $text);
sub decode2utf8 {
    my ($carrier, $charset, $text) = @_;
    return '' unless $text;
    
    my $option = {};

    $charset = lc($charset);
    $charset = {
	'shift-jis'=>'sjis',
	'shift_jis'=>'sjis',
	'iso-2022-jp'=>'jis',
	'euc-jp'=>'euc',
	'utf-8'=>'utf8'
    }->{$charset} || $charset;
    my $carrier_table = $ENCODING_TABLE->{$carrier || 'pc'} || {};
    my $encoding = $carrier_table->{$charset};
    if ($encoding) {
	$text = KetaiPost::Emoji::_decode($encoding, $text);
    } else {
	Encode::from_to($text, $charset, 'utf-8');
    }
    return $text;
}

# 絵文字をTypeCast形式で表記したUTF-8文字列に変換
# KetaiPost::Emoji::_decode('x-sjis-e4u-docomo', $text);
sub _decode {
    my ($encoding, $text) = @_;
    
    # さくらだと↓でOKだけど、ハッスルだとダメだった 
    #    Encode::from_to($text, $encoding, 'x-utf8-e4u-none',
    #    Encode::JP::Emoji::FB_EMOJI_TYPECAST::FB_EMOJI_TYPECAST());
    
    # ↓これならできた
    Encode::from_to($text, $encoding, 'utf8');  # Google UTF-8
    $text = Encode::decode('x-utf8-e4u-none', $text,
			   Encode::JP::Emoji::FB_EMOJI_TYPECAST::FB_EMOJI_TYPECAST());
    utf8::encode($text) if utf8::is_utf8($text); # フラグを落とす

    $text =~ s{<emoticons base="" name="([\w\-]{0,16})".*?/>}{_emoticon_mark($1)}eg;
    return $text;
}

sub _emoticon_mark {
    my ($name) = @_;
    return '[E:'.$name.']';
}

1;
