package Slim::Web::HTTP::CSRF;
# Stub: no CSRF protection at all - protect* return their argument unchanged.
sub protectName { $_[1] }
sub protectURI { $_[1] }
1;
