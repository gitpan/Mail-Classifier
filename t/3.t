# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 3;
#use Test::More qw( no_plan );
BEGIN { use_ok('Mail::Classifier::GrahamSpam'); srand(23) };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $bb = Mail::Classifier::GrahamSpam->new();
isa_ok($bb,'Mail::Classifier::GrahamSpam','Got the right object back from new');

TODO: {
    local $TODO = "Can't get test to give predictable results with srand yet";
    my %xval = $bb->crossval( 
        {   'folds' => 2, 
            'threshold' => 0.5, 
            'corpus_list' => {  'examples/corpora/sa-spam.mbox' => 'SPAM',
                                'examples/corpora/sa-nonspam.mbox' => 'NONSPAM'} 
        } 
    );

    my %expect = (  'SPAM' => { 'SPAM' => 48, 'NONSPAM' => 2, 'UNK' => 0 }, 
                    'NONSPAM' => { 'SPAM' => 0, 'NONSPAM' => 50, 'UNK' => 0 } );

    is_deeply( \%expect, \%xval, 'Comparing crossval output');
}
