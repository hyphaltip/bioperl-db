# $Id$
#
# BioPerl module for Bio::DB::BioSQL::Oracle::BiosequenceAdaptorDriver
#
# Cared for by Hilmar Lapp <hlapp at gmx.net>
#
# Copyright Hilmar Lapp
#
# You may distribute this module under the same terms as perl itself

#
# (c) Hilmar Lapp, hlapp at gmx.net, 2002.
# (c) GNF, Genomics Institute of the Novartis Research Foundation, 2002.
#
# You may distribute this module under the same terms as perl itself.
# Refer to the Perl Artistic License (see the license accompanying this
# software package, or see http://www.perl.com/language/misc/Artistic.html)
# for the terms under which you may use, modify, and redistribute this module.
# 
# THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#

# POD documentation - main docs before the code

=head1 NAME

Bio::DB::BioSQL::Oracle::BiosequenceAdaptorDriver - DESCRIPTION of Object

=head1 SYNOPSIS

Give standard usage here

=head1 DESCRIPTION

Describe the object here

=head1 FEEDBACK

=head2 Mailing Lists

User feedback is an integral part of the evolution of this and other
Bioperl modules. Send your comments and suggestions preferably to
the Bioperl mailing list.  Your participation is much appreciated.

  bioperl-l@bioperl.org              - General discussion
  http://bioperl.org/MailList.shtml  - About the mailing lists

=head2 Reporting Bugs

Report bugs to the Bioperl bug tracking system to help us keep track
of the bugs and their resolution. Bug reports can be submitted via
email or the web:

  bioperl-bugs@bioperl.org
  http://bugzilla.bioperl.org/

=head1 AUTHOR - Hilmar Lapp

Email hlapp at gmx.net

Describe contact details here

=head1 CONTRIBUTORS

Additional contributors names and emails here

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::DB::BioSQL::Oracle::BiosequenceAdaptorDriver;
use vars qw(@ISA);
use strict;

# Object preamble - inherits from Bio::Root::Root

use Bio::DB::BioSQL::Oracle::BasePersistenceAdaptorDriver;

@ISA = qw(Bio::DB::BioSQL::Oracle::BasePersistenceAdaptorDriver);

# new() is inherited

=head2 insert_object

 Title   : insert_object
 Usage   :
 Function: We override this here in order to omit the insert if there are
           no values. This is because this entity basically represents a
           derived class, and we may simply be dealing with the base class.

 Example :
 Returns : The primary key of the newly inserted record.
 Args    : A Bio::DB::BioSQL::BasePersistenceAdaptor derived object
           (basically, it needs to implement dbh(), sth($key, $sth),
	    dbcontext(), and get_persistent_slots()).
	   The object to be inserted.
           A reference to an array of foreign key objects; if any of those
           foreign key values is NULL (some foreign keys may be nullable),
           then give the class name.


=cut

sub insert_object{
    my $self = shift;
    my ($adp,$obj,$fkobjs) = @_;
    
    # obtain the object's slot values to be serialized
    my $slotvals = $adp->get_persistent_slot_values($obj, $fkobjs);
    # any value present?
    my $isdef;
    foreach (@$slotvals) { $isdef ||= $_; last if $isdef; }
    return $self->SUPER::insert_object(@_) if $isdef;
    return -1;
}

=head2 update_object

 Title   : update_object
 Usage   :
 Function: See parent class. We need to override this here because
           there is no Biosequence object separate from PrimarySeq
           that would hold a primary key. Hence, store()s cannot
           recognize when the Biosequence for a Bioentry already
           exists and needs to be updated, or when it needs to be
           created. The way the code is currently wired, the presence
           of the primary key (stemming from the bioentry) will always
           trigger an update.

           So, what we need to do here is check whether the entry already
           exists and if not delegate to insert_object().
 Example :
 Returns : The number of updated rows
 Args    : A Bio::DB::BioSQL::BasePersistenceAdaptor derived object
           (basically, it needs to implement dbh(), sth($key, $sth),
	    dbcontext(), and get_persistent_slots()).
	   The object to be updated.
           A reference to an array of foreign key objects; if any of those
           foreign key values is NULL (some foreign keys may be nullable),
           then give the class name.


=cut

