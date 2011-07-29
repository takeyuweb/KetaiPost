package KetaiPost::Callbacks;

use strict;
use warnings;

use KetaiPost::Util qw( log_debug get_blog_setting get_system_setting get_website_setting
                        update_or_create_ketaipost_author);

sub _cb_tmpl_source_ketaipost_config {
    my ( $cb, $app, $tmpl ) = @_;
    
    my $plugin = MT->component( 'KetaiPost' );
    log_debug( "_cb_tmpl_source_ketaipost_config called" );
    
    my $blog = $app->blog;
    return unless defined( $blog );
    
    my $website;
    my $template_id;
    if ( $blog->parent_id ) {
        $website = MT->model('website')->load($blog->parent_id);
        $template_id = get_blog_setting($blog->id, 'entry_text_template_id');
    } else {
        $website = $blog;
        undef $blog;
        $template_id = get_blog_setting($website->id, 'entry_text_template_id');
    }

    my @templates;
    @templates = MT->model('template')->load( {
        'blog_id' => $blog->id,
        'type' => 'custom'
    } ) if $blog;
    my @website_templates = MT->model('template')->load( {
        'blog_id' => $website->id,
        'type' => 'custom'
    } );
    my @system_templates = MT->model('template')->load( {
        'blog_id' => 0,
        'type' => 'custom'
    } );
    
    my $src = '<select id="entry_text_template_id" name="entry_text_template_id">' .
        "\n" .
        '<option value="0"' . ($template_id ? '' : ' selected="selected"') . '>親の設定を継承</option>' .
        '<option value="-1"' . ($template_id == -1 ? ' selected="selected"' : '') . '>KetaiPost既定</option>';
    if ( $blog ) {
        $src .= '<optgroup label="ブログのテンプレートモジュール">' . "\n";
        foreach my $template ( @templates ) {
            if ( $template_id == $template->id ) {
                $src .= '<option value="' . $template->id . '" selected="selected">' . $template->name . '</option>' . "\n";
            } else {
                $src .= '<option value="' . $template->id . '">' . $template->name . '</option>' . "\n";
            }
        }
        $src .= '</optgroup>';
    }
    
    $src .= '<optgroup label="ウェブサイトのテンプレートモジュール">' . "\n";
    foreach my $template ( @website_templates ) {
        if ( $template_id == $template->id ) {
            $src .= '<option value="' . $template->id . '" selected="selected">' . $template->name . '</option>' . "\n";
        } else {
            $src .= '<option value="' . $template->id . '">' . $template->name . '</option>' . "\n";
        }
    }
    $src .= '</optgroup>';
    
    $src .= '<optgroup label="システムのテンプレートモジュール">' . "\n";
    foreach my $template ( @system_templates ) {
        if ( $template_id eq $template->id ) {
            $src .= '<option value="' . $template->id . '" selected="selected">' . $template->name . '</option>' . "\n";
        } else {
            $src .= '<option value="' . $template->id . '">' . $template->name . '</option>' . "\n";
        }
    }
    $src .= '</optgroup>';
    
    $src .= '</select>';
    
    $$tmpl =~ s/\[select_entry_text_template_id\]/$src/sg;
}

sub _cb_tmpl_source_ketaipost_sysconfig {
    my ( $cb, $app, $tmpl ) = @_;
    
    my $plugin = MT->component( 'KetaiPost' );
    log_debug( "_cb_tmpl_source_ketaipost_config called" );

    my $template_id = get_system_setting('entry_text_template_id');
    
    my @templates = MT->model( 'template' )->load( {
        'blog_id' => 0,
        'type' => 'custom'
    } );

    my $src = '<select id="entry_text_template_id" name="sys_entry_text_template_id">' .
      "\n" .
        '<option value="-1"' . ($template_id == -1 ? ' selected="selected"' : '') . '>KetaiPost Default</option>' .
          '<optgroup label="' . $plugin->translate('System Template Modules') . '">' . "\n";
    foreach my $template ( @templates ) {
        if ( $template_id eq $template->id ) {
            $src .= '<option value="' . $template->id . '" selected="selected">' . $template->name . '</option>' . "\n";
        } else {
            $src .= '<option value="' . $template->id . '">' . $template->name . '</option>' . "\n";
        }
    }
    $src .= '</optgroup></select>' . "\n";
    $$tmpl =~ s/\[select_entry_text_template_id\]/$src/sg;
}

sub hdlr_post_save_permission {
    my ( $cb, $obj, $org_obj ) = @_;
    my $app = MT->instance;
    #die 'ref:'.ref($obj).' author_id:'.$obj->author_id.' permissions:'.$obj->permissions . ' can_do:'.$obj->can_do('create_post');
    return 1 unless $obj && ref($obj) eq 'MT::Permission';
    return 1 unless $obj->author_id;

    return 1 unless $obj->can_do( 'create_post' );

    my $author = MT->model( 'author' )->load( $obj->author_id );

    update_or_create_ketaipost_author( $app, $author );
}

sub hdlr_cms_post_save_author {
    my ( $cb, $app, $obj, $org_obj ) = @_;
    return 1 unless $obj && ref($obj) eq 'MT::Author';

    log_debug( 'hdlr_cms_post_save_author called' );

    my $count = MT->model( 'permission' )->count({ author_id => $obj->id,
                                                   permissions => {
                                                       like => "%'create_post'%"
                                                   }});

    log_debug( 'create_post count:'.$count );

    return 1 unless $count;
    
    update_or_create_ketaipost_author( $app, $obj );
}

1;
