################################################################################
# WeBWorK mod_perl (c) 2000-2002 WeBWorK Project
# $Id$
################################################################################

package WeBWorK::DB::Schema::WW1Hash;
use base qw(WeBWorK::DB::Schema);

=head1 NAME

WeBWorK::DB::Schema::WW1Hash - support access to the set_user and problem_user
tables with a WWDBv1 hash-style backend.

=cut

use strict;
use warnings;
use WeBWorK::DB::Utils qw(record2hash hash2record hash2string string2hash);

use constant TABLES => qw(set_user problem_user);
use constant STYLE  => "hash";

use constant LOGIN_PREFIX => "login<>";
use constant SET_PREFIX   => "set<>";
use constant MAX_PSVN_GENERATION_ATTEMPTS => 200;

################################################################################
# table access functions
################################################################################

sub list($@) {
	my ($self, @keyparts) = @_;
	my ($matchUserID, $matchSetID) = @keyparts[0 .. 1];
	
	# connect
	return unless $self->{driver}->connect("ro");
	
	# get a list of PSVNs that match the userID and setID given
	my @matchingPSVNs;
	if (defined $matchUserID and not defined $matchSetID) {
		@matchingPSVNs = $self->getPSVNsForUser($matchUserID);
	} elsif (defined $matchSetID and not defined $matchUserID) {
		@matchingPSVNs = $self->getPSVNsForSet($matchSetID);
	} elsif (defined $matchUserID and defined $matchSetID) {
		@matchingPSVNs = $self->getPSVN($matchUserID, $matchSetID);
	} else {
		# we need all PSVNs, so we have to do this ourselves.
		@matchingPSVNs =
			grep { m/^\d+$/ }
				keys %{ $self->{driver}->hash() };
	}
	
	# retrieve the strings associated with those PSVNs and retrieve the
	# desired parts of that record
	my @result;
	if ($self->{table} eq "set_user") {
		foreach (@matchingPSVNs) {
			my $string = $self->{driver}->hash()->{$_};
			# the record may have been removed while we were doing other things
			next unless defined $string;
			my $UserSet = $self->string2records($string);
			push @result, [$UserSet->user_id(), $UserSet->set_id()];
		}
	} elsif ($self->{table} eq "problem_user") {
		my $matchProblemID = $keyparts[2];
		foreach (@matchingPSVNs) {
			my $string = $self->{driver}->hash()->{$_};
			# the record may have been removed while we were doing other things
			next unless defined $string;
			my (undef, @UserProblems) = $self->string2records($string);
			foreach (@UserProblems) {
				# if we're looking for a particular problem:
				next if defined $matchProblemID
					and $matchProblemID ne $_->problem_id();
				push @result, [$_->user_id(), $_->set_id(),
					       $_->problem_id()];
			}
		}
	}
	
	# disconnect
	$self->{driver}->disconnect();
	
	return @result;
}

sub exists($@) {
	my ($self, @keyparts) = @_;
	my ($userID, $setID) = @keyparts[0 .. 1];
	
	return 0 unless $self->{driver}->connect("ro");
	
	# get a list of PSVNs that match the userID and setID given
	my @matchingPSVNs;
	if (defined $userID and not defined $setID) {
		@matchingPSVNs = $self->getPSVNsForUser($userID);
	} elsif (defined $setID and not defined $userID) {
		@matchingPSVNs = $self->getPSVNsForSet($setID);
	} elsif (defined $userID and defined $setID) {
		@matchingPSVNs = $self->getPSVN($userID, $setID);
	} else {
		# we need all PSVNs, so we have to do this ourselves.
		@matchingPSVNs =
			grep { m/^\d+$/ }
				keys %{ $self->{driver}->hash() };
	}
	
	my $result = 0;
	if (@matchingPSVNs) {
		if ($self->{table} eq "set_user") {
			# at least one set matched
			$result = 1;
		} elsif ($self->{table} eq "problem_user") {
			my $problemID = $keyparts[2];
			if (defined $problemID) {
				# check each set for a matching problem
				foreach my $PSVN (@matchingPSVNs) {
					my $string = $self->fetchString($PSVN);
					next unless defined $string;
					my @problemIDs = $self->string2IDs($string);
					shift @problemIDs; # remove userID
					shift @problemIDs; # remove setID
					if (grep { $_ eq $problemID } @problemIDs) {
						$result = 1;
						last;
					}
				}
			} else {
				# we'll take ANY problem in ANY set
				$result = 1;
			}
		}
	}
	
	$self->{driver}->disconnect();
	return $result;
}

