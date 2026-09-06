package Plugins::SACDPlayer::Registry;
# Shared between the server process (Plugin.pm) and the scanner process (Importer.pm).
use strict;
use warnings;
use File::Spec::Functions qw(catdir);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.sacdplayer');
my $prefs = preferences('plugin.sacdplayer');
my $tagClassRegistered;

sub log { $log }

sub prefs {
	$prefs->init({
		cache_dir         => catdir($ENV{HOME} || '/tmp', 'Library', 'Caches', 'Squeezebox', 'SACDPlayer'),
		cache_cap_gb      => 200,
		extract_timeout_s => 600,
		min_free_gb       => 5,
	});
	return $prefs;
}

sub cacheDir { $_[0]->prefs->get('cache_dir') }

my ($cache, $binary, $extractor);
sub cache {
	my $class = shift;
	return $cache if $cache;
	require Plugins::SACDPlayer::Cache;
	my $p = $class->prefs;
	$cache = Plugins::SACDPlayer::Cache->new(
		dir            => $p->get('cache_dir'),
		cap_bytes      => $p->get('cache_cap_gb') * 1024**3,
		min_free_bytes => $p->get('min_free_gb') * 1024**3,
		log            => $log,
	);
	return $cache;
}
# Returns 1 if the singletons were dropped, 0 if an extraction is in flight (the running
# sacd_extract still writes into the old cache dir, so swapping it out now would strand files).
sub resetCache {
	if ($extractor && ($extractor->busy || @{ $extractor->queued })) {
		$log->info('cache reset deferred: extractor still busy');
		return 0;
	}
	undef $cache;
	undef $extractor;
	return 1;
}
sub binary {
	return $binary if defined $binary;
	require Slim::Utils::Misc;
	$binary = Slim::Utils::Misc::findbin('sacd_extract') || '';
	$binary = '' unless $binary && -x $binary;
	$log->warn('sacd_extract not found via findbin') unless $binary;
	return $binary;
}
sub _resetBinaryForTests { undef $binary }

sub extractor {
	my ($class, %opt) = @_;
	return $extractor if $extractor && !%opt;
	require Plugins::SACDPlayer::Extractor;
	$extractor = Plugins::SACDPlayer::Extractor->new(
		cache => $class->cache, binary => $class->binary, timeout_s => $class->prefs->get('extract_timeout_s'), log => $log,
		($opt{spawn} ? (spawn => $opt{spawn}) : ()),
	);
	return $extractor;
}

sub registerTagClass {
	return if $tagClassRegistered++;
	require Slim::Formats;
	Slim::Formats->init;                              # init() rewrites %tagClasses, so it must run first
	$Slim::Formats::tagClasses{'sacd'} = 'Plugins::SACDPlayer::Format';
	$log->info('registered tag class for type sacd');
}

1;
