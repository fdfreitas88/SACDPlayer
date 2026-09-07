package Plugins::SACDPlayer::Commands;
use strict;
use warnings;
use Slim::Control::Request;
use Plugins::SACDPlayer::Registry;

my $registered;

sub register {
	return if $registered++;
	Slim::Control::Request::addDispatch(['sacdplayer', 'cachestats'],         [0, 1, 0, \&cachestats]);
	Slim::Control::Request::addDispatch(['sacdplayer', 'status', '_target'],  [0, 1, 0, \&status]);
	Slim::Control::Request::addDispatch(['sacdplayer', 'prepare', '_target'], [0, 0, 0, \&prepare]);
	Slim::Control::Request::addDispatch(['sacdplayer', 'evict', '_target'],   [0, 0, 0, \&evict]);
}

sub _fail { my ($r, $msg) = @_; $r->addResult('success', 0); $r->addResult('error', $msg); $r->setStatusDone; return }

# Accepts a virtual track URL (file://...iso#2ch-01) or "<key>/<area>". Returns ($key, $area, $iso) or ().
sub resolveTarget {
	my ($target) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	return () unless defined $target;
	if (my ($iso, $area) = $cache->parseUrl($target)) {
		my $key = $cache->keyFor($iso);
		return () unless defined $key;             # ISO vanished: no key, so nothing to act on
		return ($key, $area, $iso);
	}
	if ($target =~ m{^([0-9a-f]{16})/(2ch|mch)$}) {
		my $idx = $cache->loadIndex($1) or return ();
		return ($1, $2, $idx->{iso});
	}
	return ();
}

sub cachestats {
	my ($r) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my $x     = Plugins::SACDPlayer::Registry->extractor;
	$r->addResult('usage_bytes', $cache->usageBytes);
	$r->addResult('cap_bytes',   Plugins::SACDPlayer::Registry->prefs->get('cache_cap_gb') * 1024**3);
	$r->addResult('free_bytes',  $cache->freeBytes);
	$r->addResult('binary',      Plugins::SACDPlayer::Registry->binary ? 1 : 0);
	$r->addResult('busy',        $x->busy);
	$r->addResult('queued',      scalar @{ $x->queued });
	$r->addResult('low_disk',    $cache->lowOnDisk);
	my $i = 0;
	for my $alb (@{ $cache->albumsByAge }) {
		my $idx = $cache->loadIndex($alb->{key}) || {};
		$r->addResultLoop('albums', $i, $_, $alb->{$_}) for qw(key area bytes last_access);
		$r->addResultLoop('albums', $i, 'iso',   $idx->{iso} || '');
		$r->addResultLoop('albums', $i, 'title', ($idx->{toc}{title} || '') . " ($alb->{area})");
		$i++;
	}
	$r->setStatusDone;
}

sub status {
	my ($r) = @_;
	my ($key, $area, $iso) = resolveTarget($r->getParam('_target')) or return _fail($r, 'unknown target');
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my $idx = $cache->loadIndex($key) or return _fail($r, 'no index for target');
	my ($a) = grep { $_->{area} eq $area } @{ $idx->{toc}{areas} || [] };
	$r->addResult('key', $key); $r->addResult('area', $area); $r->addResult('title', $idx->{toc}{title});
	my $i = 0;
	for my $t (@{ $a ? $a->{tracks} : [] }) {
		my $slot = sprintf('%s/%02d', $area, $t->{number});
		my $st   = $idx->{tracks}{$slot} || {};
		$r->addResultLoop('tracks', $i, 'number', $t->{number});
		$r->addResultLoop('tracks', $i, 'state',  $cache->trackState($key, $area, $t->{number}));
		$r->addResultLoop('tracks', $i, 'bytes',  $st->{bytes} || 0);
		$r->addResultLoop('tracks', $i, 'error',  $st->{error} || '');
		$i++;
	}
	$r->addResult('success', 1);
	$r->setStatusDone;
}

# Shared prepare/evict logic used by both the JSON-RPC handlers and the settings page.
# Returns (1) on success or (0, 'error text') on failure.
sub prepareTarget {
	my ($target) = @_;
	my ($key, $area, $iso) = resolveTarget($target) or return (0, 'unknown target');
	return (0, 'sacd_extract missing') unless Plugins::SACDPlayer::Registry->binary;
	Plugins::SACDPlayer::Registry->extractor->requestAlbum($iso, $area, 2);
	Plugins::SACDPlayer::Plugin::armTick() if defined &Plugins::SACDPlayer::Plugin::armTick;
	return (1);
}

sub evictTarget {
	my ($target) = @_;
	my ($key, $area) = resolveTarget($target) or return (0, 'unknown target');
	Plugins::SACDPlayer::Registry->extractor->cancelAlbum($key, $area);
	Plugins::SACDPlayer::Registry->cache->evictAlbum($key, $area);
	return (1);
}

sub prepare {
	my ($r) = @_;
	my ($ok, $err) = prepareTarget($r->getParam('_target'));
	return _fail($r, $err) unless $ok;
	$r->addResult('success', 1); $r->setStatusDone;
}

sub evict {
	my ($r) = @_;
	my ($ok, $err) = evictTarget($r->getParam('_target'));
	return _fail($r, $err) unless $ok;
	$r->addResult('success', 1); $r->setStatusDone;
}

1;
