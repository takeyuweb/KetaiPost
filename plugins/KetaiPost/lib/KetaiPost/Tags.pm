package KetaiPost::Tags;

use strict;
use warnings;
use MT::Entry;
use MT::Asset::Image;
use File::Basename;

use KetaiPost::Util qw( log_debug get_setting );

sub _hdlr_entry_ketai_post_video {
    my ( $ctx, $args ) = @_;

    log_debug( "_hdlr_entry_ketai_post_video called" );
    
    my $tag = 'MT' . $ctx->stash( 'tag' );
    my $entry = $ctx->stash( 'entry' );
    return $ctx->_no_entry_error( $tag ) unless defined $entry;
    log_debug("[$tag] entry found.");
    my $asset = $ctx->stash( 'asset' );
    return $ctx->_no_asset_error( $tag ) unless defined $asset;
    log_debug("[$tag] video found.");
    my $thumbnail = MT::Asset::Image->load( { parent => $asset->id } );
    log_debug("[$tag] thumbnail found.");
    
    my $jwplayer_url = get_setting($entry->blog_id, 'jwplayer_url');
    my ($video_basename) = fileparse($asset->file_name, qr/.flv/);
    my $url = $asset->url;
    my $thumbnail_url = $thumbnail->url;
    my $thumb_width = $thumbnail->image_width;
    my $thumb_height = $thumbnail->image_height;
    
    my $video_width = $args->{width} || $thumb_width;
    
    my $scale = $video_width / $thumb_width;
    $scale = 1.0 if $scale > 1;
    
    my $html = sprintf(<<'HTML', $jwplayer_url, $video_basename, $video_basename, $jwplayer_url, $url, $thumbnail_url, $thumb_width*$scale, $thumb_height*$scale);
<script type="text/javascript" src="%s/jwplayer.js"></script>
<div id="%s-container">Loading the player ...</div>
<script type="text/javascript">
jwplayer("%s-container").setup({
flashplayer: "%s/player.swf",
file: "%s",
image: "%s",
width: %d,
height: %d,
showstop: "true",
type: "video"
});
</script>
HTML
    
    return $html;
}

1;
