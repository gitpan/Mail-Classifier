package Mail::Classifier::Trivial;

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
use Storable;

use Mail::Classifier;

our @ISA = qw( Mail::Classifier );

our $VERSION = '0.11';

### Initial Documentation ###

=head1 NAME

Mail::Classifier::Trivial - a trivial subclass example

=head1 SYNOPSIS

    use Mail::Classifier::Trivial;
    $bb = Mail::Classifier::Trivial->new();
    $bb->train( { SPAM => 'spam.mbox', NOTSPAM => 'notspam.mbox'} );
    %xval = $bb->crossval(2, .8, {SPAM => 'spam.mbox', NOTSPAM => 'notspam.mbox'} );

=head1 ABSTRACT

Mail::Classifier::Trivial is a trivial subclass implementation.

=head1 DESCRIPTION

This class demonstrates an example of subclassing Mail::Classifier to actually
classify mail.  It provides crude random categorization based on training set 
category frequencies.

=head1 METHODS THAT ARE EXTENDED IN THIS SUBCLASS

    * new 
    * init
    * forget
    * isvalid
    * parse
    * learn
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

    $bb = Mail::Classifier->new();
    $bb = Mail::Classifier->new( { OPTION1 => 'foo', OPTION2 => 'bar' } );
    $bb = Mail::Classifier->new( "/tmp/saved-classifier" );
    $cc = Mail::Classifier->new( $bb );
    
This subclass method has no additional options and only adds a data
table to use for frequency counting.  Though it doesn't really need to,
this subclass uses an MLDBM::Sync file.
 
=cut

sub new {
    my $class = shift;
    $class = ref($class) || $class;
    my $self = $class->SUPER::new( @_ );
    # create the data structure for this subclass to use
    return $self;    
}

=item I<init>

Called during I<new> to initialize the class with data tables.

    $self->init( {%options} );

=cut 

sub init {
    my ($self, $opts) = @_;
    $self->SUPER::init( $opts );
    # Trivial additional initialization
    $self->_add_data_table('categories',1);
}

=item I<forget>        

Blanks out the frequency data.

    $bb->forget;
    
=cut

sub forget {
    my $self = shift;
    $self->{categories} = {};
}    

=item I<isvalid> MESSAGE        
    
Confirm that a message can be handled -- e.g. text vs attachment, etc.  MESSAGE
is a Mail::Message object.  In this subclass version, all messages are still valid.

    $bb->isvalid($msg);

=cut

sub isvalid { 1; }

=item I<parse> MESSAGE

Breaks up a message into tokens -- this is just a stub for where/how
class extensions should place parsing.  In this subclass, no parsing
takes place and the function is still a stub.

    $bb->parse($msg);

=cut

sub parse { 1; }

=item I<learn> CATEGORY, MESSAGE

=item I<unlearn> CATEGORY, MESSAGE

I<learn> processes a message as an example of a category according to
some algorithm. MESSAGE is a Mail::Message.

I<unlearn> reverses the process, for example to "unlearn" a message that
has been falsely classified.

In this subclass, these functions only updates a frequency count of messages
by category.

    $bb->learn('SPAM', $msg);
    $bb->unlearn('SPAM', $msg);

=cut

sub learn {
    my $self = shift;
    my ($cat, $msg) = @_;

    $self->Lock('categories');
    # note the tedious load from hash to record as a reminder that this is
    # necessary when using more complicated data structures in MLDBM
    my $record = $self->{categories}{$cat} || 0;
    $record++;
    $self->{categories}{$cat} = $record;
    $self->UnLock('categories');
}

sub unlearn {
    my $self = shift;
    my ($cat, $msg) = @_;

    $self->Lock('categories');
    # note the tedious load from hash to record as a reminder that this is
    # necessary when using more complicated data structures in MLDBM
    my $record = $self->{categories}{$cat} || 0;
    $record && $record--;
    $self->{categories}{$cat} = $record;
    $self->UnLock('categories');
}

=item I<score> MESSAGE        

Takes a message and returns a list of categories and probabilities in
decending order.  MESSAGE is a Mail::Message

In this subclasses returns a single category randomly.

    ($best-cat, $best-cat-prob, @rest) = $bb->score($msg);
    %probs = $bb->score($msg);
    
=cut

sub score {
    my ($self, $msg) = @_;
    my $n = 0;

    $self->ReadLock('categories');
    my ($key, $val);
    while ( ($key, $val) = each %{$self->{categories}} ) {
        $n += $val;
    }
    if ( $n == 0 ) { return ('UNK',1) } # if there's no examples, give up
    my $random = int(rand($n)) + 1;
    my $i = 0;
    while ( ($key, $val) = each %{$self->{categories}} ) {
        $i += $val;
        last if $random <= $i;
    }
    $self->UnLock('categories');
    return ($key,1);
}

1;
__END__

######## END OF CODE #####################

=back

=head1 PREREQUISITES

    MLDBM
    MLDBM::Sync
    Mail::Box::Manager
    Mail::Address

=head1 BUGS

There are always bugs...

=head1 SEE ALSO

Mail::Classifier

=head1 AUTHOR

David Golden, E<lt>david@hyperbolic.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2002 by David Golden

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut
