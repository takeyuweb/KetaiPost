package Text::Xatena::Inline::KetaiPost;

use strict;
use warnings;
use URI::Escape;
use HTML::Entities;
use Text::Xatena::Inline -Base;

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

1;
__END__



