use inc::Module::Install;
name 'XML-Convert';
all_from 'lib/XML/Convert.pm';

# requires '';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
use_test_base;
auto_include;
WriteAll;
