package Mail::Classifier::GrahamSpam;

use 5.008;
use strict;
use warnings;

# Probably don't need these, since they're mostly used in Mail::Classifier
# but I haven't taken the time to double check
use Fcntl qw(:DEFAULT :flock);        # for file creation flags
use Carp;
use MLDBM::Sync;
use MLDBM qw(MLDBM::Sync::SDBM_File Storable);
use File::Copy;
use Mail::Box::Manager;
use Mail::Address;
use File::Temp;
use File::Spec;
use HTML::Strip;
use HTML::Entities;
use Statistics::Distributions;
use Mail::Classifier;

our @ISA = qw( Mail::Classifier );

our $VERSION = '0.13';

### Initial Documentation ###

=head1 NAME

Mail::Classifier::GrahamSpam - spam classification based on Paul Graham's algorithm

=head1 SYNOPSIS

    use Mail::Classifier::GrahamSpam;
    $bb = Mail::Classifier::GrahamSpam->new();
    $bb->bias( 'NOTSPAM', 2);
    $bb->train( { 'spam.mbox' => 'SPAM', 'notspam.mbox' => 'NOTSPAM' } );
    my ($cat, $prob) = $bb->score( $msg );

=head1 ABSTRACT

Mail::Classifier::GrahamSpam - spam classification based on Paul Graham's algorithm

=head1 DESCRIPTION

This class is a specific implementation of a Mail::Classifier that uses 
Naive Bayesian methods for associating messages with a category.  The
specific implemenation is based on the article "A Plan for Spam" by Paul 
Graham (thus the name).

For classic Graham, make sure to set I<bias> on non-spam to 2.

While this class was designed to classify spam and non-spam, there is no 
underlying limitation that only two categories be used and thus it may
be used for more general purposes as well.  (And should perhaps be renamed in
a subsequent release.)  For example, we might call

    $bb->train ({   'perl.mbox' => 'PERL',
                    'java.mbox' => 'JAVA',
                    'php.mbox'  => 'PHP'    });

in order to train the classifier to identify other categories of mail.

=head1 METHODS THAT ARE EXTENDED IN THIS SUBCLASS

    * new 
    * init
    * forget
    * isvalid
    * parse
    * learn
    * unlearn
    * score

=over 4

=cut

######## PUT CODE HERE ##########

=item I<new> [OPTIONS|FILENAME|CLASSIFIER]

Create a new classifier object, setting any class options by
passing a hash-reference to key/value pairs.  Alternatively, can
be called with a filename from a previous saved classifier, or
another classifier object, in which case the classifier will be cloned,
duplicating all data and datafiles.

    $bb = Mail::Classifier::GrahamSpam->new();
    $bb = Mail::Classifier::GrahamSpam->new( { OPTION1 => 'foo', OPTION2 => 'bar' } );
    $bb = Mail::Classifier::GrahamSpam->new( "/tmp/saved-classifier" );
    $cc = Mail::Classifier::GrahamSpam->new( $bb );

OPTIONS (with default) include:

    debug => 0,                     # Integer debug level
    
    on_disk => 0,                   # if true, will store large tables in 
                                    # scratch db-files, but with poor
                                    # performance 
    
    n_observations_required => 1,   # Ignore words with a count less than this
    
    number_of_predictors => 41,     # Score using this number of words
    
    minimum_word_prob => 0.01,       # Floor for any word's probability

    maximum_word_prob => 0.99,       # Cap for any word's probability
   	
    score_delay => 1,               # Recalculate when learned message count
                                    # exceeds scored message count by this factor

	ignored_tokens => []			# Tokens to ignore while parsing (case insensitive)
	
=cut

sub new {
    my $class = shift;
    $class = ref($class) || $class;
    my $self = $class->SUPER::new( @_ );
    # create the data structure for this subclass to use
    return $self;    
}

=item I<init>

Called during I<new> to initialize the class with default options specific to the 
class.  This includes creating data tables with I<_add_data_table>.

    $self->init( {%options} );

=cut 

