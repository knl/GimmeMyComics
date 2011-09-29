#!perl
# vim:fdm=marker

use v5.14;

use strict;
use warnings;

use YAML::Tiny;
use DateTime;
use DateTime::Format::Strptime;
use DateTime::Format::HTTP;
use LWP::UserAgent;
use HTTP::Request;
use String::Scanf;
use MIME::Lite;

sub do_fetch;
sub do_send;

my $foundcomics = {}; # here we store all found commic, and then process them

# ===== Config ===== {{{
# setup defaults
my $default = {
	config       => 'gmc.config',
	from_address => 'someone@somewhere.com',
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
$ua->agent("GimmeMyComic/0.0.1 ");
# }}}

do_fetch;
do_send;

# ===== Methods ===== {{{
sub fetch_me_a_comic($$);
sub format_me_url;
sub attach_comic;

# fetch all comics
sub do_fetch {
	foreach my $comic (keys %{$config->{comics}}) {
		my $status = fetch_me_a_comic $comic, $config->{comics}->{$comic};
	}
}

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

		my %queued_images = ();
		foreach my $image (@{$foundcomics->{$day}}) {
			my $state = $msg->attach(
   				Type => $image->{type},
   				Filename => $image->{url} =~ tr,/:,__,r,
   				Disposition => 'attachment',
   				Encoding => 'base64',
   				Data => $image->{content},
			); 
			unless ($state) {
				warn "Error adding ".$image->{file}.": $!\n"; 
				next; 
			};
			$queued_images{$image->{name}} = $image->{last}; 
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


# should now write the updated values...

sub fetch_me_a_comic($$) {
	my ($name, $comic) = @_;

	say "> processing $name [$comic->{type}]...";
	return 0 if $name =~ /^__/; # two underscores match something disabled

	return fetch_me_a_comic_date(@_) if $comic->{type} eq 'date';
	return fetch_me_a_comic_counter(@_) if $comic->{type} eq 'counter';
	return fetch_me_a_comic_mixed(@_) if $comic->{type} eq 'mixed';
	return fetch_me_a_comic_frompagecounter(@_) if $comic->{type} eq 'frompagecounter';
	return fetch_me_a_comic_frompagedate(@_) if $comic->{type} eq 'frompagedate';
}

sub format_me_url {
	my ($comic, $nextval) = @_;

	my $url = $comic->{url};
	my $value = '';
	if (ref $nextval eq 'DateTime') {
		$value = DateTime::Format::Strptime::strftime($comic->{ident}, $nextval);
	}
	unless (ref $nextval) {
		$value = sprintf($comic->{ident}, $nextval);
	}
	$url =~ s/%s/$value/g;
	return ($value, $url);
}

sub get_me_url {
	my $url = shift;

	my $req = HTTP::Request->new(GET => $url);
	my $res = $ua->request($req);

	if ($res->is_success and not $res->is_redirect and length($res->content)>0) {
		my $lastmodified = DateTime::Format::HTTP->parse_datetime($res->header('Last-Modified')//DateTime->now);
		return { 
			file => $res->filename,
			url  => $url,
			type => $res->header('Content_Type'),
			content => $res->decoded_content,
			when => $lastmodified,
		};
	}

	#warn "Could not fetch $url: ".$res->status_line;
	return undef;
}

sub get_me_page {
	my $url = shift;

	my $req = HTTP::Request->new(GET => $url);
	my $res = $ua->request($req);

	if ($res->is_success and not $res->is_redirect and length($res->content)>0) {
		return $res->decoded_content;
	}

	#warn "Could not fetch $url: ".$res->status_line;
	return undef;
}

sub fetch_me_a_comic_date($$) {
	my ($name, $comic) = @_;

	my $lastdate = DateTime::Format::Strptime::strptime($comic->{ident}, $comic->{last});
	my $today = DateTime->today(time_zone => $LocalTZ);
	my $curdate = $lastdate->add( days => 1 );
	while (DateTime->compare($curdate, $today) != 1) {
		my ($nextident, $nexturl) = format_me_url($comic, $curdate);

		my $image = get_me_url $nexturl;
		next unless $image;
		$lastdate = $curdate;

		# enqueue the comic for the mail generator
		$image->{name} = $name;
		$image->{url}  = $nexturl;
		$image->{last} = $nextident;

		push @{$foundcomics->{$curdate->ymd}}, $image;
	} continue {
		$curdate->add( days => 1 );
	}
}

sub fetch_me_a_comic_counter($$) {
	my ($name, $comic) = @_;

	my ($lastcnt) = sscanf($comic->{ident}, $comic->{last});
	my $curcnt = $lastcnt+1;
	while (1) {
		my ($nextident, $nexturl) = format_me_url($comic, $curcnt);

		my $image = get_me_url $nexturl;
		last unless $image;
		$lastcnt = $curcnt;

		# enqueue the comic for the mail generator
		$image->{name} = $name;
		$image->{url}  = $nexturl;
		$image->{last} = $nextident;

		push @{$foundcomics->{$image->{when}->ymd}}, $image;
	} continue {
		$curcnt++;
	}
}

# relies on a counter, fetches a page, and then processes that page to find the
# image link.
# in essence, two step process
sub fetch_me_a_comic_frompagecounter($$) {
	my ($name, $comic) = @_;

	my ($lastcnt) = sscanf($comic->{ident}, $comic->{last});
	my $curcnt = $lastcnt+1;
	while (1) {
		my ($nextident, $nexturl) = format_me_url($comic, $curcnt);

		my $html = get_me_page $nexturl;
		last unless $html;
		$lastcnt = $curcnt;

		unless ($html =~ m/$comic->{pattern}/is) {
			warn "No match in $nexturl for $comic->{pattern}\n";
			next;
		}

		my $imageurl = $comic->{imagebase}//'';
		$imageurl    .= $1;
		my $image = get_me_url $imageurl;
		last unless $image;

		# enqueue the comic for the mail generator
		$image->{name} = $name;
		$image->{url}  = $imageurl;
		$image->{last} = $nextident;

		push @{$foundcomics->{$image->{when}->ymd}}, $image;
	} continue {
		$curcnt++;
	}
}

# relies on a date to locate page, fetches a page, and then processes that page to find the
# image link.
# in essence, two step process
sub fetch_me_a_comic_frompagedate($$) {
	my ($name, $comic) = @_;

	my $lastdate = DateTime::Format::Strptime::strptime($comic->{ident}, $comic->{last});
	my $today = DateTime->today(time_zone => $LocalTZ);
	my $curdate = $lastdate->add( days => 1 );
	while (DateTime->compare($curdate, $today) != 1) {
		my ($nextident, $nexturl) = format_me_url($comic, $curdate);

		my $html = get_me_page $nexturl;
		last unless $html;
		$lastdate = $curdate;

		unless ($html =~ m/$comic->{pattern}/is) {
			warn "No match in $nexturl for $comic->{pattern}\n";
			next;
		}

		my $imageurl = $comic->{imagebase}//'';
		$imageurl    .= $1;
		my $image = get_me_url $imageurl;
		last unless $image;

		# enqueue the comic for the mail generator
		$image->{name} = $name;
		$image->{url}  = $imageurl;
		$image->{last} = $nextident;

		push @{$foundcomics->{$curdate->ymd}}, $image;
	} continue {
		$curdate->add( days => 1 );
	}
}

sub fetch_me_a_comic_mixed($$) {
	my ($name, $comic) = @_;
}

# }}}
