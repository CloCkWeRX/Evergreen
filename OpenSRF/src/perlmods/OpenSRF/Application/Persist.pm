package OpenSRF::Application::Persist;
use base qw/OpenSRF::Application/;
use OpenSRF::Application;

use OpenSRF::Utils::SettingsClient;
use OpenSRF::EX qw/:try/;
use OpenSRF::Utils::Logger;
use JSON;
use DBI;

use vars qw/$dbh $sc $log/;

sub initialize {
	$log = 'OpenSRF::Utils::Logger';
}

sub child_init {
	$sc = OpenSRF::Utils::SettingsClient->new;

	my $dbfile = $sc->config_value( apps => persist => app_settings => 'dbfile');
	unless ($dbfile) {
		throw OpenSRF::EX::PANIC ("Can't find my dbfile for SQLite!");
	}

	$dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","");
	$dbh->{AutoCommit} = 1;
	$dbh->{RaiseError} = 1;

	eval {
		$dbh->do( <<"		SQL" );
			CREATE TABLE storage (
				id	INT PRIMARY KEY,
				name_id	INT,
				value	TEXT
			);
		SQL

		$dbh->do( <<"		SQL" );
			CREATE TABLE store_name (
				id	INT PRIMARY KEY,
				name	TEXT UNIQUE
			);
		SQL
	};
}

sub create_store {
	my $self = shift;
	my $client = shift;

	my $name = shift || '';

	eval {
		my $sth = $dbh->prepare("INSERT INTO store_name (name) VALUES (?)");
		$sth->execute($name);
		$sth->finish;
	};
	if ($@) {
		throw OpenSRF::EX::WARN ("Duplicate key:  object name [$name] already exists!  " . $dbh->errstr);
	}

	unless ($name) {
		my $last_id = $dbh->last_insert_id();
		$name = 'AUTOGENERATED!!'.$last_id;
		$dbh->do("UPDATE store_name SET name = '$name' WHERE id = '$last_id';");
	}

	return $name;
}
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.slot.create',
	method => 'create_store',
	argc => 2,
);



sub add_item {
	my $self = shift;
	my $client = shift;

	my $name = shift or throw OpenSRF::EX::WARN ("No queue name specified!");
	my $value = shift || '';

	my $name_id = _get_name_id($name);
	
	if ($self->api_name =~ /object/) {
		$dbh->do('DELETE FROM storage WHERE name_id = ?', {}, $name_id);
	}

	$dbh->do('INSERT INTO storage (name_id,value) VALUES (?,?);', {}, $name_id, JSON->perl2JSON($value));

	return 0 if ($dbh->err);
	return $name;
}
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.object.set',
	method => 'add_item',
	argc => 2,
);
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.queue.push',
	method => 'add_item',
	argc => 2,
);
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.stack.push',
	method => 'add_item',
	argc => 2,
);

sub _get_name_id {
	my $name = shift or throw OpenSRF::EX::WARN ("No queue name specified!");

	my $name_id = $dbh->selectcol_arrayref("SELECT id FROM store_name WHERE name = ?", {}, $name)->[0];

	unless ($name_id) {
		throw OpenSRF::EX::WARN ("Object name [$name] does not exist!");
	}

	return $name_id;
}

sub destroy_store {
	my $self = shift;
	my $client = shift;

	my $name = shift;

	my $name_id = _get_name_id($name);

	$dbh->do("DELETE FROM storage WHERE name_id = ?", {}, $name_id);
	$dbh->do("DELETE FROM store_name WHERE id = ?", {}, $name_id);
}
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.slot.destroy',
	method => 'destroy_store',
	argc => 1,
);

sub _flush_by_name {
	my $name = shift;
	if ($name =~ /^AUTOGENERATED!!/) {
		my $count = $dbh->selectrow_arrayref("SELECT COUNT(*) FROM storage WHERE name = ?", {}, $name);
		if (!ref($count) || $$count[0] == 0) {
			$dbh->do("DELETE FROM store_name WHERE name = ?", {}, $name);
		}
	}
}
	
sub pop_queue {
	my $self = shift;
	my $client = shift;

	my $name = shift or throw OpenSRF::EX::WARN ("No queue name specified!");
	my $name_id = _get_name_id($name);

	my $value = $dbh->selectrow_arrayref('SELECT id, value FROM storage WHERE name_id = ? ORDER BY id ASC LIMIT 1', {}, $name_id);
	$dbh->do('DELETE FROM storage WHERE id = ?',{}, $value->[0]);

	_flush_by_name($name);
	return JSON->JSON2perl( $value->[1] );
}
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.queue.pop',
	method => 'pop_queue',
	argc => 1,
);


sub shift_stack {
	my $self = shift;
	my $client = shift;

	my $name = shift or throw OpenSRF::EX::WARN ("No queue name specified!");
	my $name_id = _get_name_id($name);

	my $value = $dbh->selectrow_arrayref('SELECT id, value FROM storage WHERE name_id = ? ORDER BY id DESC LIMIT 1', {}, $name_id);
	$dbh->do('DELETE FROM storage WHERE id = ?',{}, $value->[0]);

	_flush_by_name($name);
	return JSON->JSON2perl( $value->[1] );
}
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.stack.pop',
	method => 'shift_stack',
	argc => 1,
);

sub get_object {
	my $self = shift;
	my $client = shift;

	my $name = shift or throw OpenSRF::EX::WARN ("No queue name specified!");
	my $name_id = _get_name_id($name);

	my $value = $dbh->selectrow_arrayref('SELECT name_id, value FROM storage WHERE name_id = ? ORDER BY id DESC LIMIT 1', {}, $name_id);
	$dbh->do('DELETE FROM storage WHERE name_id = ?',{}, $value->[0]);

	_flush_by_name($name);
	return JSON->JSON2perl( $value->[1] );
}
__PACKAGE__->register_method(
	api_name => 'opensrf.persist.object.get',
	method => 'shift_stack',
	argc => 1,
);

1;