sub add($$) {
	my ($self, $Record) = @_;
	my $userID = $Record->user_id();
	my $setID = $Record->set_id();
	
	return 0 unless $self->{driver}->connect("rw");
	
	my $PSVN = $self->getPSVN($userID, $setID);
	
	my $result;
	if ($self->{table} eq "set_user") {
		if (defined $PSVN) {
			$self->{driver}->disconnect();
			die "($userID, $setID): UserSet exists.\n";
		}
		my $PSVN = $self->setPSVN($userID, $setID); # create new psvn
		my $string = $self->records2string($Record); # no problems
		$self->storeString($PSVN, $string);
		$result = 1;
	} elsif ($self->{table} eq "problem_user") {
		my $problemID = $Record->problem_id();
		unless (defined $PSVN) {
			$self->{driver}->disconnect();
			die "($userID, $setID): UserSet not found.\n";
		}
		my $string = $self->fetchString($PSVN);
		if (defined $string) {
			my ($Set, @Problems) = $self->string2records($string);
			if (grep { $_->problem_id() eq $problemID } @Problems) {
				$self->{driver}->disconnect();
				die "($userID, $setID, $problemID): UserProblem exists.\n"
			}
			push @Problems, $Record;
			$string = $self->records2string($Set, @Problems);
			$self->storeString($PSVN, $string);
			$result = 1;
		} else {
			$result = 0;
		}
	}
	
	$self->{driver}->disconnect();
	return $result;
}

sub get($@) {
	my ($self, @keyparts) = @_;
	my ($userID, $setID) = @keyparts[0 .. 1];
	# FIXME: move these checks up to DB
	die "userID not specified." unless defined $userID;
	die "setID not specified." unless defined $setID;
	
	return unless $self->{driver}->connect("ro");
	
	my $PSVN = $self->getPSVN($userID, $setID);
	unless (defined $PSVN) {
		$self->{driver}->disconnect();
		return;
	}
	my $string = $self->fetchString($PSVN);
	$self->{driver}->disconnect();
	
	if ($self->{table} eq "set_user") {
		my $UserSet = $self->string2records($string);
		$UserSet->psvn($PSVN);
		return $UserSet;
	} elsif ($self->{table} eq "problem_user") {
		my ($problemID) = $keyparts[2];
		die "problemID not specified." unless defined $problemID;
		my (undef, @UserProblems) = $self->string2records($string);
		# grep returns the number of matches in scalar context, so we have
		# to put it in list context, and pluck out the first (and only)
		# match, so that we can be called in scalar context.
		return (grep { $_->problem_id() eq $problemID } @UserProblems)[0];
	}
}

sub put($$) {
	my ($self, $Record) = @_;
	my $userID = $Record->user_id();
	my $setID = $Record->set_id();
	
	return 0 unless $self->{driver}->connect("rw");
	
	my $PSVN = $self->getPSVN($userID, $setID);
	
	unless (defined $PSVN) {
		$self->{driver}->disconnect();
		die "($userID, $setID): UserSet not found.\n";
	}
	
	my $string = $self->fetchString($PSVN);
	
	my $result;
	if (defined $string) {
		my ($Set, @Problems) = $self->string2records($string);
		if ($self->{table} eq "set_user") {
			$string = $self->records2string($Record, @Problems);
		} elsif ($self->{table} eq "problem_user") {
			my $problemID = $Record->problem_id();
			my $found = 0;
			foreach (@Problems) {
				if ($_->problem_id() eq $problemID) {
					$found = 1;
					$_ = $Record;
				}
			}
			unless ($found) {
				$self->{driver}->disconnect();
				die "($userID, $setID, $problemID): UserProblem not found.\n";
			}
			$string = $self->records2string($Set, @Problems);
		}
		$self->storeString($PSVN, $string);
		$result = 1;
	} else {
		$result = 0;
	}
	
	$self->{driver}->disconnect();
	return $result;
}

sub delete($@) {
	my ($self, $userID, $setID, $problemID) = @_;
	
	return 0 unless $self->{driver}->connect("rw");
	
	# get a list of PSVNs that match the userID and setID given
	my @matchingPSVNs;
	if (defined $userID and not defined $setID) {
		@matchingPSVNs = $self->getPSVNsForUser($userID);
	} elsif (defined $setID and not defined $userID) {
		@matchingPSVNs = $self->getPSVNsForSet($setID);
	} elsif (defined $userID and defined $setID) {
		@matchingPSVNs = $self->getPSVN($userID, $setID);
	} else {
		# we need all PSVNs, so we have to do this ourselves.
		@matchingPSVNs =
			grep { m/^\d+$/ }
				keys %{ $self->{driver}->hash() };
	}
	
	my $result = 0;
	if (@matchingPSVNs) {
		foreach my $PSVN (@matchingPSVNs) {
			# this is tricky. _deleteOne has different behavior
			# depending on the table. for the set_user table, it
			# ignores $problemID and deletes the set with the
			# matching $PSVN. for the problem_user table, it deletes
			# the problem matching $problemID from the set matching
			# $PSVN, or all problems if $problemID is not defined.
			$result = $self->_deleteOne($PSVN, $problemID);
		}
	}
	
	$self->{driver}->disconnect();
	return $result;
}

