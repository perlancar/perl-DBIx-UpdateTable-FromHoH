package DBIx::UpdateTable::FromHoH;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;
use Log::ger;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       update_table_from_hoh
               );

our %SPEC;

sub _eq {
    my ($v1, $v2) = @_;
    my $v1_def = defined $v1;
    my $v2_def = defined $v2;
    return 1 if !$v1_def && !$v2_def;
    return 0 if $v1_def xor $v2_def;
    $v1 eq $v2;
}

$SPEC{update_table_from_hoh} = {
    v => 1.1,
    summary => 'Update database table from hash-of-hash',
    description => <<'_',

Given a table `t1` like this:

    id    col1    col2    col3
    --    ----    ----    ----
    1     a       b       foo
    2     c       c       bar
    3     g       h       qux

this code:

    my $res = update_table_from_hoh(
        dbh => $dbh,
        table => 't1',
        key_column => 'id',
        hoh => {
            1 => {col1=>'a', col2=>'b'},
            2 => {col1=>'c', col2=>'d'},
            4 => {col1=>'e', col2=>'f'},
        },
    );

will perform these SQL queries:

    UPDATE TABLE t1 SET col2='d' WHERE id='2';
    INSERT INTO t1 (id,col1,col2) VALUES (4,'e','f');
    DELETE FROM t1 WHERE id='3';

to make table `t1` become like this:

    id    col1    col2    col3
    --    ----    ----    ----
    1     a       b       foo
    2     c       d       bar
    4     e       f       qux

_
    args => {
        dbh => {
            schema => ['obj*'],
            req => 1,
        },
        table => {
            schema => 'str*',
            req => 1,
        },
        hoh => {
            schema => 'hoh*',
            req => 1,
        },
        key_column => {
            schema => 'str*',
            req => 1,
        },
        data_columns => {
            schema => ['array*', of=>'str*'],
        },
        use_tx => {
            schema => 'bool*',
            default => 1,
        },
    },
};
sub update_table_from_hoh {
    my %args = @_;

    my $dbh = $args{dbh};
    my $table = $args{table};
    my $hoh = $args{hoh};
    my $key_column = $args{key_column};
    my $data_columns = $args{data_columns};
    my $use_tx = $args{use_tx} // 1;

    unless ($data_columns) {
        my %columns;
        for my $key (keys %$hoh) {
            my $row = $hoh->{$key};
            $columns{ $_ }++ for keys %$row;
        }
        $data_columns = [sort keys %columns];
    }

    my @columns = @$data_columns;
    push @columns, $key_column unless grep { $_ eq $key_column } @columns;
    my $columns_str = join(",", @columns);

    $dbh->begin_work if $use_tx;

    my $hoh_table = {};
  GET_ROWS: {
        my $sth = $dbh->prepare("SELECT $columns_str FROM $table");
        $sth->execute;
        while (my $row = $sth->fetchrow_hashref) {
            $hoh_table->{ $row->{$key_column} } = $row;
        }
    }
    my $num_rows_unchanged = keys %$hoh_table;

    my $num_rows_deleted = 0;
  DELETE: {
        for my $key (sort keys %$hoh_table) {
            unless (exists $hoh->{$key}) {
                $dbh->do("DELETE FROM $table WHERE $key_column=?", {}, $key);
                $num_rows_deleted++;
                $num_rows_unchanged--;
            }
        }
    }

    my $num_rows_updated = 0;
  UPDATE: {
        for my $key (sort keys %$hoh) {
            next unless exists $hoh_table->{$key};
            my @changed_columns;
            for my $column (@columns) {
                next if $column eq $key_column;
                unless (_eq($hoh_table->{$key}{$column}, $hoh->{$key}{$column})) {
                    push @changed_columns, $column;
                }
            }
            next unless @changed_columns;
            $dbh->do("UPDATE $table SET ".
                         join(",", map {"$_=?"} @changed_columns).
                         " WHERE $key_column=?",
                     {},
                     (map { $hoh->{$key}{$_} } @changed_columns), $key);
            $num_rows_updated++;
            $num_rows_unchanged--;
        }
    }

    my $num_rows_inserted = 0;
  INSERT: {
        my $placeholders_str = join(",", map {"?"} @columns);
        for my $key (sort keys %$hoh) {
            unless (exists $hoh_table->{$key}) {
                $dbh->do("INSERT INTO $table ($columns_str) VALUES ($placeholders_str)", {}, map {$_ eq $key_column ? $key : $hoh->{$key}{$_}} @columns);
                $num_rows_inserted++;
            }
        }
    }

    $dbh->commit if $use_tx;

    [$num_rows_deleted || $num_rows_inserted || $num_rows_updated ? 200 : 304,
     "OK",
     {
         num_rows_deleted   => $num_rows_deleted,
         num_rows_inserted  => $num_rows_inserted,
         num_rows_updated   => $num_rows_updated,
         num_rows_unchanged => $num_rows_unchanged,
     }];
}

1;
# ABSTRACT:

=head1 DESCRIPTION

Currently only tested on SQLite.


=head1 SEE ALSO

L<DBIx::UpdateHoH::FromTable>

L<DBIx::Compare> to compare database contents.

L<diffdb> from L<App::diffdb> which can compare two database (schema as well as
content) and display the result as the familiar colored unified-style diff.

L<DBIx::Diff::Schema>

=cut
