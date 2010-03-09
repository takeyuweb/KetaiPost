# KetaiPost (C) 2010 Yuichi Takeuchi
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id: Author.pm $


package KetaiPost::Author;
use warnings;
use strict;
use Carp;

use MT::Object;
@KetaiPost::Author::ISA = qw( MT::Object );

__PACKAGE__->install_properties ({
    column_defs => {
        'id' => 'integer not null auto_increment',
	'author_id' => 'integer not null',
	'address' => 'string(255)',
    },
    indexes => {
    },
    child_of => 'MT::Author',
    datasource => 'ketaipost_author',
    #audit => 1,
    primary_key => 'id',
});

1;

__END__
