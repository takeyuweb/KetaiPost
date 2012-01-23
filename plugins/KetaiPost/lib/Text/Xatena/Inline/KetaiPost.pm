package Text::Xatena::Inline::KetaiPost;

use strict;
use warnings;
use URI::Escape;
use HTML::Entities;
use Text::Xatena::Inline -Base;

sub _prepend_match ($$) { ## no critic
    my ($regexp, $block) = @_;
    my $pkg = caller(0);
    unshift @{ $pkg->inlines }, { regexp => $regexp, block => $block };
}

match qr<\[b:([^\]]+)\]>i => sub {
    my ( $self, $html ) = @_;
    return sprintf( '<strong>%s</strong>', $html );
};

match qr<\[size:([^\:]+):([^\]]+)\]>i => sub {
    my ( $self, $size, $html ) = @_;
    return sprintf( '<span style="font-size: %s;">%s</span>',
                    encode_entities( $size ),
                    $html );
};

match qr<\[color:([^\:]+):([^\]]+)\]>i => sub {
    my ( $self, $color, $html ) = @_;
    return sprintf( '<span style="color: %s;">%s</span>',
                    encode_entities( $color ),
                    $html );
};

_prepend_match qr<\[((?:https?|ftp)://[^\s:]+(?::\d+)?[^\s:]+)(:(?:title(?:=([^[]+))?|barcode))?:blank\]>i => sub {
    my ($self, $uri, $opt, $title) = @_;

    if ($opt) {
        if ($opt =~ /^:barcode$/) {
            return sprintf('<img src="http://chart.apis.google.com/chart?chs=150x150&cht=qr&chl=%s" title="%s"/>',
                uri_escape($uri),
                $uri,
            );
        }
        if ($opt =~ /^:title/) {
            if (!$title && $self->{aggressive}) {
                $title = $self->cache->get($uri);
                if (not defined $title) {
                    eval {
                        $title = $self->title_of($uri);
                        $self->cache->set($uri, $title, "30 days");
                    };
                    if ($@) {
                        warn $@;
                    }
                }
            }
            return sprintf('<a href="%s" target="_blank">%s</a>',
                $uri,
                encode_entities(decode_entities($title || ''))
            );
        }
        
    } else {
        return sprintf('<a href="%s" target="_blank">%s</a>',
            $uri,
            $uri
        );
    }

};

1;
__END__