sub init {
    my ($self, $opts) = @_;
    my %options =   ( 
        debug => 0,                     # Integer debug level
        on_disk => 0,                   # Use scratch files if true
        n_observations_required => 5,   # Ignore words with a count less than this
        number_of_predictors => 41,     # Score using this number of words
        minimum_word_prob => 0.01,       # Floor for any word's probability
        maximum_word_prob => 0.99,       # Cap for any word's probability
        score_delay => 1,               # Recalculate when learned message count
                                        # exceeds scored message count by this factor
		ignored_tokens => [],			# Ignore these tokens (case insensitively)
        %{$opts}                        # Overwrite defaults with user values
    );
    $self->SUPER::init( \%options );
    # GrahamSpam additional initialization
    $self->_add_data_table('categories');
    $self->_add_data_table('cache_meta');
    $self->_add_data_table('bias');
    $self->_add_data_table('word_score',$self->{options}{on_disk});
    $self->_add_data_table('word_count',$self->{options}{on_disk});
    # Add additional setup
    # number of messages *processed*
    $self->{cache_meta}{msg_count_current} = 0;     
    # number of messages processed as of the last time predictors were updated
    $self->{cache_meta}{msg_count_scored} = 0; 
}

=item I<forget>        

Blanks out the frequency data, resetting the classifier to its initial state.

    $bb->forget;
    
=cut

sub forget {
    my $self = shift;
    $self->LockAll;
    %{$self->{categories}} = ();
    %{$self->{cache_meta}} = ();
    %{$self->{word_count}} = ();
    %{$self->{word_score}} = ();
    %{$self->{bias}} = ();
    $self->{cache_meta}{msg_count_current} = 0;
    $self->{cache_meta}{msg_count_scored} = 0;
    $self->UnLockAll;
}    

=item I<isvalid> MESSAGE        
    
Confirm that a message can be handled -- e.g. text vs attachment, etc.  MESSAGE
is a Mail::Message object. In this version, messages are valid if they are of
MIME-type "text/*"

    $bb->isvalid($msg);

NOTE:  Need to add something to limit by character set?

=cut

sub isvalid { 
    my ($self, $msg) = @_;
    my $rv = 0;
    foreach my $part ($msg->parts('RECURSE')) {
            next if $part->body->decoded->mimeType->mediaType ne "text";
            $rv = 1;
    }
    return $rv;
}

=item I<parse> MESSAGE

Breaks up a message into tokens -- included are subject and x-mailer headers;
the name and e-mail address from a sender/from header (but not the comment,
in case this was re-directed for analysis); and all the body lines from all 
"text" (plain or html) sections of the message.  Returns an array of tokens.
Splits on anything that isn't alphanumeric, single-quote, underscore, 
dollar-sign or dash. Ignores single-character words and words that are all 
numbers.

This parsing could stand to be updated to be more intelligent, preserving 
IP addresses, e-mail, URL's, etc.  Perhaps when I learn Parse::RecDescent.

=cut

sub parse { 
    my ($self, $msg) = @_;
    my @tokens;
    my $text;
	my @ignored_tokens = $self->{options}{ignored_tokens};
	
    # add people from the To, CC, and From fields -- note, comments
    # in addresses are ignored (so as not to wrongly flag messages
    # about redirection when spams are bounced to a collection 
    # address
	$text = "";
	foreach my $person ( ( $msg->to ), ( $msg->cc ) ) {
        if (defined $person) {
            $person->phrase && ( $text .= " " . $person->phrase );
            $person->address && ( $text .= " " . $person->address );
        }
    }
	push @tokens, map { "T $_" } $self->tokenize($text); # tag as 'TO'
	
	$text = "";
	foreach my $person ( $msg->from ) {
        if (defined $person) {
            $person->phrase && ( $text .= " " . $person->phrase );
            $person->address && ( $text .= " " . $person->address );
        }
    }
	push @tokens, map { "F $_" } $self->tokenize($text); # tag as 'FROM'
	
	$text = $msg->subject();
	$text and push @tokens, map { "S $_" } $self->tokenize($text); # tag as 'SUBJ'

	$text = $msg->get('xmailer');
	$text and push @tokens, map { "M $_" } $self->tokenize($text); # tag as 'MAILER'
	
	$text = "";
    foreach my $part ($msg->parts('RECURSE')) {
        next if $part->body->decoded(keep=>1)->mimeType->mediaType ne "text";
		if ($part->body->decoded->mimeType->subType eq "html" ) {
			push @tokens, "C HTML"; # flag html messages
		}
        $text .= $part->body->decoded->string;
    }
	$text and push @tokens, $self->tokenize($text);
	
    return @tokens;
}

