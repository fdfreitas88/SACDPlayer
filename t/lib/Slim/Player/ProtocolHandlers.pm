package Slim::Player::ProtocolHandlers;
our %H;
sub registerHandler { $H{$_[1]} = $_[2] }
1;