################################################################################
# deletion helper
################################################################################

sub _deleteOne {
	my ($self, $PSVN, $problemID) = @_;
	
	my $string = $self->fetchString($PSVN);
	return 0 unless defined $string;
	my ($userID, $setID) = $self->string2IDs($string);
	
	my $result = 1;
	if ($self->{table} eq "set_user") {
		$self->deletePSVN($userID, $setID);
		$self->deleteString($PSVN);
		$result = 1;
	} elsif ($self->{table} eq "problem_user") {
		my ($Set, @Problems) = $self->string2records($string);
		my $length = @Problems;
		if (defined $problemID) {
			@Problems = grep { not $_->problem_id() eq $problemID } @Problems;
		} else {
			@Problems = (); # delete all problems
		}
		if ($length != @Problems) {
			# removed one, store the new version
			$string = $self->records2string($Set, @Problems);
			$self->storeString($PSVN, $string);
		}
		$result = 1;
	}
	
	return $result;
}

################################################################################
# matching function
################################################################################

# FIXME: we could factor out the code that decides what PSVNs to select.

################################################################################
# table multiplexing functions
#  both the set_user and problem_user tables are stored in one hash, keyed by
#  PSVN. we need to be able to split a hash value into two records, and combine
#  two records into a single hash value.
################################################################################

