package Slim::Schema;
use strict;
our @CREATED;   # tests inspect this
sub rs { bless {}, 'Slim::Schema::RSStub' }
package Slim::Schema::RSStub;
sub updateOrCreate { my ($self, $args) = @_; push @Slim::Schema::CREATED, $args; return $args }
sub search { bless {}, 'Slim::Schema::RSStub' }
sub delete_all { 1 }
1;
