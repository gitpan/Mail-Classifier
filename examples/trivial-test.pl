#!/usr/bin/perl -w

use lib '..';
use Mail::Classifier::Trivial;
use Data::Dumper;

srand(23);

my $bb = Mail::Classifier::Trivial->new();

$bb->train( {   'corpora/sa-spam.mbox' => 'SPAM', 
                'corpora/sa-nonspam.mbox' => 'NONSPAM'} );

my %xval = $bb->crossval( 
    {   'folds' => 2, 
        'threshold' => 0.5, 
        'corpus_list' => {  'corpora/sa-spam.mbox' => 'SPAM',
                            'corpora/sa-nonspam.mbox' => 'NONSPAM'} 
    } 
);
 
while ( my ($cat,$href) = each ( %xval ) ) {
	my $sum = 0;
	foreach my $c ( keys %{$href} ) {
		$sum += $href->{$c};
	}
	my $pct = $href->{$cat} / $sum * 100;
	printf ("%s\t: %.2f%%",$cat, $pct);
	foreach my $c ( keys %{$href} ) {
		print "\t\t$c: $href->{$c}";
	}
	print "\n";
}

print Dumper(\%xval) if $ARGV[0];
