package KetaiPost::Callbacks;

use strict;
use warnings;
use utf8;

sub _cb_tmpl_source_ketaipost_config {
    my ( $cb, $app, $tmpl ) = @_;
    
    my $plugin = MT->component( 'KetaiPost' );
    $plugin->log_debug( "_cb_tmpl_source_ketaipost_config called" );
    
    my $blog = $app->blog;
    return unless defined( $blog );
    
    my $website;
    my $template_id;
    if ( $blog->parent_id ) {
        $website = MT->model('website')->load($blog->parent_id);
        $template_id = $plugin->get_blog_setting($blog->id, 'entry_text_template_id');
    } else {
        $website = $blog;
        undef $blog;
        $template_id = $plugin->get_blog_setting($website->id, 'entry_text_template_id');
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
    $plugin->log_debug( "_cb_tmpl_source_ketaipost_config called" );

    my $template_id = $plugin->get_system_setting('entry_text_template_id');

    use MT::Template;
    my @templates = MT::Template->load( {
        'blog_id' => 0,
        'type' => 'custom'
    } );
    my $src = '<select id="entry_text_template_id" name="entry_text_template_id">' .
        "\n" .
        '<option value="-1"' . ($template_id == -1 ? ' selected="selected"' : '') . '>KetaiPost既定</option>' .
        '<optgroup label="システムのテンプレートモジュール">' . "\n";
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

1;