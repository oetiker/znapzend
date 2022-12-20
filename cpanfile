requires 'Mojolicious';
requires 'Scalar::Util', '>= 1.45';
requires 'Role::Tiny';
if ($ENV{TEZT}){
  do 'cpanfile.test';
}
