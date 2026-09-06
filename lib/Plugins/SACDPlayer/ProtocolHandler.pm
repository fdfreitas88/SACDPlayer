package Plugins::SACDPlayer::ProtocolHandler;
# sacd:// tracks are served from the local DSF cache. Subclassing File keeps LMS's native dsf passthrough (DoP).
use strict;
use warnings;
use base qw(Slim::Player::Protocols::File);
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Utils::Strings ();
use Plugins::SACDPlayer::Registry;

my $log = logger('plugin.sacdplayer');

sub isRemote { 0 }
sub canDirectStream { 0 }
sub contentType { 'dsf' }
sub canSeek { 1 }

sub pathFromFileURL {
	my ($class, $url) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	return $class->SUPER::pathFromFileURL($url) unless $iso;
	return $cache->trackPath($cache->keyFor($iso), $area, $n);
}

sub getNextTrack {
	my ($class, $song, $successCb, $failCb) = @_;
	my $url   = $song->currentTrack->url;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	if (!$iso) { $log->error("cannot parse $url"); return $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	my $key = $cache->keyFor($iso);
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
	$x->request($iso, $area, $n, 0, sub {
		my ($ok, $payload) = @_;
		if ($ok) { $cache->touch($key); _refreshAudioInfo($url, $payload); $successCb->() }
		else     { $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	});
	$x->requestAlbum($iso, $area, 1);
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
	my $idx = $cache->loadIndex($key)
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
