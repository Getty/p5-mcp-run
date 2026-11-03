requires 'JSON::MaybeXS';
requires 'MCP' => '0.15';
requires 'Mojolicious';
requires 'Path::Tiny';
requires 'Text::Trim';

on test => sub {
  requires 'Test::More';
};

# MCP loads JSON::Schema::Tiny, which loads strictures when AUTHOR_TESTING is
# set - and dzil test sets it.
on develop => sub {
  requires 'strictures', '2';
};
