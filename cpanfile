# Generated from Makefile.PL using makefilepl2cpanfile

requires 'perl', '5.6.2';

requires 'Carp';
requires 'DateTime::Format::Natural';
requires 'Genealogy::Gedcom::Date', '2.01';
requires 'Object::Configure';
requires 'Params::Get', '0.13';
requires 'Readonly::Values::Months', '0.02';
requires 'Scalar::Util';

on 'test' => sub {
	requires 'Data::Dumper';
	requires 'English';
	requires 'File::Spec';
	requires 'IPC::System::Simple';
	requires 'Test::Carp';
	requires 'Test::CleanNamespaces';
	requires 'Test::Compile';
	requires 'Test::Deep';
	requires 'Test::DescribeMe';
	requires 'Test::Most';
	requires 'Test::Needs';
	requires 'Test::NoWarnings';
	requires 'Test::Warn';
	requires 'WWW::RT::CPAN';
	requires 'strict';
	requires 'warnings';
};

on 'develop' => sub {
	requires 'Devel::Cover';
	requires 'Perl::Critic';
	requires 'Test::Pod';
	requires 'Test::Pod::Coverage';
};
