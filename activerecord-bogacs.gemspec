# coding: utf-8

Gem::Specification.new do |gem|
  gem.name = 'activerecord-bogacs'

  path = File.expand_path('lib/active_record/bogacs/version.rb', File.dirname(__FILE__))
  gem.version = File.read(path).match( /.*VERSION\s*=\s*['"](.*)['"]/m )[1]

  gem.authors = ['Karol Bucek']
  gem.email = ['self@kares.org']
  gem.description = %q{Improved ActiveRecord::ConnectionAdapters::ConnectionPool alternatives}
  gem.summary = 'Bogacs contains several pool implementations that can be used as a replacement ' <<
  "for ActiveRecord's built-in pool, e.g. DefaultPool is an upstream tuned version with an API " <<
  'that is compatible with older AR versions.' <<
  "\n\nNOTE: you'll need concurrent-ruby or thread_safe gem."
  gem.homepage = "http://github.com/kares/activerecord-bogacs"
  gem.licenses = ['MIT']

  gem.files = `git ls-files`.split($/)
  gem.executables = gem.files.grep(%r{^bin/}) { |f| File.basename(f) }
  gem.test_files = gem.files.grep(%r{^test/})
  gem.require_paths = ["lib"]

  gem.add_development_dependency 'concurrent-ruby', '>= 0.9' if RUBY_VERSION.index('1.8') != 0

  gem.add_development_dependency 'rake', '~> 10.3'
  gem.add_development_dependency 'test-unit', '~> 2.5'
end
