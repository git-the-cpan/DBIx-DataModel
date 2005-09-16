use strict;
use warnings;
no warnings 'uninitialized';
use DBI;

use Test::More tests => 53;

sub die_ok(&) { my $code=shift; eval {&$code()}; ok($@, $@);}



BEGIN {use_ok("DBIx::DataModel");}

  BEGIN { DBIx::DataModel->Schema('MySchema'); }

ok(MySchema->isa("DBIx::DataModel"), 'Schema defined');

# schemas must derive from main package
die_ok {MySchema->Schema('SubSchema')};


# will not override an existing package
die_ok {DBIx::DataModel->Schema('MySchema');};
die_ok {DBIx::DataModel->Schema('DBI');};

  BEGIN {
    MySchema->Table(Employee   => T_Employee   => qw/emp_id/);
    MySchema->Table(Department => T_Department => qw/dpt_id/);
    MySchema->Table(Activity   => T_Activity   => qw/act_id/);
  }

ok(Employee->isa("MySchema"), 'Table defined');
ok(Employee->can("select"), 'select method defined');

  package Department;
  sub currentEmployees {
    my $self = shift;
    my $currentAct = $self->activities({d_end => [{-is  => undef},
                                                  {"<=" => '01.01.2005'}]});
    return map {$_->employee} @$currentAct;
  }
  
  package main;		# switch back to the 'main' package


is_deeply([Employee->primKey], ['emp_id'], 'primKey');

die_ok {Employee->Table(Foo    => T_Foo => qw/foo_id/)};




  MySchema->Association([qw/Activity   activities * emp_id/],
			[qw/Employee   employee   1 emp_id/]);
  MySchema->Association([qw/Activity   activities * dpt_id/],
			[qw/Department department 1 dpt_id/], 
		        0, "");

ok(Activity->can("employee"),   'Association 1');
ok(Employee->can("activities"), 'Association 2');

  MySchema->View(MyView =>
     "DISTINCT column1 AS c1, t2.column2 AS c2",
     "Table1 AS t1 LEFT OUTER JOIN Table2 AS t2 ON t1.fk=t2.pk",
     {c1 => 'foo', c2 => {-like => 'bar%'}},
     qw/Employee Activity/);


ok(MyView->isa("MySchema"), 'View defined'); 
MyView->can('applyColumnHandlers');
ok(Employee->can('applyColumnHandlers') eq 
   Activity->can('applyColumnHandlers'), 
   'Tables have same meth applyColumnHandlers');
ok(MyView->can('applyColumnHandlers') ne 
   Activity->can('applyColumnHandlers'), 
   'Views have a different meth applyColumnHandlers');


ok(MyView->can("employee"), 'View inherits roles');

  MySchema->ColumnType(Date => 
     fromDB   => sub {$_[0] =~ s/(\d\d\d\d)-(\d\d)-(\d\d)/$3.$2.$1/},
     toDB     => sub {$_[0] =~ s/(\d\d)\.(\d\d)\.(\d\d\d\d)/$3-$2-$1/},
     validate => sub {$_[0] =~ m/(\d\d)\.(\d\d)\.(\d\d\d\d)/});;

  Employee->ColumnType(Date => qw/d_birth/);
  Activity->ColumnType(Date => qw/d_begin d_end/);

  MySchema->NoUpdateColumns(qw/d_modif user_id/);
  Employee->NoUpdateColumns(qw/last_login/);

is_deeply([Employee->noUpdateColumns], 
	  [qw/last_login d_modif user_id/], 'noUpdateColumns');


  Employee->ColumnHandlers(lastname => normalizeName => sub {
			    $_[0] =~ s/\w+/\u\L$&/g
			  });

  Activity->AutoExpand(qw/employee/);

  my $emp = Employee->blessFromDB({firstname => 'Joseph',
				   lastname  => 'BODIN DE BOISMORTIER',
				   d_birth   => '1775-12-16'});
  $emp->applyColumnHandlers('normalizeName');

is($emp->{d_birth}, '16.12.1775', 'fromDB handler');
is($emp->{lastname}, 'Bodin De Boismortier', 'ad hoc handler');


  # test self-referential assoc.
  MySchema->Association([qw/Employee   spouse   0..1 emp_id/],
			[qw/Employee   none     1    spouse_id/]);



