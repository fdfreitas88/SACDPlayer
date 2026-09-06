package Plugins::SACDPlayer::Importer;
# Loaded by the external scanner (install.xml <importmodule>). Only registers the tag class.
use strict;
use warnings;
use Plugins::SACDPlayer::Registry;
sub initPlugin { Plugins::SACDPlayer::Registry->registerTagClass; 1 }
1;
