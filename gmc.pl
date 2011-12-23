#!perl
# vim:fdm=marker

use v5.14;

package GMC::Comic::Identifier;
use Moose::Role;

has ['last', 'ident', 'url'] => (
	is => 'rw',
	isa => 'Str',
	required => 1,
);

# next 'advances' the identifier
# is_over returns true if fetching loop shoud stop
# get_image_url transforms the identifier into the url for _COMIC_ (not for page)
# current_identifier returns the string representing current value
requires 'next', 'is_over', 'get_image_url', 'current_identifier';

no Moose;
no Moose::Role;
1;

package GMC::Comic::InPage;
use HTTP::Request;
use LWP::UserAgent;

use Moose::Role;

requires 'get_image_url';

has 'pattern' => (
	is => 'rw',
	isa => 'Str',
	required => 1,
);

has 'imagebase' => (
	is => 'rw',
	isa => 'Str',
	default => '',
);

has 'ua' => (
	is => 'ro',
	isa => 'LWP::UserAgent',
	required => 1,
);

sub _get_me_page {
	my $self = shift;
	my $url = shift;

	my $req = HTTP::Request->new(GET => $url);
	my $res = $self->ua->request($req);

	if ($res->is_success and not $res->is_redirect and length($res->content)>0) {
		return $res->decoded_content;
	}

	#warn "Could not fetch $url: ".$res->status_line;
	return undef;
}

override 'get_image_url' => sub {
	my $self = shift;

	my $url = super();
	my $html = $self->_get_me_page($url);
	return undef unless $html;

	unless ($html =~ m/$self->{pattern}/ais) {
		warn "No match in $url for $self->{pattern}\n";
		return undef;
	}
	$self->{imagebase} . $1;
};

no Moose;
no Moose::Role;
1;

## Finding comic's url through date
package GMC::Comic::FromDate;
use DateTime;
use DateTime::Format::Strptime;

use Moose;
use MooseX::ClassAttribute;

with 'GMC::Comic::Identifier';

has 'curdate' => (
	is => 'rw',
	isa => 'DateTime',
	builder => '_build_curdate',
	lazy => 1,
);

class_has 'today' => (
	is => 'rw',
	isa => 'DateTime',
	builder => '_build_today',
);

sub _build_curdate {
	my $self = shift;

	DateTime::Format::Strptime::strptime($self->ident, $self->last);
}

sub _build_today {
	my $LocalTZ = DateTime::TimeZone->new( name => 'local');
	DateTime->today(time_zone => $LocalTZ);
}

sub next {
	my $self = shift;

	$self->curdate->add( days => 1 );

	$self->curdate;
}

sub is_over {
	my $self = shift;

	DateTime->compare($self->curdate, $self->today) == 1;
}

sub current_identifier {
	my $self = shift;

	return scalar DateTime::Format::Strptime::strftime($self->ident, $self->curdate);
}

sub get_image_url {
	my $self = shift;

	my $url = $self->url;
	my $value = $self->current_identifier();
	$url =~ s/%s/$value/g;

	$url;
}

no Moose;
no MooseX::ClassAttribute;
1;

package GMC::Comic::FromCounter;
use String::Scanf qw();

use Moose;

with 'GMC::Comic::Identifier';

has 'counter' => (
	is => 'rw',
	isa => 'Str',
	builder => '_build_counter',
	lazy => 1, # must be lazy, depends on ident and last
);

sub _build_counter {
	my $self = shift;

	my ($cnt) = String::Scanf::sscanf("".$self->ident, "".$self->last);
	$cnt;
}

sub next {
	my $self = shift;

	$self->counter($self->counter+1);

	my $str = sprintf($self->ident, $self->counter);
	$str;
}

# when to stop a counter based search?
sub is_over {
	0;
}

sub current_identifier {
	my $self = shift;
	return scalar sprintf($self->ident, $self->counter);
}

sub get_image_url {
	my $self = shift;

	my $url = $self->url;
	my $value = $self->current_identifier();
	$url =~ s/%s/$value/g;

	$url;
}

no Moose;
1;

package GMC::Comic::FromCounterAndPage;

use Moose;

extends 'GMC::Comic::FromCounter';
with 'GMC::Comic::InPage';

__PACKAGE__->meta->make_immutable;
no Moose;
1;

package GMC::Comic::FromDateAndPage;