sub tokenize {
	my $self = shift;
	my $text = shift;
	my @ignored_tokens = @_;
	my @tokens;
	my %unique_tokens;
	my @temp;
	
	my $HOSTNAME = qr/(?: 	[a-z0-9]\. | [a-z0-9][-a-z0-9]*[a-z0-9]\. )+
					  (?: 	com|net|org|edu|[a-z][a-z]|biz|info|gov|name|
					  		int|mil|museum|coop|aero )/ix;
							
	# pick out particular constructs from HTML
		study $text;
		push @tokens, 	map { m/((?>[^.]+)(\.[^.]+$))/ } # dom.tld and .tld
						map { lc decode_entities($_) }
						$text =~ m!(?:href|src)="\w+://([-\w.]+)!ig, 
		push @tokens, 	map { lc decode_entities($_) } 
						$text =~ m/href="mailto:(.+?)"/ig;
		push @tokens, 	map { lc decode_entities($_) } 
						$text =~ m/lang=(\w+)/ig;
		push @tokens, 	map { lc decode_entities($_) } 
						$text =~ m/color(?:="?|:)\s*([#a-zA-Z0-9]+)/ig;
		push @tokens, 	map { lc decode_entities($_) } 
						$text =~ m/javascript/ig;
		push @tokens, 	map { lc decode_entities($_) } 
						$text =~ m/language:\s*([-a-zA-Z]+)/ig;
		push @tokens, 	map { lc decode_entities($_) } 
						$text =~ m/content\s*=\s*"([^"]+)"/ig;

	# transform text 
		# strip HTML
		my $hs = new HTML::Strip;
		$text = $hs->parse( $text );
		
		# now safe to decode HTML entities
		decode_entities( $text );

		# pick out more special bits in text after decoding
		study $text;
		push @tokens, 	map { m/((?>[^.]+)(\.[^.]+$))/ } # dom.tld and .tld
						map { lc }
						$text =~ m/$HOSTNAME/g;

		push @tokens, 	map { lc } 
						$text =~ m/[-+.\w]+\@$HOSTNAME/g;
		
		# unwind forwarded messages
		$text =~ s/^(?:>+\p{Z}*)+//mg;
		
		# drop punctuation at the ends of words so we can  
		# break on space and keep symbols in words
		# note: this kills remaining \n characters!
		$text =~ s/\p{Punctuation}+(?:[\p{Separator}\p{Control}]|$)/ /g;
		$text =~ s/(?:^|[\p{Separator}\p{Control}])[\p{Punctuation}]+/ /g; 
	
	# split the rest into meaningful tokens
	@temp = split (/[\p{Separator}\p{Control}]+/,$text);    

	# add token and symbol stripped version
	push @tokens, 	map { 	my $t=$_; 
							$t=~s/[^\p{L}\p{M}\p{N}\p{Sc}]//g;
				   			$_ eq $t ? $_ : ($_, "STRP:$t")
						} 
					@temp;
	
	# discard unwanted tokens and get to unique list
	foreach my $word (@tokens) {
		next if (length($word) == 1);
		next unless ( $word =~ /[\p{Letter}\p{Number}]/ ); 
		next if grep(/^$word$/i,@ignored_tokens);
		next if (length($word) > 40);       # skip long (binary?) tokens
		$unique_tokens{$word} = 1;
	}
	
    return keys %unique_tokens;
}


=item I<bias> CATEGORY, [BIAS]

This accessor function gets/sets a bias on a category, effectively multiplying
the weight of the tokens observed in that category.  Paul Graham biased "good" 
tokens by a factor of two to cut down on false positives.  YMMV. Must be > 0 or
will silently fail.

Note: No bias is set by default, as the name of the "good" category is up to
the user.

    $bb->bias( 'NOTSPAM' => 2);
    
=cut

sub bias {
    my ($self,$cat,$bias) = @_;
    if ( $bias && $bias > 0 ) {
        return $self->{bias}{$cat} = $bias;
    } else {
        return $self->{bias}{$cat} ||= 1;
    }
}

=item I<learn> CATEGORY, MESSAGE

=item I<unlearn> CATEGORY, MESSAGE

I<learn> processes a message as an example of a category according to
some algorithm. MESSAGE is a Mail::Message.

I<unlearn> reverses the process, for example to "unlearn" a message that
has been falsely classified.

