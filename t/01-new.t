use strict;
use warnings;

use Test::More;
use Test::Exception;

use Lavoco::Website;

my @methods = qw( name dev processes base _pid _socket templates _handler start stop );

my $empty;

lives_ok { $empty = Lavoco::Website->new } "instantiated new ok";

foreach my $method ( @methods )
{
	can_ok( $empty, $method );
}



done_testing();
