package XML::Convert;

# Convert: DOM to perl object (like GData Format)

use strict;
use XML::LibXML;
use base qw(Class::Accessor::Fast);
our $VERSION = '0.01';

__PACKAGE__->mk_accessors(qw(
    content_key
    cdata_key
    attribute_prefix
    xmlns_splitter
    text_filter
));

sub new {
    my ($class, $options) = @_;
    $options ||= {};
    return bless {
        content_key => '$t',
        cdata_key => '$t',
        attribute_prefix => '@',
        xmlns_splitter => '$',
        text_filter => \&default_text_filter,
        %{$options}
    }, $class;
}

sub convert {
    my $self = shift;
    my ($from, $to, $obj) = @_;
}

sub dom2obj {
    my $self = shift;
    my $dom = shift;
    return $self->dom2obj_libxml($dom);
}

sub obj2dom {
    my $self = shift;
    my $object = shift;
    return unless ref $object eq "HASH";
    return $self->obj2dom_libxml($object);
}

sub obj2xml {
    my $self = shift;
    my $obj = shift;
    $self->obj2dom($obj)->toString(1);
}

sub obj2dom_libxml {
    my $self = shift;
    my $at = $self->attribute_prefix;
    my $t  = $self->content_key;
    my $xmlns_splitter = $self->xmlns_splitter;

    my $object = shift;
    my $doc;
    # root node
    if (exists $object->{version} && exists $object->{encoding}) {
        my ($version, $encoding) = ($object->{'version'}, $object->{'encoding'});
        my $doc = XML::LibXML::Document->createDocument($version, $encoding);
    } else {
        $doc = XML::LibXML::Document->createDocument(1.0, 'UTF-8');
    }

    # PI
    for my $key (keys %$object) {
        next unless ($key =~m{^\?});
        my $nodename = substr($key, 1);
        my @pi = (ref $object->{$key} eq "ARRAY") ? @{$object->{$key}} : $object->{$key};
        for (@pi) {
            my $pi =  $doc->createProcessingInstruction($nodename);
            $pi->setData($_->{$t});
            $doc->appendChild($pi);
        }
    }

    my $create_attr = sub {
        my ($node, $key, $value) = @_;
        # warn ($key,$value);
        $node->setAttribute($key, $value);
    };
    
    my $create_node;
    $create_node = sub {
        my ($node, $key, $value) = @_;

        # ATTR
        if (substr($key,0,1) eq $at) {
            my $attrkey = substr($key, 1);
            return $create_attr->($node, $attrkey, $value);
        }
        # TEXT NODE
        if ($key eq $t) {
            $node->appendText($value);
            return $node;
        }
        # CDATA NODE
        if ($key eq "#CDATA") {
            my $cdata = XML::LibXML::CDATASection->new($value);
            $node->appendChild($cdata);
            return $node;
        }
        if (ref ($value) eq "HASH") {
            my $new_node = $doc->createElement($key);
            for my $key (keys %$value){
                my $val = $value->{$key};
                $create_node->($new_node, $key, $val);
            }
            $node->appendChild($new_node);
            return $new_node;
        } elsif (ref $value eq "ARRAY") {
            for my $value (@{$value}) {
                # my $new_node = $doc->createElement($key);
                $create_node->($node, $key, $value);
                # $node->appendChild($new_node);
            }
            return $node;
        } else {
            $node->appendTextChild($key, $value);
            return $node;
        }
    };
    
    # documentElement
    my $current_node = $doc;
    for my $key (keys %$object) {
        next if ($key =~m{^\?});
        next if ($key =~m{^\@});
        warn $key;
        my $el = $current_node->createElement($key);
        if (!$doc->documentElement) {
            $doc->setDocumentElement($el);
            $current_node = $el;
        } else {
            $current_node->appendChild($el);
            $current_node = $el;
        }
        my $val = $object->{$key};
        for my $key (keys %$val) {
            my $val = $val->{$key};
            $create_node->($current_node, $key, $val);
        }
    }
    return $doc;
}

sub dom2obj_libxml {
    my $node = shift;
    my $dumper = \&_dom2obj_libxml;
    $dumper->($node);
}

