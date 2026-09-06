package Slim::Control::Request;
# Stub: addDispatch only records the dispatch - no request execution or notification.
our %D;
sub addDispatch { $D{ join ' ', @{$_[0]} } = $_[1] }
1;
