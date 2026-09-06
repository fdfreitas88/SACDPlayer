package Slim::Player::ProtocolHandlers;
# Stub: registerHandler only records the class - no scheme lookup or URL routing.
our %H;
sub registerHandler { $H{$_[1]} = $_[2] }
1;