sub dom2obj_libxml {
    my $self = shift;
    my $node = shift;

    my $at = $self->attribute_prefix;
    my $t  = $self->content_key;
    my $xmlns_splitter = $self->xmlns_splitter;
    
    my $nodename = $node->nodeName;
    my $nodetype = $node->nodeType;
    my @child = $node->childNodes;
   
    ### TEXT NODE: return scalar
    if ($nodename =~ /#text/ && !$node->hasAttributes) {
        my $text = $node->textContent;
        # like a "\n"
        return () if ($text =~/^\s+$/);
        return $self->text_filter->($text);
    }
    ### CDATA Section: return { nodename => { #CDATA => value } }
    if ($nodename =~ /#cdata-section/ && !$node->hasAttributes) {
        my $text = $node->textContent;
        return +{ '#CDATA' => $self->text_filter->($text) }
    }
    
    ### ATTRIBUTE
    my %attr;
    if ($node->hasAttributes) {
        %attr = map { $at.$_->nodeName => $_->getValue } $node->attributes; 
    }

    ### XML ROOT Element
    if ($nodename eq '#document') {
        $attr{$at.$_} = $node->$_ for qw(version encoding);
        $nodename = "?xml";
    }

    ### PI_NODE like as <?xml-stylesheet ?>
    if ($nodetype == XML::LibXML::XML_PI_NODE) {
        $nodename = "?" . $nodename; 
    }
    # XMLNS
    my %xmlns;
    if (%xmlns = get_ns($node)) {
        while (my($key,$value) = each %xmlns) {
            my $ns = 'xmlns' . ($key ? $xmlns_splitter.$key : "");
            $attr{$ns} = $value;
        }
    } 

    ### HAS CHILD NODES
    my $result = {};
    if (@child > 1) {
        my $type;
        my @child_dump;
        my @values;
        my %seen;
        my %dup;
        # dump child, ignore empty node
        for (@child) {
            my $dump =  $self->dom2obj_libxml($_);
            next unless $dump;
            if (ref $dump eq "HASH") {
                my ($key, $value) = each %$dump;
                push @child_dump, $dump;
                push @values, $value;
                $dup{$key} = 1 if $seen{$key};
                $seen{$key} = 1;
            } else {
                my $text = $dump;
                push @child_dump, { $t => $text }
            }
        }
        $type = "ARRAY" if (keys %seen == 1);
        $type = "SCALAR" if (scalar @child_dump == 1);

        # SCALAR
        if ($type eq "SCALAR"){
            my $dump = $child_dump[0];
            if (ref $dump eq 'HASH') {
                $result = +{ %attr,  %$dump };
            } elsif (%attr) {
                $result = +{ %attr, $t => $dump };
            } else {
                $result = $dump;
            }
        }
        # ARRAY
        elsif ($type eq "ARRAY") {
            my ($keyname) = keys %seen;
            $result = +{ %attr, $keyname => \@values};
        }
        # HASH duplicated key
        elsif (keys %dup) {
            my %hash;
            for my $child (@child_dump) {
                next unless ref $child;
                my ($key) = keys %{$child};
                my $value = $child->{$key};
                if ($dup{$key}) {
                    $hash{$key} ||= [];
                    push @{ $hash{$key} }, $value;
                } else {
                    $hash{$key} = $value;
                }
            }
            $result = +{ %attr, %hash };
        }
        # HASH no duplicated key
        else {
            my %hash = map { ref $_ ? %{$_} : () } @child_dump;
            $result = +{ %attr, %hash }; 
        }
    } elsif (@child) { # single child node
        my $dump = $self->dom2obj_libxml($child[0]);
        if (ref $dump eq 'HASH') {
            $result = { %attr, %{$dump} };
        } elsif (%attr){
            $attr{'$t'} = $dump;
            $result = \%attr;
        } else {
            $result = $dump;
        }
    } else {
        my $text = $node->textContent || "";
        if ($text){
            $attr{$t} = $text;
        }
        $result = \%attr;
    }
    # empty hash
    return +{ $nodename => "" } if (ref $result eq 'HASH' && !%$result);
    return +{ $nodename => $result };
}

sub default_text_filter {
    my $text = shift;
    return $text;
    # return substr($text, 0, 150); 
}

sub get_ns {
    my $root = shift;
    my %ns;
    # libxml 1.58
    if ($XML::LibXML::VERSION < 1.68) {
       %ns = map { ($_->getPrefix() => $_->getNamespaceURI()) } $root->getNamespaces;
    # 1.69
    } else {
       %ns = map { ($_->declaredPrefix =>  $_->declaredURI) } $root->getNamespaces
    }
    return %ns;
}   

1;

__END__

=head1 NAME

XML::Convert - convert XML::LibXML::Document to Perl Object

=head1 SYNOPSIS

  use XML::Convert;
  $p = XML::LibXML->new;
  $c = XML::Convert->new({
    # options
  });
  
  my $doc = $p->parse_string($xml);
  my $obj = $c->dom2obj($doc); # XML::LibXML::Document perl object
  
  my $node = $doc->documentElement;
  my $obj = $c->dom2obj($node); # DOM node to perl object
  my $json = JSON::Syck::Dump($obj); # get JSON String like GData JSON

=head1 DESCRIPTION

XML::Convert is

=head1 AUTHOR

mala E<lt>cpan@ma.laE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
~

