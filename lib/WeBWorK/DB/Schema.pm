################################################################################
# WeBWorK mod_perl (c) 2000-2002 WeBWorK Project
# $Id$
################################################################################

package WeBWorK::DB::Schema;

=head1 NAME

WeBWorK::DB::Schema - schema superclass (to hold documentation)

=head1 SYNOPSIS

FIXME: write synopsis

=head1 DESCRIPTION

FIXME: write description

=head2 Record Identifiers and Keys

Several of the tables used in the WeBWorK database have records that are
identified by the values of a set of fields, rather than by the value of a
single field. Because of this, when identifying a record (in calls to the
C<list>, C<exists>, C<get>, and C<delete> methods), one must specify a list of
values rather than a single value. This is represented in the documentation for
these methods by the expression C<@keyparts>. The values in C<@keyparts>
correspond to the fields returned by the C<KEYFIELDS> method of the table's
record class. If an element of C<@keyparts> is undefined, then the
corresponding field is not used in the match. Some methods require all elements
of C<@keyparts> to be defined. This is noted below.

A "record key", as in the C<list> method, is a reference to a list containing
values which correspond to the the fields returned by the C<KEYFIELDS> method
of the table's record class.

=cut

use strict;
use warnings;

################################################################################
# constructor
################################################################################

=head1 CONSTRUCTOR

=over

=item new($db, $driver, $table, $record, $params)

Creates a schema interface for C<$table>, using the driver interface provided
by C<$driver> and using the record class named in C<$record>. If the C<$driver>
does not support the driver style needed by the schema, an exception is thrown.
C<$params> contains extra information needed by the schema and is schema
dependent. C<$db> is provided so that schemas can query other schemas.

=back

=cut

sub new {
	my ($proto, $db, $driver, $table, $record, $params) = @_;
	my $class = ref($proto) || $proto;
	
	my @supportedTables = $proto->TABLES();
	die "unsupported table (schema supports: @supportedTables)"
		unless grep { $_ eq "*" or $_ eq $table } @supportedTables;
	
	my ($driverStyle, $schemaStyle) = ($driver->STYLE(), $proto->STYLE());
	die "schema/driver style mismatch (driver provides $driverStyle, schema requires $schemaStyle)"
		unless $driverStyle eq $schemaStyle;
	
	my $self = {
		db     => $db,
		driver => $driver,
		table  => $table,
		record => $record,
		params => $params,
	};
	bless $self, $class;
	return $self;
}

=head1 REQUIRED METHODS

=over

=item list(@keyparts)

Returns a list containing the key of each record in the table that matches the
values in C<@keyparts>. Elements of C<@keyparts> may be undefined.

=item exists(@keyparts)

Returns a boolean value representing whether one or more records that match the
values in C<@keyparts> exist in the table. Elements of C<@keyparts> may be
undefined.

=item add($Record)

Attempts to add C<$Record> to the table. C<$Record> must be an instance of the
table's record class. Returns true on success and false on failure (for
example, if the database couldn't be contacted). If a record with the same key
exists, an exception is thrown.

=item get(@keyparts)

Attempts to retrieve the record matching C<@keyparts> from the table. Returns
an instance of the table's record class if there is a match. Returns undef if
no record matches. All elements of C<@keyparts> must be defined.

=item put($Record)

Attempts to replace the record in the table that matches the key of $Record.
Returns true on success and false on failure (for example, if the database
couldn't be contacted). If no such record exists, an exception is thrown.

=item delete(@keyparts)

Attempts to delete the record or records in the table that match C<@keyparts>.
Returns true if the record(s) was successfully deleted or did not exist, and
false if deletion failed. Elements of C<@keyparts> may be undefined.

=back

=cut

1;
