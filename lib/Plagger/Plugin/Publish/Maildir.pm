package Plagger::Plugin::Publish::Maildir;
use strict;
use base qw( Plagger::Plugin );

use DateTime;
use DateTime::Format::Mail;
use Encode qw/ from_to encode/;
use Encode::MIME::Header;
use HTML::Entities;
use MIME::Lite;
use Digest::MD5 qw/ md5_hex /;
use File::Find;
BEGIN { eval { require Encode::IMAPUTF7 } }

sub register {
    my($self, $context) = @_;
    $context->register_hook(
        $self,
        'plugin.init'      => \&initialize,
        'publish.entry'    => \&store_entry,
        'publish.finalize' => \&finalize,
    );
}

sub rule_hook { 'publish.entry' }

sub ensure_folder {
    my ($context,$maildir,$folder,$cfg)=@_;

    my $permission = ( $cfg->{permission} ? oct($cfg->{permission}) : 0700 );

    my $path = "$maildir/.$folder";
    $path =~ s/\/\//\//g;
    $path =~ s/\/$//g;
    $path=encode($cfg->{folder_encoding} || 'UTF-8',$path);
    unless (-d $path) {
        mkdir($path, $permission)
            or die $context->log(error => "Could not create $path");
        $context->log(info           => "Create new folder ($path), permission $permission");
    }
    unless (-d $path . "/new") {
        mkdir($path . "/new", $permission)
            or die $context->log(error => "Could not Create $path/new");
        $context->log(info           => "Create new folder($path/new)");
    }

    return $path;
}

sub _clean_folder_part {
    my ($str)=@_;

    $str =~ s{\W+}{-}g;

    return $str;
}

sub initialize {
    my($self, $context, $args) = @_;
    my $cfg = $self->conf;
    if (-d $cfg->{maildir}) {
        $self->{path} = ensure_folder($context, $cfg->{maildir},$cfg->{folder}, $cfg);
    }
    else {
        die $context->log(error => "Could not access $cfg->{maildir}");
    }
}

sub finalize {
    my($self, $context, $args) = @_;
    if (my $msg_count = $self->{msg}) {
        if (my $update_count = $self->{update_msg}) {
            $context->log(info =>
"Store $msg_count message(s) ($update_count message(s) updated)"
            );
        }
        else {
            $context->log(info => "Store $msg_count message(s)");
        }
    }
}

sub store_entry {
    my($self, $context, $args) = @_;
    my $cfg = $self->conf;
    my $msg;
    my $entry      = $args->{entry};
    my $subject = eval { $entry->title->plaintext } || '(no-title)';

    my @enclosure_cb;

    if ($self->conf->{attach_enclosures}) {
        push @enclosure_cb, $self->prepare_enclosures($entry);
    }

    my $body = $self->templatize('mail.tt', $args);
    $body = encode("utf-8", $body);
    my $from = $cfg->{mailfrom} || 'plagger@localhost';
    my $id   = md5_hex($entry->id_safe);
    my $date = $entry->date || Plagger::Date->now(timezone => $context->conf->{timezone});
    my $from_name;
    if ($cfg->{use_entry_author_as_from} && $entry->author) {
    	$from_name=$entry->author->plaintext;
    }
    $from_name ||= $args->{feed}->title->plaintext;
    $from_name =~ tr/,//d;

    $msg = MIME::Lite->new(
        Date    => $date->format('Mail'),
        From    => encode('MIME-Header', qq("$from_name" <$from>)),
        To      => $cfg->{mailto},
        Subject => encode('MIME-Header', $subject),
        Type    => 'multipart/related',
    );
    $msg->attach(
        Type     => 'text/html; charset=utf-8',
        Data     => $body,
        Encoding => 'quoted-printable',
    );
    for my $cb (@enclosure_cb) {
        $cb->($msg);
    }
    $msg->add('Message-Id', "<$id.plagger\@localhost>");
    $msg->add('X-Tags', encode('MIME-Header', join(' ', @{ $entry->tags })));
    my $xmailer = "Plagger/$Plagger::VERSION";
    $msg->replace('X-Mailer', $xmailer);

    my $path=$self->{path};
    if ($cfg->{use_feed_tags_as_folder} || $cfg->{use_feed_title_as_folder}) {
        my $folder;
        if ($cfg->{use_feed_tags_as_folder}) {
            my @tags = @{ $args->{feed}->tags };
            $folder = join '.', map { _clean_folder_part($_) } @tags;
        }
        if ($cfg->{use_feed_title_as_folder}) {
            $folder .= '.' if $folder;
            $folder .= _clean_folder_part($args->{feed}->title->plaintext);
        }
        $path=ensure_folder($context,$cfg->{maildir},$folder,$cfg);
    }
    {
        local $self->{path} = $path;
        store_maildir($self, $context, $msg->as_string(), $id);
    }
    $self->{msg} += 1;
}

