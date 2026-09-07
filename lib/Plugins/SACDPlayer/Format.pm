package Plugins::SACDPlayer::Format;
# Tag reader for LMS type "sacd" (*.iso). Modelled on Slim::Formats::FLAC::getTag with an embedded cue sheet:
# creates one virtual track per SACD track and returns CT 'fec' / AUDIO 0 for the ISO itself.
use strict;
use warnings;
use File::Basename ();
use Slim::Utils::Log;
use Plugins::SACDPlayer::Registry;
use Plugins::SACDPlayer::Toc;

my $log = logger('plugin.sacdplayer');

sub getTag {
	my ($class, $file, $anchor) = @_;
	return {} unless $file && -f $file;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my $key   = $cache->keyFor($file);
	if (!defined $key) { $log->warn("cannot stat $file; skipping"); return {} }
	my $idx   = $cache->loadIndex($key);
	my $toc   = $idx && $idx->{toc} && @{ $idx->{toc}{areas} || [] } ? $idx->{toc} : undef;

	if (!$toc) {
		my $bin = Plugins::SACDPlayer::Registry->binary;
		if (!$bin) { $log->warn("sacd_extract missing; skipping $file"); return _hidden($file) }
		my $err;
		($toc, $err) = Plugins::SACDPlayer::Toc::run($bin, $file, 60);
		if (!$toc) { $log->warn("cannot read $file: $err"); return _hidden($file) }
	}
	$cache->ensureIndex($file, $toc);

	my @st    = stat($file);

	# LMS calls readTags on the anchored virtual URL (file://...iso#2ch-03) when it needs
	# that single track's tags: answer with the track's attributes, like
	# Slim::Formats::FLAC::getTag does for an embedded cue anchor.
	if (defined $anchor && length $anchor) {
		my ($ar, $num) = $anchor =~ m{^(2ch|mch)-(\d{2,3})$} or return {};
		$num += 0;
		my ($area) = grep { $_->{area} eq $ar } @{ $toc->{areas} || [] };
		my ($t) = $area ? grep { $_->{number} == $num } @{ $area->{tracks} || [] } : ();
		return {} unless $t;
		return attributesFor($toc, $area, $t, AGE => $st[9], FS => $st[7]);
	}

	my $title = $toc->{title} || (File::Basename::basename($file) =~ s/\.iso$//ir);
	my $container = { CT => 'fec', AUDIO => 0, TITLE => $title, ARTIST => $toc->{artist}, ALBUM => $title, YEAR => $toc->{year} };
	require Slim::Schema;
	my $rs = Slim::Schema->rs('Track');

	# readTags on the container is not only the scanner's business: every player status
	# query on a volatile (tmp://) entry for the ISO lands here too. If the virtual tracks are
	# already in the library for this unchanged ISO (same key => same size and mtime), do not
	# rewrite 18 rows per poll; just answer with the container tags.
	if (_childrenExist($rs, $cache, $file, $toc)) {
		return $container;
	}
	my $count = 0;
	my $failed = 0;
	for my $area (@{ $toc->{areas} }) {
		for my $t (@{ $area->{tracks} }) {
			my $attrs = attributesFor($toc, $area, $t, AGE => $st[9], FS => $st[7]);
			my $url   = $cache->trackUrl($file, $area->{area}, $t->{number});
			# One bad row (odd tag value, DB hiccup) must not abort the whole disc.
			my $ok = eval { $rs->updateOrCreate({ url => $url, attributes => $attrs, readTags => 0 }); 1 };
			if ($ok) { $count++ }
			else     { $failed++; $log->error("cannot create virtual track $url: " . ($@ || 'unknown error')) }
		}
	}
	$log->info("$file: created $count virtual tracks" . ($failed ? " ($failed failed)" : ''));
	return $container;
}

sub _childrenExist {
	my ($rs, $cache, $file, $toc) = @_;
	my ($area) = @{ $toc->{areas} || [] } or return 0;
	my ($t) = @{ $area->{tracks} || [] } or return 0;
	my $url = $cache->trackUrl($file, $area->{area}, $t->{number});
	my $n = eval { $rs->search({ url => $url })->count };
	return $n ? 1 : 0;
}

sub attributesFor {
	my ($toc, $area, $t, %file) = @_;
	my $title  = $toc->{title} || 'SACD';
	my $artist = $t->{performer} || $toc->{artist} || '';
	return {
		TITLE        => (defined $t->{title} && length $t->{title}) ? $t->{title} : sprintf('Track %02d', $t->{number}),
		ARTIST       => $artist,
		ALBUMARTIST  => $toc->{artist} || $artist,
		ALBUM        => "$title ($area->{area})",
		TRACKNUM     => $t->{number},
		YEAR         => $toc->{year},
		SECS         => $t->{secs},
		CHANNELS     => $area->{channels},
		RATE         => 2822400,
		SAMPLESIZE   => 1,
		CONTENT_TYPE => 'dsf',
		LOSSLESS     => 1,
		AUDIO        => 1,
		VIRTUAL      => 1,
		AGE          => $file{AGE},
		FS           => $file{FS},
	};
}

# An ISO we cannot read must not become a playable "track": hide it like a cue container.
sub _hidden {
	my ($file) = @_;
	return { CT => 'fec', AUDIO => 0, TITLE => (File::Basename::basename($file) =~ s/\.iso$//ir) };
}

1;
