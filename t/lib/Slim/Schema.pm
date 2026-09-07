package Slim::Schema;
# Stub: no database - updateOrCreate only records its arguments in @CREATED.
use strict;
our @CREATED;   # tests inspect this
our %EXISTING;  # url => 1 makes search({url})->count return 1
sub rs { bless {}, 'Slim::Schema::RSStub' }
package Slim::Schema::RSStub;
sub updateOrCreate { my ($self, $args) = @_; push @Slim::Schema::CREATED, $args; return $args }
sub search { my ($self, $q) = @_; bless { n => ($q && $q->{url} && $Slim::Schema::EXISTING{ $q->{url} }) ? 1 : 0 }, 'Slim::Schema::RSStub' }
sub count { $_[0]{n} || 0 }
sub delete_all { 1 }
1;
