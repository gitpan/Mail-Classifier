# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 2;
#use Test::More qw( no_plan );
BEGIN { use_ok('Mail::Classifier') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $aa = Mail::Classifier->new();
isa_ok($aa,'Mail::Classifier','Got the right object back from new');

