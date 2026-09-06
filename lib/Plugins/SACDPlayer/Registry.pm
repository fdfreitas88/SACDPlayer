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

my ($cache, $binary);
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
sub resetCache { undef $cache }
sub binary {
	return $binary if defined $binary;
	require Slim::Utils::Misc;
	$binary = Slim::Utils::Misc::findbin('sacd_extract') || '';
	$log->warn('sacd_extract not found via findbin') unless $binary;
	return $binary;
}
sub _resetBinaryForTests { undef $binary }

sub registerTagClass {
	return if $tagClassRegistered++;
	require Slim::Formats;
	Slim::Formats->init;                              # init() rewrites %tagClasses, so it must run first
	$Slim::Formats::tagClasses{'sacd'} = 'Plugins::SACDPlayer::Format';
	$log->info('registered tag class for type sacd');
}

1;
