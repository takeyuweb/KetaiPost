# KetaiPost (C) 2010 Yuichi Takeuchi
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id: MailBox.pm $


package KetaiPost::MailBox;
use warnings;
use strict;
use Carp;

use MT::Object;
@KetaiPost::MailBox::ISA = qw( MT::Object );

__PACKAGE__->install_properties ({
    column_defs => {
        'id' => 'integer not null auto_increment',
	'blog_id' => 'integer not null',
	'address' => 'string(255) not null',
	'account' => 'string(255) not null',
	'password' => 'string(255) not null',
	'host' => 'string(255) not null',
	'port' => 'integer not null',
	'use_ssl' => 'boolean',
    },
    indexes => {
    },
    child_of => 'MT::Blog',
    datasource => 'ketaipost_mailbox',
    #audit => 1,
    primary_key => 'id',
});

1;

__END__
