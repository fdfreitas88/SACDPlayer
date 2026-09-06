package Plugins::SACDPlayer::Plugin;
use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Time::HiRes ();
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Utils::Strings ();
use Slim::Player::ProtocolHandlers;
use Plugins::SACDPlayer::Registry;

my $log = Slim::Utils::Log->addLogCategory({ category => 'plugin.sacdplayer', defaultLevel => 'INFO', description => 'PLUGIN_SACDPLAYER' });
my $tickArmed = 0;

sub getDisplayName { 'PLUGIN_SACDPLAYER' }

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	Plugins::SACDPlayer::Registry->registerTagClass;
	Plugins::SACDPlayer::Registry->cache->recover;
	require Plugins::SACDPlayer::ProtocolHandler;
	Slim::Player::ProtocolHandlers->registerHandler('sacd', 'Plugins::SACDPlayer::ProtocolHandler');
	eval { require Plugins::SACDPlayer::Commands; Plugins::SACDPlayer::Commands->register; 1 } or $log->error("commands not registered: $@");
	if (main::WEBUI()) {
		eval { require Plugins::SACDPlayer::Settings; Plugins::SACDPlayer::Settings->new; 1 } or $log->error("settings not registered: $@");
	}
	$log->warn(Slim::Utils::Strings::string('PLUGIN_SACDPLAYER_MISSING_BINARY')) unless Plugins::SACDPlayer::Registry->binary;
}

# One-second driver for the extractor while it has work; stops itself when idle.
sub armTick {
	return if $tickArmed;
	$tickArmed = 1;
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, \&_tick);
}

sub _tick {
	$tickArmed = 0;
	my $x = Plugins::SACDPlayer::Registry->extractor;
	my $busy = eval { $x->tick };
	if ($@) {
		$log->error("tick failed: $@");
		$busy = $x->busy || @{ $x->queued };
	}
	armTick() if $busy;
}

# Stop the extractor before the timers: otherwise a running sacd_extract outlives the server.
sub shutdownPlugin {
	eval { Plugins::SACDPlayer::Registry->extractor->shutdown; 1 } or $log->error("extractor shutdown failed: $@");
	Slim::Utils::Timers::killTimers(undef, \&_tick);
}

1;