In this class, messages are tokenized with parse and the results are
added to a count by category for later use by I<updatepredictors>. 


    $bb->learn('SPAM', $msg);
    $bb->unlearn('SPAM', $msg);

=cut

sub learn {
    my $self = shift;
    my ($cat, $msg) = @_;

    $self->{categories}{$cat} = ( $self->{categories}{$cat} || 0 ) + 1;
    $self->{cache_meta}{msg_count_current}++;
    
    my @tokens = $self->parse($msg);
    $self->Lock('word_count');
    foreach my $word ( @tokens ) {
        my $rref = $self->{word_count}{$word};
        $rref->{$cat} = ( $rref->{$cat} || 0 ) + 1;
        $self->{word_count}{$word} = $rref;
    }
    $self->UnLock('word_count');
}   

sub unlearn {
    my $self = shift;
    my ($cat, $msg) = @_;

    ( $self->{categories}{$cat} ||= 0 ) and $self->{categories}{$cat}--; 
    # Still increment the count of messages *processed* as even unlearning
    # may need to trigger updatepredictors()
    $self->{cache_meta}{msg_count_current}++; 

    my @tokens = $self->parse($msg);
    $self->Lock('word_count');
    foreach my $word ( @tokens ) {
        my $rref = $self->{word_count}{$word};
        my $count = ( $rref->{$cat} || 0);
        $rref->{$cat} = $count && $count - 1;
        $self->{word_count}{$word} = $rref;
    }
    $self->UnLock('word_count');
}

=item I<score> MESSAGE [DETAILS]

Takes a message and returns a list of categories and probabilities in
decending order.  MESSAGE is a Mail::Message

DETAILS is a optional 
array to store notes about the details of the
calculation.  DETAILS will be overwritten.

In this class, I<score> uses the probabilities of the top most significant
tokens iteratively over each category and passes them to I<prediction>

    my ($cat, $prob) = $bb->score( $msg );

B<Note:> I<score> will take a long time to execute the first time it is
called, as it will need to call I<updatepredictors> to refresh.

=cut

sub score {
    my ($self, $msg, $dhref) = @_;
    $dhref and @{$dhref} = ();

    $self->updatepredictors
        if (    $self->{cache_meta}{msg_count_current} -
                $self->{cache_meta}{msg_count_scored} >= 
                $self->{options}{score_delay}
            );

    print  "Scoring: " . $msg->get('subject') . "\n"
        if ($self->{options}{debug} >= 10);
    
    my $href = $self->{word_score};
    my @tokens = $self->parse($msg);
    my %predictors=();
    my %significance=();
    my @interesting_words=();
    my %resultshash=();
    
    $self->ReadLock('categories');
    
    # Get probability and significance for tokens in the message
    $self->ReadLock('word_score');
    foreach my $word (@tokens) {
        print  "\tWord: $word\n" 
            if ($self->{options}{debug} >= 15 and defined $href->{$word});
        foreach my $cat ( keys %{$self->{categories}} ) {
            next unless defined $href->{$word};
            my ($prob,$sig) = @{$href->{$word}{$cat}};             
            $predictors{$word}{$cat} = $prob;   # local copy
            $significance{$word} += $sig;       # vector sum
            printf( "\t\tCat: %s\t\tp: %.2f\t\tSig: %.2f\n", $cat, $prob, $sig) 
                if ($self->{options}{debug} >= 15);            
        }
    }
    $self->UnLock('word_score');

    
    # Get the top predictive words
    my $i=0;
    foreach my $key (   sort { $significance{$b} <=> $significance{$a} } 
                        keys %significance
                    ) {
        last if ++$i > $self->{options}{number_of_predictors};
        push @interesting_words, $key;
        if (defined $dhref) {
			my $txt = "";
			for my $c ( keys %{ $predictors{$key} } ) {
				$txt .= " " if $txt;
				$txt .= sprintf("%s:%.2f", $c, $predictors{$key}{$c});
			}
            push @{$dhref}, "$key->($txt)";
        }
    }
    
    # print details if debugging
    if ($self->{options}{debug} >= 10) {
        print "\tTop Predictors:\n";
        for my $word ( @interesting_words ) {
            print "\t\t";
            while ( my ($cat,$prob) = ( each %{$predictors{$word}} ) ) {
                printf "%s\t%.2f%%\t", $cat, $prob;
            }
            print "$word\n";
        }
    }
    
    # make a prediction for each category with the interesting words
    foreach my $cat ( keys %{$self->{categories}} ) {
        my @p=();
        foreach my $word ( @interesting_words ) {
            push @p, $predictors{$word}{$cat}; 
        }
        $resultshash{$cat} = $self->prediction(@p);    
    }

    # return an array of key/prob pairs in descending order
    my @ret=();
    my @sortedcats = sort { $resultshash{$a} < $resultshash{$b} } keys %resultshash;
    foreach my $cat ( @sortedcats ) {
        push @ret, ( $cat, $resultshash{$cat} );
    }
    $self->UnLock('categories');
    return @ret;
}