sub update_object{
    my ($self,$adp,$obj,$fkobjs) = @_;
    
    my $cache_key = 'SELECT UK '.$self;
    my $sth = $adp->sth($cache_key);
    if(! $sth) {
	# create and prepare sql
	my $table = $self->table_name($adp);
	my $ukname = $self->foreign_key_name("Bio::PrimarySeqI");
	my $sql = "SELECT $ukname FROM $table WHERE $ukname = ?";
	$adp->debug("preparing SELECT statement: $sql\n");
	$sth = $adp->dbh()->prepare($sql);
	# and cache it
	$adp->sth($cache_key, $sth);
    }
    # bind parameters
    $sth->bind_param(1, $obj->primary_key());
    # execute and fetch
    $sth->execute();
    my $row = $sth->fetchall_arrayref();
    if(@$row) {
	# exists already, this is an update
	return $self->SUPER::update_object($adp,$obj,$fkobjs);
    } else {
	# doesn't exist yet, this is in fact an insert
	return $self->insert_object($adp,$obj,$fkobjs);
    }
}

=head2 get_biosequence

 Title   : get_biosequence
 Usage   :
 Function: Returns the actual sequence for a bioentry, or a substring of it.
 Example :
 Returns : A string (the sequence or subsequence)
 Args    : The calling persistence adaptor.
           The primary key of the bioentry for which to obtain the sequence.
           Optionally, start and end position if only a subsequence is to be
           returned (for long sequences, obtaining the subsequence from the
           database may be much faster than obtaining it from the complete
           in-memory string, because the latter has to be retrieved first).


=cut

sub get_biosequence{
    my ($self,$adp,$bioentryid,$start,$end) = @_;
    my ($sth, $cache_key, $row);
    my $seqstr;

    if(defined($start)) {
	# statement cached?
	$cache_key = "SELECT BIOSEQ SUBSTR".$adp.(defined($end) ?" 2POS":"");
	$sth = $adp->sth($cache_key);
	if(! $sth) {
	    # we need to create this
	    my $table = $self->table_name($adp);
	    my $seqcol = $self->slot_attribute_map($table)->{"seq"};
	    if(! $seqcol) {
		$self->throw("no mapping for column seq in table $table");
	    }
	    my $ukname = $self->foreign_key_name("Bio::PrimarySeqI");
	    my $sql = "SELECT DBMS_LOB.SUBSTR($seqcol, ";
	    if(defined($end)) {
		$sql .= "?, ?";
	    } else {
		$sql .= "DBMS_LOB.GETLENGTH($seqcol) - ?, ?";
	    }
	    $sql .= ") FROM $table WHERE $ukname = ?";
	    $adp->debug("preparing SELECT statement: $sql\n");
	    $sth = $adp->dbh()->prepare($sql);
	    # and cache it
	    $adp->sth($cache_key, $sth);
	}
	# bind parameters
	if(defined($end)) {
	    $sth->bind_param(1, $end-$start+1);
	} else {
	    $sth->bind_param(1, $start-1);
	}
	$sth->bind_param(2, $start);
	$sth->bind_param(3, $bioentryid);
    } else {
	# statement cached?
	$cache_key = "SELECT BIOSEQ ".$adp;
	$sth = $adp->sth($cache_key);
	if(! $sth) {
	    # we need to create this
	    my $table = $self->table_name($adp);
	    my $seqcol = $self->slot_attribute_map($table)->{"seq"};
	    if(! $seqcol) {
		$self->throw("no mapping for column seq in table $table");
	    }
	    my $ukname = $self->foreign_key_name("Bio::PrimarySeqI");
	    my $sql = "SELECT $seqcol FROM $table WHERE $ukname = ?";
	    $adp->debug("preparing SELECT statement: $sql\n");
	    $sth = $adp->dbh()->prepare($sql);
	    # and cache it
	    $adp->sth($cache_key, $sth);
	}
	# bind parameters
	$sth->bind_param(1, $bioentryid);
    }
    # execute and fetch
    $sth->execute();
    $row = $sth->fetchall_arrayref();
    return (@$row ? $row->[0]->[0] : undef);
}

=head2 bind_param

 Title   : bind_param
 Usage   :
 Function: Binds a parameter value to a prepared statement.

           The reason this method is here is to give RDBMS-specific
           drivers a chance to intercept the parameter
           binding. DBD::Oracle needs to be helped for the seq column.

 Example :
 Returns : the return value of the DBI::bind_param() call
 Args    : the DBI statement handle to bind to
           the index of the column
           the value to bind
           additional arguments to be passed to the sth->bind_param call


=cut

sub bind_param{
   my ($self,$sth,$i,$val,@bindargs) = @_;

   if($val && (length($val) > 4000)) {
       my $h = @bindargs ? $bindargs[-1] : {};
       $h->{ora_field} = 'SEQ';
       push(@bindargs, $h) unless @bindargs;
   }
   # delegate to the inherited version
   return $self->SUPER::bind_param($sth,$i,$val,@bindargs);
}


1;