sub string2IDs {
	my ($self, $string) = @_;
	my %hash = string2hash($string);
	my $userID = $hash{stlg};
	my $setID = $hash{stnm};
	my @problemIDs = grep { s/^pfn// } keys %hash;
	return $userID, $setID, @problemIDs;
}

# here's a little issue... the schema API seems to allow the user to specify
# what record class to use (per instance), but since WW1Hash has to monkey with
# multiple record types in the same instance, we have to hardcode record
# classes. this is fine, as long as no one tries to use non-default record
# classes. This is bad.
# (FIXME: we can say $self->{db}->{problem_user}->{record} instead)
sub string2records($$) {
	my ($self, $string) = @_;
	my %hash = string2hash($string);
	my $UserSet = hash2record("WeBWorK::DB::Record::UserSet", %hash);
	return $UserSet unless wantarray;
	my @UserProblems;
	foreach (grep { s/^pfn// } keys %hash) {
		my %problemHash = (
			"stlg"  => $hash{stlg},
			"stnm"  => $hash{stnm},
			"#"     => $_,
			"pfn#"  => $hash{"pfn$_"},
			"pva#"  => $hash{"pva$_"},
			"pmia#" => $hash{"pmia$_"},
			"pse#"  => $hash{"pse$_"},
			"pst#"  => $hash{"pst$_"},
			"pat#"  => $hash{"pat$_"},
			"pan#"  => $hash{"pan$_"},
			"pca#"  => $hash{"pca$_"},
			"pia#"  => $hash{"pia$_"},
		);
		push @UserProblems, hash2record("WeBWorK::DB::Record::UserProblem", %problemHash);
	}
	return $UserSet, @UserProblems;
}

sub records2string($$@) {
	my ($self, $Set, @Problems) = @_;
	my %hash = record2hash($Set);
	foreach (@Problems) {
		my %problemHash = record2hash($_);
		my $n = $problemHash{"#"};
		foreach ('pfn#', 'pva#', 'pmia#', 'pse#', 'pst#', 'pat#', 'pan#', 'pca#', 'pia#') {
			my $realKey = $_;
			$realKey =~ s/#/$n/;
			$hash{$realKey} = $problemHash{$_};
		}
	}
	return hash2string(%hash);
}

################################################################################
# PSVN and index functions
#  the PSVN pseudo-table and the set and user indexes are not visible to the
#  API, but we need to be able to update them to remain compatible with WWDBv1.
################################################################################

# retrieves a list of existing PSVNs from the user PSVN index
sub getPSVNsForUser($$) {
	my ($self, $userID) = @_;
	my $setsForUser = $self->fetchString(LOGIN_PREFIX.$userID);
	return unless defined $setsForUser;
	my %sets = string2hash($setsForUser);
	return values %sets;
}

# retrieves a list of existing PSVNs from the set PSVN index
sub getPSVNsForSet($$) {
	my ($self, $setID) = @_;
	my $usersForSet = $self->fetchString(SET_PREFIX.$setID);
	return unless defined $usersForSet;
	my %users = string2hash($usersForSet);
	return values %users;
}

# retrieves an existing PSVN from the PSVN indexes
sub getPSVN($$$) {
	my ($self, $userID, $setID) = @_;
	my $setsForUser = $self->{driver}->hash()->{LOGIN_PREFIX.$userID};
	my $usersForSet = $self->{driver}->hash()->{SET_PREFIX.$setID};
	# * if setsForUser is non-empty, then there are sets built for this
	#   user.
	# * if usersForSet is non-empty, then this set has been built for at
	#   least one user.
	# * if either are empty, it is guaranteed that this set has not been
	#   built for this user.
	return unless defined $setsForUser and defined $usersForSet; #shut up, shut up, shut up!
	return unless $setsForUser and $usersForSet;
	my %sets = string2hash($setsForUser);
	my %users = string2hash($usersForSet);
	return unless exists $sets{$setID} and exists $users{$userID};
	# more sanity checks: the following should never happen.
	# if they do, run screaming for the hills.
	if (defined $sets{$setID} and not defined $users{$userID}) {
		die "PSVN indexes inconsistent: set exists in user index ",
		    "but user does not exist in set index.";
	} elsif (not defined $sets{$setID} and defined $users{$userID}) {
		die "PSVN indexes inconsistent: user exists in set index ",
		    "but set does not exist in user index.";
	} elsif ($sets{$setID} != $users{$userID}) {
		die "PSVN indexes inconsistent: user index and set index ",
		    "gave different PSVN values.";
	}
	return $sets{$setID};
}

# generates a new PSVN, updates the PSVN indexes, returns the PSVN
# if there is already a PSVN for this pair, reuse it
sub setPSVN($$$) {
	my ($self, $userID, $setID) = @_;
	my $PSVN = $self->getPSVN($userID, $setID);
	unless ($PSVN) {
		# yeah, create a new PSVN here
		my $min_psvn = 10**($self->{params}->{psvnLength} - 1);
		my $max_psvn = 10**$self->{params}->{psvnLength} - 1;
		my $attempts = 0;
		do {
			if (++$attempts > MAX_PSVN_GENERATION_ATTEMPTS) {
				die "failed to find an unused PSVN within ",
				    MAX_PSVN_GENERATION_ATTEMPTS, " attempts.";
			}
			$PSVN = int(rand($max_psvn-$min_psvn+1)) + $min_psvn;
		} while ($self->fetchString($PSVN));
		# get current PSVN indexes
		my $setsForUser = $self->{driver}->hash()->{LOGIN_PREFIX.$userID};
		my $usersForSet = $self->{driver}->hash()->{SET_PREFIX.$setID};
		my %sets = string2hash($setsForUser);  # sets built for user $userID
		my %users = string2hash($usersForSet); # users for which set $setID has been built
		# insert new PSVN into each hash
		$sets{$setID} = $PSVN;
		$users{$userID} = $PSVN;
		# re-encode the hashes
		$setsForUser = hash2string(%sets);
		$usersForSet = hash2string(%users);
		# store 'em in the database
		$self->{driver}->hash()->{LOGIN_PREFIX.$userID} = $setsForUser;
		$self->{driver}->hash()->{SET_PREFIX.$setID} = $usersForSet;
	};
	return $PSVN;
}

# remove an existing PSVN from the PSVN indexes
sub deletePSVN($$$) {
	my ($self, $userID, $setID) = @_;
	my $PSVN = $self->getPSVN($userID, $setID);
	return unless $PSVN;
	my $setsForUser = $self->{driver}->hash()->{LOGIN_PREFIX.$userID};
	my $usersForSet = $self->{driver}->hash()->{SET_PREFIX.$setID};
	my %sets = string2hash($setsForUser);  # sets built for user $userID
	my %users = string2hash($usersForSet); # users for which set $setID has been built
	delete $sets{$setID};
	delete $users{$userID};
	$setsForUser = hash2string(%sets);
	$usersForSet = hash2string(%users);
	if ($setsForUser) {
		$self->{driver}->hash()->{LOGIN_PREFIX.$userID} = $setsForUser;
	} else {
		delete $self->{driver}->hash()->{LOGIN_PREFIX.$userID};
	}
	if ($usersForSet) {
		$self->{driver}->hash()->{SET_PREFIX.$setID} = $usersForSet;
	} else {
		delete $self->{driver}->hash()->{SET_PREFIX.$setID};
	}
	return 1;
}

################################################################################
# hash string interface
################################################################################

sub fetchString($$) {
	my ($self, $PSVN) = @_;
	my $string = $self->{driver}->hash()->{$PSVN};
	return $string;
}


sub storeString($$$) {
	my ($self, $PSVN, $string) = @_;
	$self->{driver}->hash()->{$PSVN} = $string;
}

sub deleteString($$) {
	my ($self, $PSVN) = @_;
	delete $self->{driver}->hash()->{$PSVN};
}

1;