use Moose;

extends 'GMC::Comic::FromDate';
with 'GMC::Comic::InPage';

__PACKAGE__->meta->make_immutable;
no Moose;
1;

package GMC::Comic::Image;

use Moose;

has 'url' => (
	is => 'ro',
	isa => 'Str',
	required => 1,
);

has 'comic' => (
	is => 'ro',
	isa => 'GMC::Comic',
	required => 1,
);

has 'ident' => ( # identifier that matches the image, to be put in field 'last'
	is => 'ro',
	isa => 'Str',
);

has ['filename', 'type', 'content'] => (
	is => 'ro',
	isa => 'Str',
	init_arg => undef,
);

has 'when' => (
	is => 'ro',
	isa => 'DateTime',
	init_arg => undef,
);

has 'status' => (
	is => 'ro',
	isa => 'DateTime',
	init_arg => undef,
);

around BUILDARGS => sub {
	my $orig = shift;
	my $class = shift;

	my $params = { @_ };

	$params->{ident} = $params->{comic}->identifier->current_identifier();

   	return $class->$orig($params);
};

sub BUILD {
	my $self = shift;
	my $args = shift;

	my $res = $args->{res};
	# if we fetch a comic through the date, use that information for when
	if ($self->comic->identifier->isa("GMC::Comic::FromDate")) {
		$self->{when} = $self->comic->identifier->curdate->clone;
	} else {
		my $lastmodified = DateTime::Format::HTTP->parse_datetime($res->header('Last-Modified')//DateTime->now);
		$self->{when} = $lastmodified;
	}
	$self->{status} = $res->status_line;
	$self->{filename} = $res->filename;
	$self->{type} = $res->header('Content_Type');
	$self->{content} = $res->decoded_content;
}

## these two return bodylink and how what to attach
sub toHTML {
}

sub toTXT {
}

no Moose;
1;

package GMC::Comic;
use HTTP::Request;
use DateTime::Format::HTTP;
use LWP::UserAgent;

use Moose;

has ['name', 'last', 'url', 'ident', 'type'] => (
	is => 'ro',
	isa => 'Str',
	required => 1,
);

has 'ua' => (
	is => 'ro',
	isa => 'LWP::UserAgent',
	required => 1,
);

has 'identifier' => (
	is => 'rw',
	isa => 'GMC::Comic::Identifier',
	init_arg => undef,
);

around BUILDARGS => sub {
	my $orig = shift;
	my $class = shift;

	my $params;

	if (ref $_[0] eq 'LWP::UserAgent') {
        my $ua = shift;
        my $name = shift;
     	$params = { ua => $ua, name => $name };
    }
	if (!ref $_[0]) {
		# just a different order
        my $name = shift;
        my $ua = shift;
     	$params = { ua => $ua, name => $name };
    }

	# append, without using loops
	@{$params}{keys %{$_[0]}} = values %{$_[0]};

   	return $class->$orig($params);
};

sub BUILD {
	my $self = shift;
	my $args = shift;

	my %params;
	foreach my $att (qw/url ident last ua/) {
		$params{$att} = $args->{$att} if exists $args->{$att};
	}
	foreach my $att (qw/pattern imagebase/) {
		$params{$att} = $args->{$att}
			if exists $args->{$att};
	}

	if ($self->type eq 'date') {
		$self->identifier(GMC::Comic::FromDate->new(%params));
	}
   	if ($self->type eq 'counter') {
		$self->identifier(GMC::Comic::FromCounter->new(%params));
	}
   	if ($self->type eq 'dateandinpage') {
		#require GMC::Comic::FromDateAndPage;
		$self->identifier(GMC::Comic::FromDateAndPage->new(%params));
	}
   	if ($self->type eq 'counterandinpage') {
		#require GMC::Comic::FromCounterAndPage;
		$self->identifier(GMC::Comic::FromCounterAndPage->new(%params));
	}
}

sub fetch_current_image {
	my $self = shift;

	my $image_url = $self->identifier->get_image_url;
	return undef unless $image_url;

	my $req = HTTP::Request->new(GET => $image_url);
	my $res = $self->ua->request($req);

	if ($res->is_success and not $res->is_redirect and length($res->content)>0) {
		my $image = GMC::Comic::Image->new(
						res		 => $res,
						url      => $image_url,
						comic	 => $self,
		);
		return $image;
	}

	#warn "Could not fetch $url: ".$res->status_line;
	return undef;
}

no Moose;
1;

package GMC;

use strict;
use warnings;

use Moose;

use YAML::Tiny;
use DateTime;
use DateTime::Format::HTTP;
use LWP::UserAgent;
use MIME::Lite;

sub do_send;

my $foundcomics = {}; # here we store all found comics, and then process them

# ===== Config ===== {{{
# setup defaults
my $default = {
	config       => 'gmc.config',
	from_address => 'Nikola Knezevic <nikola.knezevic@epfl.ch>',
	message_body => 'comics for people!',
	subject		 => 'Comics '.DateTime->today,
	sendmail	 => '/usr/sbin/sendmail',
};

# get the configuration
my $yaml = YAML::Tiny->read($default->{config});
my $config = $yaml->[0];

# timezone needs to be set (at least to 'local') to get correct dates
our $LocalTZ = DateTime::TimeZone->new( name => $config->{timezone} );

#MIME::Lite->send('sendmail', $config->{sendmail} // $default->{sendmail});
# }}}

# ===== Network ====== {{{
# setup the fetcher part
my $ua = LWP::UserAgent->new;
$ua->agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/535.7 (KHTML, like Gecko) Chrome/16.0.912.36 Safari/535.7 GimmeMyComic/0.0.1");
# }}}


# initialize all comics
my @comics;
foreach my $comic (keys %{$config->{comics}}) {
	next if $comic =~ /^__/;
	push @comics, GMC::Comic->new($ua, $comic, $config->{comics}->{$comic});
}

# fetch all images
foreach my $comic (@comics) {
	say STDERR "Processing ",$comic->name;
	my %seen = (); # some comics give you an image of the last comic for dates in the future
	while (!$comic->identifier->is_over) {
		my $last = $comic->identifier->next;

		my $image = $comic->fetch_current_image();
		if ($image and not exists $seen{$image->{url}}) {
			$seen{$image->{url}} = 1;
			push @{$foundcomics->{$image->when->ymd}}, $image;
		} else {
			say STDERR ">> No image, skipping";
			last if $comic->type =~ 'counter';
			next;
		}
	}
}

# and finally send
do_send;

# ===== Methods ===== {{{
# now, go and create messages
sub do_send {
	my @bcc_addresses = @{$config->{send_to_emails}}; shift @bcc_addresses;

	foreach my $day (sort keys %{$foundcomics}) {
		my $date = DateTime::Format::Strptime::strptime('%F', $day);

 		# Create the multipart container
		my $msg = MIME::Lite->new(
  			From => $config->{from_address}//$default->{from_address},
  			To => $config->{send_to_emails}->[0],
  			Bcc => (join ', ', @bcc_addresses),
  			Subject => DateTime::Format::Strptime::strftime($config->{subject}//$default->{subject}, $date),
  			Type =>'multipart/mixed',
  			'X-Nikola' => "GMC v0.0.1",
		) or die "Error creating multipart container: $!\n";

		my $msg_body = $default->{message_body};
		eval "\$msg_body = $config->{message_body};" if $config->{message_body};
		$msg->attach(
  			Type => 'TEXT',
  			Data => $msg_body,
		) or die "Error adding the text message part: $!\n";

		# we keep queued_images so we know what images we have sent so far
		# should not update config, because the process may fail during send
		say STDERR "DAY: ", $day, " ($date)";
		my %queued_images = ();
		foreach my $image (@{$foundcomics->{$day}}) {
			my $state = $msg->attach(
   				Type => $image->type,
   				Filename => ($image->url =~ tr,/:,__,r),
   				Disposition => 'attachment',
   				Encoding => 'base64',
   				Data => $image->content,
			);
			unless ($state) {
				warn "Error adding ".$image->filename.": $!\n";
				next;
			};

			say STDERR "Adding ".$image->ident." for ".$image->comic->name;
			$queued_images{$image->comic->name} = $image->ident;
		}

		#say "Mail for day: $day ($date): ";
		#say $msg->as_string;

		$msg->send($config->{sendmail} // $default->{sendmail}) or die "Not possible to send! $!\n";

		while (my ($name,$last) = each %queued_images) {
			$config->{comics}->{$name}->{last} = $last;
		}
	}

	$yaml->write($default->{config});
}
# }}}
