package Slim::Web::Settings;
sub new { bless {}, shift }
sub handler { $_[2] }
1;
