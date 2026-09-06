package Slim::Control::Request;
our %D;
sub addDispatch { $D{ join ' ', @{$_[0]} } = $_[1] }
1;
