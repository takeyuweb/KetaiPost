# KetaiPost (C) 2010 Yuichi Takeuchi
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id: CMS.pm $

package KetaiPost::CMS;

use strict;
use warnings;
use utf8;

use MT::Blog;
use MT::Author;
use KetaiPost::MailBox;
use KetaiPost::Author;

# KetaiPostの設定データを一覧表示
# ブログ管理画面のときは、そのブログに関することの設定だけが可能 (TODO)
# いまのところシステム設定のみ
sub list_ketaipost {
    my $app = shift;
    # my $blog_id = $app->param('blog_id');

    my $mailboxes_iter = KetaiPost::MailBox->load_iter({}, {});
    my $authors_iter = KetaiPost::Author->load_iter({}, {});

    my @mailboxes;
    my @authors;

    while (my $obj = $mailboxes_iter->()) {
	my $blog = MT::Blog->load($obj->blog_id);
	my $category = MT::Category->load($obj->category_id);
	my $ref_mailbox = {
	    id => $obj->id,
	    blog => $blog->name,
	    category => $category ? $category->label : '',
	    address => $obj->address
	};
	push(@mailboxes, $ref_mailbox);
    }

    while (my $obj = $authors_iter->()) {
	my $author = MT::Author->load($obj->author_id);
	my $ref_author = {
	    id => $obj->id,
	    author => $author->name,
	    address => $obj->address
	};
	push(@authors, $ref_author);
    }

    my $params = {
	mailboxes => \@mailboxes,
	authors => \@authors,
    };

    my $tmpl = $app->load_tmpl('list_ketaipost.tmpl');
    
    return $app->build_page($tmpl, $params);
}

# 送信先メールアドレス（メールボックス）のの編集の準備として、
# ブログを選択させる（カテゴリの設定のため）
sub select_ketaipost_blog {
    my $app = shift;
    my $id = $app->param('id');
    my $mailbox;
    $mailbox = KetaiPost::MailBox->load({ id => $id });
    $mailbox = KetaiPost::MailBox->new unless $mailbox;

    my @blogs;

    my $blog_iter = MT::Blog->load_iter({}, {});
    while (my $obj = $blog_iter->()) {
	my $selected = $obj->id  == $mailbox->blog_id ? 1 : 0;
	my $blog = {
	    id => $obj->id,
	    name => $obj->name,
	    selected => $selected
	};
	push(@blogs, $blog);
    }

    my $params = {
	id => $mailbox->id,
        blogs => \@blogs,
	return_args => $app->param('return_args'),
    };

    return $app->load_tmpl('select_ketaipost_blog.tmpl', $params);
}

sub trace_category {
    my ($ref_categories, $parent, $ref_chains) = @_;

    $ref_chains ||= [];

    push(@$ref_chains, $parent->label);
    my $category = {
	id => $parent->id,
	label => join(' > ', @$ref_chains),
	primary => 0
    };
    push(@$ref_categories, $category);

    my $category_iter = MT::Category->load_iter({ parent => $parent->id }, {});
    while (my $obj = $category_iter->()) {
	&trace_category($ref_categories, $obj, $ref_chains);
    }

    pop(@$ref_chains);
}

# 送信先メールアドレス（メールボックス）の登録
# KetaiPost::MailBox のIDが指定されていれば編集
sub edit_ketaipost_mailbox {
    my $app = shift;
    my $id = $app->param('id');
    my $blog_id = $app->param('blog_id');
    my $mailbox;
    $mailbox = KetaiPost::MailBox->load({ id => $id });
    $mailbox = KetaiPost::MailBox->new unless $mailbox;

    my $blog = MT::Blog->load({id => $blog_id});
    die "ブログが見つかりません" unless $blog;

    my @categories;

    my @top_level_categories = MT::Category->top_level_categories($blog->id);
    foreach my $obj(@top_level_categories) {
	&trace_category(\@categories, $obj);
    }
    foreach my $category(@categories) {
	$category->{selected} = 1 if $category->{id} == $mailbox->category_id;
    }

    my $params = {
	id => $mailbox->id,
	address => $mailbox->address,
	account => $mailbox->account,
	password => $mailbox->password,
	host => $mailbox->host,
	port => $mailbox->port || 110,
	use_ssl => $mailbox->use_ssl,
	use_apop => $mailbox->use_apop,
	blog_name => $blog->name,
	blog_id => $blog->id,
	categories => \@categories,
	return_args => $app->param('return_args'),
    };

    return $app->load_tmpl('edit_ketaipost_mailbox.tmpl', $params);
}

