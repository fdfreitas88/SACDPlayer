package Slim::Player::ProtocolHandlers;
# Stub: registerHandler/registerURLHandler only record the class - no scheme lookup or URL routing.
our %H;
our @U;
sub registerHandler { $H{$_[1]} = $_[2] }
sub registerURLHandler { push @U, [ $_[1], $_[2] ] }
1;
