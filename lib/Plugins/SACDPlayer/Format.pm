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
	my $title = $toc->{title} || (File::Basename::basename($file) =~ s/\.iso$//ir);
	require Slim::Schema;
	my $rs = Slim::Schema->rs('Track');
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
	return { CT => 'fec', AUDIO => 0, TITLE => $title, ARTIST => $toc->{artist}, ALBUM => $title, YEAR => $toc->{year} };
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
