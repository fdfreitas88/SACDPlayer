package Plugins::SACDPlayer::ProtocolHandler;
# Virtual tracks (file:///path/Album.iso#2ch-03) are served from the local DSF cache.
# Subclassing File keeps LMS's native dsf passthrough (DoP).
use strict;
use warnings;
use base qw(Slim::Player::Protocols::File);
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes ();
use Slim::Utils::Strings ();
use Plugins::SACDPlayer::Registry;

my $log = logger('plugin.sacdplayer');

sub isRemote { 0 }
sub canDirectStream { 0 }
# These are file:// URLs, so LocalFile's direct-stream path may be consulted: refuse it,
# the ISO on disk is not the DSF we serve.
sub canDirectStreamSong { 0 }
sub contentType { 'dsf' }
# Seeking needs the local DSF: File::open cannot seek into a track we have not extracted yet.
sub canSeek {
	my ($class, $client, $song) = @_;
	return 0 unless $song && $song->can('currentTrack') && $song->currentTrack;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($song->currentTrack->url);
	return 0 unless $iso;
	my $key = $cache->keyFor($iso);
	return 0 unless defined $key;
	return $cache->trackState($key, $area, $n) eq 'ready' ? 1 : 0;
}

sub pathFromFileURL {
	my ($class, $url) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	return $class->SUPER::pathFromFileURL($url) unless $iso;
	my $key = $cache->keyFor($iso);
	if (!defined $key) { $log->error("cannot stat ISO for $url"); return undef }
	return $cache->trackPath($key, $area, $n);
}

sub getNextTrack {
	my ($class, $song, $successCb, $failCb) = @_;
	my $url   = $song->currentTrack->url;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	if (!$iso) { $log->error("cannot parse $url"); return $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	my $key = $cache->keyFor($iso);
	if (!defined $key) { $log->error("cannot stat ISO for $url"); return $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	my $x   = Plugins::SACDPlayer::Registry->extractor;

	if ($cache->trackState($key, $area, $n) eq 'ready') {
		$cache->touch($key);
		_refreshAudioInfo($url, $cache->trackPath($key, $area, $n));
		return $successCb->();
	}

	my $client = $song->master;
	my $idx = $cache->loadIndex($key);
	my ($a) = grep { $_->{area} eq $area } @{ $idx ? $idx->{toc}{areas} : [] };
	my $total = $a ? scalar @{ $a->{tracks} } : '?';
	if ($client && $client->can('showBriefly')) {
		$client->showBriefly({ line => [ Slim::Utils::Strings::string('PLUGIN_SACDPLAYER_PREPARING'), "$n / $total" ] }, { duration => 10 });
	}
	# Exactly one of the waiter and the deadline may call back: if the extractor never
	# answers (crashed worker, wedged tick) the player must still be told, not left hanging.
	my $done = 0;
	my $timeout = Plugins::SACDPlayer::Registry->prefs->get('extract_timeout_s') || 600;
	my $deadline;
	$deadline = sub {
		return if $done;
		# The player may have already moved on to a different song (skip, stop) while this
		# extraction was still pending: don't fail a track nobody is waiting on any more.
		if ($client && $client->can('playingSong') && $client->playingSong && $client->playingSong != $song) {
			return;
		}
		$done = 1;
		$log->error("extraction deadline expired for $url");
		$failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED');
	};
	Slim::Utils::Timers::setTimer($client || undef, Time::HiRes::time() + $timeout + 30, $deadline);

	$x->request($iso, $area, $n, 0, sub {
		my ($ok, $payload) = @_;
		return if $done;
		$done = 1;
		Slim::Utils::Timers::killTimers($client || undef, $deadline);
		if ($ok) { $cache->touch($key); _refreshAudioInfo($url, $payload); $successCb->() }
		else     { $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	});
	# Only stereo areas are pre-extracted in the background: multichannel DST decodes at ~1.2x
	# realtime on the server (measured 2026-09-06), so mch albums are prepared manually.
	$x->requestAlbum($iso, $area, 1) if $area eq '2ch';
	Plugins::SACDPlayer::Plugin::armTick() if defined &Plugins::SACDPlayer::Plugin::armTick;
	return;
}

# After extraction, copy the DSF's real audio geometry into the virtual track row so File::open can seek.
sub _refreshAudioInfo {
	my ($url, $path) = @_;
	return unless -f $path;
	my $tags = eval { require Slim::Formats; Slim::Formats->readTags($path) } || {};
	my %audio = map { $_ => $tags->{$_} } grep { defined $tags->{$_} } qw(SIZE OFFSET SECS RATE SAMPLESIZE CHANNELS BLOCKALIGN BITRATE);
	return unless %audio;
	eval { require Slim::Schema; Slim::Schema->rs('Track')->updateOrCreate({ url => $url, attributes => \%audio, readTags => 0 }) };
	$log->warn("audio info update failed for $url: $@") if $@;
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	return {} unless $iso;
	my $key = $cache->keyFor($iso);
	my $idx = (defined $key ? $cache->loadIndex($key) : undef)
		or return { title => "Track $n", artist => '', album => '', duration => 0, sacd_state => 'absent' };
	my ($a) = grep { $_->{area} eq $area } @{ $idx->{toc}{areas} || [] };
	my ($t) = $a ? grep { $_->{number} == $n } @{ $a->{tracks} } : ();
	return {
		title      => $t ? $t->{title} : "Track $n",
		artist     => $t && $t->{performer} ? $t->{performer} : $idx->{toc}{artist},
		album      => "$idx->{toc}{title} ($area)",
		duration   => $t ? $t->{secs} : 0,
		sacd_state => $cache->trackState($key, $area, $n),
	};
}

1;