SKIP: {
  my $dbh;
  eval {$dbh = DBI->connect('DBI:Mock:', '', '')};
  skip "DBD::Mock does not seem to be installed", 35 if $@ or not $dbh;


  sub sqlLike { # closure on $dbh
    my $sql = quotemeta(shift);
    my $bind = shift;
    my $msg = shift;
    $sql =~ s/(\\?\s)+/\\s+/gs;
    $sql =~ s/\\\(/\\(\\s*/g;
    $sql =~ s/\\\)/\\s*\\)/g;
    my $regex = qr/^\s*$sql\s*$/i;
    my $dbd_last = $dbh->{mock_all_history}[-1];
    like($dbd_last->statement, $regex, "$msg (SQL)");
    is_deeply($dbd_last->bound_params, $bind, "$msg (params)");
    $dbh->{mock_clear_history} = 1;
  }


  die_ok {$emp->dbh($dbh)};

  die_ok {Employee->dbh($dbh)};

  MySchema->dbh($dbh);
  isa_ok($emp->dbh, 'DBI::db', 'dbh handle');

  my $lst;
  $lst = Employee->select;
  sqlLike('SELECT * FROM t_employee', [], 'empty select');

  $lst = Employee->select([qw/firstname lastname emp_id/],
			  {firstname => {-like => 'D%'}});
  sqlLike('SELECT firstname, lastname, emp_id '.
	  'FROM t_employee ' .
	  "WHERE (firstname LIKE ?)", ['D%'], 'like select');


  $lst = Employee->select({firstname => {-like => 'D%'}});
  sqlLike('SELECT * '.
	  'FROM t_employee ' .
	  "WHERE ( firstname LIKE ? )", ['D%'], 'implicit *');


  $lst = Employee->select("firstname AS fn, lastname AS ln",
			  undef,
			  [qw/d_birth/]);


  sqlLike('SELECT firstname AS fn, lastname AS ln '.
	  'FROM t_employee ' .
	  "ORDER BY d_birth", [], 'order_by select');

  $emp->{emp_id} = 999;

  $lst = $emp->activities;

  sqlLike('SELECT * ' .
	  'FROM t_activity ' .
	  "WHERE ( emp_id = ? )", [999], 'activities');


  $lst = $emp->activities([qw/d_begin d_end/]);

  sqlLike('SELECT d_begin, d_end ' .
	  'FROM t_activity ' .
	  "WHERE ( emp_id = ? )", [999], 'activities column list');


  $lst = $emp->activities({d_begin => {">=" => '2000-01-01'}});

  sqlLike('SELECT * ' .
	  'FROM t_activity ' .
	  "WHERE (d_begin >= ? AND emp_id = ?)", ['2000-01-01', 999], 
	    'activities where criteria');

  
  $lst = $emp->activities("d_begin AS db, d_end AS de", {}, [qw/d_begin d_end/]);

  sqlLike('SELECT d_begin AS db, d_end AS de ' .
	  'FROM t_activity ' .
	  "WHERE (emp_id = ?) ".
	  'ORDER BY d_begin, d_end', [999], 
	    'activities order by');


  MyView->select({c3 => 22});

  sqlLike('SELECT DISTINCT column1 AS c1, t2.column2 AS c2 ' .
	  'FROM Table1 AS t1 LEFT OUTER JOIN Table2 AS t2 '.
	  'ON t1.fk=t2.pk ' .
	  'WHERE (c1 = ? AND c2 LIKE ? AND c3 = ?)',
	     ['foo', 'bar%', 22], 'MyView');

  my $view = MySchema->ViewFromRoles(qw/Employee activities department/);
  $view->select("lastname, dpt_name", {gender => 'F'});

  sqlLike('SELECT lastname, dpt_name ' .
	  'FROM t_employee, t_department LEFT OUTER JOIN t_activity ' .
	  'ON t_employee.emp_id=t_activity.emp_id ' .
	  'WHERE ( T_Activity.dpt_id=T_Department.dpt_id AND '.
          'gender = ? )', ['F'], 'association');




  Employee->update(999, {firstname => 'toto', 
			 d_modif => '02.09.2005',
			 d_birth => '01.01.1950',
			 last_login => '01.09.2005'});

  sqlLike('UPDATE t_employee SET d_birth = ?, firstname = ? '.
	  'WHERE (emp_id = ?)', ['1950-01-01', 'toto', 999], 'update');


  Employee->update(     {firstname => 'toto', 
			 d_modif => '02.09.2005',
			 d_birth => '01.01.1950',
			 last_login => '01.09.2005',
			 emp_id => 999});

  sqlLike('UPDATE t_employee SET d_birth = ?, firstname = ? '.
	  'WHERE (emp_id = ?)', ['1950-01-01', 'toto', 999], 'update2');


  $emp->{firstname}  = 'toto'; 
  $emp->{d_modif}    = '02.09.2005';
  $emp->{d_birth}    = '01.01.1950';
  $emp->{last_login} = '01.09.2005';

  my %emp2 = %$emp;

  $emp->update;

  sqlLike('UPDATE t_employee SET d_birth = ?, firstname = ?, lastname = ? '.
	  'WHERE (emp_id = ?)', 
	  ['1950-01-01', 'toto', 'Bodin De Boismortier', 999], 'update3');


  MySchema->AutoUpdateColumns( last_modif => 
    sub{"someUser, someTime"}
  );
  Employee->update(\%emp2);
  sqlLike('UPDATE t_employee SET d_birth = ?, firstname = ?, ' .
	    'last_modif = ?, lastname = ? WHERE (emp_id = ?)', 
	  ['1950-01-01', 'toto', "someUser, someTime", 
	   'Bodin De Boismortier', 999], 'autoUpdate');



  $emp = Employee->blessFromDB({emp_id => 999});
  $emp->delete;
  sqlLike('DELETE FROM t_employee '.
	  'WHERE (emp_id = ?)', [999], 'delete');


  $emp = Employee->blessFromDB({emp_id => 999, spouse_id => 888});
  my $emp2 = $emp->spouse;
  sqlLike('SELECT * ' .
	  'FROM t_employee ' .
	  "WHERE ( emp_id = ? )", [888], 'spouse self-ref assoc.');


};



__END__

TODO: 

hasInvalidFields
expand
autoExpand
AUTOLOAD
document the tests !!


