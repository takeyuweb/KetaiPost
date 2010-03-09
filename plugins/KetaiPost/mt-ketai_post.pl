# $Id$

package MT::Plugin::KetaiPost;

use strict;
use MT::Plugin;
use base qw( MT::Plugin );

use vars qw($PLUGIN_NAME $VERSION);
$PLUGIN_NAME = 'KetaiPost';
$VERSION = '0.1';

use KetaiPost::MailBox;
use KetaiPost::Author;

use MT;
my $plugin = MT::Plugin::KetaiPost->new({
    id => 'ketaipost',
    key => __PACKAGE__,
    name => $PLUGIN_NAME,
    version => $VERSION,
    description => "携帯メールを使った記事投稿のためのプラグイン。",
    doc_link => '',
    author_name => 'Yuichi Takeuchi',
    author_link => 'http://takeyu-web.com/',
    schema_version => 0.01,
    object_classes => [ 'KetaiPost::MailBox', 'KetaiPost::Author' ],
    # settings => new MT::PluginSettings([
    #    ['allow_picture', { Default => 1 }],
    # ]),
    registry => {
        object_types => {
            'ketaipost_mailbox' => 'KetaiPost::MailBox',
	    'ketaipost_author' => 'KetaiPost::Author'
        },
        tasks =>  {
            'KetaiPost' => {
                label     => 'KetaiPost',
                frequency => 1 * 60 * 60,   # no more than every 1 hours
                code      => \&do_ketai_post,
            },
        },
	# 管理画面
	applications => {
	    cms => {
		menus => {
		    'settings:list_ketaipost' => {
			label => 'KetaiPost',
			order => 10100,
			mode => 'list_ketaipost',
			view => 'system',
			system_permission => "administer",
		    }
		},
		methods => {
		    list_ketaipost => '$ketaipost::KetaiPost::CMS::list_ketaipost',
		    edit_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::edit_ketaipost_mailbox',
		    save_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::save_ketaipost_mailbox',
		    edit_ketaipost_author => '$ketaipost::KetaiPost::CMS::edit_ketaipost_author',
		    save_ketaipost_author => '$ketaipost::KetaiPost::CMS::save_ketaipost_author',
		}
	    }
	}
    },
});

MT->add_plugin($plugin);

sub instance { $plugin; }

sub doLog {
    my ($msg) = @_; 
    return unless defined($msg);

    use MT::Log;
    my $log = MT::Log->new;
    $log->message($msg) ;
    $log->save or die $log->errstr;
}

#----- Task
sub do_ketai_post {
    
    1
}

1;
