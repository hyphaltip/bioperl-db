# -*-Perl-*-
# $Id$

use lib 't';

BEGIN {
    # to handle systems with no installed Test module
    # we include the t dir (where a copy of Test.pm is located)
    # as a fallback
    eval { require Test; };
    use Test;    
    plan tests => 59;
}

use DBTestHarness;
use Bio::SeqIO;
use Bio::Root::IO;

$biosql = DBTestHarness->new("biosql");
$db = $biosql->get_DBAdaptor();
ok $db;

my $seqio = Bio::SeqIO->new('-format' => 'genbank',
                            '-file' => Bio::Root::IO->catfile(
                                                   't','data','test.genbank'));

my ($seq, $pseq);
my @seqs = ();
my @arr = ();

eval {
    my $pk = -1;
    while($seq = $seqio->next_seq()) {
        $pseq = $db->create_persistent($seq);
        $pseq->namespace("mytestnamespace");
        $pseq->create();
        ok $pseq->primary_key();
        ok $pseq->primary_key() != $pk;
        $pk = $pseq->primary_key();
        push(@seqs, $pseq);
    }
    ok (scalar(@seqs), 4);
    $pseq = $seqs[@seqs-1];

    $seqadp = $db->get_object_adaptor("Bio::SeqI");
    ok $seqadp;

    # re-fetch from database
    $pseq = $seqadp->find_by_primary_key($pseq->primary_key());
    
    # features
    @arr = $pseq->top_SeqFeatures();
    ok (scalar(@arr), 26);

    # references
    @arr = $pseq->annotation()->get_Annotations("reference");
    ok (scalar(@arr), 1);

    # all feature qualifier/value pairs
    @arr = ();
    foreach my $feat ($pseq->top_SeqFeatures()) {
        foreach ($feat->all_tags()) {
            push(@arr, $feat->each_tag_value($_));
        }
    }
    ok (scalar(@arr), 38);

    # delete all features
    foreach my $feat ($pseq->top_SeqFeatures()) {
        ok ($feat->remove(), 1);
    }

    # delete all references
    foreach my $ref ($pseq->annotation()->get_Annotations("reference")) {
        ok ($ref->remove(), 1);
    }

    # re-fetch sequence and retest
    $pseq = $seqadp->find_by_primary_key($pseq->primary_key());
    
    # features
    @arr = $pseq->top_SeqFeatures();
    ok (scalar(@arr), 0);

    # references
    @arr = $pseq->annotation()->get_Annotations("reference");
    ok (scalar(@arr), 0);

    # test removing associations:

    # add the same comment to both seq0 and seq1
    my $cmt = Bio::Annotation::Comment->new(
                                        -tagname => "comment",
                                        -text => "this is a simple comment");
    # add the same simple value to both seq0 and seq1
    my $sv = Bio::Annotation::SimpleValue->new(-tagname => "Fancy",
                                               -value => "a simple value");
    $seqs[0]->annotation->add_Annotation($cmt);
    $seqs[0]->annotation->add_Annotation($sv);
    $seqs[1]->annotation->add_Annotation($cmt);
    $seqs[1]->annotation->add_Annotation($sv);
    ok $seqs[0]->store();
    ok $seqs[1]->store();
    # delete all annotation from seq0 (also shares a reference with seq1)
    ok $seqs[0]->annotation->remove(-fkobjs => [$seqs[0]]);

    # now re-fetch seq0 and seq1 by primary key
    $pseq = $seqadp->find_by_primary_key($seqs[0]->primary_key);
    my $pseq1 = $seqadp->find_by_primary_key($seqs[1]->primary_key);
    # test annotation counts and whether seq1 was unaffected
    ok (scalar($pseq->annotation->get_Annotations()), 0);
    ok (scalar($pseq1->annotation->get_Annotations("reference")), 3);
    ok (scalar($pseq1->annotation->get_Annotations("comment")), 1);
    my ($cmt1) = $pseq1->annotation->get_Annotations("comment");
    ok ($cmt1->text, $cmt->text);
    ok (scalar($pseq1->annotation->get_Annotations("Fancy")), 1);
    my ($sv1) = $pseq1->annotation->get_Annotations("Fancy");
    ok ($sv1->value, $sv->value);
};

print STDERR $@ if $@;

# delete seq
foreach $pseq (@seqs) {
    ok ($pseq->remove(), 1);
}
my $ns = Bio::DB::Persistent::BioNamespace->new(-identifiable => $pseq);
ok $ns = $db->get_object_adaptor($ns)->find_by_unique_key($ns);
ok $ns->primary_key();
ok ($ns->remove(), 1);