# 送信先メールアドレス（メールボックス）の保存
# KetaiPost::MailBox のIDが指定されていれば更新
sub save_ketaipost_mailbox {
    my $app = shift;
    my $id = $app->param('id');

    return unless $app->validate_magic;

    my $mailbox;
    $mailbox = KetaiPost::MailBox->load($id) if $id > 0;
    $mailbox = KetaiPost::MailBox->new unless $mailbox;

    my $blog_id = $app->param('blog_id');
    my $category_id = $app->param('category_id');

    my $blog = MT::Blog->load({'id' => $blog_id}) if $blog_id > 0;
    my $category = MT::Category->load({id => $category_id, blog_id => $blog->id}) if $blog && $category_id > 0;
    $mailbox->blog_id($blog->id) if $blog;
    $mailbox->category_id($category ? $category->id : 0);
    $mailbox->address($app->param('address'));
    $mailbox->host($app->param('host'));
    $mailbox->port($app->param('port'));
    $mailbox->account($app->param('account'));
    $mailbox->password($app->param('password'));
    $mailbox->use_ssl($app->param('use_ssl'));
    $mailbox->use_apop($app->param('use_apop'));

    $mailbox->save or die "保存に失敗しました：", $mailbox->errstr;

    my $params = {
	return_uri => $app->return_uri,
    };
    return $app->load_tmpl('save_ketaipost_mailbox.tmpl', $params);
}

sub delete_ketaipost_mailbox {
    my $app = shift;
    my @ids = $app->param('id');

    return unless $app->validate_magic;

    foreach my $id(@ids) {
	my $mailbox = KetaiPost::MailBox->load({id => $id});
	next unless $mailbox;
	$mailbox->remove();
    }
    
    $app->call_return;
}

# 送信元メールアドレスとユーザーとの関連付け
sub edit_ketaipost_author {
    my $app = shift;
    my $id = $app->param('id');
    my $author;
    $author = KetaiPost::Author->load({ id => $id });
    $author = KetaiPost::Author->new unless $author;

    my @authors;

    my $author_iter = MT::Author->load_iter({}, {});
    while (my $obj = $author_iter->()) {
	my $selected = $obj->id  == $author->author_id ? 1 : 0;
	my $author = {
	    id => $obj->id,
	    name => $obj->name,
	    selected => $selected
	};
	push(@authors, $author);
    }

    my $params = {
	id => $author->id,
	address => $author->address,
        authors => \@authors,
	return_args => $app->param('return_args'),
    };

    return $app->load_tmpl('edit_ketaipost_author.tmpl', $params);
}

# 送信元メールアドレスの保存
sub save_ketaipost_author {
    my $app = shift;
    my $id = $app->param('id');

    return unless $app->validate_magic;
    
    my $author;
    $author = KetaiPost::Author->load($id) if $id > 0;
    $author = KetaiPost::Author->new unless $author;

    my $obj = MT::Author->load({'id' => $app->param('author_id')});
    $author->author_id($obj->id) if $obj;
    $author->address($app->param('address'));

    $author->save or die "保存に失敗しました：", $author->errstr;

    my $params = {
	return_uri => $app->return_uri,
    };
    return $app->load_tmpl('save_ketaipost_author.tmpl', $params);
}

sub delete_ketaipost_author {
    my $app = shift;
    my @ids = $app->param('id');

    return unless $app->validate_magic;

    foreach my $id(@ids) {
	my $author = KetaiPost::Author->load({id => $id});
	next unless $author;
	$author->remove();
    }
    
    $app->call_return;
}

1;

