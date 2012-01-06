package Text::Xatena::Node::KetaiPost;

use strict;
use warnings;
use base qw(Text::Xatena::Node);
use Text::Xatena::Util;

use HTML::Entities;

use constant {
    BEGINNING => qr/^>\[([^\]]*)\]$/,
    ENDOFNODE => qr/^\[\]<$/,
};

sub parse {
    my ($class, $s, $parent, $stack) = @_;
    if ($s->scan(BEGINNING)) {
        my $style = $s->matched->[1];
        my $content = $s->scan_until(ENDOFNODE);
        pop @$content;
        my $node = $class->new([join("\n", @$content)]);
        $node->{style} = $style;
        push @$parent, $node;
        return 1;
    }
}

sub style { $_[0]->{style} }

sub as_html {
    my ($self, $context, %opts) = @_;
    $context->_tmpl(__PACKAGE__, q[
        ? if ($style) {
            <div style="{{= $style }};">{{= $content }}</div>
        ? } else {
            <div>{{= $content }}</div>
        ? }
    ], {
        style    => encode_entities( $self->style ),
        content => escape_html(join "", @{ $self->children })
    });
}

1;
__END__
