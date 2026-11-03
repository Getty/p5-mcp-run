requires 'JSON::MaybeXS';
requires 'MCP' => '0.15';
requires 'Mojolicious';
requires 'Path::Tiny';
requires 'Text::Trim';

on test => sub {
  requires 'Test::More';
};