=item updatepredictors 

Updates the precalculated predictors hash.  This function is called
periodically whenever enough new messages are learned since the 
last time it was called.

Per-token predictions are based on the formula used by Graham:

    prob(bad) =  
                                ( b / nb ) * bb 
                        --------------------------------
                         (g / ng) * gb + (b / nb ) * bb 


    where   b = number of times a token appeared in "bad" messages
            nb = number of bad messages
            bb = bias factor for bad messages
            g = number of times a token appeared in "good" messages
            ng = number of good messages
            gb = bias factor for good messages

except that predictors generalize to the N-category case.

    $self->updatepredictors;
    
=cut

sub updatepredictors {
    my ($self) = @_;

    print "Updating predictors after @{[$self->{cache_meta}{msg_count_current}]} messages\n"
        if $self->{options}{debug} >= 5;

    $self->ReadLock('word_count');
    $self->Lock('word_score');
    $self->{cache_meta}{msg_count_scored} = $self->{cache_meta}{msg_count_current};
    my $min = $self->{options}{minimum_word_prob};
    my $max = $self->{options}{maximum_word_prob};
	
	# Cache biases
	my %biascache;
	foreach my $cat (keys %{$self->{categories}} ) {
		$biascache{$cat} = $self->bias($cat);
	}
	
    while ( my ( $word, $rref ) = each ( %{$self->{word_count}} )) {
        my %ratios = ();
        my $ratio_sum = 0;
        my $n_obs = 0;
        for my $cat ( keys %{$rref} ) {
            $ratios{$cat} =  $rref->{$cat} / $self->{categories}{$cat} * 
                            $biascache{$cat};
            $ratio_sum += $ratios{$cat};
            $n_obs += $rref->{$cat};
        }
        next unless $n_obs >= $self->{options}{n_observations_required};
        my $record = {};
        for my $cat ( keys %{$self->{categories}} ) {
            my $p = ( $ratios{$cat} || 0 ) / $ratio_sum;
            $p >= $min or $p = $min;
            $p <= $max or $p = $max; 
            $record->{$cat} = [ $p, $p**2 ];
        }
        $self->{word_score}{$word} = $record; 
    }
    $self->UnLock('word_score');
    $self->UnLock('word_count');
}

=item prediction ARRAY

I<prediction> takes an array of token probabilities and returns the collective prediction
based on all of them taken together

Overall probability based on N tokens comes from Robinson using Fisher's method:

	P = prbx( -2 * sum(ln(1-f(w))), 2*N)
	Q = prbx( -2 * sum(ln (f(w))), 2*N)
	
    prob(category) = (1 + Q - P) /2

	where prbx is inverse chi-squared probability and f(w) is p(category|word);

    $result = $bb->prediction( @predictors );
    
=cut

sub prediction {
    my ($self, @f) = @_;
    my $N = @f;
   	
    return 0.5 unless $N;

	my ($sum_f, $sum_1_minus_f) = (0,0);
	for (@f) {
		$sum_f += log($_);
		$sum_1_minus_f += log(1 - $_);
	}
	
	my $P = Statistics::Distributions::chisqrprob( 2 * $N, -2 * $sum_1_minus_f );	
	my $Q = Statistics::Distributions::chisqrprob( 2 * $N, -2 * $sum_f );	
	
    return (1 + $Q - $P) / 2;
}

1;
__END__

######## END OF CODE #####################

=back

=head1 PREREQUISITES

See Mail::Classifier

=head1 BUGS

There are always bugs...

=head1 AUTHOR

David Golden, E<lt>david@hyperbolic.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2002 and 2003 by David Golden

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut
