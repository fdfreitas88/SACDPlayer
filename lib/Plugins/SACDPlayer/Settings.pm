package Plugins::SACDPlayer::Settings;
use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Slim::Utils::Strings qw(string);
use Slim::Web::HTTP::CSRF;
use Plugins::SACDPlayer::Registry;
require Plugins::SACDPlayer::Commands;

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_SACDPLAYER') }
sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/SACDPlayer/settings/basic.html') }

sub handler {
	my ($class, $client, $params) = @_;
	my $prefs = Plugins::SACDPlayer::Registry->prefs;
	my $message = '';
	if ($params->{saveSettings} && !$params->{prepare} && !$params->{evict}) {
		my $dir = $params->{cache_dir} || '';
		if ($dir ne '' && !-d $dir) { $message = "Folder does not exist: $dir" }
		else {
			$prefs->set('cache_dir', $dir) if $dir ne '';
			for my $k (qw(cache_cap_gb extract_timeout_s min_free_gb)) {
				$prefs->set($k, int($params->{$k})) if defined $params->{$k} && $params->{$k} =~ /^\d+$/;
			}
			$message = Plugins::SACDPlayer::Registry->resetCache
				? 'Settings saved.'
				: 'Settings saved; cache change applies after current extraction';
		}
	}

	if (my $t = $params->{prepare}) {
		my ($ok, $err) = Plugins::SACDPlayer::Commands::prepareTarget($t);
		$message = $err unless $ok;
	}
	if (my $t = $params->{evict}) {
		my ($ok, $err) = Plugins::SACDPlayer::Commands::evictTarget($t);
		$message = $err unless $ok;
	}

	my $cache = Plugins::SACDPlayer::Registry->cache;
	$params->{prefs}       = { map { $_ => $prefs->get($_) } qw(cache_dir cache_cap_gb extract_timeout_s min_free_gb) };
	$params->{message}     = $message;
	$params->{binary}      = Plugins::SACDPlayer::Registry->binary ? 1 : 0;
	$params->{usage_gb}    = sprintf('%.1f', $cache->usageBytes / 1024**3);
	$params->{free_gb}     = sprintf('%.1f', $cache->freeBytes / 1024**3);
	$params->{low_disk}    = $cache->lowOnDisk;
	$params->{busy}        = Plugins::SACDPlayer::Registry->extractor->busy;
	$params->{queued}      = scalar @{ Plugins::SACDPlayer::Registry->extractor->queued };
	$params->{albums}      = [ map { my $idx = $cache->loadIndex($_->{key}) || {}; { %$_, iso => $idx->{iso}, title => ($idx->{toc}{title} || '') . " ($_->{area})", gb => sprintf('%.2f', $_->{bytes} / 1024**3), when => scalar localtime($_->{last_access}) } } reverse @{ $cache->albumsByAge } ];
	return $class->SUPER::handler($client, $params);
}

1;
