#!/usr/bin/perl -w

use lib '..';
use Mail::Classifier::GrahamSpam;
use Data::Dumper; 

srand(23);
my %xval;

my $bb = Mail::Classifier::GrahamSpam->new( { minimum_word_prob => 0.1,
                                              maximum_word_prob => 0.9,
                                              number_of_predictors => 5 } );

$bb->train( {   'corpora/sa-spam.mbox' => 'SPAM', 
                'corpora/sa-nonspam.mbox' => 'NONSPAM'} );
		
%xval = $bb->classify( 
    {   'threshold' => 0.9, 
        'corpus_list' => {  'corpora/sa-spam.mbox' => 'SPAM',
                            'corpora/sa-nonspam.mbox' => 'NONSPAM'} 
    } 
);

print "Results of classify:\n";
while ( my ($cat,$href) = each ( %xval ) ) {
	my $sum = 0;
	foreach my $c ( keys %{$href} ) {
		$sum += $href->{$c};
	}
	my $pct = $href->{$cat} / $sum * 100;
	printf ("%s\t: %.2f%%",$cat, $pct);
	foreach my $c ( keys %{$href} ) {
		print "\t$c: $href->{$c}";
	}
	print "\n";
}

%xval = ();
%xval = $bb->crossval( 
    {   'folds' => 2, 
        'threshold' => 0.9, 
        'corpus_list' => {  'corpora/sa-spam.mbox' => 'SPAM',
                            'corpora/sa-nonspam.mbox' => 'NONSPAM'} 
    } 
);
 
print "Results of crossval:\n";
while ( my ($cat,$href) = each ( %xval ) ) {
	my $sum = 0;
	foreach my $c ( keys %{$href} ) {
		$sum += $href->{$c};
	}
	my $pct = $href->{$cat} / $sum * 100;
	printf ("%s\t: %.2f%%",$cat, $pct);
	foreach my $c ( keys %{$href} ) {
		print "\t$c: $href->{$c}";
	}
	print "\n";
}

print Dumper(\%xval) if $ARGV[0];
