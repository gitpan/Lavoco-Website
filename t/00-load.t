#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Lavoco::Website' ) || print "Bail out!\n";
}

diag( "Testing Lavoco::Website $Lavoco::Website::VERSION, Perl $], $^X" );