sub prepare_enclosures {
    my($self, $entry) = @_;

    if (grep $_->is_inline, $entry->enclosures) {

        # replace inline enclosures to cid: entities
        my %url2enclosure = map { $_->url => $_ } $entry->enclosures;

        my $output;
        my $p = HTML::Parser->new(api_version => 3);
        $p->handler(default => sub { $output .= $_[0] }, "text");
        $p->handler(
            start => sub {
                my($tag, $attr, $attrseq, $text) = @_;

                # TODO: use HTML::Tagset?
                if (my $url = $attr->{src}) {
                    if (my $enclosure = $url2enclosure{$url}) {
                        $attr->{src} = "cid:" . $self->enclosure_id($enclosure);
                    }
                    $output .= $self->generate_tag($tag, $attr, $attrseq);
                }
                else {
                    $output .= $text;
                }
            },
            "tag, attr, attrseq, text"
        );
        $p->parse($entry->body);
        $p->eof;

        $entry->body($output);
    }

    return sub {
        my $msg = shift;

        for my $enclosure (grep $_->local_path, $entry->enclosures) {
            if (!-e $enclosure->local_path) {
                Plagger->context->log(warning => $enclosure->local_path .  " doesn't exist.  Skip");
                next;
            }

            my %param = (
                Type     => $enclosure->type,
                Path     => $enclosure->local_path,
                Filename => $enclosure->filename,
            );

            if ($enclosure->is_inline) {
                $param{Id} = '<' . $self->enclosure_id($enclosure) . '>';
                $param{Disposition} = 'inline';
            }
            else {
                $param{Disposition} = 'attachment';
            }

            $msg->attach(%param);
        }
      }
}

sub generate_tag {
    my($self, $tag, $attr, $attrseq) = @_;

    return "<$tag " . join(
        ' ',
        map {
            $_ eq '/' ? '/' : sprintf qq(%s="%s"), $_,
              encode_entities($attr->{$_}, q(<>"'))
          } @$attrseq
      )
      . '>';
}

sub enclosure_id {
    my($self, $enclosure) = @_;
    return Digest::MD5::md5_hex($enclosure->url->as_string) . '@Plagger';
}

sub store_maildir {
    my($self, $context, $msg, $id) = @_;
    my $filename = $id . ".plagger";
    find(
        sub {
            if ($_ =~ m!$id.*!) {
                unlink $_;
                $self->{update_msg} += 1;
            }
        },
        $self->{path} . "/cur"
    );
    $context->log(debug => "writing: new/$filename");
    my $path = $self->{path} . "/new/" . $filename;
    open my $fh, ">", $path or $context->error("$path: $!");
    print $fh $msg;
    close $fh;
}

1;

=head1 NAME

Plagger::Plugin::Publish::Maildir - Store Maildir

=head1 SYNOPSIS

  - module: Publish::Maildir 
    config:
      maildir: /home/foo/Maildir
      folder: plagger
      attach_enclosures: 1
      mailfrom: plagger@localhost

=head1 DESCRIPTION

This plugin changes an entry into e-mail, and saves it to Maildir.

=head1 AUTHOR

Nobuhito Sato

=head1 SEE ALSO

L<Plagger>

=cut

